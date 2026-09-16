/**
 * Unit tests for the pure logic in src/limits.mjs: payload parsing, USD credit
 * math, formatting and the end-to-end fetchLimits flow against a stubbed fetch.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  STATUS,
  buildTooltip,
  computeCredits,
  computeMonthlyWindow,
  emptyResult,
  fetchLimits,
  formatAmount,
  formatClock,
  formatCount,
  formatDelta,
  formatPercent,
  formatResetAt,
  formatTokenCount,
  formatUsagePair,
  normalizeConfig,
  parsePeriod,
  parseSpend,
  parseWindow,
  redact,
  toFiniteNumber,
  unwrapData,
} from "../src/limits.mjs";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = (name) => JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));

const NOW = Date.parse("2026-08-15T16:48:00.000Z");

/** Config with a token so nothing has to be read from disk. */
function config(overrides = {}) {
  return normalizeConfig({ apiKey: "test-token-not-a-real-secret", ...overrides });
}

/** Stub fetch that answers by URL fragment and records what was requested. */
function stubFetch(routes, seen = []) {
  return async (url, init) => {
    seen.push({ url: String(url), authorization: init?.headers?.Authorization, redirect: init?.redirect });
    for (const [fragment, response] of Object.entries(routes)) {
      if (String(url).includes(fragment)) {
        if (typeof response === "number") {
          return { ok: false, status: response, json: async () => ({}) };
        }
        return { ok: true, status: 200, json: async () => response };
      }
    }
    return { ok: true, status: 200, json: async () => ({}) };
  };
}

describe("parseWindow", () => {
  test("normalizes cap/used into a clamped percent with an ISO reset", () => {
    const window = parseWindow({ cap: 100, used: 40, resetAt: "2026-08-15T20:00:00.000Z" });
    assert.deepEqual(window, { used: 40, cap: 100, percent: 40, resetAt: "2026-08-15T20:00:00.000Z" });
  });

  test("accepts numeric strings from the API", () => {
    const window = parseWindow({ cap: "500", used: "25" });
    assert.equal(window.percent, 5);
    assert.equal(window.resetAt, null);
  });

  test("rounds percentages to two decimals", () => {
    const window = parseWindow({ cap: 41, used: 15 });
    assert.equal(window.percent, 36.59);
  });

  test("a missing or non-positive cap means the window has not opened", () => {
    assert.equal(parseWindow({ cap: 0, used: 0 }), null);
    assert.equal(parseWindow({ cap: -5, used: 1 }), null);
    assert.equal(parseWindow({ used: 10 }), null);
    assert.equal(parseWindow(null), null);
  });

  test("clamps usage above the cap to 100%", () => {
    assert.equal(parseWindow({ cap: 500, used: 750 }).percent, 100);
  });

  test("ignores a negative used value", () => {
    assert.equal(parseWindow({ cap: 100, used: -1 }), null);
  });

  test("drops an unparseable resetAt instead of inventing a time", () => {
    assert.equal(parseWindow({ cap: 100, used: 1, resetAt: "not-a-date" }).resetAt, null);
  });

  test("treats epoch-millis resetAt as absent (no reset scheduled)", () => {
    assert.equal(parseWindow({ cap: 100, used: 1, resetAt: 0 }).resetAt, null);
  });

  test("accepts a seconds-based resetAt", () => {
    assert.equal(parseWindow({ cap: 100, used: 1, resetAt: 1771000000 }).resetAt, "2026-02-13T16:26:40.000Z");
  });
});

describe("unwrapData", () => {
  test("prefers the nested data shell", () => {
    assert.deepEqual(unwrapData({ data: { a: 1 } }), { a: 1 });
  });

  test("returns the outer record when there is no data shell", () => {
    assert.deepEqual(unwrapData({ a: 1 }), { a: 1 });
  });

  test("rejects non-objects", () => {
    assert.equal(unwrapData(null), null);
    assert.equal(unwrapData([1, 2]), null);
    assert.equal(unwrapData("x"), null);
  });
});

