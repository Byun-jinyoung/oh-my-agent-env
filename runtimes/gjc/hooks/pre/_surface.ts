/**
 * Shared graph-nudge registration for the GJC search-family surfaces
 * (search / search_tool_bm25 / find / read). Single source of truth so every
 * discovery tool applies the identical two-layer nudge:
 *
 *   1. graft-uptake (./_graft-nudge.ts): orient through the graph instead of a
 *      raw grep / bm25 / whole-file read. Blocks until graft is used this session.
 *   2. graphify-freshness (./_graphify-nudge.ts): once graft HAS been used this
 *      session and the session edited code, nudge `graphify update .` so the AST
 *      graph is not stale. Sequenced AFTER graft (Q1a): graft speaks first; the
 *      graphify layer only speaks when graft is not nudging AND was used.
 *
 * A single `tool_call` handler returns at most one { block, reason }, so the two
 * are strictly prioritized: graft first, graphify only when graft yields.
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { evaluate as graftEvaluate, graftUsed } from "./_graft-nudge.ts";
import { evaluate as graphifyEvaluate } from "./_graphify-nudge.ts";

export function registerGraphNudge(pi: HookAPI): void {
	pi.on("tool_call", async (event: any, ctx: any) => {
		const graft = await graftEvaluate(event, ctx);
		if (graft) return graft; // graft-uptake takes precedence

		// graft is not nudging (unavailable, disabled, already used, or deadlock-guarded).
		// The graphify freshness layer only speaks once graft was actually used this
		// session — otherwise stay silent so a graft-less repo is never touched.
		try {
			const entries = ctx?.sessionManager?.getEntries?.() ?? [];
			if (!graftUsed(entries)) return undefined;
		} catch {
			return undefined;
		}
		return graphifyEvaluate(event, ctx);
	});
}
