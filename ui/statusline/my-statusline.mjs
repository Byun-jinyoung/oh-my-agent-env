#!/usr/bin/env node
/**
 * Byun's Custom Statusline (omc-free) — merged OMA + cc-alchemy view.
 *
 * One line, OMC-style bars, combining:
 *   - cc-alchemy/our side: Model, git branch, 5h/wk usage BARS, session timer, ctx bar
 *   - oma side (read straight from the statusline payload): $cost, token io
 *
 * Data sources:
 *   - stdin JSON (Claude Code / agy statusline payload): model, context_window
 *     (used_percentage, total_input/output_tokens), cost.total_cost_usd,
 *     rate_limits.{five_hour,seven_day} (used_percentage, resets_at),
 *     transcript_path. Rate limits are taken from the payload when present.
 *   - ~/.claude/statusline_cache.json: 5h/7d windows from cc-alchemy's OAuth
 *     fetch — used as a FALLBACK when the payload omits rate_limits (e.g. older
 *     Claude Code). A background `cc-alchemy-statusline --fetch-only` keeps it warm.
 *   - transcript first timestamp → session duration.
 *
 * No oh-my-claudecode (omc) dependency. Omitted vs oma's HUD: [OMA] label,
 * subagents/bg/workflow operational state (oma-engine-internal).
 *
 * Install: statusLine in ~/.claude/settings.json:
 *   { "type": "command", "command": "node $HOME/.claude/hud/my-statusline.mjs" }
 */

import { readFileSync, openSync, readSync, closeSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execSync, spawn } from "node:child_process";

const HOME = homedir();
const CACHE_FILE = join(HOME, ".claude", "statusline_cache.json");

// --- Colors (Catppuccin-ish, matching the prior HUD palette) ---
const rgb = (r, g, b) => `\x1b[38;2;${r};${g};${b}m`;
const RST = "\x1b[0m";
const DIM = rgb(108, 112, 134);
const TEXT = rgb(205, 214, 244);
const MODEL = rgb(147, 153, 178);
const BRANCH = rgb(137, 180, 250);
const GREEN = rgb(166, 227, 161);
const YELLOW = rgb(249, 226, 175);
const RED = rgb(243, 139, 168);
const pcolor = (p) => (p < 50 ? GREEN : p < 90 ? YELLOW : RED);

function readStdin() {
  try {
    return readFileSync(0, "utf-8");
  } catch {
    return "";
  }
}

function gitBranch(cwd) {
  try {
    return execSync("git rev-parse --abbrev-ref HEAD 2>/dev/null", {
      cwd: cwd || process.cwd(),
      encoding: "utf-8",
      timeout: 2000,
    }).trim();
  } catch {
    return "";
  }
}

function readCache() {
  try {
    return JSON.parse(readFileSync(CACHE_FILE, "utf-8"));
  } catch {
    return {};
  }
}

// Refresh the usage cache in the background (cc-alchemy rate-limits its own
// fetches, so calling this every render is cheap and usually a no-op). Only
// matters when the payload itself doesn't carry rate_limits.
function refreshCache() {
  try {
    const child = spawn("cc-alchemy-statusline", ["--fetch-only"], {
      detached: true,
      stdio: "ignore",
    });
    // spawn() reports a missing binary via an async 'error' event, NOT the
    // synchronous try/catch. Without this listener the unhandled error crashes
    // the process (exit 1) on machines where cc-alchemy isn't installed, so the
    // statusline silently breaks even though both lines were already printed.
    child.on("error", () => {});
    child.unref();
  } catch {
    // cc-alchemy not installed — render with whatever cache/payload exists.
  }
}

// Session duration = now - first transcript entry timestamp. Reads only the
// first chunk of the (append-only) transcript, so cost is O(1) regardless of
// transcript size. The first few entries are meta (no timestamp); take the
// first one that has one.
function sessionMins(transcriptPath) {
  if (!transcriptPath) return null;
  let fd;
  try {
    fd = openSync(transcriptPath, "r");
    const buf = Buffer.alloc(16384);
    const n = readSync(fd, buf, 0, buf.length, 0);
    for (const line of buf.toString("utf-8", 0, n).split("\n")) {
      if (!line.trim()) continue;
      let ts;
      try { ts = JSON.parse(line).timestamp; } catch { continue; }
      if (ts) return Math.max(0, Math.floor((Date.now() - new Date(ts).getTime()) / 60000));
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) try { closeSync(fd); } catch {}
  }
}

