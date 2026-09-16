// Minimal stand-in for `src/session.mjs`, for tests and for demonstrating the
// tray without credentials.
//
// It speaks the same loopback contract (`/state`, `/refresh`) and writes the
// same `.cache/session.json`, so the tray takes exactly the code path it takes
// in production. Values mutate on every /refresh, which is what makes the
// "updates while the bubble is open" behaviour observable.
//
//   node test/session-stub.mjs [--port 0] [--state-file <path>]

import { createServer } from "node:http";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SRC_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SRC_DIR, "..");

function parseArgs(argv) {
  const options = { port: 0, stateFile: join(PROJECT_ROOT, ".cache", "session.json") };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg.startsWith("--port=")) options.port = Number(arg.slice("--port=".length));
    else if (arg === "--state-file") options.stateFile = argv[++index];
    else if (arg.startsWith("--state-file=")) options.stateFile = arg.slice("--state-file=".length);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const sessionToken = `stub-${Math.random().toString(36).slice(2, 12)}`;

let revision = 0;
let fetchCount = 0;

function snapshot() {
  const fiveUsed = Math.min(14, 2 + fetchCount * 1.5);
  const weeklyUsed = Math.min(35, 8 + fetchCount * 2);
  const monthlyUsed = Math.min(70, 9 + fetchCount * 2.5);
  const tokens = 563961963 + fetchCount * 120000;
  const runs = 3120 + fetchCount * 3;
  const now = Date.now();
  return {
    source: "stub",
    fetchedAt: now,
    plan: { id: "stub-plan", periodStart: new Date(now - 86400000).toISOString(), periodEnd: new Date(now + 86400000).toISOString() },
    fiveHour: { used: fiveUsed, cap: 14, percent: (fiveUsed / 14) * 100, resetAt: new Date(now + 3600000).toISOString() },
    weekly: { used: weeklyUsed, cap: 35, percent: (weeklyUsed / 35) * 100, resetAt: new Date(now + 86400000).toISOString() },
    monthly: { used: monthlyUsed, cap: 70, percent: (monthlyUsed / 70) * 100, resetAt: new Date(now + 20 * 86400000).toISOString() },
    tokens: { total: tokens, input: tokens - 3855762, output: 3855762 },
    runs: { total: runs, completed: runs, failed: 0, successRate: 100 },
    credits: { used: 4 + fetchCount, limit: 70, remaining: 66 - fetchCount, percent: ((4 + fetchCount) / 70) * 100 },
    creditsPending: false,
    limited: false,
    exceeded: null,
    display: {
      fiveHourPercent: `${Math.round((fiveUsed / 14) * 100)}%`,
      fiveHourUsage: `${fiveUsed.toFixed(2).replace(".", ",")} / 14`,
      fiveHourResetIn: "1h",
      fiveHourResetAt: "domani",
      weeklyPercent: `${Math.round((weeklyUsed / 35) * 100)}%`,
      weeklyUsage: `${weeklyUsed.toFixed(2).replace(".", ",")} / 35`,
      weeklyResetIn: "1g",
      weeklyResetAt: "domani",
      monthlyPercent: `${Math.round((monthlyUsed / 70) * 100)}%`,
      monthlyUsage: `${monthlyUsed.toFixed(2).replace(".", ",")} / 70`,
      monthlyResetIn: "20g",
      monthlyResetAt: "domani",
      tokensValue: `${(tokens / 1e6).toFixed(1).replace(".", ",")} M`,
      runsValue: String(runs),
      creditsText: `Crediti: ${(4 + fetchCount).toFixed(2)} su 70,00 USD`,
    },
    revision,
    fetching: false,
    consecutiveFailures: 0,
    refreshSeconds: 15,
    lastDurationMs: 5,
    pid: process.pid,
  };
}

function send(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  response.end(body);
}

const server = createServer((request, response) => {
  const path = new URL(request.url, "http://127.0.0.1").pathname;
  if (path !== "/state" && path !== "/refresh") {
    send(response, 404, { error: "not_found" });
    return;
  }
  if (request.headers["x-session-token"] !== sessionToken) {
    send(response, 403, { error: "forbidden" });
    return;
  }
  if (path === "/refresh") {
    fetchCount += 1;
    revision += 1;
    send(response, 202, { ...snapshot(), started: true });
    return;
  }
  send(response, 200, snapshot());
});

server.listen(options.port, "127.0.0.1", () => {
  const { port } = server.address();
  mkdirSync(dirname(options.stateFile), { recursive: true });
  writeFileSync(
    options.stateFile,
    JSON.stringify({ port, sessionToken, pid: process.pid, startedAt: Date.now() }),
    "utf8",
  );
  console.log(JSON.stringify({ event: "stub_listening", port, pid: process.pid }));
});