describe("computeCredits", () => {
  const period = { start: "2026-08-01T00:00:00.000Z", end: "2026-09-01T00:00:00.000Z" };
  const pools = { monthlyCredits: 20, purchasedCredits: 5, freeCredits: 1 };

  test("sums the pools and derives used/limit from period spend", () => {
    assert.deepEqual(computeCredits(pools, period, 15), {
      used: 15,
      limit: 41,
      remaining: 26,
      percent: 36.59,
      // A purchased pool rolls over past the period end, so no expiry is claimed.
      expiresAt: null,
    });
  });

  test("omits the window without a billing period: unscoped spend is lifetime", () => {
    assert.equal(computeCredits(pools, null, 15), null);
    assert.equal(computeCredits(pools, { start: null, end: null }, 15), null);
  });

  test("omits the window when spend is unavailable", () => {
    assert.equal(computeCredits(pools, period, null), null);
  });

  test("omits the window when no remaining-credit field is present", () => {
    assert.equal(computeCredits({}, period, 5), null);
  });

  test("a fully exhausted account still reports a zero-remaining window", () => {
    const result = computeCredits({ monthlyCredits: 0, purchasedCredits: 0, freeCredits: 0 }, period, 12);
    assert.equal(result.remaining, 0);
    assert.equal(result.limit, 12);
    assert.equal(result.percent, 100);
  });

  test("roll-over purchased credits suppress the subscription expiry", () => {
    const result = computeCredits({ monthlyCredits: 0, purchasedCredits: 10, freeCredits: 0 }, period, 4);
    assert.equal(result.remaining, 10);
    assert.equal(result.expiresAt, null);
  });

  test("a monthly-only balance keeps its subscription expiry", () => {
    const result = computeCredits({ monthlyCredits: 20 }, period, 5);
    assert.equal(result.limit, 25);
    assert.equal(result.expiresAt, "2026-09-01T00:00:00.000Z");
  });

  test("treats negative pool values as zero rather than crediting the user", () => {
    assert.equal(computeCredits({ monthlyCredits: -5, freeCredits: 10 }, period, 0).remaining, 10);
  });
});

describe("parsePeriod / parseSpend", () => {
  test("unwraps the envelope and keeps plan id plus period bounds", () => {
    assert.deepEqual(parsePeriod(fixture("subscriptions-individual.json")), {
      start: "2026-08-01T00:00:00.000Z",
      end: "2026-09-01T00:00:00.000Z",
      planId: "individual-pro",
    });
  });

  test("returns null for an empty or unusable payload", () => {
    assert.equal(parsePeriod({}), null);
    assert.equal(parsePeriod(null), null);
  });

  test("reads totalCost, falling back to totalMonthlyCredits", () => {
    assert.equal(parseSpend({ data: { totalCost: 15 } }).cost, 15);
    assert.equal(parseSpend({ totalMonthlyCredits: 3 }).cost, 3);
    assert.equal(parseSpend({}), null);
    assert.equal(parseSpend({ totalCost: -1 }), null);
  });

  test("carries the run and token totals the dashboard shows", () => {
    const spend = parseSpend({
      totalCost: 8.936571315,
      totalCount: 3120,
      completedCount: 3120,
      failedCount: 0,
      successRate: 100,
      totalTokens: 563961963,
      totalTokensIn: 560106201,
      totalTokensOut: 3855762,
    });
    assert.equal(spend.runs, 3120);
    assert.equal(spend.completedRuns, 3120);
    assert.equal(spend.failedRuns, 0);
    assert.equal(spend.successRate, 100);
    assert.equal(spend.totalTokens, 563961963);
    assert.equal(spend.tokensIn, 560106201);
    assert.equal(spend.tokensOut, 3855762);
  });

  test("leaves absent run and token totals null instead of guessing zero", () => {
    const spend = parseSpend({ totalCost: 5 });
    assert.equal(spend.runs, null);
    assert.equal(spend.totalTokens, null);
    assert.equal(spend.tokensIn, null);
  });
});

