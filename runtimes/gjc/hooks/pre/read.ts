/**
 * GJC pre_tool_use graph nudges — `read` surface (thin wrapper).
 * Filename MUST equal the tool name so the loose-surface loader routes `read`
 * calls here. Logic in ./_surface.ts, shared with search / search_tool_bm25 /
 * find. A `read` before graft was used is blocked with a pointer-less nudge; the
 * FIRST `graft …` bash call flips graftUsed=true and unblocks every read for the
 * rest of the session (so graft pointer spans — and the attitude-gate spec read —
 * are always reachable: run graft once, then read freely).
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { registerGraphNudge } from "./_surface.ts";

export default function (pi: HookAPI) {
	registerGraphNudge(pi);
}
