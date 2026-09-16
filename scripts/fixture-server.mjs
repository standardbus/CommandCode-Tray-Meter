#!/usr/bin/env node
/**
 * Local fixture server that mimics Command Code's `/alpha/*` endpoints.
 *
 * Lets the whole pipeline (session -> loopback -> tray popup) be exercised, and
 * the "updates in real time while the popup is open" behaviour demonstrated,
 * without a real credential.
 *
 *   node scripts/fixture-server.mjs [--port 8787] [--mode grow|full|weekly|auth|down]
 *
 * Point the monitor at it with either:
 *   node src/fetch.mjs --url http://127.0.0.1:8787
 *   node src/session.mjs --config <(endpoints.baseUrl = fixture)/  (see README)
 *
 * `--mode grow` increments usage on every request, which is what makes a live
 * refresh visible in the tray.
 */

import { createServer } from "node:http";

function parseArgs(argv) {
  const options = { port: 8787, mode: "grow" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg.startsWith("--port=")) options.port = Number(arg.slice("--port=".length));
    else if (arg === "--mode") options.mode = String(argv[++index] ?? "grow");
    else if (arg.startsWith("--mode=")) options.mode = arg.slice("--mode=".length);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
let tick = 0;

const json = (response, statusCode, payload) => {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  response.end(body);
};

const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  const path = url.pathname;
  tick += 1;

  if (options.mode === "auth" && path !== "/alpha/whoami") {
    json(response, 401, { error: "unauthorized" });
    return;
  }
  if (options.mode === "down") {
    json(response, 503, { error: "service unavailable" });
    return;
  }
  if (path === "/alpha/whoami") {
    json(response, 200, { org: { id: "team-org-7", name: "Fixture Team" } });
    return;
  }
  if (path === "/alpha/billing/subscriptions") {
    const start = new Date();
    start.setDate(1);
    const end = new Date(start);
    end.setMonth(end.getMonth() + 1);
    json(response, 200, {
      data: {
        planId: "individual-pro",
        currentPeriodStart: start.toISOString(),
        currentPeriodEnd: end.toISOString(),
      },
    });
    return;
  }
  if (path === "/alpha/usage/summary") {
    json(response, 200, { data: { totalCost: Number(url.searchParams.get("since") ? 15.4 : 0) } });
    return;
  }
  if (path === "/alpha/billing/credits") {
    const grow = (start, step, cap) => Math.min(cap, start + step * (tick - 1));
    const fiveHourUsed = options.mode === "grow" ? grow(40, 7, 100) : 40;
    const weeklyUsed = options.mode === "grow" ? grow(120, 11, 500) : 120;
    if (options.mode === "weekly") {
      json(response, 200, { data: { windowLimits: { weekly: { cap: 500, used: weeklyUsed } } } });
      return;
    }
    json(response, 200, {
      credits: { monthlyCredits: 20, purchasedCredits: 0, freeCredits: 1 },
      windowLimits: {
        fiveHour: {
          cap: 100,
          used: fiveHourUsed,
          resetAt: new Date(Date.now() + 3 * 3600_000 + 12 * 60_000).toISOString(),
        },
        weekly: {
          cap: 500,
          used: weeklyUsed,
          resetAt: new Date(Date.now() + 2 * 86400_000 + 4 * 3600_000).toISOString(),
        },
        exceeded: null,
        limited: false,
      },
    });
    return;
  }
  json(response, 404, { error: "not_found", path });
});

server.listen(options.port, "127.0.0.1", () => {
  console.log(
    `fixture server su http://127.0.0.1:${options.port} (modo: ${options.mode}). ` +
      `Try: node src/fetch.mjs --url http://127.0.0.1:${options.port} --pretty`,
  );
});