function fmtDuration(mins) {
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m ? `${h}h${m}m` : `${h}h`;
}

function fmtTokens(n) {
  if (n < 1000) return `${n}`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

function bar(pct, n) {
  const filled = Math.max(0, Math.min(n, Math.round((pct / 100) * n)));
  return "[" + "█".repeat(filled) + "░".repeat(n - filled) + "]";
}

function resetTxt(resetsAt) {
  if (!resetsAt) return "";
  const secs = Math.floor((new Date(resetsAt).getTime() - Date.now()) / 1000);
  if (secs < 60) return ""; // expired / stale source — omit instead of "(0m)"
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (h > 24) return `(${Math.floor(h / 24)}d${h % 24}h)`;
  if (h > 0) return `(${h}h${m}m)`;
  return `(${m}m)`;
}

// A rate window can come from the payload or the cc-alchemy cache. The payload
// sometimes carries a STALE resets_at (long-lived session); the cache is freshly
// fetched. Pick whichever resets furthest in the future so the freshest snapshot
// (percentage + countdown) wins. Missing resets_at sorts oldest.
function pickWindow(a, b) {
  const t = (w) => (w && w.resets_at ? new Date(w.resets_at).getTime() : 0);
  if (!a) return b;
  if (!b) return a;
  return t(a) >= t(b) ? a : b;
}

// A usage window may come from the payload ({used_percentage, resets_at}) or
// the cc-alchemy cache ({utilization, resets_at}). Normalize both.
function usageSeg(label, period) {
  const pct = period?.used_percentage ?? period?.utilization;
  if (pct == null) return `${DIM}${label}:${bar(0, 8)}${RST} ${DIM}--${RST}`;
  const u = Math.round(pct);
  return `${DIM}${label}:${pcolor(u)}${bar(u, 8)}${u}%${DIM}${resetTxt(period.resets_at)}${RST}`;
}

function main() {
  let data = {};
  try {
    const raw = readStdin();
    if (raw.trim()) data = JSON.parse(raw);
  } catch {
    // malformed stdin — render with defaults
  }

  const m = data.model || {};
  const name = (m.display_name || m.id || "Claude").replace("Claude ", "");
  const cwd = data.workspace?.current_dir || data.cwd || process.cwd();
  const branch = gitBranch(cwd);
  const ctxPct = Math.round(data.context_window?.used_percentage || 0);

  // Rate limits: take the freshest of {payload, cc-alchemy cache} per window
  // (payload resets_at can be stale on long sessions; cache is freshly fetched).
  const cache = readCache();
  const five = pickWindow(data.rate_limits?.five_hour, cache.five_hour);
  const week = pickWindow(data.rate_limits?.seven_day, cache.seven_day);

  const mins = sessionMins(data.transcript_path);
  const cost = data.cost?.total_cost_usd;
  const inTok = data.context_window?.total_input_tokens || 0;
  const outTok = data.context_window?.total_output_tokens || 0;

  const SEP = ` ${DIM}|${RST} `;

  // Line 1: identity (model + branch)
  const line1 = [`${DIM}Model: ${MODEL}${name}${RST}`];
  if (branch) line1.push(`${DIM}branch:${BRANCH}${branch}${RST}`);

  // Line 2: usage / cost metrics
  const line2 = [`${usageSeg("5h", five)} ${usageSeg("wk", week)}`];
  if (mins != null) line2.push(`${DIM}session:${TEXT}${fmtDuration(mins)}${RST}`);
  line2.push(`${DIM}ctx:${pcolor(ctxPct)}${bar(ctxPct, 10)}${ctxPct}%${RST}`);
  if (cost != null && cost > 0) line2.push(`${DIM}$${TEXT}${cost.toFixed(2)}${RST}`);
  if (inTok > 0 || outTok > 0) {
    line2.push(`${DIM}tok:${TEXT}${fmtTokens(inTok)}↑${fmtTokens(outTok)}↓${RST}`);
  }

  console.log(line1.join(SEP) + "\n" + line2.join(SEP));
  refreshCache();
}

main();
