/**
 * GJC pre_tool_use graph nudges — `search_tool_bm25` surface (thin wrapper).
 * Filename MUST equal the tool name so the loose-surface loader routes
 * `search_tool_bm25` calls here. This is the surface the pilot caught the model
 * abusing: it tried to ACTIVATE graft as an MCP tool via bm25 instead of running
 * the graft CLI. The nudge redirects it to `graft ask` in bash. Logic in
 * ./_surface.ts, shared with search / find / read.
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { registerGraphNudge } from "./_surface.ts";

export default function (pi: HookAPI) {
	registerGraphNudge(pi);
}
