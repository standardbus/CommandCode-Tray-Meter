/**
 * Command Code usage-limit logic: credential resolution, payload parsing and
 * human-readable formatting.
 *
 * This module is intentionally free of side effects beyond reading credential
 * files, so it can be unit-tested without network access and reused by both the
 * one-shot CLI (`fetch.mjs`) and the long-running loopback session
 * (`session.mjs`).
 *
 * The Command Code API surface used here (`/alpha/*`) is NOT documented
 * publicly and may change without notice; every field is therefore read
 * defensively and every endpoint path is overridable from `config.json`.
 */

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

/** Machine-readable outcome codes surfaced to the tray. */
export const STATUS = Object.freeze({
  AUTH_NEEDED: "auth_needed",
  NETWORK_ERROR: "network_error",
  HTTP_ERROR: "http_error",
});

export const DEFAULT_BASE_URL = "https://api.commandcode.ai";

export const DEFAULT_ENDPOINTS = Object.freeze({
  baseUrl: DEFAULT_BASE_URL,
  whoamiPath: "/alpha/whoami",
  creditsPath: "/alpha/billing/credits",
  subscriptionsPath: "/alpha/billing/subscriptions",
  usageSummaryPath: "/alpha/usage/summary",
});

export const DEFAULT_REQUEST_TIMEOUT_MS = 8000;
export const DEFAULT_REFRESH_SECONDS = 120;
export const DEFAULT_MAX_AGE_ON_OPEN_SECONDS = 5;
export const DEFAULT_THRESHOLDS = Object.freeze({ warn: 60, critical: 85 });

/** Which window the tray icon's ring tracks. */
export const ICON_METRICS = Object.freeze(["fiveHour", "weekly", "monthly"]);
export const DEFAULT_ICON_METRIC = "fiveHour";

/**
 * Only these files are ever opened, and only for reading. Refreshing an expired
 * token belongs to the CLI that owns the file: writing here would race the CLI
 * and corrupt state shared by every harness on the machine.
 */
export const DEFAULT_CREDIT_FILES = Object.freeze([
  "~/.commandcode/auth.json",
  "~/.pi/agent/auth.json",
]);

/** Files whose entire contents belong to Command Code (unkeyed `apiKey` is safe only here). */
const OFFICIAL_AUTH_FILE = ".commandcode/auth.json";
/** Keys a harness may file the credential under. */
const CREDENTIAL_KEYS = ["command-code", "commandcode"];
/** Object fields that may hold the token itself. */
const TOKEN_FIELDS = ["access", "apiKey", "key"];

const MONTHS_SHORT = [
  "gen", "feb", "mar", "apr", "mag", "giu",
  "lug", "ago", "set", "ott", "nov", "dic",
];
const DAYS_SHORT = ["dom", "lun", "mar", "mer", "gio", "ven", "sab"];
const DAYS_LONG = [
  "domenica", "lunedi", "martedi", "mercoledi", "giovedi", "venerdi", "sabato",
];

// --- small helpers ---------------------------------------------------------

export function toFiniteNumber(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

export function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

/** Prefer the nested `data` shell when the outer object is only an envelope. */
export function unwrapData(value) {
  const record = asRecord(value);
  if (!record) return null;
  const inner = asRecord(record.data);
  return inner ?? record;
}

function clampPercent(value) {
  if (!Number.isFinite(value)) return undefined;
  return Math.min(100, Math.max(0, value));
}

/** Round to 2 decimals so the tray never renders 36.585365853658534%. */
function round2(value) {
  return Math.round(value * 100) / 100;
}

function toIsoOrUndefined(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return undefined;
    const parsed = Date.parse(trimmed);
    if (Number.isFinite(parsed)) return new Date(parsed).toISOString();
    return undefined;
  }
  const numeric = toFiniteNumber(value);
  // Seconds vs milliseconds: anything below ~1e11 is a seconds timestamp.
  if (numeric !== undefined && numeric > 0 && numeric < 1e11) {
    return new Date(numeric * 1000).toISOString();
  }
  if (numeric !== undefined && numeric >= 1e11) {
    return new Date(numeric).toISOString();
  }
  return undefined;
}

