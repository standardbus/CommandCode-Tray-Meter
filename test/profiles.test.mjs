/**
 * Profile (multi-account) tests.
 *
 * The single-account configuration is the compatibility contract: a config.json
 * without `profiles` must keep behaving exactly as it did before profiles
 * existed, and a named account must never silently borrow another key.
 */

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  STATUS,
  activeProfileId,
  fetchAllProfiles,
  normalizeConfig,
  resolveActiveProfileId,
  resolveCredential,
  resolveProfiles,
  writeActiveProfileId,
} from "../src/limits.mjs";

const TOKEN = "test-token-not-a-real-secret";

/** Config with a token so nothing has to be read from disk. */
function config(overrides = {}) {
  return normalizeConfig({ apiKey: TOKEN, ...overrides });
}

/** Stub fetch that answers by URL fragment. */
function stubFetch(routes) {
  return async (url) => {
    for (const [fragment, response] of Object.entries(routes)) {
      if (String(url).includes(fragment)) {
        if (typeof response === "number") return { ok: false, status: response, json: async () => ({}) };
        return { ok: true, status: 200, json: async () => response };
      }
    }
    return { ok: true, status: 200, json: async () => ({}) };
  };
}

const CREDITS = {
  credits: { monthlyCredits: 70, purchasedCredits: 0, freeCredits: 0 },
  windowLimits: {
    fiveHour: { used: 3.5, cap: 14, exceeded: false, resetAt: "2026-08-15T20:00:00.000Z" },
    weekly: { used: 12.25, cap: 35, exceeded: false, resetAt: "2026-08-18T08:00:00.000Z" },
  },
};

describe("single-account compatibility", () => {
  test("no profiles means one implicit account using the top-level key", () => {
    const profiles = resolveProfiles(config({}));
    assert.equal(profiles.length, 1);
    assert.equal(profiles[0].id, "default");
    assert.equal(profiles[0].config.apiKey, TOKEN);
    assert.notEqual(profiles[0].config.strictCredential, true);
  });

  test("the implicit account keeps the historical credential precedence", () => {
    const cfg = config({});
    assert.equal(resolveCredential(cfg, { env: { COMMANDCODE_API_KEY: "from-env" } }).token, "from-env");
    assert.equal(resolveCredential(cfg, { env: {} }).token, TOKEN);
  });

  test("names the implicit account after the configured name when there is one", () => {
    assert.equal(resolveProfiles(config({ name: "Personal" }))[0].name, "Personal");
    assert.equal(resolveProfiles(config({}))[0].name, "default");
  });
});

describe("resolveProfiles", () => {
  test("reads ids, names and both credential spellings", () => {
    const cfg = config({
      profiles: [
        { id: "personal", name: "Personal", apiKey: "key-a" },
        { id: "work", apiKeyEnv: "COMMANDCODE_API_KEY_WORK" },
      ],
    });
    const profiles = resolveProfiles(cfg);
    assert.deepEqual(profiles.map((p) => p.id), ["personal", "work"]);
    assert.equal(profiles[0].name, "Personal");
    assert.equal(profiles[1].name, "work", "an account without a name falls back to its id");
    assert.equal(profiles[0].config.apiKey, "key-a");
    assert.equal(profiles[1].config.apiKeyEnv, "COMMANDCODE_API_KEY_WORK");
    assert.equal(profiles[0].config.strictCredential, true);
  });

  test("lower-cases ids so a menu entry and a --profile flag always agree", () => {
    const profiles = resolveProfiles(config({ profiles: [{ id: "Work", apiKey: "k" }] }));
    assert.equal(profiles[0].id, "work");
  });

  test("refuses an id that cannot address an account", () => {
    for (const id of ["", "with space", "Ünïcode", "-leading", "under_score"]) {
      assert.throws(() => resolveProfiles(config({ profiles: [{ id, apiKey: "k" }] })), /invalid id/);
    }
  });

  test("refuses duplicates and an account with no credential at all", () => {
    assert.throws(
      () => resolveProfiles(config({ profiles: [{ id: "a", apiKey: "k" }, { id: "a", apiKey: "k2" }] })),
      /duplicate account id/,
    );
    assert.throws(() => resolveProfiles(config({ profiles: [{ id: "a" }] })), /neither apiKey nor apiKeyEnv/);
    assert.throws(() => resolveProfiles(config({ profiles: ["nope"] })), /not an object/);
  });
});

