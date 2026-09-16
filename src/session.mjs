#!/usr/bin/env node
/**
 * Long-running limits session for the tray.
 *
 * Owns three responsibilities:
 *   1. a single-instance lock, so two tray icons can never run at once;
 *   2. polling Command Code on a jittered interval with backoff on failure;
 *   3. a loopback HTTP server the PowerShell tray queries every tick, including
 *      "refresh now" when the popup opens.
 *
 * The lock is an exclusive file create holding the owning PID. A lock whose PID
 * is gone is stale and is taken over, so a hard-killed tray cannot wedge the
 * monitor permanently.
 *
 *   node src/session.mjs [--config PATH] [--interval SECONDS] [--once]
 *
 * Prints one JSON line on startup: {"event":"listening","port":N,...}
 */

import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { STATUS, fetchLimits, loadConfig, normalizeConfig, redact } from "./limits.mjs";

const SRC_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SRC_DIR, "..");
const CACHE_DIR = join(PROJECT_ROOT, ".cache");
const LOCK_PATH = join(CACHE_DIR, "session.lock");
const SESSION_PATH = join(CACHE_DIR, "session.json");

const MAX_BACKOFF_MS = 15 * 60 * 1000;

function parseArgs(argv) {
  const options = { configPath: "", interval: 0, once: false, watchStdin: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--once") options.once = true;
    else if (arg === "--watch-stdin") options.watchStdin = true;
    else if (arg === "--config") options.configPath = argv[++index] ?? "";
    else if (arg.startsWith("--config=")) options.configPath = arg.slice("--config=".length);
    else if (arg === "--interval") options.interval = Number(argv[++index] ?? 0);
    else if (arg.startsWith("--interval=")) options.interval = Number(arg.slice("--interval=".length));
  }
  return options;
}

function log(object) {
  process.stdout.write(`${JSON.stringify(object)}\n`);
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the PID exists but belongs to another user.
    return error?.code === "EPERM";
  }
}

/**
 * Take the single-instance lock. Returns null on success, or the owning PID of
 * the live instance that already holds it.
 */
function acquireLock() {
  mkdirSync(CACHE_DIR, { recursive: true });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      writeFileSync(LOCK_PATH, JSON.stringify({ pid: process.pid, at: Date.now() }), { flag: "wx" });
      return null;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      let owner = null;
      try {
        owner = JSON.parse(readFileSync(LOCK_PATH, "utf8"));
      } catch {
        owner = null;
      }
      if (owner && isProcessAlive(Number(owner.pid))) return Number(owner.pid);
      // Stale lock: the previous owner is gone. Remove it and retry once.
      try {
        rmSync(LOCK_PATH, { force: true });
      } catch {
        /* another process may have removed it first */
      }
    }
  }
  return null;
}

function releaseLock() {
  try {
    const owner = JSON.parse(readFileSync(LOCK_PATH, "utf8"));
    if (Number(owner?.pid) === process.pid) rmSync(LOCK_PATH, { force: true });
  } catch {
    /* nothing to release */
  }
  try {
    const session = JSON.parse(readFileSync(SESSION_PATH, "utf8"));
    if (Number(session?.pid) === process.pid) rmSync(SESSION_PATH, { force: true });
  } catch {
    /* nothing to release */
  }
}

const options = parseArgs(process.argv.slice(2));
const configPath = options.configPath ? resolve(options.configPath) : join(PROJECT_ROOT, "config.json");
let config = loadConfig(configPath);
if (options.interval > 0) config = normalizeConfig({ ...config, refreshSeconds: options.interval });

/** Shared state, read by every /state request. */
const state = {
  result: {
    status: STATUS.NETWORK_ERROR,
    source: "none",
    fetchedAt: 0,
    message: "Primo aggiornamento in corso.",
  },
  fetching: false,
  fetchedAt: 0,
  consecutiveFailures: 0,
  lastDurationMs: 0,
  partialAt: 0,
};

/** Bumped on every state change so the tray can tell "new numbers" from
 * "same numbers" with a single integer comparison. */
let revision = 0;

function bumpRevision() {
  revision += 1;
}

/** Snapshot of everything the tray renders, plus freshness metadata. */
function snapshot() {
  return {
    ...state.result,
    age: state.result.fetchedAt ? Date.now() - state.result.fetchedAt : null,
    fetching: state.fetching,
    consecutiveFailures: state.consecutiveFailures,
    refreshSeconds: config.refreshSeconds,
    lastDurationMs: state.lastDurationMs,
    partialAt: state.partialAt,
    revision,
    pid: process.pid,
  };
}

