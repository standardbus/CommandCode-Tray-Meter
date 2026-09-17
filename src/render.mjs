/**
 * Terminal presentation for the cross-platform CLI (`bin/ccmeter`).
 *
 * Pure string building, so it can be unit-tested without a terminal: the entry
 * point decides colours, languages and the refresh loop, this module decides
 * what the lines look like. Every label comes from `src/i18n.mjs`, so the
 * terminal meter and the Windows tray speak the same words.
 */

import { STATUS, buildDisplay, formatAmount, formatClock, redact } from "./limits.mjs";
import { t } from "./i18n.mjs";

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

/** Characters a terminal draws two columns wide (CJK, fullwidth forms). */
const WIDE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua000-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe6f\uff00-\uff60\uffe0-\uffe6]/;

/** Visible column width of a string, so a CJK label lines up with a Latin one. */
export function displayWidth(text) {
  let width = 0;
  for (const char of String(text ?? "").replace(ANSI, "")) width += WIDE.test(char) ? 2 : 1;
  return width;
}

/** Pad to a column width, measuring the visible text and ignoring colour. */
export function pad(text, width) {
  const value = text === undefined || text === null ? "" : String(text);
  return value + " ".repeat(Math.max(0, width - displayWidth(value)));
}

/**
 * One line for a status bar: `CC 5h 16% · 7d 55% · 30d 27% · 577.1 M · 3120`.
 * With several accounts the account name leads the line.
 */
export function compactLine(result, display, { name = "" } = {}) {
  // A failed refresh collapses to its own state, so a status bar never shows a
  // row of blanks that looks like real data.
  if (result.status) return `${name ? `${name}  ` : ""}CC ${String(result.status).replace(/_/g, " ")}`;
  const percent = (key) => (result[key] ? display[`${key}Percent`] : "-");
  const parts = [
    `CC ${t("tooltip.fiveHour")} ${percent("fiveHour")}`,
    `${t("tooltip.weekly")} ${percent("weekly")}`,
    `${t("tooltip.monthly")} ${percent("monthly")}`,
  ];
  // Guard the value, not just the pool: a caller that hands over a partial
  // display must not get "undefined" printed into a status bar.
  for (const value of [display.tokensValue, display.runsValue]) if (value) parts.push(value);
  return `${name ? `${name}  ` : ""}${parts.join(" \u00b7 ")}`;
}

const WINDOW_KEYS = ["fiveHour", "weekly", "monthly"];

/**
 * Render one payload as text.
 * @param result - a `fetchLimits` payload, with or without a failure status.
 * @param config - the resolved configuration, for the colour thresholds.
 * @param options - `color`, `ascii`, `compact`, and `name` for a named account.
 */
export function renderPanel(result, config = {}, options = {}) {
  const { color = false, ascii = false, name = "" } = options;
  const paint = (text, tone) => (color && CODES[tone] ? `\u001b[${CODES[tone]}m${text}\u001b[0m` : String(text));
  const display = buildDisplay(result);

  if (options.compact) return compactLine(result, display, { name });

  const plan = result.plan?.id ? ` \u00b7 ${result.plan.id}` : "";
  const lines = [paint(t("panel.title"), "bold") + paint(plan, "dim")];

  const error = typeof result.status === "string" && result.status !== "";
  if (error) {
    lines.push("");
    lines.push(redact(result.message ?? t("panel.noData")));
    // The credential hint belongs to the one failure it can actually fix, and
    // names the account when the configuration has several.
    if (result.status === STATUS.AUTH_NEEDED) {
      lines.push("");
      lines.push(paint(name ? t("cli.credentialHintProfile", { id: name }) : t("cli.credentialHint"), "dim"));
    }
    return lines.join("\n");
  }

  // One column for every label, the widest row deciding it, so a long
  // translation or a CJK label cannot push a value out of its column.
  const labels = WINDOW_KEYS.map((key) => t(`panel.${key}`));
  const rowLabels = [
    ...labels,
    t("panel.tokens"),
    t("panel.runs"),
    t("panel.credits"),
    t("panel.updatedLabel"),
  ];
  const labelWidth = Math.max(...rowLabels.map((label) => displayWidth(label)));
  const usageWidth = Math.max(...WINDOW_KEYS.map((key) => String(display[`${key}Usage`] ?? "-").length));

  lines.push("");
  WINDOW_KEYS.forEach((key, index) => {
    const window = result[key];
    const label = labels[index];
    // A pool Command Code does not report for this account keeps its row, so the
    // panel never changes shape between accounts.
    if (!window) {
      lines.push(`  ${pad(label, labelWidth)}  ${paint(t("panel.notOpen"), "dim")}`);
      return;
    }
    const tone = phase(window.percent, config?.thresholds);
    const percentText = paint(pad(display[`${key}Percent`] ?? "-", 4), tone);
    const barText = paint(bar(window.percent, { ascii }), tone);
    const usage = pad(display[`${key}Usage`] ?? "-", usageWidth);
    const reset = window.resetAt
      ? paint(t("panel.resetShort", { in: display[`${key}ResetIn`], at: display[`${key}ResetAt`] }), "dim")
      : "";
    lines.push(`  ${pad(label, labelWidth)}  ${percentText} ${barText}  ${usage}  ${reset}`.trimEnd());
  });

  lines.push("");
  if (result.tokens) lines.push(`  ${pad(t("panel.tokens"), labelWidth)}  ${display.tokensValue}`);
  if (result.runs) lines.push(`  ${pad(t("panel.runs"), labelWidth)}  ${display.runsValue}`);
  if (result.credits) {
    const credits = t("panel.creditsValue", {
      used: formatAmount(result.credits.used),
      limit: formatAmount(result.credits.limit),
      left: formatAmount(result.credits.remaining),
    });
    lines.push(`  ${pad(t("panel.credits"), labelWidth)}  ${credits}`);
  }
  lines.push(`  ${pad(t("panel.updatedLabel"), labelWidth)}  ${paint(formatClock(result.fetchedAt), "dim")}`);
  return lines.join("\n");
}

/**
 * Render every configured account.
 *
 * One account renders as it always did, with no header: the single-account
 * output stays byte-identical to earlier releases. Two or more get a header and
 * a blank line between them, so a copy-paste into a report stays readable.
 */
export function renderAccounts(entries, config = {}, options = {}) {
  if (options.compact) {
    return entries.map(({ profile, result }) => renderPanel(result, config, { ...options, name: entries.length > 1 ? profile.name : "" })).join("\n");
  }
  if (entries.length === 1) {
    // The implicit single account keeps its historical output, hint included.
    const only = entries[0].profile;
    return renderPanel(entries[0].result, config, { ...options, name: only.id === "default" ? "" : only.id });
  }
  return entries
    .map(({ profile, result }, index) => {
      const header = options.color ? `\u001b[1m${t("cli.profileHeader", { name: profile.name })}\u001b[0m` : t("cli.profileHeader", { name: profile.name });
      const block = renderPanel(result, config, { ...options, name: profile.id });
      return index === 0 ? `${header}\n${block}` : `${header}\n${block}`;
    })
    .join("\n\n");
}
