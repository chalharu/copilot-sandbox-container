import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const hooksDir = path.dirname(currentFile);
const hookPath = path.join(hooksDir, "exec-forward.mjs");

function writeExecutable(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function setupHelper(t, { fail = false } = {}) {
	const tempDir = fs.mkdtempSync(
		path.join(os.tmpdir(), "exec-forward-hook-test-"),
	);
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
if [[ "${fail ? "1" : "0"}" == "1" ]]; then
  printf '%s\n' 'helper failed' >&2
  exit 64
fi
`,
	);

	return { helperPath, helperLogPath };
}

function runHook(input, env) {
	const result = spawnSync(process.execPath, [hookPath], {
		encoding: "utf8",
		env,
		input: JSON.stringify(input),
	});
	assert.equal(result.error, undefined);
	return result;
}

test("exec-forward prepares the session pod and rewrites bash commands", (t) => {
	const { helperPath, helperLogPath } = setupHelper(t);
	const input = {
		toolName: "bash",
		toolArgs: {
			command: "echo hello",
			timeout: 30,
		},
		cwd: "/workspace/repo",
	};

	const result = runHook(input, {
		...process.env,
		CONTROL_PLANE_FAST_EXECUTION_ENABLED: "1",
		CONTROL_PLANE_HOOK_SESSION_KEY: "sess-42",
		CONTROL_PLANE_SESSION_EXEC_BIN: helperPath,
	});

	assert.equal(result.status, 0);
	const output = JSON.parse(result.stdout);
	assert.equal(output.permissionDecision, "allow");
	assert.equal(output.modifiedArgs.timeout, 30);
	assert.equal(
		output.modifiedArgs.command,
		[
			shellQuote(helperPath),
			"proxy",
			"--session-key",
			shellQuote("sess-42"),
			"--cwd",
			shellQuote("/workspace/repo"),
			"--command-base64",
			shellQuote(Buffer.from("echo hello", "utf8").toString("base64")),
		].join(" "),
	);
	assert.equal(
		fs.readFileSync(helperLogPath, "utf8"),
		"prepare\n--session-key\nsess-42\n",
	);
});

test("exec-forward denies the tool call when session pod preparation fails", (t) => {
	const { helperPath } = setupHelper(t, { fail: true });
	const result = runHook(
		{
			toolName: "bash",
			toolArgs: {
				command: "echo hello",
			},
			cwd: "/workspace/repo",
		},
		{
			...process.env,
			CONTROL_PLANE_FAST_EXECUTION_ENABLED: "1",
			CONTROL_PLANE_HOOK_SESSION_KEY: "sess-43",
			CONTROL_PLANE_SESSION_EXEC_BIN: helperPath,
		},
	);

	assert.equal(result.status, 0);
	assert.deepEqual(JSON.parse(result.stdout), {
		permissionDecision: "deny",
		permissionDecisionReason: "helper failed",
	});
});