// --- formatting ------------------------------------------------------------

/** `"3h 12m"`, `"2g 4h"`, `"45m"`, `"ora"`. */
export function formatDelta(ms) {
  if (!Number.isFinite(ms)) return "-";
  if (ms <= 0) return "ora";
  const totalMinutes = Math.floor(ms / 60000);
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return hours > 0 ? `${days}g ${hours}h` : `${days}g`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  if (totalMinutes > 0) return `${totalMinutes}m`;
  return "<1m";
}

/** Percentage shown as an integer, matching the CLI's meter style. */
export function formatPercent(percent) {
  if (!Number.isFinite(percent)) return "-";
  return `${Math.round(percent)}%`;
}

/**
 * Compact credit amount for the panel: `"2"`, `"2,5"`, `"8,45"`.
 *
 * Two decimals at most, and a decimal separator that follows the configured
 * locale (Italian here): the raw API values carry nine decimals and render as
 * unreadable noise like `2.000223421`.
 */
export function formatAmount(value, locale = "it-IT") {
  const numeric = toFiniteNumber(value);
  if (numeric === undefined) return "-";
  const rounded = Math.round(numeric * 100) / 100;
  try {
    return rounded.toLocaleString(locale, { maximumFractionDigits: 2 });
  } catch {
    return String(rounded);
  }
}

/** `"2 / 14"` â€” the used-against-cap pair shown under each bar. */
export function formatUsagePair(used, cap, locale = "it-IT") {
  return `${formatAmount(used, locale)} / ${formatAmount(cap, locale)}`;
}

/**
 * Compact absolute time for a reset: `"20:00"`, `"domani 20:00"`,
 * `"lun 20:00"`, `"12 set 09:30"`.
 */
export function formatResetAt(iso, now = Date.now()) {
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return "-";
  const date = new Date(parsed);
  const reference = new Date(now);
  const hhmm = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const dayDiff = Math.round((startOfDay(date) - startOfDay(reference)) / 86400000);
  if (dayDiff <= 0) return hhmm;
  if (dayDiff === 1) return `domani ${hhmm}`;
  if (dayDiff < 7) return `${DAYS_SHORT[date.getDay()]} ${hhmm}`;
  return `${date.getDate()} ${MONTHS_SHORT[date.getMonth()]} ${hhmm}`;
}

/** Absolute date+time for the "last updated" footer: `"20:14:07"`. */
export function formatClock(ms) {
  const numeric = toFiniteNumber(ms);
  if (numeric === undefined) return "-";
  const date = new Date(numeric);
  return [date.getHours(), date.getMinutes(), date.getSeconds()]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");
}

/** Long-form reset timestamp used in the tooltip: `"lunedi 20:00"`. */
export function formatLongResetAt(iso, now = Date.now()) {
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return "-";
  const date = new Date(parsed);
  const hhmm = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  const dayName = DAYS_LONG[date.getDay()];
  return `${dayName} ${hhmm}`;
}

// --- credential resolution -------------------------------------------------

function expandHome(path) {
  const trimmed = String(path ?? "").trim();
  if (!trimmed) return "";
  if (trimmed === "~") return homedir();
  if (trimmed.startsWith("~/") || trimmed.startsWith("~\\")) {
    return join(homedir(), trimmed.slice(2));
  }
  return isAbsolute(trimmed) ? trimmed : join(process.cwd(), trimmed);
}

function readJsonFile(path, fs) {
  try {
    const text = fs.readFileSync(path, "utf8");
    const parsed = JSON.parse(String(text).replace(/^\uFEFF/, ""));
    return asRecord(parsed);
  } catch {
    // A missing or malformed file is skipped, never fatal: one broken source
    // must not mask a working one further down the list.
    return null;
  }
}

