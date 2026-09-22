/**
 * Unit tests for the attitude-gate pure logic (no model, no gjc session).
 * Run: bun test tests/attitude-gate.test.ts
 */
import { test, expect } from "bun:test";
import {
	isMutatingBash,
	scanEntries,
	decide,
	mergeConfig,
	loadConfig,
	DEFAULT_CONFIG,
	type GateConfig,
} from "../runtimes/gjc/hooks/pre/_gate.ts";

const CFG: GateConfig = { ...DEFAULT_CONFIG, enabled: true };

// ---- isMutatingBash -----------------------------------------------------------
test("mutating bash: redirection to a real file", () => {
	expect(isMutatingBash("echo hi > src/x.txt")).toBe(true);
	expect(isMutatingBash("printf a >> log")).toBe(true);
	expect(isMutatingBash("cat tpl | tee out.conf")).toBe(true);
	expect(isMutatingBash("sed -i s/a/b/ file")).toBe(true);
	expect(isMutatingBash("cp a b")).toBe(true);
	expect(isMutatingBash("mv a b")).toBe(true);
	expect(isMutatingBash("touch new")).toBe(true);
});
test("non-mutating bash passes", () => {
	expect(isMutatingBash("echo hello")).toBe(false);
	expect(isMutatingBash("ls -la src")).toBe(false);
	expect(isMutatingBash("cat f | grep x")).toBe(false);
	expect(isMutatingBash("echo x 2>&1")).toBe(false);
	expect(isMutatingBash("run >/dev/null 2>&1")).toBe(false);
	expect(isMutatingBash("git status")).toBe(false);
});
test("non-mutating bash: mutator word inside a path/arg is not a mutation", () => {
	expect(isMutatingBash("grep -rn foo ~/.bun/install/cache/@gajae-code")).toBe(false);
	expect(isMutatingBash("find ~/.bun/install -name '*.ts'")).toBe(false);
	expect(isMutatingBash("cat notes | grep cp")).toBe(false);
	expect(isMutatingBash("rg mkdir src/")).toBe(false);
	expect(isMutatingBash("ls node_modules/rsync")).toBe(false);
	expect(isMutatingBash("echo see /var/lib/tee/data")).toBe(false);
});
test("mutating bash: real command at a command position is still caught", () => {
	expect(isMutatingBash("mkdir -p a && cp x y")).toBe(true);
	expect(isMutatingBash("false; touch marker")).toBe(true);
	expect(isMutatingBash("sudo install -m 755 a /usr/bin/b")).toBe(true);
	expect(isMutatingBash("cat tpl | tee out.conf")).toBe(true);
	expect(isMutatingBash("DEST=/tmp rsync -a a b")).toBe(true);
});
test("non-mutating bash: literal '>' inside quotes/heredocs is not a redirect", () => {
	// arrows and comparisons in quoted strings
	expect(isMutatingBash('echo "settings.conf -> config.yml"')).toBe(false);
	expect(isMutatingBash('echo "a >= b comparison"')).toBe(false);
	expect(isMutatingBash("git commit -m 'fix: handle a -> b and x > y'")).toBe(false);
	// python heredoc with comparison operators (the real false positive)
	expect(isMutatingBash("python3 - <<'PY'\nif cr==0 and i>BIG:\n    pass\nPY")).toBe(false);
	expect(isMutatingBash("python3 - <<'PY'\nif m>=restart-3600:\n    ok=1\nPY")).toBe(false);
});
test("mutating bash: a real redirect outside quotes is still caught", () => {
	expect(isMutatingBash('echo "literal -> arrow" > realfile.txt')).toBe(true);
	expect(isMutatingBash("cat > out.conf <<'EOF'\nbody with i>BIG inside\nEOF")).toBe(true);
	// interpreter inline-write is caught even though it lives inside a heredoc
	expect(isMutatingBash("python3 - <<'PY'\nopen('x.txt','w').write('hi')\nPY")).toBe(true);
});

