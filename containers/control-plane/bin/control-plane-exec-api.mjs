#!/usr/bin/env node

import { spawn } from "node:child_process";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const DEFAULT_PORT = 8080;
const workspaceRoot = path.resolve(
	process.env.CONTROL_PLANE_WORKSPACE ?? "/workspace",
);
const portValue =
	process.env.CONTROL_PLANE_FAST_EXECUTION_PORT ?? `${DEFAULT_PORT}`;
const port = Number.parseInt(portValue, 10);
const execApiToken = process.env.CONTROL_PLANE_EXEC_API_TOKEN ?? "";

if (!Number.isSafeInteger(port) || port <= 0 || port > 65535) {
	console.error(
		`control-plane-exec-api: invalid CONTROL_PLANE_FAST_EXECUTION_PORT: ${portValue}`,
	);
	process.exit(64);
}

function readRequestBody(request) {
	return new Promise((resolve, reject) => {
		let body = "";
		request.setEncoding("utf8");
		request.on("data", (chunk) => {
			body += chunk;
		});
		request.on("end", () => resolve(body));
		request.on("error", reject);
	});
}

function writeJson(response, statusCode, payload) {
	response.writeHead(statusCode, {
		"content-type": "application/json; charset=utf-8",
	});
	response.end(JSON.stringify(payload));
}

function signalExitCode(signal) {
	if (!signal) {
		return 1;
	}

	const signalNumber = os.constants.signals[signal];
	if (typeof signalNumber !== "number") {
		return 1;
	}

	return 128 + signalNumber;
}

function normalizeCwd(rawCwd) {
	if (typeof rawCwd !== "string" || rawCwd.trim() === "") {
		return workspaceRoot;
	}

	return path.resolve(rawCwd);
}

function cwdWithinWorkspace(cwd) {
	return cwd === workspaceRoot || cwd.startsWith(`${workspaceRoot}${path.sep}`);
}

function runShellCommand(command, cwd) {
	return new Promise((resolve) => {
		const child = spawn("bash", ["-lc", command], {
			cwd,
			env: process.env,
			stdio: ["ignore", "pipe", "pipe"],
		});

		let stdout = "";
		let stderr = "";

		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (chunk) => {
			stdout += chunk;
		});
		child.stderr.on("data", (chunk) => {
			stderr += chunk;
		});

		child.on("error", (error) => {
			resolve({
				stdout,
				stderr: `${stderr}${error instanceof Error ? error.message : String(error)}\n`,
				exitCode: 1,
			});
		});

		child.on("close", (exitCode, signal) => {
			resolve({
				stdout,
				stderr,
				exitCode:
					typeof exitCode === "number" ? exitCode : signalExitCode(signal),
			});
		});
	});
}

async function handleExec(request, response) {
	const tokenHeader = request.headers["x-control-plane-exec-token"];
	if (
		execApiToken !== "" &&
		(typeof tokenHeader !== "string" || tokenHeader !== execApiToken)
	) {
		writeJson(response, 403, { error: "missing or invalid exec API token" });
		return;
	}

	const rawBody = await readRequestBody(request);
	let body;

	try {
		body = rawBody.trim() === "" ? {} : JSON.parse(rawBody);
	} catch (error) {
		writeJson(response, 400, {
			error: `invalid JSON body: ${error instanceof Error ? error.message : String(error)}`,
		});
		return;
	}

	if (!body || typeof body !== "object" || Array.isArray(body)) {
		writeJson(response, 400, { error: "request body must be a JSON object" });
		return;
	}

	const command = body.command;
	if (typeof command !== "string" || command === "") {
		writeJson(response, 400, { error: "command must be a non-empty string" });
		return;
	}

	const cwd = normalizeCwd(body.cwd);
	if (!cwdWithinWorkspace(cwd)) {
		writeJson(response, 400, {
			error: `cwd must stay within ${workspaceRoot}: ${cwd}`,
		});
		return;
	}

	const result = await runShellCommand(command, cwd);
	writeJson(response, 200, result);
}

const server = http.createServer(async (request, response) => {
	try {
		if (
			request.method === "GET" &&
			(request.url === "/healthz" || request.url === "/readyz")
		) {
			writeJson(response, 200, {
				status: "ok",
				workspace: workspaceRoot,
			});
			return;
		}

		if (request.method === "POST" && request.url === "/exec") {
			await handleExec(request, response);
			return;
		}

		writeJson(response, 404, { error: "not found" });
	} catch (error) {
		writeJson(response, 500, {
			error: error instanceof Error ? error.message : String(error),
		});
	}
});

server.listen(port, "0.0.0.0", () => {
	console.error(
		`control-plane-exec-api: listening on 0.0.0.0:${port} for ${workspaceRoot}`,
	);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
	process.on(signal, () => {
		server.close(() => {
			process.exit(0);
		});
	});
}