/** Extract `{ token, expires }` from a credential value of any known shape. */
function candidate(value) {
  if (typeof value === "string") {
    const token = value.trim();
    return token ? { token, expires: undefined } : null;
  }
  const record = asRecord(value);
  if (!record) return null;
  for (const field of TOKEN_FIELDS) {
    const raw = record[field];
    if (typeof raw === "string" && raw.trim()) {
      return { token: raw.trim(), expires: toFiniteNumber(record.expires) };
    }
  }
  return null;
}

function isExpired(expires, now) {
  return typeof expires === "number" && expires > 0 && expires <= now;
}

/**
 * Read one auth file and return a live candidate, if any.
 *
 * `apiKey` is unkeyed, so it is only consulted in Command Code's own file. A
 * shared harness keystore holds every provider the user signed into, so a key
 * that names no provider must not be read out of one.
 */
export function readAuthFile(filePath, { fs, now = Date.now() }) {
  const record = readJsonFile(filePath, fs);
  if (!record) return null;
  const isOfficial = String(filePath).replace(/\\/g, "/").endsWith(OFFICIAL_AUTH_FILE);
  const rawCandidates = [];
  for (const key of CREDENTIAL_KEYS) {
    if (key in record) rawCandidates.push(record[key]);
  }
  if (isOfficial && "apiKey" in record) rawCandidates.push(record.apiKey);
  for (const raw of rawCandidates) {
    const found = candidate(raw);
    if (!found) continue;
    if (isExpired(found.expires, now)) continue;
    return found;
  }
  return null;
}

function expiredOnlyIn(filePath, { fs, now }) {
  const record = readJsonFile(filePath, fs);
  if (!record) return false;
  const isOfficial = String(filePath).replace(/\\/g, "/").endsWith(OFFICIAL_AUTH_FILE);
  const rawCandidates = [];
  for (const key of CREDENTIAL_KEYS) {
    if (key in record) rawCandidates.push(record[key]);
  }
  if (isOfficial && "apiKey" in record) rawCandidates.push(record.apiKey);
  return rawCandidates.some((raw) => {
    const found = candidate(raw);
    return found ? isExpired(found.expires, now) : false;
  });
}

/**
 * Resolve the Bearer token and report where it came from.
 *
 * Precedence: `COMMANDCODE_API_KEY` -> `config.apiKey` -> configured auth files
 * (Command Code CLI first, then shared harness keystores). The returned `source`
 * is a description, never the secret itself.
 *
 * @returns {{token: string, source: string} | {error: string, source: string, message: string}}
 */
export function resolveCredential(config = {}, options = {}) {
  const fs = options.fs ?? { readFileSync };
  const env = options.env ?? process.env;
  const now = options.now ?? Date.now();

  const envToken = String(env?.COMMANDCODE_API_KEY ?? "").trim();
  if (envToken) return { token: envToken, source: "COMMANDCODE_API_KEY" };

  const configToken = String(config.apiKey ?? config.token ?? "").trim();
  if (configToken) return { token: configToken, source: "config.json" };

  const files = Array.isArray(config.creditFiles) && config.creditFiles.length > 0
    ? config.creditFiles
    : DEFAULT_CREDIT_FILES;
  const seenPaths = [];
  let sawExpired = false;
  for (const rawPath of files) {
    const filePath = expandHome(rawPath);
    if (!filePath) continue;
    seenPaths.push(filePath);
    const found = readAuthFile(filePath, { fs, now });
    if (found) return { token: found.token, source: filePath };
    if (expiredOnlyIn(filePath, { fs, now })) sawExpired = true;
  }

  if (sawExpired) {
    return {
      error: STATUS.AUTH_NEEDED,
      source: "none",
      message:
        "Accesso Command Code scaduto. Apri il CLI e ripeti l'accesso, oppure incolla una Provider-API key in config.json.",
    };
  }
  return {
    error: STATUS.AUTH_NEEDED,
    source: "none",
    message:
      "Nessuna credenziale Command Code. Incolla una Provider-API key in config.json (commandcode.ai/studio/provider) o imposta COMMANDCODE_API_KEY.",
  };
}

