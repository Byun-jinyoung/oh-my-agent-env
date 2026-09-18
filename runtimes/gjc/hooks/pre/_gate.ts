/**
 * Shared "work-attitude" gate logic for GJC pre_tool_use hooks.
 * Single source of truth imported by write.ts / edit.ts / bash.ts.
 *
 * Enforces the user's most-repeated standing rules DETERMINISTICALLY on every
 * filesystem-mutating tool call (the model cannot ignore a returned { block }):
 *
 *   specExists       합의된 scope/spec 존재   — <specPath> exists & non-empty  (HARD)
 *   specReferenced   spec 참조               — spec was read this session      (FORM)
 *   intentReported   의도 보고 전 mutation 금지 — "INTENT:"/"의도:" line emitted  (FORM)
 *   investigated     조사 없이 구현 금지       — >= minInvestigations reads/searches (FORM)
 *   todoActive       미완 작업 등록 강제        — todo_write 또는 goal(create/resume) 사용   (FORM)
 *
 * The todoActive gate exists so GJC's compaction auto-continue keeps firing:
 * auto-continue only resumes when there is unfinished work (an active goal or
 * pending/in_progress todos). Forcing the model to declare a todo list / goal
 * BEFORE it mutates guarantees that unfinished-work signal exists.
 *
 * NOT enforced: whether a change is semantically WITHIN the spec — that is an
 * LLM judgment, not a machine-decidable pre-tool check.
 *
 * Config (merged: built-in defaults <- user <- project; later wins):
 *   user:    ~/.gjc/agent/hooks/attitude-gate.json
 *   project: <cwd>/.gjc/attitude-gate.json
 * Default `enabled` is FALSE so a global install is a no-op until opted in,
 * and never bricks a project that has no spec.
 */
import { readFileSync } from "fs";
import { join } from "path";

export interface GateConfig {
	enabled: boolean;
	specPath: string;
	minInvestigations: number;
	failClosed: boolean;
	gates: {
		specExists: boolean;
		specReferenced: boolean;
		intentReported: boolean;
		investigated: boolean;
		todoActive: boolean;
	};
}

export const DEFAULT_CONFIG: GateConfig = {
	enabled: false,
	specPath: ".gjc/spec.md",
	minInvestigations: 1,
	failClosed: false,
	// todoActive defaults OFF: a global install must stay a no-op until opted in,
	// and it must never brick a session before the model has learned the workflow.
	gates: { specExists: true, specReferenced: true, intentReported: true, investigated: true, todoActive: false },
};

function readJson(path: string): Partial<GateConfig> | null {
	try {
		return JSON.parse(readFileSync(path, "utf-8"));
	} catch {
		return null;
	}
}

export function mergeConfig(base: GateConfig, over: Partial<GateConfig> | null): GateConfig {
	if (!over) return base;
	return {
		...base,
		...over,
		gates: { ...base.gates, ...(over.gates ?? {}) },
	};
}

export function loadConfig(cwd: string, hookDir?: string): GateConfig {
	let cfg = DEFAULT_CONFIG;
	// User config sits next to this hook set: <configDir>/hooks/attitude-gate.json.
	// Resolve relative to this module so it is correct under any configDir
	// (default ~/.gjc/agent, or an overridden GJC_CODING_AGENT_DIR).
	const dir = hookDir ?? (typeof import.meta?.dir === "string" ? import.meta.dir : "");
	if (dir) cfg = mergeConfig(cfg, readJson(join(dir, "..", "attitude-gate.json")));
	// Project config overrides user config.
	cfg = mergeConfig(cfg, readJson(join(cwd, ".gjc", "attitude-gate.json")));
	return cfg;
}

const INVESTIGATE = new Set(["read", "search", "find", "grep", "list"]);
const INTENT_RE = /(?:^|\n)\s*(?:INTENT|의도)\s*[:：]/i;