async function refresh(reason) {
  if (state.fetching) return state.result;
  state.fetching = true;
  const started = Date.now();
  // The windows arrive long before the optional USD line, so publish them the
  // moment they are ready instead of holding the whole answer back. The previous
  // USD line is carried over in the meantime: a partial result means "these
  // numbers are newer", not "drop the line that is still valid".
  const onPartial = (partial) => {
    if (partial.status) return;
    const previous = state.result;
    state.result = {
      ...partial,
      // Carry the slow-tail fields over rather than dropping them: a partial
      // result means "these windows are newer", not "forget the rest".
      credits: previous.credits ?? null,
      creditsPending: partial.creditsPending === true,
      monthly: previous.monthly ?? null,
      tokens: previous.tokens ?? null,
      runs: previous.runs ?? null,
      plan: previous.plan ?? null,
      display: {
        ...partial.display,
        ...(previous.display?.creditsText ? { creditsText: previous.display.creditsText } : {}),
        ...(previous.display?.usageText ? { usageText: previous.display.usageText } : {}),
      },
    };
    state.fetchedAt = partial.fetchedAt;
    state.partialAt = Date.now();
    bumpRevision();
  };
  try {
    const result = await fetchLimits(config, { onPartial });
    if (result.status) {
      state.consecutiveFailures += 1;
      // Keep the last good numbers on screen: a transient network failure must
      // not blank out the limits the user is looking at.
      const previous = state.result;
      if (!previous.status && previous.fetchedAt > 0) {
        state.result = { ...previous, stale: true, staleReason: result.message, lastErrorAt: Date.now() };
      } else {
        state.result = result;
      }
    } else {
      state.consecutiveFailures = 0;
      state.result = result;
      state.fetchedAt = result.fetchedAt;
    }
    return result;
  } catch (error) {
    state.consecutiveFailures += 1;
    const message = redact(`Errore imprevisto: ${error?.message ?? error}`);
    state.result = { ...state.result, stale: true, staleReason: message, lastErrorAt: Date.now() };
    return { status: STATUS.NETWORK_ERROR, message };
  } finally {
    state.fetching = false;
    state.lastDurationMs = Date.now() - started;
    bumpRevision();
  }
}

const owner = acquireLock();
if (owner !== null) {
  log({ event: "already_running", pid: owner });
  process.exit(0);
}

// A live session.json whose PID is still running means the lock file was lost
// (manual deletion, cleanup tooling). Refuse to start rather than hijack the
// port the running tray is already talking to.
try {
  const existing = JSON.parse(readFileSync(SESSION_PATH, "utf8"));
  if (Number(existing?.pid) !== process.pid && isProcessAlive(Number(existing?.pid))) {
    log({ event: "already_running", pid: Number(existing.pid) });
    process.exit(0);
  }
} catch {
  /* no previous session, or it is unreadable: the stale file is overwritten below */
}

let timer = null;
let shuttingDown = false;

function snapshotForOnce() {
  return { ...state.result, consecutiveFailures: state.consecutiveFailures };
}

function scheduleNext() {
  if (shuttingDown) return;
  const base = Math.max(15, Number(config.refreshSeconds) || 120) * 1000;
  // Back off on repeated failures so a broken token or an outage cannot turn
  // into a retry storm; a manual refresh always bypasses this.
  const backoff = state.consecutiveFailures === 0
    ? base
    : Math.min(MAX_BACKOFF_MS, base * 2 ** Math.min(state.consecutiveFailures, 5));
  // Jitter keeps multiple machines from synchronising their polls.
  const jitter = backoff * (0.9 + Math.random() * 0.2);
  timer = setTimeout(async () => {
    await refresh("scheduled");
    scheduleNext();
  }, Math.round(jitter));
  if (typeof timer.unref === "function") timer.unref();
}

const sessionToken = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
const ALLOWED_ENDPOINTS = new Set(["/state", "/refresh", "/health"]);

function send(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

const server = createServer((request, response) => {
  let pathname;
  try {
    pathname = new URL(request.url, "http://127.0.0.1").pathname;
  } catch {
    send(response, 400, { error: "bad_request" });
    return;
  }
  if (!ALLOWED_ENDPOINTS.has(pathname)) {
    send(response, 404, { error: "not_found" });
    return;
  }
  // Loopback-only plus a per-run token: a local server still should not answer
  // whatever else happens to be running on the machine.
  if (request.headers["x-session-token"] !== sessionToken) {
    send(response, 403, { error: "forbidden" });
    return;
  }

  if (pathname === "/health") {
    send(response, 200, { ok: true, pid: process.pid });
    return;
  }
  if (pathname === "/state") {
    send(response, 200, snapshot());
    return;
  }

  // /refresh: kick the work off and answer at once. The caller already has a
  // cached value to draw; the fresh numbers are picked up on the next /state
  // read, and the windows land there long before the USD tail.
  const alreadyRunning = state.fetching;
  if (!alreadyRunning) {
    refresh("request").then(() => scheduleNext());
  }
  send(response, 202, { ...snapshot(), started: !alreadyRunning });
});

function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  if (timer) clearTimeout(timer);
  try {
    server.close();
  } catch {
    /* already closed */
  }
  releaseLock();
  process.exit(code);
}

server.on("error", (error) => {
  log({ event: "error", message: redact(error?.message ?? String(error)) });
  shutdown(1);
});

server.listen(0, "127.0.0.1", () => {
  const { port } = server.address();
  writeFileSync(
    SESSION_PATH,
    JSON.stringify({ port, sessionToken, pid: process.pid, startedAt: Date.now() }),
    "utf8",
  );
  log({ event: "listening", port, sessionToken, pid: process.pid, configPath });
  if (options.once) {
    refresh("startup").then(() => {
      console.log(JSON.stringify(snapshotForOnce(), null, 2));
      shutdown(0);
    });
  } else {
    refresh("startup").then(scheduleNext);
  }
});

process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));
// Opt-in only: the tray passes --watch-stdin so this process dies with it.
// Watching stdin unconditionally would be a trap, because a redirected or
// already-closed stdin fires `close` immediately and would exit at startup.
if (options.watchStdin) {
  process.stdin.on("end", () => shutdown(0));
  process.stdin.on("close", () => shutdown(0));
  process.stdin.resume();
}
