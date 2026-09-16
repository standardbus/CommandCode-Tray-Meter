#!/usr/bin/env node
/**
 * One-shot Command Code limits probe.
 *
 * Always prints exactly one line of JSON (even on failure) so the tray and the
 * setup scripts can consume it without parsing prose.
 *
 *   node src/fetch.mjs                      # live probe using config.json
 *   node src/fetch.mjs --auth-only          # credential discovery, no network
 *   node src/fetch.mjs --url http://127.0.0.1:8787   # probe a fixture server
 *   node src/fetch.mjs --pretty             # indented output for humans
 *
 * Exit codes: 0 = data or non-fatal error payload, 2 = authentication needed,
 * 3 = the probe could not run at all (bad arguments, unreadable config).
 */

import { existsSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  STATUS,
  fetchLimits,
  formatClock,
  loadConfig,
  normalizeConfig,
  redact,
  resolveCredential,
} from "./limits.mjs";

const SRC_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SRC_DIR, "..");

function parseArgs(argv) {
  const options = { authOnly: false, pretty: false, url: "", configPath: "", outPath: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--auth-only":
        options.authOnly = true;
        break;
      case "--pretty":
        options.pretty = true;
        break;
      case "--url":
        options.url = argv[++index] ?? "";
        break;
      case "--config":
        options.configPath = argv[++index] ?? "";
        break;
      case "--out":
        options.outPath = argv[++index] ?? "";
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        if (arg.startsWith("--config=")) options.configPath = arg.slice("--config=".length);
        else if (arg.startsWith("--url=")) options.url = arg.slice("--url=".length);
        else if (arg.startsWith("--out=")) options.outPath = arg.slice("--out=".length);
        else {
          console.error(`Unrecognised argument: ${arg}`);
          process.exit(3);
        }
    }
  }
  return options;
}

/**
 * Emit the payload on stdout, and additionally to a file when `--out` is given.
 * Writing the file from here (rather than redirecting our stdout) keeps the
 * caller from holding a lock on the destination while it reads the result back.
 */
function emit(payload, pretty, outPath) {
  const text = JSON.stringify(payload, null, pretty ? 2 : 0);
  process.stdout.write(`${text}\n`);
  if (outPath) {
    try {
      writeFileSync(outPath, `${text}\n`, "utf8");
    } catch (error) {
      console.error(`Could not write ${outPath}: ${error.message}`);
    }
  }
}

const options = parseArgs(process.argv.slice(2));
if (options.help) {
  console.log(
    [
      "Usage: node src/fetch.mjs [--auth-only] [--pretty] [--url URL] [--config PATH]",
      "",
      "  --auth-only   reports only which credential source was found",
      "  --url URL     overrides the base URL (useful with scripts/fixture-server.mjs)",
      "  --config PATH use an alternative configuration file",
      "  --pretty      indented JSON output",
    ].join("\n"),
  );
  process.exit(0);
}

const configPath = options.configPath
  ? resolve(options.configPath)
  : join(PROJECT_ROOT, "config.json");

let config;
try {
  config = loadConfig(configPath);
} catch (error) {
  emit({ status: STATUS.HTTP_ERROR, message: redact(`config.json is not readable: ${error.message}`) }, options.pretty, options.outPath);
  process.exit(3);
}

if (options.url) {
  config = normalizeConfig({
    ...config,
    endpoints: { ...config.endpoints, baseUrl: options.url },
  });
}

if (options.authOnly) {
  const credential = resolveCredential(config);
  const payload = {
    configPath,
    configExists: existsSync(configPath),
    hasToken: Boolean(credential.token),
    source: credential.source,
    ...(credential.error ? { status: credential.error, message: credential.message } : {}),
  };
  emit(payload, true, options.outPath);
  process.exit(credential.error ? 2 : 0);
}

let result;
try {
  result = await fetchLimits(config);
} catch (error) {
  // fetchLimits is designed not to throw; this is a last-resort guard so the
  // tray always receives parseable JSON.
  result = {
    status: STATUS.NETWORK_ERROR,
    source: "none",
    fetchedAt: Date.now(),
    message: redact(`Unexpected error: ${error?.message ?? error}`),
  };
}

if (result.fetchedAt) result.fetchedAtClock = formatClock(result.fetchedAt);
emit(result, options.pretty, options.outPath);
process.exit(result.status === STATUS.AUTH_NEEDED ? 2 : 0);
