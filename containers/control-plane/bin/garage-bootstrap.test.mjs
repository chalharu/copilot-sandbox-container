import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const binDir = path.dirname(currentFile);
const bootstrapScriptPath = path.join(binDir, "garage-bootstrap.mjs");
const keyName = "control-plane-sccache";

function json(body, status = 200) {
	return {
		status,
		headers: { "content-type": "application/json" },
		body: JSON.stringify(body),
	};
}

function text(body = "", status = 200) {
	return {
		status,
		headers: { "content-type": "text/plain; charset=utf-8" },
		body,
	};
}

function keyInfo(accessKeyId, secretAccessKey) {
	return {
		accessKeyId,
		secretAccessKey,
		name: keyName,
		expired: false,
		permissions: {},
		buckets: [],
	};
}

function parseArgs(raw) {
	return raw.split("\0").filter(Boolean);
}

function readOptionalFile(pathname) {
	try {
		return readFileSync(pathname, "utf8");
	} catch {
		return "";
	}
}

async function startServer({
	listKeysResponses,
	createKeyResponses,
	getKeyInfoResponses,
	createBucketResponses,
	getBucketInfoResponses,
}) {
	const state = {
		listKeysResponses: [...listKeysResponses],
		createKeyResponses: [...createKeyResponses],
		getKeyInfoResponses: [...getKeyInfoResponses],
		createBucketResponses: [...createBucketResponses],
		getBucketInfoResponses: [...getBucketInfoResponses],
	};

	const server = http.createServer(async (req, res) => {
		const url = new URL(req.url, `http://${req.headers.host}`);
		let response;
		switch (`${req.method} ${url.pathname}`) {
			case "GET /v2/GetClusterStatus":
				response = json({
					nodes: [
						{
							id: "node-1",
							role: {
								zone: "dc1",
								capacity: 5368709120,
								tags: ["control-plane", "sccache"],
							},
						},
					],
				});
				break;
			case "GET /v2/ListKeys":
				response = state.listKeysResponses.shift();
				break;
			case "POST /v2/CreateKey":
				response = state.createKeyResponses.shift();
				break;
			case "GET /v2/GetKeyInfo":
				response = state.getKeyInfoResponses.shift();
				break;
			case "POST /v2/CreateBucket":
				response = state.createBucketResponses.shift();
				break;
			case "GET /v2/GetBucketInfo":
				response = state.getBucketInfoResponses.shift();
				break;
			case "POST /v2/UpdateBucket":
			case "POST /v2/AllowBucketKey":
				response = text("", 204);
				break;
			default:
				if (req.method === "GET" && url.pathname === "/") {
					response = text("forbidden", 403);
					break;
				}
				if (
					req.method === "PUT" &&
					url.pathname === "/control-plane-sccache" &&
					url.search === "?lifecycle="
				) {
					response = text("", 200);
					break;
				}
				throw new Error(
					`Unexpected request: ${req.method} ${url.pathname}${url.search}`,
				);
		}

		assert.ok(
			response,
			`Missing mock response for ${req.method} ${url.pathname}${url.search}`,
		);
		res.writeHead(response.status, response.headers);
		res.end(response.body);
	});

	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return {
		close: () => new Promise((resolve) => server.close(resolve)),
		url: `http://127.0.0.1:${server.address().port}`,
	};
}

async function runBootstrap(t, serverUrl) {
	const tempDir = mkdtempSync(path.join(os.tmpdir(), "garage-bootstrap-test-"));
	t.after(() => rmSync(tempDir, { recursive: true, force: true }));

	const fakeBinDir = path.join(tempDir, "fake-bin");
	const kubectlArgsPath = path.join(tempDir, "kubectl.args");
	const kubectlStdinPath = path.join(tempDir, "kubectl.stdin");
	const adminTokenPath = path.join(tempDir, "admin-token");
	const kubectlPath = path.join(fakeBinDir, "kubectl");

	mkdirSync(fakeBinDir, { recursive: true });
	writeFileSync(adminTokenPath, "admin-token\n");
	writeFileSync(
		kubectlPath,
		`#!/usr/bin/env bash
set -euo pipefail
printf '%s\\0' "$@" > "${kubectlArgsPath}"
cat > "${kubectlStdinPath}"
`,
		{ mode: 0o755 },
	);

	return await new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [bootstrapScriptPath], {
			env: {
				...process.env,
				PATH: `${fakeBinDir}:${process.env.PATH ?? ""}`,
				GARAGE_ADMIN_URL: serverUrl,
				GARAGE_S3_ENDPOINT: serverUrl,
				GARAGE_ADMIN_TOKEN_FILE: adminTokenPath,
				GARAGE_S3_BUCKET: "control-plane-sccache",
				GARAGE_S3_KEY_NAME: keyName,
				GARAGE_S3_AUTH_SECRET_NAME: "garage-sccache-auth",
				GARAGE_WAIT_TIMEOUT_SECONDS: "5",
				POD_NAMESPACE: "copilot-sandbox",
			},
			stdio: ["ignore", "pipe", "pipe"],
		});

		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => {
			stdout += chunk.toString();
		});
		child.stderr.on("data", (chunk) => {
			stderr += chunk.toString();
		});
		child.on("error", reject);
		child.on("close", (code) =>
			resolve({
				code,
				stdout,
				stderr,
				kubectlArgs: readOptionalFile(kubectlArgsPath),
				kubectlStdin: readOptionalFile(kubectlStdinPath),
			}),
		);
	});
}

