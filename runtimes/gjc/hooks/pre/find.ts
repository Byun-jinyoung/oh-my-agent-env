/**
 * GJC pre_tool_use graph nudges — `find` surface (thin wrapper).
 * Filename MUST equal the tool name so the loose-surface loader routes `find`
 * calls here. Logic in ./_surface.ts, shared with search / search_tool_bm25 /
 * read. The `paths` globs become the `graft ask` query.
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { registerGraphNudge } from "./_surface.ts";

export default function (pi: HookAPI) {
	registerGraphNudge(pi);
}