describe("computeMonthlyWindow", () => {
  const period = { start: "2026-09-10T21:25:59.000Z", end: "2026-10-10T21:25:59.000Z" };

  test("derives the monthly cap from spend plus what remains", () => {
    // The live account: 8.936571315 spent, 61.6-ish left of a $70 pool. This is
    // the figure Studio reports as 13% of the monthly limit.
    const credits = { monthlyCredits: 61.63, purchasedCredits: 0, freeCredits: 0 };
    const window = computeMonthlyWindow(credits, period, { cost: 8.37 });
    assert.equal(Math.round(window.cap), 70);
    assert.equal(Math.round(window.percent), 12);
    assert.equal(window.resetAt, "2026-10-10T21:25:59.000Z");
  });

  test("counts the purchased and free pools towards the cap", () => {
    const credits = { monthlyCredits: 10, purchasedCredits: 5, freeCredits: 1 };
    const window = computeMonthlyWindow(credits, period, { cost: 4 });
    assert.equal(window.cap, 20);
    assert.equal(Math.round(window.percent), 20);
  });

  test("accepts a bare number as spend, for callers holding only the cost", () => {
    const window = computeMonthlyWindow({ monthlyCredits: 10 }, period, 10);
    assert.equal(window.cap, 20);
    assert.equal(window.percent, 50);
  });

  test("returns null without a billing period", () => {
    assert.equal(computeMonthlyWindow({ monthlyCredits: 10 }, null, { cost: 1 }), null);
    assert.equal(computeMonthlyWindow({ monthlyCredits: 10 }, { start: null }, { cost: 1 }), null);
  });

  test("returns null when the remaining allowance is unknown", () => {
    assert.equal(computeMonthlyWindow({}, period, { cost: 1 }), null);
    assert.equal(computeMonthlyWindow({ monthlyCredits: 10 }, period, null), null);
  });
});

describe("formatTokenCount / formatCount", () => {
  test("scales large token counts for readability", () => {
    assert.equal(formatTokenCount(563961963), "564.0 M");
    assert.equal(formatTokenCount(1843200000), "1.84 B");
    assert.equal(formatTokenCount(45231), "45.2 K");
    assert.equal(formatTokenCount(999), "999");
    assert.equal(formatTokenCount(0), "0");
  });

  test("degrades gracefully on junk", () => {
    assert.equal(formatTokenCount(null), "-");
    assert.equal(formatTokenCount(-5), "-");
    assert.equal(formatTokenCount("abc"), "-");
  });

  test("renders run counts ungrouped, matching the C# implementation", () => {
    // Grouping would depend on the ICU data bundled with the runtime, which is
    // absent from small Node builds. Both implementations therefore print the
    // exact integer, so the two cannot drift.
    assert.equal(formatCount(3120), "3120");
    assert.equal(formatCount(1234567), "1234567");
    assert.equal(formatCount(0), "0");
    assert.equal(formatCount(null), "-");
    assert.equal(formatCount(-1), "-");
  });
});

describe("formatters", () => {
  test("formatDelta renders days, hours and minutes", () => {
    assert.equal(formatDelta(3 * 3600000 + 12 * 60000), "3h 12m");
    assert.equal(formatDelta(2 * 86400000 + 4 * 3600000), "2d 4h");
    assert.equal(formatDelta(2 * 86400000), "2d");
    assert.equal(formatDelta(45 * 60000), "45m");
    assert.equal(formatDelta(0), "<1m");
    assert.equal(formatDelta(-1000), "<1m");
    assert.equal(formatDelta(30000), "<1m");
    assert.equal(formatDelta(NaN), "-");
  });

  test("formatPercent rounds to whole percent", () => {
    assert.equal(formatPercent(36.59), "37%");
    assert.equal(formatPercent(undefined), "-");
  });

  test("formatAmount trims API floats to at most two decimals", () => {
    // The live API returns values like 2.000223421; printing them raw is noise.
    assert.equal(formatAmount(2.000223421), "2");
    assert.equal(formatAmount(8.452685563), "8.45");
    assert.equal(formatAmount(1.910707981), "1.91");
    assert.equal(formatAmount(14), "14");
    assert.equal(formatAmount(69.907555494), "69.91");
    assert.equal(formatAmount(0), "0");
  });

  test("formatAmount respects the requested locale", () => {
    assert.equal(formatAmount(8.45, "en-US"), "8.45");
    assert.equal(formatAmount(8.45, "it-IT"), "8,45");
  });

  test("formatAmount degrades gracefully on junk", () => {
    assert.equal(formatAmount(undefined), "-");
    assert.equal(formatAmount(null), "-");
    assert.equal(formatAmount("abc"), "-");
  });

  test("formatUsagePair renders the used-against-cap pair", () => {
    assert.equal(formatUsagePair(2.000223421, 14), "2 / 14");
    assert.equal(formatUsagePair(8.452685563, 35), "8.45 / 35");
  });

  test("formatResetAt shortens to a clock time, adding a day marker when needed", () => {
    const now = new Date(2026, 7, 15, 16, 48, 0).getTime();
    const at = (d, h, m) => new Date(2026, 7, d, h, m, 0).toISOString();
    assert.equal(formatResetAt(at(15, 20, 0), now), "20:00");
    assert.equal(formatResetAt(at(16, 9, 30), now), `tomorrow 09:30`);
    assert.equal(formatResetAt("nonsense", now), "-");
  });

  test("formatClock zero-pads a timestamp", () => {
    const ms = new Date(2026, 7, 15, 9, 4, 7).getTime();
    assert.equal(formatClock(ms), "09:04:07");
    assert.equal(formatClock(undefined), "-");
  });

  test("toFiniteNumber accepts numeric strings but rejects junk", () => {
    assert.equal(toFiniteNumber("12.5"), 12.5);
    assert.equal(toFiniteNumber(""), undefined);
    assert.equal(toFiniteNumber("abc"), undefined);
    assert.equal(toFiniteNumber(NaN), undefined);
    assert.equal(toFiniteNumber(0), 0);
  });
});

