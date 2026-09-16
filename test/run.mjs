/**
 * Test runner that executes each *.test.mjs file in its own Node process and
 * aggregates the TAP result.
 *
 * Why not `node --test test/`: the test runner spawns child processes with
 * piped stdio, which some confined environments (including the DSH file
 * sandbox) deny with `spawn EPERM`. Running each file directly works there and
 * behaves identically everywhere else.
 */

import { spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const testDir = dirname(fileURLToPath(import.meta.url));
const files = readdirSync(testDir)
  .filter((name) => name.endsWith(".test.mjs"))
  .sort();

if (files.length === 0) {
  console.error("No test files found in " + testDir);
  process.exit(1);
}

const totals = { tests: 0, pass: 0, fail: 0 };
const failures = [];
const scratch = mkdtempSync(join(tmpdir(), "cc-monitor-tests-"));

try {
  for (const file of files) {
    // Capture through a file descriptor rather than a pipe: confined sandboxes
    // can deny `child_process` piped stdio entirely, while a plain file handle
    // always works.
    const logPath = join(scratch, `${file}.log`);
    const logFd = openSync(logPath, "w");
    let result;
    try {
      result = spawnSync(process.execPath, [join(testDir, file)], {
        stdio: ["ignore", logFd, logFd],
      });
    } finally {
      closeSync(logFd);
    }
    const output = readFileSync(logPath, "utf8");
    const stat = (name) => {
      const match = output.match(new RegExp(`^# ${name} (\\d+)$`, "m"));
      return match ? Number(match[1]) : 0;
    };
    const passed = stat("pass");
    const failed = stat("fail");
    totals.tests += stat("tests");
    totals.pass += passed;
    totals.fail += failed;

    const bad = result.status !== 0 || failed > 0;
    console.log(`${bad ? "FAIL" : "ok  "}  ${file}  (${passed} passed, ${failed} failed)`);
    if (bad) {
      const details = output
        .split("\n")
        .filter((line) => /^\s*not ok|^\s*error:|^\s*\+|^\s*-/.test(line))
        .slice(0, 40)
        .join("\n");
      failures.push(`--- ${file} ---\n${details || output.slice(-2000)}`);
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(`\n${totals.pass} passed, ${totals.fail} failed (${totals.tests} tests in ${files.length} files)`);
if (failures.length > 0) {
  console.error(`\n${failures.join("\n\n")}`);
  process.exit(1);
}
