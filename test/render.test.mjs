/**
 * Presentation tests for the cross-platform CLI (`src/render.mjs`).
 *
 * A terminal is never involved: every function returns a string, so the tests
 * pin the exact layout the README screenshots and the status-bar line depend on.
 */

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { STATUS } from "../src/limits.mjs";
import { bar, compactLine, pad, phase, renderPanel } from "../src/render.mjs";

/** A payload shaped like a live one, with every pool present. */
function payload(overrides = {}) {
  return {
    source: "config.json",
    fetchedAt: Date.UTC(2026, 8, 16, 9, 30, 0),
    plan: { id: "individual-goat" },
    fiveHour: { used: 2.28, cap: 14, percent: 16.28, resetAt: "2026-09-16T12:01:00.000Z" },
    weekly: { used: 19.15, cap: 35, percent: 54.73, resetAt: "2026-09-17T23:38:00.000Z" },
    monthly: { used: 18.97, cap: 69.82, percent: 27.18, resetAt: "2026-10-10T23:25:00.000Z" },
    credits: { used: 18.97, limit: 69.82, remaining: 50.85, percent: 27.18 },
    tokens: { total: 577100000, input: 1, output: 2 },
    runs: { total: 3120, failed: 0, successRate: 100 },
    ...overrides,
  };
}

describe("phase", () => {
  test("follows the configured thresholds", () => {
    assert.equal(phase(0, { warn: 60, critical: 85 }), "ok");
    assert.equal(phase(59.9, { warn: 60, critical: 85 }), "ok");
    assert.equal(phase(60, { warn: 60, critical: 85 }), "warn");
    assert.equal(phase(84.9, { warn: 60, critical: 85 }), "warn");
    assert.equal(phase(85, { warn: 60, critical: 85 }), "critical");
    assert.equal(phase(100, { warn: 60, critical: 85 }), "critical");
  });

  test("defaults to 60 and 85 when none are configured", () => {
    assert.equal(phase(59, undefined), "ok");
    assert.equal(phase(60, undefined), "warn");
    assert.equal(phase(85, {}), "critical");
  });

  test("reports an unknown percentage as dim rather than throwing", () => {
    assert.equal(phase(undefined, { warn: 60, critical: 85 }), "dim");
    assert.equal(phase(NaN, { warn: 60, critical: 85 }), "dim");
  });
});

describe("bar", () => {
  test("fills proportionally across the full range", () => {
    assert.equal(bar(0, { width: 10 }), "\u2591".repeat(10));
    assert.equal(bar(50, { width: 10 }), "\u2588".repeat(5) + "\u2591".repeat(5));
    assert.equal(bar(100, { width: 10 }), "\u2588".repeat(10));
  });

  test("clamps out-of-range and non-finite values instead of throwing", () => {
    assert.equal(bar(-20, { width: 10 }), "\u2591".repeat(10));
    assert.equal(bar(150, { width: 10 }), "\u2588".repeat(10));
    assert.equal(bar(NaN, { width: 10 }), "\u2591".repeat(10));
  });

  test("draws ASCII when asked, so a non-UTF-8 terminal stays readable", () => {
    assert.equal(bar(50, { width: 10, ascii: true }), "#####-----");
  });
});

describe("pad", () => {
  test("pads to the column width", () => {
    assert.equal(pad("abc", 6), "abc   ");
    assert.equal(pad("abcdef", 3), "abcdef");
  });

  test("measures the visible text, not the escape sequences", () => {
    assert.equal(pad("\u001b[32m7%\u001b[0m", 5), "\u001b[32m7%\u001b[0m   ");
  });

  test("treats a missing value as empty rather than printing undefined", () => {
    assert.equal(pad(undefined, 3), "   ");
  });
});

describe("compactLine", () => {
  test("reports every window plus the optional rows", () => {
    const result = payload();
    const line = compactLine(result, {
      fiveHourPercent: "16%",
      weeklyPercent: "55%",
      monthlyPercent: "27%",
      tokensValue: "577.1 M",
      runsValue: "3120",
    });
    assert.equal(line, "CC 5h 16% \u00b7 7d 55% \u00b7 30d 27% \u00b7 577.1 M \u00b7 3120");
  });

  test("shows a dash for a pool the account does not report", () => {
    const result = payload({ weekly: null });
    const line = compactLine(result, { fiveHourPercent: "16%", weeklyPercent: undefined, monthlyPercent: "27%" });
    assert.equal(line, "CC 5h 16% \u00b7 7d - \u00b7 30d 27%");
    assert.doesNotMatch(line, /undefined/);
  });

  test("collapses a failed refresh to its state", () => {
    const line = compactLine({ status: STATUS.AUTH_NEEDED }, {});
    assert.equal(line, "CC auth needed");
    assert.equal(compactLine({ status: STATUS.NETWORK_ERROR }, {}), "CC network error");
  });
});

describe("renderPanel", () => {
  test("lays out the three windows with their usage and reset", () => {
    const text = renderPanel(payload(), {});
    assert.match(text, /^Command Code \u00b7 individual-goat$/m);
    assert.match(text, /5 hours\s+16%\s+\S{20}\s+2\.28 \/ 14\s+reset in /);
    assert.match(text, /Weekly\s+55% /);
    assert.match(text, /Monthly\s+27% /);
    assert.match(text, /Tokens used\s+577\.1 M/);
    assert.match(text, /Runs\s+3120/);
    assert.match(text, /Credits\s+18\.97 of 69\.82 USD\s+\(50\.85 left\)/);
  });

  test("never prints undefined for a pool that is missing", () => {
    const text = renderPanel(payload({ weekly: null, tokens: null, runs: null, credits: null }), {});
    assert.match(text, /Weekly\s+not open yet/);
    assert.doesNotMatch(text, /undefined/);
  });

  test("keeps one row per window so the panel does not change shape", () => {
    const full = renderPanel(payload(), {}).split("\n").length;
    const sparse = renderPanel(payload({ credits: null }), {}).split("\n").length;
    assert.equal(full - sparse, 1);
  });

  test("explains a credential failure and how to fix it", () => {
    const text = renderPanel(
      { status: STATUS.AUTH_NEEDED, message: "No Command Code credentials. Paste a Provider-API key into config.json." },
      {},
    );
    assert.match(text, /No Command Code credentials/);
    assert.match(text, /Set COMMANDCODE_API_KEY, or put apiKey in config\.json\./);
  });

  test("does not offer the credential hint for a network failure", () => {
    const text = renderPanel({ status: STATUS.NETWORK_ERROR, message: "Network unreachable at api.commandcode.ai." }, {});
    assert.match(text, /Network unreachable/);
    assert.doesNotMatch(text, /Set COMMANDCODE_API_KEY/);
  });

  test("emits colour only when asked", () => {
    assert.doesNotMatch(renderPanel(payload(), {}, { color: false }), /\u001b\[/);
    assert.match(renderPanel(payload(), {}, { color: true }), /\u001b\[/);
  });

  test("honours the configured thresholds for the bar colour", () => {
    const strict = renderPanel(payload(), { thresholds: { warn: 10, critical: 20 } }, { color: true });
    // 16% is amber once the warning threshold drops to 10.
    assert.match(strict, /\u001b\[33m/);
    const relaxed = renderPanel(payload(), { thresholds: { warn: 90, critical: 95 } }, { color: true });
    assert.doesNotMatch(relaxed, /\u001b\[33m/);
  });

  test("compact mode returns the single status-bar line", () => {
    const text = renderPanel(payload(), {}, { compact: true });
    assert.equal(text.split("\n").length, 1);
    assert.match(text, /^CC 5h /);
  });
});