describe("buildTooltip", () => {
  test("stays well under the 63-character Windows limit", () => {
    const tooltip = buildTooltip({
      display: { fiveHourPercent: "40%", fiveHourResetIn: "3h 12m", weeklyPercent: "5%" },
    });
    assert.ok(tooltip.length <= 63, `tooltip too long: ${tooltip.length}`);
    assert.match(tooltip, /5h 40%/);
    assert.match(tooltip, /7g 5%/);
  });

  test("names the failure state instead of showing stale numbers", () => {
    assert.match(buildTooltip(emptyResult(STATUS.AUTH_NEEDED, "x")), /authentication required/);
    assert.match(buildTooltip(emptyResult(STATUS.NETWORK_ERROR, "x")), /data unavailable/);
  });
});

describe("normalizeConfig", () => {
  test("applies defaults for an empty config", () => {
    const normalized = normalizeConfig({});
    assert.equal(normalized.endpoints.baseUrl, "https://api.commandcode.ai");
    assert.equal(normalized.endpoints.creditsPath, "/alpha/billing/credits");
    assert.equal(normalized.refreshSeconds, 120);
    assert.deepEqual(normalized.thresholds, { warn: 60, critical: 85 });
    assert.equal(normalized.requestTimeoutMs, 8000);
  });

  test("the shipped config.example.json is valid and matches the documented schema", () => {
    // A guard rather than a formality: this file is the only instructions a new
    // user gets, and it must never go missing or drift from the real schema.
    const examplePath = join(PROJECT_ROOT, "config.example.json");
    assert.ok(existsSync(examplePath), "config.example.json must exist");
    const raw = JSON.parse(readFileSync(examplePath, "utf8"));
    const normalized = normalizeConfig(raw);
    // Every documented key must survive normalization with the stated default.
    assert.equal(normalized.apiKey, "");
    assert.equal(normalized.endpoints.baseUrl, "https://api.commandcode.ai");
    assert.equal(normalized.refreshSeconds, 120);
    assert.deepEqual(normalized.thresholds, { warn: 60, critical: 85 });
    assert.equal(normalized.requestTimeoutMs, 8000);
    assert.equal(normalized.creditFiles.length, 2);
    assert.equal(normalized.ui.monochrome, false);
    assert.equal(normalized.ui.showTooltip, true);
  });

  test("honours overrides and strips a trailing slash from the base URL", () => {
    const normalized = normalizeConfig({
      endpoints: { baseUrl: "https://example.test/", creditsPath: "/x" },
      refreshSeconds: 30,
      thresholds: { warn: 10, critical: 20 },
    });
    assert.equal(normalized.endpoints.baseUrl, "https://example.test");
    assert.equal(normalized.endpoints.creditsPath, "/x");
    assert.equal(normalized.refreshSeconds, 30);
    assert.deepEqual(normalized.thresholds, { warn: 10, critical: 20 });
  });

  test("rejects an absurdly small refresh interval that would hammer the API", () => {
    assert.equal(normalizeConfig({ refreshSeconds: 1 }).refreshSeconds, 120);
    assert.equal(normalizeConfig({ refreshSeconds: 0 }).refreshSeconds, 120);
  });
});

