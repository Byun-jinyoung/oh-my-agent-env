/**
 * Unit tests for the graft-nudge pure logic (no model, no gjc session, no graft
 * binary). Covers the surface-expansion helpers and the session-state scanners.
 * Run: bun test tests/graft-nudge.test.ts
 */
import { test, expect } from "bun:test";
import {
	extractQuery,
	isGrepLike,
	extractGrepPattern,
	graftUsed,
	priorNudges,
	reasonText,
	mergeConfig,
	DEFAULT_CONFIG,
} from "../runtimes/gjc/hooks/pre/_graft-nudge.ts";

const asst = (content: any[]) => ({ type: "message", message: { role: "assistant", content } });
const call = (name: string, args: any = {}) => ({ type: "toolCall", name, arguments: args });

// ---- extractQuery -------------------------------------------------------------
test("extractQuery: pattern > query > q precedence", () => {
	expect(extractQuery({ input: { pattern: "A", query: "B", q: "C" } })).toBe("A");
	expect(extractQuery({ input: { query: "B", q: "C" } })).toBe("B");
	expect(extractQuery({ input: { q: "C" } })).toBe("C");
});
test("extractQuery: find paths array/string become the query", () => {
	expect(extractQuery({ input: { paths: ["src/**/*.ts", "test/**"] } })).toBe("src/**/*.ts test/**");
	expect(extractQuery({ input: { paths: "src/foo.ts" } })).toBe("src/foo.ts");
});
test("extractQuery: read (path only) yields empty -> pointer-less block", () => {
	expect(extractQuery({ input: { path: "src/foo.ts:50-100" } })).toBe("");
	expect(extractQuery({ input: {} })).toBe("");
	expect(extractQuery({})).toBe("");
});
test("extractQuery: blank strings are skipped", () => {
	expect(extractQuery({ input: { pattern: "   ", query: "real" } })).toBe("real");
});

// ---- isGrepLike ---------------------------------------------------------------
test("isGrepLike: raw grep/rg scans are gated", () => {
	expect(isGrepLike("grep -n foo src")).toBe(true);
	expect(isGrepLike("rg 'HistoryPolicy' src")).toBe(true);
	expect(isGrepLike("cd x && egrep bar .")).toBe(true);
});
test("isGrepLike: a graft command is NEVER gated (even with grep in it)", () => {
	expect(isGrepLike("graft grep SwarmRepulsionGuidance")).toBe(false);
	expect(isGrepLike("cd repo && graft ask 'x'")).toBe(false);
});
test("isGrepLike: non-grep commands pass through", () => {
	expect(isGrepLike("ls -la")).toBe(false);
	expect(isGrepLike("echo grepfoo")).toBe(false); // 'grep' as a substring, not the command
	expect(isGrepLike("python run.py")).toBe(false);
});

// ---- extractGrepPattern -------------------------------------------------------
test("extractGrepPattern: first quoted token wins", () => {
	expect(extractGrepPattern("grep -n 'HistoryPolicy' src")).toBe("HistoryPolicy");
	expect(extractGrepPattern('rg "resolve_noisy_score_bias" .')).toBe("resolve_noisy_score_bias");
});
test("extractGrepPattern: unquoted -> first non-flag token", () => {
	expect(extractGrepPattern("grep -n SwarmRepulsion src/foo.py")).toBe("SwarmRepulsion");
});
test("extractGrepPattern: nothing extractable -> empty", () => {
	expect(extractGrepPattern("grep")).toBe("");
});

// ---- graftUsed ----------------------------------------------------------------
test("graftUsed: a graft bash call flips it true", () => {
	expect(graftUsed([asst([call("bash", { command: "cd r && graft ask 'x'" })])])).toBe(true);
});
test("graftUsed: a graft-named tool flips it true", () => {
	expect(graftUsed([asst([call("graft_ask", {})])])).toBe(true);
});
test("graftUsed: raw grep / plain reads do NOT count as graft usage", () => {
	expect(graftUsed([asst([call("bash", { command: "grep -n foo ." })])])).toBe(false);
	expect(graftUsed([asst([call("read", { path: "a" })])])).toBe(false);
	expect(graftUsed([])).toBe(false);
});

// ---- priorNudges --------------------------------------------------------------
test("priorNudges: counts POLICY[graft] markers anywhere in entries", () => {
	const withMark = { type: "message", message: { role: "user", content: [{ type: "text", text: "POLICY[graft]: ..." }] } };
	expect(priorNudges([withMark, withMark])).toBe(2);
	expect(priorNudges([asst([call("read", {})])])).toBe(0);
});

// ---- reasonText ---------------------------------------------------------------
test("reasonText: always carries the POLICY[graft] marker; pointers embedded when present", () => {
	expect(reasonText("")).toContain("POLICY[graft]");
	const withPtr = reasonText("  1. Foo — src/foo.py:L1-L9");
	expect(withPtr).toContain("POLICY[graft]");
	expect(withPtr).toContain("src/foo.py:L1-L9");
});

// ---- mergeConfig (shared) -----------------------------------------------------
test("mergeConfig: project override wins, defaults preserved", () => {
	const merged = mergeConfig(DEFAULT_CONFIG, { enabled: true, maxNudges: 5 });
	expect(merged.enabled).toBe(true);
	expect(merged.maxNudges).toBe(5);
	expect(merged.results).toBe(DEFAULT_CONFIG.results);
});