describe("named accounts", () => {
  const cfg = () =>
    config({
      profiles: [
        { id: "personal", name: "Personal", apiKey: "key-personal" },
        { id: "work", name: "Work", apiKeyEnv: "COMMANDCODE_API_KEY_WORK" },
      ],
    });

  test("an account uses its own key and never an ambient one", () => {
    const [personal] = resolveProfiles(cfg());
    const resolved = resolveCredential(personal.config, { env: { COMMANDCODE_API_KEY: "ambient" } });
    assert.equal(resolved.token, "key-personal");
    assert.equal(resolved.source, "config.json");
  });

  test("an account reads the environment variable it names", () => {
    const [, work] = resolveProfiles(cfg());
    const resolved = resolveCredential(work.config, { env: { COMMANDCODE_API_KEY_WORK: "key-work", COMMANDCODE_API_KEY: "ambient" } });
    assert.equal(resolved.token, "key-work");
    assert.equal(resolved.source, "COMMANDCODE_API_KEY_WORK");
  });

  test("a missing credential is reported against the account, not globally", () => {
    const [, work] = resolveProfiles(cfg());
    const resolved = resolveCredential(work.config, { env: { COMMANDCODE_API_KEY: "ambient" } });
    assert.equal(resolved.error, STATUS.AUTH_NEEDED);
    assert.match(resolved.message, /"work"/);
  });
});

describe("activeProfileId", () => {
  test("honours activeProfile, falls back to the first account", () => {
    const profiles = resolveProfiles(
      config({ activeProfile: "work", profiles: [{ id: "personal", apiKey: "a" }, { id: "work", apiKey: "b" }] }),
    );
    assert.equal(activeProfileId(config({ activeProfile: "work" }), profiles), "work");
    assert.equal(activeProfileId(config({}), profiles), "personal");
    assert.equal(activeProfileId(config({ activeProfile: "ghost" }), profiles), "personal", "an unknown name is ignored");
    assert.equal(activeProfileId(config({}), resolveProfiles(config({ profiles: [] }))), "default");
  });
});

describe("resolveActiveProfileId", () => {
  const cfg = config({
    activeProfile: "personal",
    profiles: [
      { id: "personal", apiKey: "a" },
      { id: "work", apiKey: "b" },
    ],
  });
  const profiles = resolveProfiles(cfg);
  /** Stand-in for the cache file: the monitor never writes config.json, so the
   * account picked in the tray menu lives here and wins over the configuration. */
  const cache = (contents) => ({ readFileSync: () => (contents === null ? "" : JSON.stringify(contents)) });

  test("reads the account recorded in the cache", () => {
    assert.equal(resolveActiveProfileId(cfg, profiles, { cachePath: "unused", fs: cache({ id: "work" }) }), "work");
    assert.equal(resolveActiveProfileId(cfg, profiles, { cachePath: "unused", fs: cache({ id: "WORK" }) }), "work");
  });

  test("falls back to the configuration when there is no cache", () => {
    const missing = { readFileSync: () => { throw new Error("ENOENT"); } };
    assert.equal(resolveActiveProfileId(cfg, profiles, { cachePath: "unused", fs: missing }), "personal");
    assert.equal(resolveActiveProfileId(cfg, profiles, { cachePath: "unused", fs: cache("not json") }), "personal");
  });

  test("ignores a cached account that no longer exists", () => {
    // A configuration edited after the choice was made must not leave the tray
    // following an account that is gone.
    assert.equal(resolveActiveProfileId(cfg, profiles, { cachePath: "unused", fs: cache({ id: "deleted" }) }), "personal");
  });

  test("falls back to the first account when nothing names one", () => {
    const noActive = config({ profiles: [{ id: "a", apiKey: "k" }, { id: "b", apiKey: "k" }] });
    const missing = { readFileSync: () => { throw new Error("ENOENT"); } };
    assert.equal(resolveActiveProfileId(noActive, resolveProfiles(noActive), { cachePath: "unused", fs: missing }), "a");
    assert.equal(resolveActiveProfileId(config({}), resolveProfiles(config({})), { cachePath: "unused", fs: missing }), "default");
  });
});

