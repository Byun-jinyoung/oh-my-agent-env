/**
 * GJC pre_tool_use attitude gate — `edit` surface (thin wrapper).
 * All logic lives in ./_gate.ts (single source of truth). Filename MUST equal
 * the tool name so the loose-surface loader routes `edit` calls here.
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { evaluate } from "./_gate.ts";

export default function (pi: HookAPI) {
	pi.on("tool_call", async (event: any, ctx: any) => evaluate("edit", event, ctx));
}
