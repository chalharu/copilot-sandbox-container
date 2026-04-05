import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const binDir = path.dirname(currentFile);
const execApiPath = path.join(binDir, "control-plane-exec-api.mjs");

function requestJson({ port, method, pathName, headers = {}, body }) {
	return new Promise((resolve, reject) => {
		const request = http.request(
			{
				host: "127.0.0.1",
				port,
				method,
				path: pathName,
				headers,
			},
			(response) => {
				let responseBody = "";
				response.setEncoding("utf8");
				response.on("data", (chunk) => {
					responseBody += chunk;
				});
				response.on("end", () => {
					resolve({
						statusCode: response.statusCode ?? 0,
						body: responseBody.trim() === "" ? {} : JSON.parse(responseBody),
					});
				});
			},
		);
		request.on("error", reject);
		if (body !== undefined) {
			request.write(JSON.stringify(body));
		}
		request.end();
	});
}

async function freePort() {
	return await new Promise((resolve, reject) => {
		const server = net.createServer();
		server.on("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			if (!address || typeof address === "string") {
				reject(new Error("failed to allocate port"));
				return;
			}
			server.close((error) => {
				if (error) {
					reject(error);
					return;
				}
				resolve(address.port);
			});
		});
	});
}

async function startExecApi(t) {
	const workspaceDir = fs.mkdtempSync(
		path.join(os.tmpdir(), "control-plane-exec-api-test-"),
	);
	t.after(() => {
		fs.rmSync(workspaceDir, { recursive: true, force: true });
	});

	const port = await freePort();
	const token = "test-exec-token";
	const child = spawn(process.execPath, [execApiPath], {
		env: {
			...process.env,
			CONTROL_PLANE_FAST_EXECUTION_PORT: `${port}`,
			CONTROL_PLANE_WORKSPACE: workspaceDir,
			CONTROL_PLANE_EXEC_API_TOKEN: token,
		},
		stdio: ["ignore", "pipe", "pipe"],
	});
	let stderr = "";
	child.stderr.setEncoding("utf8");
	child.stderr.on("data", (chunk) => {
		stderr += chunk;
	});

	await new Promise((resolve, reject) => {
		const timeout = setTimeout(() => {
			reject(new Error(`timed out waiting for exec api startup: ${stderr}`));
		}, 5000);
		child.on("error", reject);
		child.stderr.on("data", () => {
			if (stderr.includes("control-plane-exec-api: listening")) {
				clearTimeout(timeout);
				resolve();
			}
		});
	});

	t.after(async () => {
		child.kill("SIGTERM");
		await new Promise((resolve) => child.on("close", resolve));
	});

	return { port, token, workspaceDir };
}

test("exec api rejects requests without the session token and runs authorized commands", async (t) => {
	const execApi = await startExecApi(t);

	const denied = await requestJson({
		port: execApi.port,
		method: "POST",
		pathName: "/exec",
		headers: {
			"Content-Type": "application/json",
		},
		body: {
			command: "printf denied",
			cwd: execApi.workspaceDir,
		},
	});
	assert.equal(denied.statusCode, 403);
	assert.equal(denied.body.error, "missing or invalid exec API token");

	const allowed = await requestJson({
		port: execApi.port,
		method: "POST",
		pathName: "/exec",
		headers: {
			"Content-Type": "application/json",
			"X-Control-Plane-Exec-Token": execApi.token,
		},
		body: {
			command:
				"printf 'api stdout\\n'; printf 'api stderr\\n' >&2; printf ok > api-marker.txt",
			cwd: execApi.workspaceDir,
		},
	});
	assert.equal(allowed.statusCode, 200);
	assert.equal(allowed.body.stdout, "api stdout\n");
	assert.equal(allowed.body.stderr, "api stderr\n");
	assert.equal(allowed.body.exitCode, 0);
	assert.equal(
		fs.readFileSync(path.join(execApi.workspaceDir, "api-marker.txt"), "utf8"),
		"ok",
	);
});