// --- configuration --------------------------------------------------------

/** Merge user config with defaults, ignoring the `$comment*` documentation keys. */
export function normalizeConfig(raw = {}) {
  const record = asRecord(raw) ?? {};
  const endpointsRaw = asRecord(record.endpoints) ?? {};
  const baseUrl = String(endpointsRaw.baseUrl ?? DEFAULT_BASE_URL).trim().replace(/\/+$/, "");
  const endpoints = {
    baseUrl: baseUrl || DEFAULT_BASE_URL,
    whoamiPath: String(endpointsRaw.whoamiPath ?? DEFAULT_ENDPOINTS.whoamiPath),
    creditsPath: String(endpointsRaw.creditsPath ?? DEFAULT_ENDPOINTS.creditsPath),
    subscriptionsPath: String(endpointsRaw.subscriptionsPath ?? DEFAULT_ENDPOINTS.subscriptionsPath),
    usageSummaryPath: String(endpointsRaw.usageSummaryPath ?? DEFAULT_ENDPOINTS.usageSummaryPath),
  };
  const thresholdsRaw = asRecord(record.thresholds) ?? {};
  const warn = toFiniteNumber(thresholdsRaw.warn);
  const critical = toFiniteNumber(thresholdsRaw.critical);
  const uiRaw = asRecord(record.ui) ?? {};
  const refresh = toFiniteNumber(record.refreshSeconds);
  const timeout = toFiniteNumber(record.requestTimeoutMs);

  return {
    apiKey: typeof record.apiKey === "string" ? record.apiKey : "",
    token: typeof record.token === "string" ? record.token : "",
    endpoints,
    refreshSeconds: refresh !== undefined && refresh >= 15 ? refresh : DEFAULT_REFRESH_SECONDS,
    requestTimeoutMs: timeout !== undefined && timeout >= 1000 ? timeout : DEFAULT_REQUEST_TIMEOUT_MS,
    thresholds: {
      warn: warn !== undefined ? clampPercent(warn) ?? DEFAULT_THRESHOLDS.warn : DEFAULT_THRESHOLDS.warn,
      critical:
        critical !== undefined ? clampPercent(critical) ?? DEFAULT_THRESHOLDS.critical : DEFAULT_THRESHOLDS.critical,
    },
    ui: {
      monochrome: uiRaw.monochrome === true,
      showTooltip: uiRaw.showTooltip !== false,
      iconMetric: ICON_METRICS.includes(String(uiRaw.iconMetric))
        ? String(uiRaw.iconMetric)
        : DEFAULT_ICON_METRIC,
    },
    creditFiles: Array.isArray(record.creditFiles)
      ? record.creditFiles.filter((value) => typeof value === "string")
      : [...DEFAULT_CREDIT_FILES],
  };
}

/** Read `config.json`, tolerating a missing or malformed file. */
export function loadConfig(configPath, { fs } = {}) {
  const reader = fs ?? { readFileSync };
  const record = readJsonFile(configPath, reader);
  return normalizeConfig(record ?? {});
}

// --- payload parsing -------------------------------------------------------

/**
 * One rolling window: `{ cap, used, resetAt }` off `/alpha/billing/credits`.
 * A window with no positive cap has not opened yet (or does not apply to the
 * plan) and must not be rendered as 0% used.
 */
export function parseWindow(value) {
  const record = asRecord(value);
  if (!record) return null;
  const cap = toFiniteNumber(record.cap);
  const used = toFiniteNumber(record.used);
  if (cap === undefined || used === undefined) return null;
  if (cap <= 0 || used < 0) return null;
  const percent = round2(clampPercent((used / cap) * 100) ?? 0);
  const resetAt = toIsoOrUndefined(record.resetAt) ?? null;
  return { used, cap, percent, resetAt };
}

/**
 * The USD credit pool is only meaningful when a billing period is known:
 * unscoped `/alpha/usage/summary` spend is lifetime, not current-cycle, and
 * mixing the two would produce a wrong percentage.
 */