test("garage bootstrap creates a Garage key and patches the auth secret", async (t) => {
	const server = await startServer({
		listKeysResponses: [json([])],
		createKeyResponses: [
			json(keyInfo("GK000000000001", "generated-secret"), 201),
		],
		getKeyInfoResponses: [],
		createBucketResponses: [json({ id: "bucket-1" }, 201)],
		getBucketInfoResponses: [],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 0);
	assert.match(result.stdout, /garage-bootstrap: bootstrap complete/);
	assert.deepEqual(parseArgs(result.kubectlArgs), ["apply", "-f", "-"]);
	assert.deepEqual(JSON.parse(result.kubectlStdin), {
		apiVersion: "v1",
		kind: "Secret",
		metadata: {
			name: "garage-sccache-auth",
			namespace: "copilot-sandbox",
		},
		type: "Opaque",
		stringData: {
			"access-key-id": "GK000000000001",
			"secret-access-key": "generated-secret",
		},
	});
});

test("garage bootstrap succeeds when the key and bucket already exist", async (t) => {
	const server = await startServer({
		listKeysResponses: [
			json([{ id: "GK000000000002", name: keyName, expired: false }]),
		],
		createKeyResponses: [],
		getKeyInfoResponses: [json(keyInfo("GK000000000002", "existing-secret"))],
		createBucketResponses: [json({ message: "exists" }, 409)],
		getBucketInfoResponses: [json({ id: "bucket-1" })],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 0);
	assert.match(result.stdout, /garage-bootstrap: bootstrap complete/);
	assert.deepEqual(JSON.parse(result.kubectlStdin), {
		apiVersion: "v1",
		kind: "Secret",
		metadata: {
			name: "garage-sccache-auth",
			namespace: "copilot-sandbox",
		},
		type: "Opaque",
		stringData: {
			"access-key-id": "GK000000000002",
			"secret-access-key": "existing-secret",
		},
	});
});

test("garage bootstrap rethrows the original CreateKey failure when no exact-name key exists", async (t) => {
	const server = await startServer({
		listKeysResponses: [json([]), json([])],
		createKeyResponses: [
			json({ message: "temporary create key failure" }, 503),
		],
		getKeyInfoResponses: [],
		createBucketResponses: [],
		getBucketInfoResponses: [],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 64);
	assert.match(result.stderr, /POST .*\/v2\/CreateKey failed with HTTP 503/);
	assert.doesNotMatch(result.stderr, /Garage key .* not found/);
	assert.equal(result.kubectlStdin, "");
});

test("garage bootstrap rethrows the original CreateBucket failure when the bucket is still missing", async (t) => {
	const server = await startServer({
		listKeysResponses: [json([])],
		createKeyResponses: [json(keyInfo("GK000000000003", "secret-value"), 201)],
		getKeyInfoResponses: [],
		createBucketResponses: [json({ message: "temporary create failure" }, 503)],
		getBucketInfoResponses: [
			json(
				{
					code: "NoSuchBucket",
					message: "Bucket not found: control-plane-sccache",
				},
				404,
			),
		],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 64);
	assert.match(result.stderr, /POST .*\/v2\/CreateBucket failed with HTTP 503/);
	assert.doesNotMatch(result.stderr, /GetBucketInfo/);
	assert.doesNotMatch(result.stderr, /NoSuchBucket/);
	assert.equal(result.kubectlStdin, "");
});
