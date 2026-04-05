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

await readStdin();

if (process.env.CONTROL_PLANE_FAST_EXECUTION_ENABLED !== "1") {
	process.exit(0);
}

const sessionKey =
	process.env.CONTROL_PLANE_HOOK_SESSION_KEY || `${process.ppid}`;

const result = spawnSync(
	sessionExecBin,
	["cleanup", "--session-key", sessionKey],
	{
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
	},
);

if (result.status !== 0) {
	const stderr = (result.stderr || result.stdout || "").trim();
	throw new Error(
		stderr === "" ? "failed to clean up session execution pod" : stderr,
	);
}