// ---- scanEntries --------------------------------------------------------------
const asst = (content: any[]) => ({ type: "message", message: { role: "assistant", content } });
test("scanEntries counts investigations and detects intent + spec read", () => {
	const entries = [
		asst([{ type: "text", text: "INTENT: build the thing" }]),
		asst([{ type: "toolCall", name: "read", arguments: { path: ".gjc/spec.md" } }]),
		asst([{ type: "toolCall", name: "search", arguments: { pattern: "x" } }]),
	];
	const s = scanEntries(entries, ".gjc/spec.md");
	expect(s.investigations).toBe(2);
	expect(s.intentReported).toBe(true);
	expect(s.specReferenced).toBe(true);
});
test("scanEntries: no signals on empty transcript", () => {
	const s = scanEntries([], ".gjc/spec.md");
	expect(s).toEqual({ investigations: 0, intentReported: false, specReferenced: false, todoActive: false });
});
test("scanEntries: todo_write marks todoActive", () => {
	const s = scanEntries([asst([{ type: "toolCall", name: "todo_write", arguments: { ops: [] } }])], ".gjc/spec.md");
	expect(s.todoActive).toBe(true);
});
test("scanEntries: goal create/resume marks todoActive, but get/complete does not", () => {
	expect(scanEntries([asst([{ type: "toolCall", name: "goal", arguments: { op: "create", objective: "x" } }])], ".gjc/spec.md").todoActive).toBe(true);
	expect(scanEntries([asst([{ type: "toolCall", name: "goal", arguments: { op: "resume" } }])], ".gjc/spec.md").todoActive).toBe(true);
	expect(scanEntries([asst([{ type: "toolCall", name: "goal", arguments: { op: "get" } }])], ".gjc/spec.md").todoActive).toBe(false);
	expect(scanEntries([asst([{ type: "toolCall", name: "goal", arguments: { op: "complete" } }])], ".gjc/spec.md").todoActive).toBe(false);
});
test("scanEntries: a handoff-injected active goal context marks todoActive", () => {
	// GJC re-injects these custom entries into the post-handoff session even though
	// the original goal(create) toolCall is gone; the gate must honor them so
	// auto-continue is not blocked.
	expect(scanEntries([{ type: "custom_message", customType: "goal-mode-context" }], ".gjc/spec.md").todoActive).toBe(true);
	expect(scanEntries([{ type: "custom_message", customType: "goal-continuation" }], ".gjc/spec.md").todoActive).toBe(true);
	expect(scanEntries([{ type: "custom_message", customType: "workflow-intent-diff" }], ".gjc/spec.md").todoActive).toBe(false);
});
test("scanEntries: reading a non-spec file is not a spec reference", () => {
	const s = scanEntries([asst([{ type: "toolCall", name: "read", arguments: { path: "src/a.ts" } }])], ".gjc/spec.md");
	expect(s.specReferenced).toBe(false);
	expect(s.investigations).toBe(1);
});

// ---- decide -------------------------------------------------------------------
const full: any = { investigations: 1, intentReported: true, specReferenced: true };
test("decide: blocks when spec missing", () => {
	expect(decide(full, "", CFG, "write")?.reason).toContain("합의된 scope/spec 없음");
});
test("decide: blocks when spec not referenced", () => {
	expect(decide({ ...full, specReferenced: false }, "spec", CFG, "write")?.reason).toContain("미참조");
});
test("decide: blocks when no intent", () => {
	expect(decide({ ...full, intentReported: false }, "spec", CFG, "write")?.reason).toContain("의도 보고");
});
test("decide: blocks when not investigated", () => {
	expect(decide({ ...full, investigations: 0 }, "spec", CFG, "write")?.reason).toContain("조사 없이");
});
test("decide: allows when all gates satisfied", () => {
	expect(decide(full, "spec text", CFG, "write")).toBeUndefined();
});
test("decide: todoActive gate off by default -> no block even without a todo", () => {
	expect(decide({ ...full, todoActive: false }, "spec text", CFG, "write")).toBeUndefined();
});
test("decide: todoActive gate on blocks until a todo/goal exists", () => {
	const cfg = { ...CFG, gates: { ...CFG.gates, todoActive: true } };
	expect(decide({ ...full, todoActive: false }, "spec text", cfg, "write")?.reason).toContain("미완 작업 미등록");
	expect(decide({ ...full, todoActive: true }, "spec text", cfg, "write")).toBeUndefined();
});
test("decide: disabled gate is skipped", () => {
	const cfg = { ...CFG, gates: { ...CFG.gates, specExists: false, specReferenced: false } };
	expect(decide({ ...full, specReferenced: false }, "", cfg, "write")).toBeUndefined();
});

// ---- mergeConfig / loadConfig -------------------------------------------------
test("mergeConfig deep-merges gates", () => {
	const m = mergeConfig(DEFAULT_CONFIG, { enabled: true, gates: { investigated: false } as any });
	expect(m.enabled).toBe(true);
	expect(m.gates.investigated).toBe(false);
	expect(m.gates.specExists).toBe(true); // preserved
});
test("loadConfig default is disabled (safe global no-op)", () => {
	expect(loadConfig("/nonexistent-cwd-xyz").enabled).toBe(false);
});
