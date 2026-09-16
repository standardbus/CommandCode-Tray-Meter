/**
 * Credential-resolution tests.
 *
 * These use a real temporary filesystem rather than a stub so that the "read
 * only, never rewrite" guarantee is actually exercised, and the files are
 * hashed before and after to prove nothing was written back.
 */

import { test, describe, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as nodeFs from "node:fs";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { STATUS, normalizeConfig, resolveCredential } from "../src/limits.mjs";

const FUTURE = Date.now() + 86_400_000;
const PAST = Date.now() - 86_400_000;

const tempDirs = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    rmSync(tempDirs.pop(), { recursive: true, force: true });
  }
});

/** Lay out files under a fresh temp root and return the root. */
function makeTree(files) {
  const root = mkdtempSync(join(tmpdir(), "cc-monitor-test-"));
  tempDirs.push(root);
  for (const [relative, contents] of Object.entries(files)) {
    const target = join(root, relative);
    mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, typeof contents === "string" ? contents : JSON.stringify(contents), "utf8");
  }
  return root;
}

function digest(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

describe("resolveCredential", () => {
  test("environment variable outranks every file", () => {
    const root = makeTree({
      ".commandcode/auth.json": { "command-code": { access: "from-file", expires: FUTURE } },
    });
    const result = resolveCredential(
      normalizeConfig({ apiKey: "from-config", creditFiles: [join(root, ".commandcode/auth.json")] }),
      { env: { COMMANDCODE_API_KEY: "from-env" }, fs: nodeFs },
    );
    assert.deepEqual(result, { token: "from-env", source: "COMMANDCODE_API_KEY" });
  });

  test("a blank environment variable falls through to the next source", () => {
    const result = resolveCredential(normalizeConfig({ apiKey: "from-config" }), {
      env: { COMMANDCODE_API_KEY: "   " },
      fs: nodeFs,
    });
    assert.equal(result.token, "from-config");
    assert.equal(result.source, "config.json");
  });

  test("config apiKey is used and labelled without exposing the value", () => {
    const result = resolveCredential(normalizeConfig({ apiKey: "cc-secret-value" }), {
      env: {},
      fs: nodeFs,
    });
    assert.equal(result.token, "cc-secret-value");
    assert.equal(result.source, "config.json");
  });

  test("reads the official CLI OAuth shape under both provider keys", () => {
    for (const key of ["command-code", "commandcode"]) {
      const root = makeTree({ ".commandcode/auth.json": { [key]: { type: "oauth", access: "tok", expires: FUTURE } } });
      const path = join(root, ".commandcode/auth.json");
      const result = resolveCredential(normalizeConfig({ creditFiles: [path] }), { env: {}, fs: nodeFs });
      assert.equal(result.token, "tok", `failed for ${key}`);
    }
  });

  test("reads a legacy plain-string credential", () => {
    const root = makeTree({ ".commandcode/auth.json": { commandcode: "plain-token" } });
    const result = resolveCredential(
      normalizeConfig({ creditFiles: [join(root, ".commandcode/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(result.token, "plain-token");
  });

  test("reads the unkeyed apiKey only out of Command Code's own file", () => {
    const own = makeTree({ ".commandcode/auth.json": { apiKey: "pasted-key" } });
    const fromOwn = resolveCredential(
      normalizeConfig({ creditFiles: [join(own, ".commandcode/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(fromOwn.token, "pasted-key");

    const shared = makeTree({ "agent/auth.json": { apiKey: "another-providers-secret" } });
    const fromShared = resolveCredential(
      normalizeConfig({ creditFiles: [join(shared, "agent/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(fromShared.error, STATUS.AUTH_NEEDED);
  });

  test("skips an expired token and falls through to a live one", () => {
    const root = makeTree({
      "a/auth.json": { "command-code": { access: "stale", expires: PAST } },
      "b/auth.json": { commandcode: { access: "live", expires: FUTURE } },
    });
    const result = resolveCredential(
      normalizeConfig({ creditFiles: [join(root, "a/auth.json"), join(root, "b/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(result.token, "live");
  });

  test("a token without an expiry is treated as live", () => {
    const root = makeTree({ ".commandcode/auth.json": { "command-code": { access: "no-expiry" } } });
    const result = resolveCredential(
      normalizeConfig({ creditFiles: [join(root, ".commandcode/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(result.token, "no-expiry");
  });

  test("distinguishes a lapsed sign-in from never having signed in", () => {
    const expired = makeTree({ ".commandcode/auth.json": { "command-code": { access: "x", expires: PAST } } });
    const lapsed = resolveCredential(
      normalizeConfig({ creditFiles: [join(expired, ".commandcode/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(lapsed.error, STATUS.AUTH_NEEDED);
    assert.match(lapsed.message, /expired/i);

    const signedOut = resolveCredential(normalizeConfig({ creditFiles: [join(expired, "absent.json")] }), {
      env: {},
      fs: nodeFs,
    });
    assert.equal(signedOut.error, STATUS.AUTH_NEEDED);
    assert.match(signedOut.message, /No Command Code credentials/i);
  });

  test("a malformed file is skipped, not fatal", () => {
    const root = makeTree({
      "broken/auth.json": "{not json",
      "good/auth.json": { commandcode: "recovered" },
    });
    const result = resolveCredential(
      normalizeConfig({ creditFiles: [join(root, "broken/auth.json"), join(root, "good/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.equal(result.token, "recovered");
  });

  test("never modifies the credential files it reads", () => {
    const root = makeTree({
      ".commandcode/auth.json": { "command-code": { access: "tok", expires: PAST } },
      "agent/auth.json": { commandcode: "live" },
    });
    const paths = [join(root, ".commandcode/auth.json"), join(root, "agent/auth.json")];
    const before = paths.map(digest);
    resolveCredential(normalizeConfig({ creditFiles: paths }), { env: {}, fs: nodeFs });
    const after = paths.map(digest);
    assert.deepEqual(after, before, "credential files must be read-only inputs");
  });

  test("the resolved source is a path, never a secret", () => {
    const root = makeTree({ ".commandcode/auth.json": { "command-code": { access: "tok" } } });
    const result = resolveCredential(
      normalizeConfig({ creditFiles: [join(root, ".commandcode/auth.json")] }),
      { env: {}, fs: nodeFs },
    );
    assert.match(result.source, /auth\.json$/);
    assert.doesNotMatch(result.source, /tok/);
  });
});
