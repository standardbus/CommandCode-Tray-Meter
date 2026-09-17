/**
 * The repository is public, so no API key or token may ever reach a file that
 * git would track. A key in the working tree is a key one `git add -A` away
 * from being published, and once published it is compromised even if the commit
 * is later rewritten: assume it is copied within minutes.
 *
 * This test is the guard: it walks the files a commit would carry and fails on
 * anything shaped like a credential. The only permitted matches are the fake
 * fixtures the redaction tests use, listed below.
 *
 * The fixtures are built by concatenation on purpose, so this file does not
 * itself contain a string the scanner would match. The scanner does not skip
 * itself: a real key pasted in here would still be caught.
 */

import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, test } from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Directories a commit never carries, so scanning them proves nothing. */
const SKIP_DIRS = new Set([".git", "node_modules", ".cache", "screenshots"]);

/** Files that hold the operator's own credentials and are gitignored. */
const SKIP_FILES = new Set(["config.json", ".credentials.yaml", ".env"]);

/** Text files a credential could hide in. */
const EXTENSIONS = /\.(mjs|js|ps1|cs|json|md|vbs|yml|yaml|txt|xml|toml|gitignore|gitattributes)$/;

/** Executables without an extension are text too, and carry the CLI. */
const EXTENSIONLESS = new Set(["ccmeter"]);

/**
 * Strings that look like a credential but are deliberate test fixtures.
 * Each entry names the file it lives in, so a fixture cannot silently excuse a
 * real key elsewhere.
 */
const FIXTURES = [
  { file: "test/limits.test.mjs", value: `${"sk"}-${"abcdefghijklmnopqrstuvwx"}`, why: "redaction test input" },
  { file: "test/limits.test.mjs", value: `${"test"}-${"token"}-not-a-real-secret`, why: "config fixture" },
  { file: "test/credentials.test.mjs", value: `${"plain"}-${"token"}`, why: "credential fixture" },
  { file: "test/credentials.test.mjs", value: `${"cc"}-${"secret"}-value`, why: "credential fixture" },
  { file: "csharp/SelfTest.cs", value: `${"selftest"}-${"token"}`, why: "self-test fixture" },
];

/** Every shape a credential in this project's world could take. */
const PATTERNS = [
  ["Command Code key", /user_[A-Za-z0-9]{20,}/g],
  ["GitHub OAuth token", /gho_[A-Za-z0-9]{20,}/g],
  ["GitHub classic token", /ghp_[A-Za-z0-9]{20,}/g],
  ["GitHub fine-grained token", /github_pat_[A-Za-z0-9_]{20,}/g],
  ["OpenAI-style key", /sk-[A-Za-z0-9]{20,}/g],
  ["Anthropic key", /sk-ant-[A-Za-z0-9_-]{20,}/g],
  ["Google API key", /AIza[A-Za-z0-9_-]{30,}/g],
  ["Slack token", /xox[baprs]-[A-Za-z0-9-]{20,}/g],
  ["private key block", /-----BEGIN [A-Z ]*PRIVATE KEY-----/g],
  ["AWS access key", /AKIA[0-9A-Z]{16}/g],
];

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, out);
    else if ((EXTENSIONS.test(entry) || EXTENSIONLESS.has(entry)) && !SKIP_FILES.has(entry)) out.push(path);
  }
  return out;
}

/** Mask a match so a failure report never repeats the secret itself. */
const mask = (value) => `${value.slice(0, 6)}…(${value.length} chars)`;

describe("no credential in the files a commit would carry", () => {
  const files = walk(ROOT).map((path) => ({ path, rel: relative(ROOT, path).replace(/\\/g, "/") }));

  test("the walk covers the project's text files", () => {
    assert.ok(files.length > 30, `only ${files.length} files found: the walk is wrong`);
    for (const expected of ["README.md", "bin/ccmeter", "src/limits.mjs", "csharp/Lang.cs", "lang/en.json"]) {
      assert.ok(files.some((f) => f.rel === expected), `${expected} must be scanned`);
    }
  });

  test("no key-shaped string outside the declared fixtures", () => {
    const offenders = [];
    for (const { path, rel } of files) {
      let text;
      try {
        text = readFileSync(path, "utf8");
      } catch {
        continue;
      }
      for (const [name, pattern] of PATTERNS) {
        pattern.lastIndex = 0;
        for (const match of text.match(pattern) ?? []) {
          const excused = FIXTURES.some((fixture) => fixture.file === rel && fixture.value === match);
          if (!excused) offenders.push(`${rel}: ${name} ${mask(match)}`);
        }
      }
    }
    assert.deepEqual(offenders, [], `credentials must never be committed:\n  ${offenders.join("\n  ")}`);
  });

  test("the fixtures are still where they are declared", () => {
    // A stale allowlist is a hole: if a fixture moves or is renamed, its entry
    // must be updated rather than left excusing a match that no longer exists.
    const stale = FIXTURES.filter((fixture) => {
      let text;
      try {
        text = readFileSync(join(ROOT, fixture.file), "utf8");
      } catch {
        return true;
      }
      return !text.includes(fixture.value);
    });
    assert.deepEqual(stale.map((f) => `${f.file}: ${f.value}`), []);
  });

  test("the files that hold a real key are not tracked", () => {
    // These are the operator's own credentials: they may exist locally, and the
    // ignore rules are what keeps them out of a commit.
    const ignore = readFileSync(join(ROOT, ".gitignore"), "utf8");
    for (const file of ["config.json", ".env", ".env.*", ".credentials.yaml"]) {
      assert.ok(ignore.split("\n").includes(file), `${file} must be listed in .gitignore`);
    }
  });
});