describe("writeActiveProfileId", () => {
  test("writes the chosen id and its time", () => {
    const written = [];
    const fs = { writeFileSync: (path, text) => written.push({ path, text }) };
    assert.equal(writeActiveProfileId("work", { cachePath: "C:/tmp/active.json", fs }), true);
    assert.equal(written.length, 1);
    assert.equal(written[0].path, "C:/tmp/active.json");
    assert.equal(JSON.parse(written[0].text).id, "work");
  });

  test("reports a failure instead of throwing", () => {
    // A cache that cannot be written must not stop the tray from switching
    // account for the current run.
    const fs = { writeFileSync: () => { throw new Error("EACCES"); } };
    assert.equal(writeActiveProfileId("work", { cachePath: "C:/tmp/active.json", fs }), false);
  });
});

describe("fetchAllProfiles", () => {
  test("fetches every account and keeps them in configuration order", async () => {
    const cfg = config({
      profiles: [
        { id: "personal", name: "Personal", apiKey: "key-personal" },
        { id: "work", name: "Work", apiKey: "key-work" },
      ],
    });
    const entries = await fetchAllProfiles(cfg, {
      fetchImpl: stubFetch({ "/billing/credits": CREDITS, "/usage/summary": {}, "/billing/subscriptions": {} }),
    });
    assert.deepEqual(entries.map((e) => e.profile.id), ["personal", "work"]);
    for (const entry of entries) {
      assert.equal(entry.result.status, undefined);
      assert.equal(entry.result.fiveHour.percent, 25);
    }
  });

  test("one failing account never hides the others", async () => {
    const cfg = config({
      profiles: [
        { id: "good", apiKey: "k1" },
        { id: "bad", apiKey: "k2" },
      ],
    });
    let calls = 0;
    const fetchImpl = async (url, init) => {
      const isBad = String(init?.headers?.Authorization).includes("k2");
      calls += 1;
      if (String(url).includes("/billing/credits")) {
        return isBad ? { ok: false, status: 401, json: async () => ({}) } : { ok: true, status: 200, json: async () => CREDITS };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    };
    const entries = await fetchAllProfiles(cfg, { fetchImpl });
    assert.ok(calls > 0);
    assert.equal(entries[0].result.status, undefined);
    assert.equal(entries[1].result.status, STATUS.AUTH_NEEDED);
    assert.match(entries[1].result.message, /HTTP 401/);
  });

  test("a caller can ask for one account only", async () => {
    const cfg = config({ profiles: [{ id: "a", apiKey: "k1" }, { id: "b", apiKey: "k2" }] });
    const entries = await fetchAllProfiles(cfg, {
      only: ["B"],
      fetchImpl: stubFetch({ "/billing/credits": CREDITS }),
    });
    assert.deepEqual(entries.map((e) => e.profile.id), ["b"], "the filter is case-insensitive");
  });

  test("an unusable profiles list is reported, not thrown", async () => {
    const entries = await fetchAllProfiles(config({ profiles: [{ id: "a" }] }), { fetchImpl: stubFetch({}) });
    assert.equal(entries.length, 1);
    assert.equal(entries[0].result.status, STATUS.HTTP_ERROR);
    assert.match(entries[0].result.message, /neither apiKey nor apiKeyEnv/);
  });

  test("a single account still fetches through the implicit profile", async () => {
    const entries = await fetchAllProfiles(config({}), { fetchImpl: stubFetch({ "/billing/credits": CREDITS }) });
    assert.equal(entries.length, 1);
    assert.equal(entries[0].profile.id, "default");
    assert.equal(entries[0].result.fiveHour.percent, 25);
  });
});
