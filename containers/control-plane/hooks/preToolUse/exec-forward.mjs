#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import process from "node:process";

const sessionExecBin =
	process.env.CONTROL_PLANE_SESSION_EXEC_BIN ||
	"/usr/local/bin/control-plane-session-exec";

function readStdin() {
	return new Promise((resolve, reject) => {
		let data = "";
		process.stdin.setEncoding("utf8");
		process.stdin.on("data", (chunk) => {
			data += chunk;
		});
		process.stdin.on("end", () => resolve(data));
		process.stdin.on("error", reject);
	});
}

function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function parseInput(rawInput) {
	if (rawInput.trim() === "") {
		return {};
	}

	const parsed = JSON.parse(rawInput);
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error("hook input must be a top-level JSON object");
	}

	return parsed;
}

function parseToolArgs(toolArgs) {
	if (toolArgs === undefined || toolArgs === null) {
		return {};
	}
	if (typeof toolArgs === "string") {
		const parsed = JSON.parse(toolArgs);
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			throw new Error("preToolUse toolArgs must decode to a JSON object");
		}
		return parsed;
	}
	if (typeof toolArgs !== "object" || Array.isArray(toolArgs)) {
		throw new Error(
			"preToolUse toolArgs must be a JSON object or JSON object string",
		);
	}
	return toolArgs;
}

function prepareExecutionPod(sessionKey) {
	const result = spawnSync(
		sessionExecBin,
		["prepare", "--session-key", sessionKey],
		{
			encoding: "utf8",
			stdio: ["ignore", "pipe", "pipe"],
		},
	);

	if (result.status === 0) {
		return;
	}

	const stderr = (result.stderr || result.stdout || "").trim();
	throw new Error(
		stderr === "" ? "failed to prepare session execution pod" : stderr,
	);
}

function sessionKeyFromEnvironment() {
	const value = process.env.CONTROL_PLANE_HOOK_SESSION_KEY;
	if (typeof value === "string" && value !== "") {
		return value;
	}

	return `${process.ppid}`;
}

try {
	const input = parseInput(await readStdin());
	if (input.toolName !== "bash") {
		process.exit(0);
	}

	if (process.env.CONTROL_PLANE_FAST_EXECUTION_ENABLED !== "1") {
		process.exit(0);
	}

	const toolArgs = parseToolArgs(input.toolArgs);
	if (typeof toolArgs.command !== "string" || toolArgs.command === "") {
		process.exit(0);
	}

	const sessionKey = sessionKeyFromEnvironment();
	const cwd =
		typeof input.cwd === "string" && input.cwd !== ""
			? input.cwd
			: process.cwd();

	prepareExecutionPod(sessionKey);

	const commandBase64 = Buffer.from(toolArgs.command, "utf8").toString(
		"base64",
	);
	const rewrittenCommand = [
		shellQuote(sessionExecBin),
		"proxy",
		"--session-key",
		shellQuote(sessionKey),
		"--cwd",
		shellQuote(cwd),
		"--command-base64",
		shellQuote(commandBase64),
	].join(" ");

	process.stdout.write(
		JSON.stringify({
			permissionDecision: "allow",
			modifiedArgs: {
				...toolArgs,
				command: rewrittenCommand,
			},
		}),
	);
} catch (error) {
	process.stdout.write(
		JSON.stringify({
			permissionDecision: "deny",
			permissionDecisionReason:
				error instanceof Error ? error.message : String(error),
		}),
	);
}
