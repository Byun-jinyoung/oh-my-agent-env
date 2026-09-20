/**
 * GJC pre_tool_use — `bash` surface (thin wrapper). Filename MUST equal the tool
 * name so the loose-surface loader routes `bash` calls here. Two layers:
 *
 *   1. graft-uptake (./_graft-nudge.ts evaluateBash): a raw grep/rg scan on a
 *      graft repo, before graft was used this session, is redirected to graft.
 *      Only NON-mutating grep-likes are gated — a mutating command (or a `graft …`
 *      command) always falls through so the attitude gate stays authoritative and
 *      the model can always run graft to clear the nudge.
 *   2. attitude-gate (./_gate.ts): mutation-attitude enforcement (spec/intent/
 *      investigate) on every filesystem-mutating bash command.
 */
import type { HookAPI } from "@gajae-code/coding-agent";
import { evaluate as gateEvaluate, isMutatingBash } from "./_gate.ts";
import { evaluateBash as graftBash } from "./_graft-nudge.ts";

export default function (pi: HookAPI) {
	pi.on("tool_call", async (event: any, ctx: any) => {
		const cmd = String(event?.input?.command ?? "");
		if (!isMutatingBash(cmd)) {
			const graft = await graftBash(event, ctx);
			if (graft) return graft; // redirect a raw grep scan into graft
		}
		return gateEvaluate("bash", event, ctx);
	});
}