export function computeCredits(credits, period, spend) {
  const record = asRecord(credits);
  if (!record) return null;
  const poolKeys = ["monthlyCredits", "purchasedCredits", "freeCredits"].filter((key) => key in record);
  const pools = poolKeys.map((key) => toFiniteNumber(record[key]));
  // Field presence is what separates a real balance from absent data: a fully
  // exhausted account still reports 0, while no field at all means there is
  // nothing to meter.
  if (pools.length === 0) return null;
  if (!period || !period.start) return null;
  const used = toFiniteNumber(spend);
  if (used === undefined || used < 0) return null;
  const remaining = pools.reduce((sum, value) => sum + Math.max(0, value ?? 0), 0);
  const limit = used + remaining;
  const percent = round2(limit > 0 ? clampPercent((used / limit) * 100) ?? 0 : 0);
  // Purchased credits roll over past the subscription period end, so an expiry
  // is only truthful when there is no non-expiring purchased pool at all.
  // Presence, not value: a spend-only account has no purchased field and keeps
  // its period end, while an exhausted purchased balance still counts as one.
  const hasPurchasedPool = poolKeys.includes("purchasedCredits");
  return {
    used,
    limit,
    remaining,
    percent,
    expiresAt: hasPurchasedPool ? null : period.end ?? null,
  };
}

export function parsePeriod(subscriptionsPayload) {
  const body = unwrapData(subscriptionsPayload);
  if (!body) return null;
  const start = toIsoOrUndefined(body.currentPeriodStart) ?? null;
  const end = toIsoOrUndefined(body.currentPeriodEnd) ?? null;
  const planId = typeof body.planId === "string" && body.planId.trim() ? body.planId.trim() : null;
  if (!start && !end && !planId) return null;
  return { start, end, planId };
}

export function parseOrgId(whoamiPayload) {
  const body = unwrapData(whoamiPayload);
  if (!body) return null;
  const org = asRecord(body.org);
  const id = typeof org?.id === "string" && org.id.trim() ? org.id.trim() : null;
  return id;
}

export function parseSpend(usagePayload) {
  const body = unwrapData(usagePayload);
  if (!body) return null;
  const total = toFiniteNumber(body.totalCost) ?? toFiniteNumber(body.totalMonthlyCredits);
  if (total === undefined || total < 0) return null;
  // This payload also carries the run and token totals the Studio dashboard
  // shows, so they come along instead of costing another request.
  const runs = toFiniteNumber(body.totalCount);
  const totalTokens = toFiniteNumber(body.totalTokens);
  return {
    cost: total,
    runs: runs !== undefined && runs >= 0 ? runs : null,
    completedRuns: toFiniteNumber(body.completedCount) ?? null,
    failedRuns: toFiniteNumber(body.failedCount) ?? null,
    successRate: toFiniteNumber(body.successRate) ?? null,
    totalTokens: totalTokens !== undefined && totalTokens >= 0 ? totalTokens : null,
    tokensIn: toFiniteNumber(body.totalTokensIn) ?? null,
    tokensOut: toFiniteNumber(body.totalTokensOut) ?? null,
  };
}

/**
 * The monthly window, derived rather than read.
 *
 * `windowLimits` has no `monthly` entry, but the monthly cap is simply the
 * subscription's credit allowance, and the response names the components of the
 * spend that consumes it: `totalCost` (billing-period scoped), plus what remains
 * in each pool, sums to the allowance. Verified against Studio, which reports
 * the same figure for this account (13% of a $70 monthly pool).
 */
export function computeMonthlyWindow(credits, period, spend) {
  const record = asRecord(credits);
  if (!record || !period || !period.start) return null;
  const used = spend?.cost ?? toFiniteNumber(spend);
  if (used === undefined || used < 0) return null;
  const remainingMonthly = toFiniteNumber(record.monthlyCredits);
  if (remainingMonthly === undefined) return null;
  const purchased = toFiniteNumber(record.purchasedCredits) ?? 0;
  const free = toFiniteNumber(record.freeCredits) ?? 0;
  const cap = used + Math.max(0, remainingMonthly) + Math.max(0, purchased) + Math.max(0, free);
  if (!(cap > 0)) return null;
  return {
    used,
    cap: round2(cap),
    percent: round2(clampPercent((used / cap) * 100) ?? 0),
    resetAt: period.end ?? null,
  };
}

