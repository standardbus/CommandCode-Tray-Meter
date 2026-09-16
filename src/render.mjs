/**
 * Terminal presentation for the cross-platform CLI (`bin/ccmeter`).
 *
 * Pure string building, so it can be unit-tested without a terminal: the entry
 * point decides colours and the refresh loop, this module decides what the
 * lines look like. The thresholds and the placement of every value match the
 * Windows tray, which is why they come from the same config keys.
 */

import { STATUS, buildDisplay, formatAmount, formatClock, redact } from "./limits.mjs";

const CODES = { ok: 32, warn: 33, critical: 31, dim: 2, bold: 1 };
const ANSI = /\u001b\[[0-9;]*m/g;

/** Colour name for a percentage, using the configured thresholds. */
export function phase(percent, thresholds) {
  const warn = thresholds?.warn ?? 60;
  const critical = thresholds?.critical ?? 85;
  if (!Number.isFinite(percent)) return "dim";
  if (percent >= critical) return "critical";
  if (percent >= warn) return "warn";
  return "ok";
}

/** Proportional bar; out-of-range and non-finite values clamp rather than throw. */
export function bar(percent, { width = 20, ascii = false } = {}) {
  const value = Number.isFinite(percent) ? Math.max(0, Math.min(100, percent)) : 0;
  const filled = Math.round((value / 100) * width);
  const [full, empty] = ascii ? ["#", "-"] : ["\u2588", "\u2591"];
  return full.repeat(filled) + empty.repeat(width - filled);
}

/** Pad to a column width, measuring the visible text and ignoring colour. */
export function pad(text, width) {
  const value = text === undefined || text === null ? "" : String(text);
  const visible = value.replace(ANSI, "").length;
  return value + " ".repeat(Math.max(0, width - visible));
}

/** One line for a status bar: `CC 5h 16% · 7d 55% · 30d 27% · 577.1 M · 3120`. */
export function compactLine(result, display) {
  // A failed refresh collapses to its own state, so a status bar never shows a
  // row of blanks that looks like real data.
  if (result.status) return `CC ${String(result.status).replace(/_/g, " ")}`;
  const percent = (key) => (result[key] ? display[`${key}Percent`] : "-");
  const parts = [`CC 5h ${percent("fiveHour")}`, `7d ${percent("weekly")}`, `30d ${percent("monthly")}`];
  // Guard the value, not just the pool: a caller that hands over a partial
  // display must not get "undefined" printed into a status bar.
  for (const value of [display.tokensValue, display.runsValue]) if (value) parts.push(value);
  return parts.join(" \u00b7 ");
}

const WINDOWS = [
  ["fiveHour", "5 hours"],
  ["weekly", "Weekly"],
  ["monthly", "Monthly"],
];

/**
 * Render one payload as text.
 * @param result - a `fetchLimits` payload, with or without a failure status.
 * @param config - the resolved configuration, for the colour thresholds.
 * @param options - `color` (ANSI output) and `ascii` (bar characters).
 */
export function renderPanel(result, config = {}, options = {}) {
  const { color = false, ascii = false } = options;
  const paint = (text, name) => (color && CODES[name] ? `\u001b[${CODES[name]}m${text}\u001b[0m` : String(text));
  const display = buildDisplay(result);

  if (options.compact) return compactLine(result, display);

  const plan = result.plan?.id ? ` \u00b7 ${result.plan.id}` : "";
  const lines = [paint("Command Code", "bold") + paint(plan, "dim")];

  const error = typeof result.status === "string" && result.status !== "";
  if (error) {
    lines.push("");
    lines.push(redact(result.message ?? "Data unavailable."));
    // The credential hint belongs to the one failure it can actually fix.
    if (result.status === STATUS.AUTH_NEEDED) {
      lines.push("");
      lines.push(paint("Set COMMANDCODE_API_KEY, or put apiKey in config.json.", "dim"));
    }
    return lines.join("\n");
  }

  const labelWidth = Math.max(...WINDOWS.map(([, label]) => label.length));
  const usageWidth = Math.max(...WINDOWS.map(([key]) => String(display[`${key}Usage`] ?? "-").length));

  lines.push("");
  for (const [key, label] of WINDOWS) {
    const window = result[key];
    // A pool Command Code does not report for this account keeps its row, so the
    // panel never changes shape between accounts.
    if (!window) {
      lines.push(`  ${pad(label, labelWidth)}  ${paint("not open yet", "dim")}`);
      continue;
    }
    const tone = phase(window.percent, config?.thresholds);
    const percentText = paint(pad(display[`${key}Percent`] ?? "-", 4), tone);
    const barText = paint(bar(window.percent, { ascii }), tone);
    const usage = pad(display[`${key}Usage`] ?? "-", usageWidth);
    const reset = window.resetAt
      ? paint(`reset in ${display[`${key}ResetIn`]} (${display[`${key}ResetAt`]})`, "dim")
      : "";
    lines.push(`  ${pad(label, labelWidth)}  ${percentText} ${barText}  ${usage}  ${reset}`.trimEnd());
  }

  lines.push("");
  if (result.tokens) lines.push(`  ${pad("Tokens", labelWidth)}  ${display.tokensValue}`);
  if (result.runs) lines.push(`  ${pad("Runs", labelWidth)}  ${display.runsValue}`);
  if (result.credits) {
    const credits = `${formatAmount(result.credits.used)} of ${formatAmount(result.credits.limit)} USD  (${formatAmount(result.credits.remaining)} left)`;
    lines.push(`  ${pad("Credits", labelWidth)}  ${credits}`);
  }
  lines.push(`  ${pad("Updated", labelWidth)}  ${paint(formatClock(result.fetchedAt), "dim")}`);
  return lines.join("\n");
}
