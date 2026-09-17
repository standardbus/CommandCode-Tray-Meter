/**
 * Language-table tests.
 *
 * The three tables are a contract: a key added to English and forgotten in
 * Chinese would surface as a raw `panel.tokens` in the interface, so coverage is
 * asserted here rather than discovered by a user.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, test } from "node:test";

import {
  DEFAULT_LANGUAGE,
  LANGUAGES,
  availableLanguages,
  compareLanguage,
  currentLanguage,
  currentLocale,
  detectSystemLanguage,
  hasLanguage,
  languageFallbackNotice,
  setLanguage,
  t,
} from "../src/i18n.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const raw = (code) => JSON.parse(readFileSync(join(ROOT, "lang", `${code}.json`), "utf8"));

function flatten(value, prefix = "") {
  return Object.entries(value).flatMap(([key, entry]) =>
    entry && typeof entry === "object" ? flatten(entry, `${prefix}${key}.`) : [`${prefix}${key}`],
  );
}

describe("language files", () => {
  test("every shipped language is present and parses", () => {
    for (const code of LANGUAGES) {
      assert.ok(hasLanguage(code), `${code}.json must load`);
      assert.equal(raw(code).code, code);
    }
    assert.deepEqual(availableLanguages(), [...LANGUAGES]);
  });

  test("ships exactly the three advertised languages", () => {
    assert.deepEqual([...LANGUAGES], ["en", "it", "zh"]);
    assert.equal(DEFAULT_LANGUAGE, "en");
  });

  test("Italian and Chinese cover the same keys as English", () => {
    for (const code of ["it", "zh"]) {
      const report = compareLanguage(code);
      assert.deepEqual(report.missing, [], `${code} is missing keys`);
      assert.deepEqual(report.extra, [], `${code} has unknown keys`);
      assert.equal(report.count, flatten(raw("en")).length);
    }
  });

  test("placeholders match across languages, so no value can be swallowed", () => {
    const placeholders = (text) => (String(text).match(/\{[a-zA-Z]+\}/g) ?? []).sort().join(",");
    const english = raw("en");
    const walk = (node, prefix = "") => {
      for (const [key, value] of Object.entries(node)) {
        if (value && typeof value === "object") {
          walk(value, `${prefix}${key}.`);
          continue;
        }
        const expected = placeholders(value);
        for (const code of ["it", "zh"]) {
          const other = prefix + key;
          const actual = placeholders(other.split(".").reduce((o, k) => o?.[k], raw(code)));
          assert.equal(actual, expected, `${code} placeholder mismatch at ${other}`);
        }
      }
    };
    walk(english);
  });

  test("carries no Italian leftovers in the English table", () => {
    const italian = /\b(che|non|sono|questo|della|delle|nella|viene|anche|senza|ogni|quando|più|già|così|perché|quindi|invece|mentre|oppure|però|ancora|sempre|dove|quale|loro|fatto|deve|devono|hanno|nel|sul|alla|gli|dei|crediti|limiti|finestra|icona|bolla|avvio|errore|caratteri|rimasti)\b|[àèéìòù]/i;
    const offenders = Object.entries(raw("en"))
      .filter(([key]) => !["code", "name"].includes(key))
      .flatMap(([, value]) => flatten(value))
      .filter((entry) => italian.test(entry));
    assert.deepEqual(offenders, []);
  });
});

describe("translator", () => {
  test("translates into each language and restores English", () => {
    setLanguage("en");
    assert.equal(t("panel.fiveHour"), "5 hours");
    assert.equal(t("panel.weekly"), "Weekly");
    setLanguage("it");
    assert.equal(t("panel.fiveHour"), "5 ore");
    assert.equal(t("panel.weekly"), "Settimanale");
    setLanguage("zh");
    assert.equal(t("panel.fiveHour"), "5 小时");
    assert.equal(t("panel.weekly"), "每周");
    setLanguage("en");
    assert.equal(currentLanguage(), "en");
  });

  test("substitutes placeholders and leaves unknown ones alone", () => {
    setLanguage("en");
    assert.equal(t("panel.updated", { time: "09:30:00" }), "Updated at 09:30:00");
    assert.equal(t("panel.updated"), "Updated at {time}");
  });

  test("falls back to the key rather than printing nothing", () => {
    setLanguage("en");
    assert.equal(t("panel.doesNotExist"), "panel.doesNotExist");
  });

  test("accepts auto and maps the system locale", () => {
    assert.equal(detectSystemLanguage({ LANG: "it_IT.UTF-8" }), "it");
    assert.equal(detectSystemLanguage({ LC_ALL: "zh_CN.UTF-8" }), "zh");
    assert.equal(detectSystemLanguage({ LANG: "en_GB.UTF-8" }), "en");
    assert.equal(detectSystemLanguage({ LANG: "de_DE.UTF-8" }), "en");
    setLanguage("auto");
    assert.ok(["en", "it", "zh"].includes(currentLanguage()));
    setLanguage("en");
  });

  test("an unknown language falls back to English and says so", () => {
    assert.equal(setLanguage("klingon"), "en");
    assert.match(languageFallbackNotice(), /klingon/);
    assert.equal(currentLanguage(), "en");
    assert.equal(setLanguage(""), "en");
    assert.equal(languageFallbackNotice(), "");
  });

  test("reports the locale used for numbers and dates", () => {
    setLanguage("en");
    assert.equal(currentLocale(), "en-US");
    setLanguage("it");
    assert.equal(currentLocale(), "it-IT");
    setLanguage("zh");
    assert.equal(currentLocale(), "zh-CN");
    setLanguage("en");
  });
});
