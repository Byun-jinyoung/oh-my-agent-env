/**
 * Shared graphify-freshness nudge logic for GJC pre_tool_use hooks.
 * Companion to _graft-nudge.ts, imported by search.ts (single source of truth).
 *
 * WHY (Q1a sequencing): graft-nudge drives UPTAKE — orient through the graph
 * instead of grep. This module drives the *other* half: FRESHNESS. graft keeps
 * itself current with a background sync on every edit; graphify's AST graph does
 * not, so after a session has edited code, graphify-out/graph.json is stale and
 * answers confidently about code that has moved. search.ts evaluates graft first;
 * only once graft was actually USED this session does this layer speak, nudging
 * `graphify update .` (AST-only, no API cost, no --deep).
 *
 * Staleness signal — NOT `graphify check-update`: that only flags pending
 * SEMANTIC (LLM) re-extraction via graphify-out/needs_update, written by the
 * watch daemon on doc/image changes. We run neither --deep nor watch, so it never
 * fires for code edits. Staleness is measured the way lib/doctor/graph-freshness.sh
 * measures it — by mtime — but scoped to THIS session: the newest mtime among the
 * files the session edited vs graphify-out/graph.json. O(edits), never scans the
 * repo, and catches uncommitted live edits a git-log check would miss.
 *
 * Brick-safety (this hook must NEVER wedge a session):
 *   - default enabled=false; a global install is a no-op until opted in.
 *   - no graphify-out/graph.json in the repo => allow (undefined).
 *   - graph not stale (no session edit newer than the graph) => allow.
 *   - >= maxNudges prior nudges this session => allow (deadlock guard).
 *   - any internal error => allow (fail-open).
 * Only the `search` surface reaches this, and only after graft was used, so spec
 * reads and the attitude-gate's own reads can never be blocked here.
 *
 * Config (merged: built-in defaults <- user <- project; later wins):
 *   user:    ~/.gjc/agent/hooks/graphify-nudge.json
 *   project: <cwd>/.gjc/graphify-nudge.json
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export interface FreshConfig {
	enabled: boolean;
	/** Max times to nudge per session before yielding, so a stubborn model can't deadlock. */
	maxNudges: number;
}

export const DEFAULT_CONFIG: FreshConfig = {
	enabled: false,
	maxNudges: 2,
};

function readJson(path: string): Partial<FreshConfig> | null {
	try {
		return JSON.parse(readFileSync(path, "utf-8"));
	} catch {
		return null;
	}
}

export function mergeConfig(base: FreshConfig, over: Partial<FreshConfig> | null): FreshConfig {
	return over ? { ...base, ...over } : base;
}

export function loadConfig(cwd: string, hookDir?: string): FreshConfig {
	let cfg = DEFAULT_CONFIG;
	const dir = hookDir ?? (typeof import.meta?.dir === "string" ? import.meta.dir : "");
	if (dir) cfg = mergeConfig(cfg, readJson(join(dir, "..", "graphify-nudge.json")));
	cfg = mergeConfig(cfg, readJson(join(cwd, ".gjc", "graphify-nudge.json")));
	return cfg;
}

/** A repo carries a graphify graph when graphify-out/graph.json exists. */
export function graphifyAvailable(cwd: string): boolean {
	return existsSync(join(cwd, "graphify-out", "graph.json"));
}

/**
 * Pure: absolute paths of files this session edited (write/edit/ast_edit tool
 * calls with a path argument). Used as the cheap, session-scoped staleness probe.
 */
export function editedPaths(entries: any[], cwd: string): string[] {
	const out: string[] = [];
	for (const e of entries ?? []) {
		if (e?.type !== "message" || e?.message?.role !== "assistant" || !Array.isArray(e.message.content)) continue;
		for (const c of e.message.content) {
			if (c?.type !== "toolCall") continue;
			const name = String(c.name ?? "");
			if (name !== "write" && name !== "edit" && name !== "ast_edit") continue;
			const p = c?.arguments?.path;
			if (typeof p !== "string" || !p) continue;
			out.push(isAbsolute(p) ? p : join(cwd, p));
		}
	}
	return out;
}

const NUDGE_MARK = "POLICY[graphify]";

/**
 * Pure: how many graphify freshness nudges already landed this session. A blocked
 * call's reason is recorded back into the transcript as a tool error, so counting
 * the marker anywhere is a runner-shape-independent, deadlock-proof bound.
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

/** Pure: is the graph stale — did the session edit a file after the graph was built? */
export function graphStale(cwd: string, edited: string[]): boolean {
	let gm: number;
	try {
		gm = statSync(join(cwd, "graphify-out", "graph.json")).mtimeMs;
	} catch {
		return false; // no graph -> not stale (handled upstream too)
	}
	for (const p of edited) {
		try {
			if (statSync(p).mtimeMs > gm) return true;
		} catch {
			/* edited file vanished/renamed — ignore */
		}
	}
	return false;
}

/** Build the block reason nudging an AST-only graph refresh. */
export function reasonText(): string {
	return (
		`${NUDGE_MARK}: 이 저장소의 graphify 코드 그래프(graphify-out/graph.json)가 이번 세션의 편집 이후로 낡았다. ` +
		"낡은 그래프는 이동한 코드를 자신있게 틀리게 답한다 — 그래프를 조회하기 전에 bash 도구로 " +
		'`graphify update .` 를 실행해 최신화하라(AST 전용, API 비용 0, --deep 아님). 이후 필요하면 ' +
		'`graphify query "<질의>"` 로 조회한다. graphify 를 한 번 실행하면 이 안내는 사라진다.'
	);
}

/**
 * Tool-facing entry point for the shared `search` surface (called by search.ts
 * only after graft was used this session). Returns { block, reason } to nudge a
 * graph refresh, or undefined to allow. Fail-open in every branch.
 */
export async function evaluate(event: any, ctx: any): Promise<{ block: true; reason: string } | undefined> {
	let cwd: string;
	try {
		cwd = ctx?.sessionManager?.getCwd?.() ?? process.cwd();
	} catch {
		return undefined;
	}
	let cfg: FreshConfig;
	try {
		cfg = loadConfig(cwd);
	} catch {
		return undefined; // cannot read config -> do not interfere
	}
	if (!cfg.enabled) return undefined;

	try {
		if (!graphifyAvailable(cwd)) return undefined; // no graph here -> never brick a plain repo
		const entries = ctx?.sessionManager?.getEntries?.() ?? [];
		if (priorNudges(entries) >= cfg.maxNudges) return undefined; // deadlock guard
		if (!graphStale(cwd, editedPaths(entries, cwd))) return undefined; // graph still current
		return { block: true, reason: reasonText() };
	} catch {
		return undefined; // fail-open: a nudge is never worth wedging a session
	}
}
