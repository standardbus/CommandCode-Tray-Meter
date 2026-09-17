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

import { STATUS, fetchAllProfiles, loadConfig, normalizeConfig, redact, resolveActiveProfileId, resolveProfiles, writeActiveProfileId } from "./limits.mjs";

const SRC_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SRC_DIR, "..");
const CACHE_DIR = join(PROJECT_ROOT, ".cache");
const LOCK_PATH = join(CACHE_DIR, "session.lock");
const SESSION_PATH = join(CACHE_DIR, "session.json");
/** Menu choice made in the tray, which outlives any single session process. */
const ACTIVE_PROFILE_PATH = join(CACHE_DIR, "active-profile.json");

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

// The account list is resolved once per process: resolveProfiles() reports an
// unusable list by throwing, and the tray must still receive a payload it can
// render, so that failure becomes a single synthetic account carrying the
// reason.
function listProfiles() {
  try {
    return resolveProfiles(config);
  } catch (error) {
    return [{ id: "config", name: "config" }];
  }
}

const profiles = listProfiles();
/** Cache-first, so an account chosen in the tray menu survives a restart. */
const initialActiveId = resolveActiveProfileId(config, profiles, { cachePath: ACTIVE_PROFILE_PATH }) || profiles[0]?.id || "";

/** What one account's fetch currently holds. */
function emptyEntry(profile) {
  return {
    profile,
    result: {
      status: STATUS.NETWORK_ERROR,
      source: "none",
      fetchedAt: 0,
      message: "First update in progress.",
    },
    consecutiveFailures: 0,
  };
}

/** Shared state, read by every /state request. */
const state = {
  profiles,
  entries: new Map(profiles.map((profile) => [profile.id, emptyEntry(profile)])),
  activeId: initialActiveId,
  fetching: false,
  fetchedAt: 0,
  lastDurationMs: 0,
  partialAt: 0,
};

/** Bumped on every state change so the tray can tell "new numbers" from
 * "same numbers" with a single integer comparison. */
let revision = 0;

function bumpRevision() {
  revision += 1;
}

/** The active account, or the first one when the id no longer names an account. */
function activeEntry() {
  return state.entries.get(state.activeId) ?? state.entries.values().next().value ?? null;
}

/** Worst failure count across accounts: it drives the retry backoff. */
function failureCount() {
  let worst = 0;
  for (const entry of state.entries.values()) worst = Math.max(worst, entry.consecutiveFailures);
  return worst;
}

/** The one account the bubble and the tray icon follow, without the session
 * metadata. Absent while the very first fetch is still in flight. */
function activeResult() {
  return activeEntry()?.result ?? null;
}

/**
 * Every account, in configuration order, with the figures the tray's Accounts
 * section renders. Only the display block is carried: the tray never formats an
 * account row from raw API numbers.
 */
function accountSummaries() {
  return state.profiles.map((profile) => {
    const result = state.entries.get(profile.id)?.result ?? {};
    return {
      id: profile.id,
      name: profile.name,
      ...(result.status ? { status: result.status } : {}),
      fiveHour: result.fiveHour ?? null,
      weekly: result.weekly ?? null,
      monthly: result.monthly ?? null,
      display: result.display ?? {},
    };
  });
}

/** Snapshot of everything the tray renders, plus freshness metadata. */
function snapshot() {
  const result = activeResult() ?? {};
  const multiple = state.profiles.length > 1;
  return {
    // The active account's fields stay at the top level, so every existing tray
    // code path keeps reading the payload it always read.
    ...result,
    ...(multiple ? { activeProfile: state.activeId, accounts: accountSummaries() } : {}),
    age: result.fetchedAt ? Date.now() - result.fetchedAt : null,
    fetching: state.fetching,
    consecutiveFailures: failureCount(),
    refreshSeconds: config.refreshSeconds,
    lastDurationMs: state.lastDurationMs,
    partialAt: state.partialAt,
    revision,
    pid: process.pid,
  };
}

