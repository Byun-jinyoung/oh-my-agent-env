/**
 * GJC pre_tool_use graph nudges — `search` surface (thin wrapper).
 * Filename MUST equal the tool name so the loose-surface loader routes `search`
 * calls here. All logic lives in ./_surface.ts, shared with the sibling
 * discovery surfaces (search_tool_bm25 / find / read).
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { registerGraphNudge } from "./_surface.ts";

export default function (pi: HookAPI) {
	registerGraphNudge(pi);
}