describe("redact", () => {
  test("removes bearer tokens and key-shaped strings", () => {
    assert.equal(redact("Authorization: Bearer abcdefgh12345678"), "Authorization: Bearer <redacted>");
    assert.match(redact("token cc-abcdefghijklmnopqrstuvwx"), /<redacted-token>/);
    assert.doesNotMatch(redact("token sk-abcdefghijklmnopqrstuvwx"), /abcdefghijklmnopqrstuvwx/);
  });
});

describe("fetchLimits", () => {
  test("maps a full payload, including subscription-scoped credits", async () => {
    const seen = [];
    const result = await fetchLimits(config(), {
      fetchImpl: stubFetch(
        {
          "/alpha/whoami": fixture("whoami-org.json"),
          "/alpha/billing/subscriptions": fixture("subscriptions-individual.json"),
          "/alpha/usage/summary": fixture("usage-summary.json"),
          "/alpha/billing/credits": fixture("credits-full.json"),
        },
        seen,
      ),
      now: NOW,
    });

    assert.equal(result.status, undefined);
    assert.equal(result.source, "config.json");
    assert.equal(result.fiveHour.percent, 40);
    assert.equal(result.weekly.percent, 5);
    assert.equal(result.plan.id, "individual-pro");
    assert.deepEqual(result.credits, {
      used: 15,
      limit: 41,
      remaining: 26,
      percent: 36.59,
      // credits-full.json carries a purchased pool, so the expiry is withheld.
      expiresAt: null,
    });
    assert.equal(result.display.fiveHourPercent, "40%");
    assert.equal(result.display.weeklyPercent, "5%");
    assert.ok(result.tooltip.length <= 63);
  });

  test("reads credits unscoped for speed, then re-reads scoped the team orgId", async () => {
    const seen = [];
    await fetchLimits(config(), {
      fetchImpl: stubFetch(
        {
          "/alpha/whoami": fixture("whoami-org.json"),
          "/alpha/billing/subscriptions": fixture("subscriptions-individual.json"),
          "/alpha/usage/summary": fixture("usage-summary.json"),
          "/alpha/billing/credits": fixture("credits-full.json"),
        },
        seen,
      ),
      now: NOW,
    });
    const creditsCalls = seen
      .filter((call) => call.url.includes("/alpha/billing/credits"))
      .map((call) => call.url);
    // The fast path must not wait for whoami: the first credits read is unscoped,
    // and the org-scoped re-read follows once the org id is known.
    assert.equal(creditsCalls[0], "https://api.commandcode.ai/alpha/billing/credits");
    assert.ok(
      creditsCalls.includes("https://api.commandcode.ai/alpha/billing/credits?orgId=team-org-7"),
      `expected an org-scoped re-read, got: ${creditsCalls.join(", ")}`,
    );
    const spendCall = seen.find((call) => call.url.includes("/alpha/usage/summary"));
    assert.match(spendCall.url, /[?&]since=2026-08-01T00%3A00%3A00\.000Z/);
    // The token must never follow a redirect off the canonical host.
    assert.ok(seen.every((call) => call.redirect === "error"));
  });

  test("delivers the rolling windows before the slow USD tail resolves", async () => {
    const partials = [];
    let slowTailReached = false;
    const result = await fetchLimits(config(), {
      fetchImpl: async (url, init) => {
        const target = String(url);
        if (target.includes("/alpha/billing/subscriptions")) {
          // The USD line depends on this call; it must resolve after onPartial.
          slowTailReached = true;
          await new Promise((resolve) => setTimeout(resolve, 30));
        }
        return stubFetch({
          "/alpha/whoami": fixture("whoami-org.json"),
          "/alpha/billing/subscriptions": fixture("subscriptions-individual.json"),
          "/alpha/usage/summary": fixture("usage-summary.json"),
          "/alpha/billing/credits": fixture("credits-full.json"),
        })(url, init);
      },
      onPartial: (partial) => partials.push({ ...partial, sawSlowTail: slowTailReached }),
      now: NOW,
    });

    assert.equal(partials.length, 1, "expected exactly one partial delivery");
    assert.equal(partials[0].sawSlowTail, false, "partial must precede the slow tail");
    assert.equal(partials[0].creditsPending, true);
    assert.equal(partials[0].fiveHour.percent, 40);
    assert.equal(partials[0].weekly.percent, 5);
    assert.equal(partials[0].credits, null);
    // The final result carries the hydrated USD line.
    assert.equal(result.creditsPending, false);
    assert.equal(result.credits.used, 15);
    assert.equal(result.display.creditsText.includes("15"), true);
  });

  test("never fires onPartial when there is no credit pool to hydrate", async () => {
    const partials = [];
    await fetchLimits(config(), {
      fetchImpl: stubFetch({
        "/alpha/whoami": 500,
        "/alpha/billing/credits": fixture("credits-weekly-only.json"),
      }),
      onPartial: (partial) => partials.push(partial),
      now: NOW,
    });
    assert.equal(partials.length, 0);
  });

  test("keeps rolling windows when whoami and the spend summary fail", async () => {
    const result = await fetchLimits(config(), {
      fetchImpl: stubFetch({
        "/alpha/whoami": 500,
        "/alpha/billing/subscriptions": 500,
        "/alpha/usage/summary": 500,
        "/alpha/billing/credits": fixture("credits-enveloped.json"),
      }),
      now: NOW,
    });
    assert.equal(result.status, undefined);
    assert.equal(result.fiveHour.percent, 25);
    assert.equal(result.weekly, null);
    assert.equal(result.credits, null);
    assert.equal(result.display.fiveHourPercent, "25%");
  });

  test("a window with no cap is reported as not opened rather than 0%", async () => {
    const result = await fetchLimits(config(), {
      fetchImpl: stubFetch({
        "/alpha/whoami": 500,
        "/alpha/billing/credits": fixture("credits-inactive-and-over.json"),
      }),
      now: NOW,
    });
    assert.equal(result.fiveHour, null);
    assert.equal(result.weekly.percent, 100);
  });

  test("treats a 401/403 as terminal auth failure", async () => {
    for (const status of [401, 403]) {
      const result = await fetchLimits(config(), {
        fetchImpl: stubFetch({ "/alpha/whoami": 500, "/alpha/billing/credits": status }),
        now: NOW,
      });
      assert.equal(result.status, STATUS.AUTH_NEEDED);
      assert.equal(result.httpStatus, status);
    }
  });

  test("treats 429 and 5xx as retryable network errors", async () => {
    for (const status of [429, 500, 503]) {
      const result = await fetchLimits(config(), {
        fetchImpl: stubFetch({ "/alpha/whoami": 500, "/alpha/billing/credits": status }),
        now: NOW,
      });
      assert.equal(result.status, STATUS.HTTP_ERROR);
      assert.equal(result.httpStatus, status);
    }
  });

  test("reports a network error when the request throws", async () => {
    const result = await fetchLimits(config(), {
      fetchImpl: async () => {
        throw new Error("getaddrinfo ENOTFOUND");
      },
      now: NOW,
    });
    assert.equal(result.status, STATUS.NETWORK_ERROR);
  });

  test("reports an unrecognised schema instead of rendering empty bars", async () => {
    const result = await fetchLimits(config(), {
      fetchImpl: stubFetch({
        "/alpha/whoami": 500,
        "/alpha/billing/credits": fixture("credits-malformed.json"),
      }),
      now: NOW,
    });
    assert.equal(result.status, STATUS.HTTP_ERROR);
    assert.match(result.message, /unrecognised schema/);
  });

  test("never leaks the token into the serialized result", async () => {
    const result = await fetchLimits(config(), {
      fetchImpl: stubFetch({
        "/alpha/whoami": fixture("whoami-org.json"),
        "/alpha/billing/credits": fixture("credits-full.json"),
      }),
      now: NOW,
    });
    assert.doesNotMatch(JSON.stringify(result), /test-token-not-a-real-secret/);
  });

  test("returns auth_needed without touching the network when there is no credential", async () => {
    let calls = 0;
    const result = await fetchLimits(normalizeConfig({ creditFiles: [] }), {
      fetchImpl: async () => {
        calls += 1;
        return { ok: true, status: 200, json: async () => ({}) };
      },
      env: {},
      fs: { readFileSync: () => { throw new Error("ENOENT"); } },
      now: NOW,
    });
    assert.equal(calls, 0);
    assert.equal(result.status, STATUS.AUTH_NEEDED);
  });
});