/** Publish the windows of one account the moment they are ready. */
function publishPartial(id, partial) {
  if (partial.status) return;
  const entry = state.entries.get(id);
  if (!entry) return;
  const previous = entry.result;
  entry.result = {
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
}

async function refresh(reason) {
  if (state.fetching) return activeResult();
  state.fetching = true;
  const started = Date.now();
  try {
    // Every account is fetched in parallel; one failing account never hides the
    // others, and a partial delivery refreshes only its own account.
    const duringFetch = state.activeId;
    const results = await fetchAllProfiles(config, {
      profiles: state.profiles,
      onPartial: (partial) => publishPartial(duringFetch, partial),
      onProfilePartial: (id, partial) => publishPartial(id, partial),
    });
    for (const { profile, result } of results) {
      const entry = state.entries.get(profile.id);
      if (entry) entry.result = result;
    }
    for (const entry of state.entries.values()) {
      const result = entry.result;
      if (result.status) {
        entry.consecutiveFailures += 1;
        // Keep the last good numbers on screen: a transient network failure must
        // not blank out the limits the user is looking at.
        if (!result.stale && result.fetchedAt > 0) {
          entry.result = { ...result, stale: true, staleReason: result.message, lastErrorAt: Date.now() };
        }
      } else {
        entry.consecutiveFailures = 0;
        state.fetchedAt = result.fetchedAt;
      }
    }
    return activeResult();
  } catch (error) {
    for (const entry of state.entries.values()) entry.consecutiveFailures += 1;
    const message = redact(`Unexpected error: ${error?.message ?? error}`);
    const entry = activeEntry();
    if (entry) {
      entry.result = { ...entry.result, stale: true, staleReason: message, lastErrorAt: Date.now() };
    }
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
  return { ...snapshot(), consecutiveFailures: failureCount() };
}

function scheduleNext() {
  if (shuttingDown) return;
  const base = Math.max(15, Number(config.refreshSeconds) || 120) * 1000;
  // Back off on repeated failures so a broken token or an outage cannot turn
  // into a retry storm; a manual refresh always bypasses this.
  const failures = failureCount();
  const backoff = failures === 0
    ? base
    : Math.min(MAX_BACKOFF_MS, base * 2 ** Math.min(failures, 5));
  // Jitter keeps multiple machines from synchronising their polls.
  const jitter = backoff * (0.9 + Math.random() * 0.2);
  timer = setTimeout(async () => {
    await refresh("scheduled");
    scheduleNext();
  }, Math.round(jitter));
  if (typeof timer.unref === "function") timer.unref();
}

const sessionToken = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
const ALLOWED_ENDPOINTS = new Set(["/state", "/refresh", "/health", "/profile"]);

function send(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

/** Read a small request body; anything oversized is refused rather than buffered. */
function readBody(request, limit = 4096) {
  return new Promise((resolve) => {
    let text = "";
    request.on("data", (chunk) => {
      text += chunk;
      if (text.length > limit) request.destroy();
    });
    request.on("end", () => resolve(text));
    request.on("error", () => resolve(""));
  });
}

/** Accept a menu choice, persist it and refresh, without blocking the answer. */
function selectProfile(id) {
  const wanted = String(id ?? "").trim().toLowerCase();
  const known = state.profiles.some((profile) => profile.id === wanted);
  if (!known) return null;
  if (wanted !== state.activeId) {
    state.activeId = wanted;
    // Recorded before the fetch: the choice must survive a restart even if the
    // network is down right now.
    writeActiveProfileId(wanted, { cachePath: ACTIVE_PROFILE_PATH });
    bumpRevision();
  }
  kickRefresh("profile");
  return wanted;
}

/** Start a fetch in the background; the caller answers from the cache at once. */
function kickRefresh(reason) {
  if (state.fetching) return false;
  refresh(reason)
    .then(() => scheduleNext())
    .catch((error) => log({ event: "error", message: redact(error?.message ?? String(error)) }));
  return true;
}

const server = createServer(async (request, response) => {
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
  if (pathname === "/profile") {
    if (request.method !== "POST") {
      send(response, 405, { error: "method_not_allowed" });
      return;
    }
    let wanted = "";
    try {
      const body = await readBody(request);
      wanted = body ? String(JSON.parse(body)?.id ?? "") : "";
    } catch {
      send(response, 400, { error: "bad_request" });
      return;
    }
    const selected = selectProfile(wanted);
    if (!selected) {
      send(response, 404, { error: "unknown_profile", id: wanted });
      return;
    }
    // The tray repaints from this answer, whose top-level fields already belong
    // to the newly active account.
    send(response, 200, { ...snapshot(), selected });
    return;
  }

  // /refresh: kick the work off and answer at once. The caller already has a
  // cached value to draw; the fresh numbers are picked up on the next /state
  // read, and the windows land there long before the USD tail.
  const started = kickRefresh("request");
  send(response, 202, { ...snapshot(), started });
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
