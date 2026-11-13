import { expect, test, spyOn } from "bun:test";
import fs from "node:fs";
import path from "node:path";

for (const customDir of [false, true]) {
  test(`Herdr extension deploys twice into ${customDir ? "a custom" : "a fresh default"} OMO directory`, async () => {
    // Given: a machine without an initialized OMO config directory.
    const root = path.resolve(import.meta.dir, "..");
    const home = fs.mkdtempSync(path.join(import.meta.dir, ".herdr-home-"));
    const agentDir = path.join(home, customDir ? "custom-agent" : ".omo/agent");
    try {
      // When: the existing sync boundary runs twice, without network or other setup.
      const child = Bun.spawn(["bash", "-c", `
        set -eu
        SCRIPT_DIR="$1"
        ERRORS=0
        log_and_print() { printf '%s\\n' "$*"; }
        . "$SCRIPT_DIR/lib/sync/agent-clis.sh"
        sync_omo_herdr_extension
        sync_omo_herdr_extension
        test "$ERRORS" -eq 0
      `, "herdr-deploy-test", root], {
        env: { ...process.env, HOME: home, OMO_CODING_AGENT_DIR: customDir ? agentDir : "" },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);

      // Then: the deployed module equals the shared source, including after re-sync.
      expect({ code, stderr }, stdout).toEqual({ code: 0, stderr: "" });
      expect(fs.readFileSync(path.join(agentDir, "extensions/herdr-omp-agent-state.ts")))
        .toEqual(fs.readFileSync(path.join(root, "runtimes/omo/extensions/herdr-omp-agent-state.ts")));
      if (customDir) expect(fs.existsSync(path.join(home, ".omo"))).toBe(false);
    } finally {
      fs.rmSync(home, { recursive: true });
    }
  });
}

test("herdr-core receives Pi identity and lifecycle status through the controlling terminal", async () => {
  // Given: OMO runs in core, with stdout redirected as in its interactive launcher.
  const savedEnv = { ...process.env };
  delete process.env.HERDR_ENV;
  delete process.env.TMUX;
  process.env.HC_TERMINAL_ID = "t2";
  process.env.HC_TERMINAL_SOCKET = "/unused/core.sock";
  const writes: string[] = [];
  const open = spyOn(fs, "openSync").mockReturnValue(123);
  const close = spyOn(fs, "closeSync").mockImplementation(() => {});
  let idleSeen: (() => void) | undefined;
  const write = spyOn(fs, "writeSync").mockImplementation((_fd, value) => {
    const text = String(value);
    writes.push(text);
    if (text.includes("state=idle")) idleSeen?.();
    return Buffer.byteLength(text);
  });
  const ctx = { hasUI: true, isIdle: () => false };
  type Handler = (event: Record<string, unknown>, context: typeof ctx) => void | Promise<void>;
  const handlers = new Map<string, Handler>();
  const events = new Map<string, (data: { active: boolean; label?: string }) => void>();
  try {
    const { default: extension } = await import("../runtimes/omo/extensions/herdr-omp-agent-state.ts");
    extension({
      on: (name: string, handler: Handler) => handlers.set(name, handler),
      events: { on: (name: string, handler: (data: { active: boolean; label?: string }) => void) => events.set(name, handler) },
    });
    const emit = async (name: string, event: Record<string, unknown> = {}, context = ctx) => {
      const handler = handlers.get(name);
      expect(handler).toBeDefined();
      await handler?.(event, context);
    };

    // When: a background context starts, it must not claim the root terminal.
    await emit("session_start", {}, { ...ctx, hasUI: false });
    expect(writes).toEqual([]);
    await emit("session_start");
    await emit("tool_approval_requested", { reason: "permission: test\nvalue" });
    await emit("tool_approval_resolved");
    events.get("herdr:blocked")?.({ active: true, label: "question" });
    await Promise.resolve();
    events.get("herdr:blocked")?.({ active: false });
    await Promise.resolve();
    const idle = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("idle report missing")), 1000);
      idleSeen = () => { clearTimeout(timeout); resolve(); };
    });
    await emit("agent_end", { messages: [] });
    await idle;
    await emit("session_shutdown");

    // Then: reports carry Pi identity and encoded messages, and clear on exit.
    expect(writes).toEqual([
      "\x1b]7501;state=working:app=pi\x1b\\",
      `\x1b]7501;state=blocked:app=pi:msg=${Buffer.from("permission: test\nvalue").toString("base64")}\x1b\\`,
      "\x1b]7501;state=working:app=pi\x1b\\",
      `\x1b]7501;state=blocked:app=pi:msg=${Buffer.from("question").toString("base64")}\x1b\\`,
      "\x1b]7501;state=working:app=pi\x1b\\",
      "\x1b]7501;state=idle:app=pi\x1b\\",
      "\x1b]7501;state=clear\x1b\\",
    ]);
    expect(open).toHaveBeenCalledWith(process.platform === "win32" ? "CONOUT$" : "/dev/tty", "w");
    expect(close).toHaveBeenCalledTimes(writes.length);
  } finally {
    open.mockRestore();
    write.mockRestore();
    close.mockRestore();
    process.env = savedEnv;
  }
});
