/**
 * Shared graft-uptake nudge logic for GJC pre_tool_use hooks.
 * Single source of truth imported by search.ts (filename = tool name so the
 * loose-surface loader routes that tool's `tool_call` here).
 *
 * WHY: graft's own uptake lever is a Claude UserPromptSubmit hook that runs
 * `graft ask <prompt> --json -n 3` and injects the top pointers before the turn.
 * GJC has no prompt-injection surface for directory hooks, and a GJC pre_tool_use
 * hook can only return { block, reason } (see ToolCallEventResult) — it cannot
 * inject context. So we port graft's behaviour onto the one lever we have: when a
 * repo has a graft code-graph and the model reaches for a content SEARCH (the
 * grep-equivalent) before ever touching graft this session, run `graft ask` and
 * hand back the top pointers AS the block reason. The model orients through the
 * graph instead of scanning, then reads only the spans that matter.
 *
 * Brick-safety (this hook must NEVER wedge a session):
 *   - default enabled=false; a global install is a no-op until opted in.
 *   - no graft/ graph in the repo  => allow (undefined).
 *   - graft already used this session => allow (get out of the way).
 *   - >= maxNudges prior nudges this session => allow (deadlock guard).
 *   - any internal error / missing graft binary => allow (fail-open).
 * Gated surfaces: the content-discovery tools `search`/`search_tool_bm25`/`find`,
 * whole-file `read`, and grep-like `bash` (grep/rg/ag/ack — never a `graft …`
 * command). All share ONE lever: block-until-graft. The FIRST `graft …` bash call
 * flips graftUsed=true and every surface unblocks for the rest of the session, so
 * the attitude-gate's own spec `read` is never permanently wedged — run graft once,
 * then read freely. maxNudges still bounds total blocks as a hard deadlock guard.
 *
 * Config (merged: built-in defaults <- user <- project; later wins):
 *   user:    ~/.gjc/agent/hooks/graft-nudge.json
 *   project: <cwd>/.gjc/graft-nudge.json
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface NudgeConfig {
	enabled: boolean;
	/** Max times to block per session before yielding, so a stubborn model can't deadlock. */
	maxNudges: number;
	/** Upper bound on the `graft ask` child, in ms. */
	askTimeoutMs: number;
	/** How many pointers to surface (`graft ask -n`). */
	results: number;
}

export const DEFAULT_CONFIG: NudgeConfig = {
	enabled: false,
	maxNudges: 3,
	askTimeoutMs: 8000,
	results: 3,
};

function readJson(path: string): Partial<NudgeConfig> | null {
	try {
		return JSON.parse(readFileSync(path, "utf-8"));
	} catch {
		return null;
	}
}

export function mergeConfig(base: NudgeConfig, over: Partial<NudgeConfig> | null): NudgeConfig {
	return over ? { ...base, ...over } : base;
}

export function loadConfig(cwd: string, hookDir?: string): NudgeConfig {
	let cfg = DEFAULT_CONFIG;
	const dir = hookDir ?? (typeof import.meta?.dir === "string" ? import.meta.dir : "");
	if (dir) cfg = mergeConfig(cfg, readJson(join(dir, "..", "graft-nudge.json")));
	cfg = mergeConfig(cfg, readJson(join(cwd, ".gjc", "graft-nudge.json")));
	return cfg;
}

/** A repo carries a graft code-graph when the built `graft/` wiring dir exists. */
export function graftAvailable(cwd: string): boolean {
	return existsSync(join(cwd, "graft"));
}