/**
 * `"564,0 M"`, `"1,2 Mrd"` — token counts run to hundreds of millions and are
 * unreadable in full, so large values are scaled and the exact figure is kept in
 * the tooltip.
 */
export function formatTokenCount(value, locale = "it-IT") {
  const numeric = toFiniteNumber(value);
  if (numeric === undefined || numeric < 0) return "-";
  const scale = (divisor, suffix, decimals) => {
    const scaled = numeric / divisor;
    return `${scaled.toLocaleString(locale, {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    })} ${suffix}`;
  };
  if (numeric >= 1e9) return scale(1e9, "Mrd", 2);
  if (numeric >= 1e6) return scale(1e6, "M", 1);
  if (numeric >= 1e3) return scale(1e3, "K", 1);
  return numeric.toLocaleString(locale);
}

/** `"3.120"` with locale grouping. */
export function formatCount(value, locale = "it-IT") {
  const numeric = toFiniteNumber(value);
  if (numeric === undefined || numeric < 0) return "-";
  return Math.round(numeric).toLocaleString(locale);
}

/** Build the `display` block the tray renders (countdowns, clock times, amounts). */
export function buildDisplay(result, now = Date.now()) {
  const display = {};
  const windows = [
    ["fiveHour", result.fiveHour],
    ["weekly", result.weekly],
    ["monthly", result.monthly],
  ];
  for (const [key, window] of windows) {
    if (!window) continue;
    display[`${key}Percent`] = formatPercent(window.percent);
    // Pre-formatted so the panel never prints raw API floats.
    display[`${key}Usage`] = formatUsagePair(window.used, window.cap);
    if (window.resetAt) {
      const remaining = Date.parse(window.resetAt) - now;
      display[`${key}ResetIn`] = formatDelta(remaining);
      display[`${key}ResetAt`] = formatResetAt(window.resetAt, now);
      display[`${key}ResetLong`] = formatLongResetAt(window.resetAt, now);
    }
  }
  if (result.credits) {
    display.creditsPercent = formatPercent(result.credits.percent);
    display.creditsText = `Crediti: ${formatAmount(result.credits.used)} su ${formatAmount(
      result.credits.limit,
    )} USD  (${formatAmount(result.credits.remaining)} rimasti)`;
  }
  if (result.tokens) {
    display.tokensValue = formatTokenCount(result.tokens.total);
    if (result.tokens.input !== null && result.tokens.output !== null) {
      display.tokensDetail = `${formatTokenCount(result.tokens.input)} in / ${formatTokenCount(result.tokens.output)} out`;
    }
  }
  if (result.runs) {
    display.runsValue = formatCount(result.runs.total);
    if (result.runs.failed !== null && result.runs.failed > 0) {
      display.runsDetail = `${formatCount(result.runs.failed)} falliti`;
    } else if (result.runs.successRate !== null) {
      display.runsDetail = `${formatAmount(result.runs.successRate)}% riusciti`;
    }
  }
  return display;
}

/** Compact tooltip text (Windows caps a tray tooltip at 63 characters). */
export function buildTooltip(result) {
  if (result.status) {
    const label = result.status === STATUS.AUTH_NEEDED ? "accesso richiesto" : "dati non disponibili";
    return `Command Code: ${label}`;
  }
  const parts = [];
  if (result.display?.fiveHourPercent) {
    const suffix = result.display.fiveHourResetIn ? ` (reset ${result.display.fiveHourResetIn})` : "";
    parts.push(`5h ${result.display.fiveHourPercent}${suffix}`);
  }
  if (result.display?.weeklyPercent) parts.push(`7g ${result.display.weeklyPercent}`);
  if (result.display?.monthlyPercent) parts.push(`30g ${result.display.monthlyPercent}`);
  if (parts.length === 0) return "Command Code: nessun limite attivo";
  return `Command Code ${parts.join(" | ")}`;
}

