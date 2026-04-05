import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const hooksDir = path.dirname(currentFile);
const hookPath = path.join(hooksDir, "cleanup.mjs");

function writeExecutable(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, content, { mode: 0o755 });
}

test("cleanup hook runs the session exec cleanup helper for the current session", (t) => {
	const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "cleanup-hook-test-"));
	t.after(() => {
		fs.rmSync(tempDir, { recursive: true, force: true });
	});

	const helperPath = path.join(tempDir, "control-plane-session-exec");
	const helperLogPath = path.join(tempDir, "helper.log");
	writeExecutable(
		helperPath,
		`#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${helperLogPath}"
`,
	);

	const result = spawnSync(process.execPath, [hookPath], {
		encoding: "utf8",
		env: {
			...process.env,
			CONTROL_PLANE_FAST_EXECUTION_ENABLED: "1",
			CONTROL_PLANE_HOOK_SESSION_KEY: "sess-99",
			CONTROL_PLANE_SESSION_EXEC_BIN: helperPath,
		},
		input: JSON.stringify({ eventName: "sessionEnd" }),
	});

	assert.equal(result.error, undefined);
	assert.equal(result.status, 0);
	assert.equal(result.stdout, "");
	assert.equal(result.stderr, "");
	assert.equal(
		fs.readFileSync(helperLogPath, "utf8"),
		"cleanup\n--session-key\nsess-99\n",
	);
});