// Conservative heuristic: does this bash command write to the filesystem?
// Command-position prefix: start of line or right after a shell separator that
// begins a new simple command (optionally through sudo/env wrappers). Anchoring
// here stops a mutator NAME buried in a path/argument (e.g. a read-only
// `grep ... ~/.bun/install/cache/...`) from being misread as the `install` command.
const CMD_POS = String.raw`(?:^|[\n;&|({]|&&|\|\|)\s*(?:(?:sudo|command|nohup)\s+|\w+=\S+\s+)*`;
const MUTATORS: RegExp[] = [
	/(^|[^0-9&])>>?\s*(?!\/dev\/(null|stdout|stderr)\b)(?!&\d)[^\s&|;<>]/, // redirect to a real file
	new RegExp(CMD_POS + String.raw`tee\b`), // tee is a real command at a command position
	/\bsed\b[^|]*\s-i\b/,
	/\bperl\b[^|]*\s-i\b/,
	new RegExp(CMD_POS + String.raw`(?:cp|mv|install|dd|touch|mkdir|ln|rsync|truncate)\b`),
	/\b(python3?|node|bun)\b[^|]*(open\([^)]*['"][wa]|writeFileSync|fs\.write)/,
];

export function isMutatingBash(cmd: string): boolean {
	return MUTATORS.some(re => re.test(cmd));
}

export interface SessionState {
	investigations: number;
	intentReported: boolean;
	specReferenced: boolean;
	todoActive: boolean;
}

/** Pure: derive attitude signals from session entries. Unit-testable. */
export function scanEntries(entries: any[], specPath: string): SessionState {
	const specName = specPath.split("/").pop() ?? specPath;
	let investigations = 0;
	let intentReported = false;
	let specReferenced = false;
	let todoActive = false;
	for (const e of entries ?? []) {
		if (e?.type !== "message" || e?.message?.role !== "assistant" || !Array.isArray(e.message.content)) continue;
		for (const c of e.message.content) {
			if (c?.type === "toolCall") {
				if (INVESTIGATE.has(c.name)) investigations++;
				const p = c?.arguments?.path;
				if (c.name === "read" && typeof p === "string" && p.includes(specName)) specReferenced = true;
				// Unfinished-work signal for GJC auto-continue: a written todo list, or
				// a goal being created/resumed. complete/drop/get do NOT establish work.
				if (c.name === "todo_write") todoActive = true;
				if (c.name === "goal" && (c?.arguments?.op === "create" || c?.arguments?.op === "resume")) todoActive = true;
			}
			if (c?.type === "text" && typeof c.text === "string" && INTENT_RE.test(c.text)) intentReported = true;
		}
	}
	return { investigations, intentReported, specReferenced, todoActive };
}

/** Pure: given signals + spec text + config, decide block/allow. Unit-testable. */
export function decide(
	state: SessionState,
	specText: string,
	cfg: GateConfig,
	surface: string,
): { block: true; reason: string } | undefined {
	const g = cfg.gates;
	if (g.specExists && !specText) {
		return { block: true, reason: `POLICY[spec]: 합의된 scope/spec 없음 — 구현 전 ${cfg.specPath}에 합의된 범위/명세를 기록하라 (${surface})` };
	}
	if (g.specReferenced && !state.specReferenced) {
		return { block: true, reason: `POLICY[spec]: 합의된 spec 미참조 — 구현 전 ${cfg.specPath}를 read 하라 (${surface})` };
	}
	if (g.intentReported && !state.intentReported) {
		return { block: true, reason: `POLICY[intent]: 의도 보고 전 mutation 금지 — 먼저 'INTENT: <이해한 목표 한 줄>'을 출력하라 (${surface})` };
	}
	if (g.investigated && state.investigations < cfg.minInvestigations) {
		return { block: true, reason: `POLICY[investigate]: 조사 없이 구현 금지 — mutation 전 read/search 최소 ${cfg.minInvestigations}회 (${surface})` };
	}
	if (g.todoActive && !state.todoActive) {
		return { block: true, reason: `POLICY[todo]: 미완 작업 미등록 — mutation 전 todo_write로 할 일 목록을 만들거나 goal(op:create)로 목표를 등록하라 (그래야 세션이 자동으로 이어진다) (${surface})` };
	}
	return undefined;
}

/**
 * Tool-facing entry point. `surface` is "write" | "edit" | "bash".
 * Fail policy: on internal error, honor cfg.failClosed (default fail-open =
 * allow) so a hook bug cannot brick the agent; the error surfaces via the
 * runner's error listeners.
 */
export async function evaluate(
	surface: "write" | "edit" | "bash",
	event: any,
	ctx: any,
): Promise<{ block: true; reason: string } | undefined> {
	const cwd = ctx?.sessionManager?.getCwd?.() ?? process.cwd();
	let cfg: GateConfig;
	try {
		cfg = loadConfig(cwd);
	} catch {
		return undefined; // cannot read config -> do not interfere
	}
	if (!cfg.enabled) return undefined;

	if (surface === "bash") {
		const cmd = (event?.input?.command ?? "") as string;
		if (!isMutatingBash(cmd)) return undefined; // read-only bash passes freely
	}

	try {
		let specText = "";
		try {
			specText = readFileSync(join(cwd, cfg.specPath), "utf-8").trim();
		} catch {
			specText = "";
		}
		const state = scanEntries(ctx?.sessionManager?.getEntries?.() ?? [], cfg.specPath);
		return decide(state, specText, cfg, surface);
	} catch (err) {
		return cfg.failClosed
			? { block: true, reason: `POLICY[gate-error]: attitude gate failed and failClosed=true (${String(err).slice(0, 80)})` }
			: undefined;
	}
}