// --- HTTP ------------------------------------------------------------------

function joinUrl(base, path) {
  if (/^https?:\/\//i.test(path)) return path;
  return `${base.replace(/\/+$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
}

/**
 * Soft-fail GET returning a parsed JSON record, or null when unavailable.
 * `redirect: "error"` keeps the Bearer token from ever following a redirect.
 */
async function getJson(url, { token, timeoutMs, fetchImpl }) {
  const response = await fetchImpl(url, {
    headers: { Accept: "application/json", Authorization: `Bearer ${token}` },
    redirect: "error",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    const error = new Error(`HTTP ${response.status}`);
    error.httpStatus = response.status;
    throw error;
  }
  return unwrapData(await response.json());
}

/**
 * Fetch live limits. Never throws: always resolves to a result object carrying
 * either live data or a `status` code the tray can render.
 *
 * The two rolling windows come from a single fast call, so `onPartial` fires
 * with them as soon as they are available. The USD credit line needs two slow
 * calls (subscriptions ~1.5s, usage summary ~0.7s) and is therefore hydrated
 * afterwards: when `onPartial` is supplied the caller can render the windows
 * immediately instead of blocking on the optional line.
 */
export async function fetchLimits(config, options = {}) {
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const now = options.now ?? Date.now();
  const timeoutMs = config.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
  const endpoints = { ...DEFAULT_ENDPOINTS, ...(config.endpoints ?? {}) };
  const onPartial = typeof options.onPartial === "function" ? options.onPartial : null;

  const credential = resolveCredential(config, options);
  if (credential.error) {
    return {
      status: credential.error,
      source: credential.source,
      fetchedAt: now,
      message: credential.message,
    };
  }
  const { token, source } = credential;

  const base = { source, fetchedAt: now };
  const plainCreditsUrl = joinUrl(endpoints.baseUrl, endpoints.creditsPath);

  // whoami only scopes team accounts by orgId; credits is the critical path.
  // Racing them costs the slower of the two, not the sum, and a failed whoami
  // just means an unscoped read.
  // whoami only scopes team accounts by orgId, and credits is the critical path:
  // racing them costs the slower of the two, not their sum.
  const [orgQuery, creditsRead] = await Promise.all([
    (async () => {
      try {
        const whoami = await getJson(joinUrl(endpoints.baseUrl, endpoints.whoamiPath), {
          token,
          timeoutMs,
          fetchImpl,
        });
        const orgId = parseOrgId(whoami);
        return orgId ? `?orgId=${encodeURIComponent(orgId)}` : "";
      } catch {
        return "";
      }
    })(),
    getJson(plainCreditsUrl, { token, timeoutMs, fetchImpl }).then(
      (value) => ({ ok: true, value }),
      (error) => ({ ok: false, error }),
    ),
  ]);

  if (!creditsRead.ok) {
    const error = creditsRead.error;
    const status = error?.httpStatus;
    if (status === 401 || status === 403) {
      return {
        ...base,
        status: STATUS.AUTH_NEEDED,
        httpStatus: status,
        message:
          "Command Code ha rifiutato la credenziale (HTTP " +
          status +
          "). Rinnova la Provider-API key in config.json.",
      };
    }
    return {
      ...base,
      status: status === undefined ? STATUS.NETWORK_ERROR : STATUS.HTTP_ERROR,
      httpStatus: status,
      message:
        status === undefined
          ? "Rete non raggiungibile su api.commandcode.ai."
          : `Errore HTTP ${status} da api.commandcode.ai.`,
    };
  }

  const body = creditsRead.value;
  const credits = asRecord(body?.credits);
  const limits = asRecord(body?.windowLimits);
  const fiveHour = parseWindow(limits?.fiveHour);
  const weekly = parseWindow(limits?.weekly);
  if (!fiveHour && !weekly && !credits) {
    return {
      ...base,
      status: STATUS.HTTP_ERROR,
      message: "Risposta inattesa da /alpha/billing/credits (schema non riconosciuto).",
    };
  }

  const result = {
    ...base,
    plan: null,
    fiveHour,
    weekly,
    // Filled in with the slow tail; the windows above are what the fast path
    // can already deliver.
    monthly: null,
    credits: null,
    tokens: null,
    runs: null,
    creditsPending: Boolean(credits),
    limited: limits?.limited === true,
    exceeded: limits?.exceeded ?? null,
  };
  result.display = buildDisplay(result, now);
  result.tooltip = buildTooltip(result);

  // The windows are ready: let the caller paint before the slow tail.
  if (onPartial && credits) {
    try {
      onPartial({ ...result, display: { ...result.display } });
    } catch {
      /* a failing consumer must not break the fetch */
    }
  }

  if (!credits) return result;

  // Optional tail: subscription period + period spend, for the USD line only.
  // A team account needs the org-scoped read; that re-read happens here, after
  // the fast path has already been delivered, so it never delays the windows.
  let scopedCredits = credits;
  if (orgQuery) {
    try {
      const scoped = await getJson(`${plainCreditsUrl}${orgQuery}`, { token, timeoutMs, fetchImpl });
      const scopedLimits = asRecord(scoped?.windowLimits);
      const scopedFiveHour = parseWindow(scopedLimits?.fiveHour);
      const scopedWeekly = parseWindow(scopedLimits?.weekly);
      if (scopedFiveHour || scopedWeekly) {
        result.fiveHour = scopedFiveHour;
        result.weekly = scopedWeekly;
        result.limited = scopedLimits?.limited === true;
        result.exceeded = scopedLimits?.exceeded ?? null;
      }
      if (asRecord(scoped?.credits)) scopedCredits = asRecord(scoped.credits);
    } catch {
      /* keep the unscoped read rather than lose the windows */
    }
  }

  let period = null;
  try {
    period = parsePeriod(
      await getJson(`${joinUrl(endpoints.baseUrl, endpoints.subscriptionsPath)}${orgQuery}`, {
        token,
        timeoutMs,
        fetchImpl,
      }),
    );
  } catch {
    period = null;
  }
  let spend = null;
  if (period?.start) {
    const since = `${orgQuery ? "&" : "?"}since=${encodeURIComponent(period.start)}`;
    try {
      spend = parseSpend(
        await getJson(`${joinUrl(endpoints.baseUrl, endpoints.usageSummaryPath)}${orgQuery}${since}`, {
          token,
          timeoutMs,
          fetchImpl,
        }),
      );
    } catch {
      spend = null;
    }
  }

  result.plan = period ? { id: period.planId, periodStart: period.start, periodEnd: period.end } : null;
  result.monthly = computeMonthlyWindow(scopedCredits, period, spend);
  result.credits = spend
    ? computeCredits(scopedCredits, period, spend.cost)
    : null;
  if (spend) {
    result.tokens = spend.totalTokens === null
      ? null
      : { total: spend.totalTokens, input: spend.tokensIn, output: spend.tokensOut };
    result.runs = spend.runs === null
      ? null
      : {
          total: spend.runs,
          completed: spend.completedRuns,
          failed: spend.failedRuns,
          successRate: spend.successRate,
        };
  }
  result.creditsPending = false;
  result.display = buildDisplay(result, now);
  result.tooltip = buildTooltip(result);
  return result;
}

// --- misc ------------------------------------------------------------------

export function emptyResult(status, message, now = Date.now()) {
  return { status, fetchedAt: now, message, source: "none" };
}

/** Redact anything that looks like a Bearer token before logging or serializing. */
export function redact(text) {
  return String(text ?? "")
    .replace(/\b(Bearer)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 <redacted>")
    .replace(/\b(cc|sk|cmd)[-_][A-Za-z0-9._-]{16,}\b/g, "<redacted-token>");
}