/** Pure: has graft already been used this session (a `graft …` bash call or a graft tool)? */
export function graftUsed(entries: any[]): boolean {
	for (const e of entries ?? []) {
		if (e?.type !== "message" || e?.message?.role !== "assistant" || !Array.isArray(e.message.content)) continue;
		for (const c of e.message.content) {
			if (c?.type !== "toolCall") continue;
			const name = String(c.name ?? "");
			if (name.includes("graft")) return true; // any graft-named tool
			if (name === "bash") {
				const cmd = String(c?.arguments?.command ?? "");
				if (/(?:^|[\s;&|(])graft\s/.test(cmd)) return true;
			}
		}
	}
	return false;
}

const NUDGE_MARK = "POLICY[graft]";

/**
 * Pure: how many graft nudges already landed this session. A blocked call's
 * reason is recorded back into the transcript as a tool error, so counting the
 * marker anywhere in the entries is a runner-shape-independent, deadlock-proof
 * bound (unlike counting toolCall entries, which may or may not include blocked
 * calls). The current turn's block is not in `entries` yet when this runs.
 */
export function priorNudges(entries: any[]): number {
	let n = 0;
	for (const e of entries ?? []) {
		try {
			if (JSON.stringify(e).includes(NUDGE_MARK)) n++;
		} catch {
			/* unserializable entry — ignore */
		}
	}
	return n;
}

/** Run `graft ask` bounded; format the top hits as pointer lines, or "" on any failure. */
export function graftPointers(cwd: string, query: string, cfg: NudgeConfig): string {
	const q = (query || "").trim();
	if (!q) return "";
	try {
		const out = execFileSync("graft", ["ask", q, ".", "--json", "-n", String(cfg.results)], {
			cwd,
			encoding: "utf-8",
			timeout: cfg.askTimeoutMs,
			// Bun's execFileSync `timeout` only sends SIGTERM and does NOT escalate to
			// SIGKILL, so a `graft ask` child that is slow (graph refresh, cross-session
			// lock contention) or ignores SIGTERM blocks past askTimeoutMs until GJC's
			// 30s extension-handler timeout fires (`handler timed out after 30000ms`).
			// killSignal:SIGKILL makes askTimeoutMs a hard bound (verified under Bun 1.4).
			killSignal: "SIGKILL",
			stdio: ["ignore", "pipe", "ignore"],
		});
		// `graft ask` may print a "[graft] refreshed the graph …" preamble before the JSON.
		const brace = out.indexOf("{");
		if (brace < 0) return "";
		const json = JSON.parse(out.slice(brace));
		const hits = Array.isArray(json?.hits) ? json.hits : [];
		return hits
			.slice(0, cfg.results)
			.map((h: any, i: number) => `  ${i + 1}. ${h.title ?? h.pointer} — ${h.pointer}`)
			.filter((line: string) => line.trim().length > 0)
			.join("\n");
	} catch {
		return "";
	}
}

/** Build the block reason, embedding live `graft ask` pointers when available. */
export function reasonText(pointers: string): string {
	const head =
		`${NUDGE_MARK}: 이 저장소엔 graft 코드 그래프가 있다. 원시 \`grep\`/\`search\`/전체파일 \`read\`로 스캔하지 말고, ` +
		'bash 도구로 `graft ask "<질의>"` 를 직접 실행해 시작점을 잡아라(graft는 이미 PATH에 있으니 ' +
		"도구 활성화·검색 불필요; 필요하면 graft grep/skeleton/callers/map 도 bash로). 토큰을 아끼고 호출체인을 정확히 짚는다.";
	return pointers
		? `${head}\n\n지금 질의에 대한 graft 시작점:\n${pointers}\n\n이 포인터의 파일 스팬만 read 하면 충분하다. bash로 graft를 한 번이라도 실행하면 이 안내는 사라진다.`
		: `${head} bash로 graft를 한 번이라도 실행하면 이 안내는 사라진다.`;
}

/**
 * Extract a graft-ask query from a tool event across the search-family surfaces.
 * `search`/`search_tool_bm25` carry a pattern/query/q; `find` carries `paths`
 * globs. `read` carries only a path (not a query) -> "" -> a pointer-less block.
 */
export function extractQuery(event: any): string {
	const i = event?.input ?? {};
	for (const k of ["pattern", "query", "q"]) {
		const v = i[k];
		if (typeof v === "string" && v.trim()) return v.trim();
	}
	if (Array.isArray(i.paths)) {
		const s = i.paths.filter((x: any) => typeof x === "string").join(" ").trim();
		if (s) return s;
	}
	if (typeof i.paths === "string" && i.paths.trim()) return i.paths.trim();
	return "";
}

const GREP_RE = /(?:^|[\s;&|(])(?:grep|egrep|fgrep|rg|ag|ack)\s/;
const GRAFT_RE = /(?:^|[\s;&|(])graft\s/;

/** A bash command scans code with raw grep and is NOT itself a graft call. */
export function isGrepLike(cmd: string): boolean {
	return GREP_RE.test(cmd) && !GRAFT_RE.test(cmd);
}

/** Best-effort: pull the search pattern out of a grep-like command (or ""). */
export function extractGrepPattern(cmd: string): string {
	const q = cmd.match(/["']([^"']+)["']/); // first quoted token
	if (q) return q[1];
	const m = cmd.match(/(?:grep|egrep|fgrep|rg|ag|ack)\s+((?:-\S+\s+)*)(\S+)/); // first non-flag token
	return m ? m[2] : "";
}

/** Shared decision: block-until-graft, bounded by graftUsed + maxNudges. */
function coreDecision(
	cwd: string,
	entries: any[],
	query: string,
	cfg: NudgeConfig,
): { block: true; reason: string } | undefined {
	if (!graftAvailable(cwd)) return undefined; // no graph here -> never brick a plain repo
	if (graftUsed(entries)) return undefined; // already oriented via graft
	if (priorNudges(entries) >= cfg.maxNudges) return undefined; // deadlock guard
	return { block: true, reason: reasonText(graftPointers(cwd, query, cfg)) };
}

/**
 * Tool-facing entry for the search-family surfaces (search / search_tool_bm25 /
 * find / read). Returns { block, reason } to redirect into graft, or undefined to
 * allow. Fail-open in every branch.
 */
export async function evaluate(event: any, ctx: any): Promise<{ block: true; reason: string } | undefined> {
	let cwd: string;
	try {
		cwd = ctx?.sessionManager?.getCwd?.() ?? process.cwd();
	} catch {
		return undefined;
	}
	let cfg: NudgeConfig;
	try {
		cfg = loadConfig(cwd);
	} catch {
		return undefined; // cannot read config -> do not interfere
	}
	if (!cfg.enabled) return undefined;
	try {
		const entries = ctx?.sessionManager?.getEntries?.() ?? [];
		return coreDecision(cwd, entries, extractQuery(event), cfg);
	} catch {
		return undefined; // fail-open: a nudge is never worth wedging a session
	}
}

/**
 * Tool-facing entry for the `bash` surface: only grep-like, non-graft commands
 * are gated (raw code scans). Everything else — including `graft …` itself — is
 * allowed so the model can always run graft to clear the nudge. Fail-open.
 */
export async function evaluateBash(event: any, ctx: any): Promise<{ block: true; reason: string } | undefined> {
	const cmd = String(event?.input?.command ?? "");
	if (!isGrepLike(cmd)) return undefined;
	let cwd: string;
	try {
		cwd = ctx?.sessionManager?.getCwd?.() ?? process.cwd();
	} catch {
		return undefined;
	}
	let cfg: NudgeConfig;
	try {
		cfg = loadConfig(cwd);
	} catch {
		return undefined;
	}
	if (!cfg.enabled) return undefined;
	try {
		const entries = ctx?.sessionManager?.getEntries?.() ?? [];
		return coreDecision(cwd, entries, extractGrepPattern(cmd), cfg);
	} catch {
		return undefined;
	}
}
