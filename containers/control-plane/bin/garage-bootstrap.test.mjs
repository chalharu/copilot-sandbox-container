import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const binDir = path.dirname(currentFile);
const bootstrapScriptPath = path.join(binDir, "garage-bootstrap.mjs");
const desiredRole = {
	zone: "dc1",
	capacity: 5368709120,
	tags: ["control-plane", "sccache"],
};

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

async function startServer({
	importKeyResponses,
	getKeyInfoResponses,
	createBucketResponses,
	getBucketInfoResponses,
}) {
	const state = {
		importKeyResponses: [...importKeyResponses],
		getKeyInfoResponses: [...getKeyInfoResponses],
		createBucketResponses: [...createBucketResponses],
		getBucketInfoResponses: [...getBucketInfoResponses],
	};

	const server = http.createServer(async (req, res) => {
		const url = new URL(req.url, `http://${req.headers.host}`);
		let response;
		switch (`${req.method} ${url.pathname}`) {
			case "GET /v2/GetClusterStatus":
				response = json({ nodes: [{ id: "node-1", role: desiredRole }] });
				break;
			case "POST /v2/ImportKey":
				response = state.importKeyResponses.shift();
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

	const secretFiles = {
		adminToken: path.join(tempDir, "admin-token"),
		accessKeyId: path.join(tempDir, "access-key-id"),
		secretAccessKey: path.join(tempDir, "secret-access-key"),
	};
	writeFileSync(secretFiles.adminToken, "admin-token\n");
	writeFileSync(secretFiles.accessKeyId, "key-id\n");
	writeFileSync(secretFiles.secretAccessKey, "secret-value\n");

	return await new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [bootstrapScriptPath], {
			env: {
				...process.env,
				GARAGE_ADMIN_URL: serverUrl,
				GARAGE_S3_ENDPOINT: serverUrl,
				GARAGE_ADMIN_TOKEN_FILE: secretFiles.adminToken,
				AWS_ACCESS_KEY_ID_FILE: secretFiles.accessKeyId,
				AWS_SECRET_ACCESS_KEY_FILE: secretFiles.secretAccessKey,
				GARAGE_S3_BUCKET: "control-plane-sccache",
				GARAGE_WAIT_TIMEOUT_SECONDS: "5",
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
		child.on("close", (code) => resolve({ code, stdout, stderr }));
	});
}

test("garage bootstrap succeeds when the key and bucket already exist", async (t) => {
	const server = await startServer({
		importKeyResponses: [json({ message: "exists" }, 409)],
		getKeyInfoResponses: [json({ secretAccessKey: "secret-value" })],
		createBucketResponses: [json({ message: "exists" }, 409)],
		getBucketInfoResponses: [json({ id: "bucket-1" })],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 0);
	assert.match(result.stdout, /garage-bootstrap: bootstrap complete/);
});

test("garage bootstrap rethrows the original ImportKey failure when the key is still missing", async (t) => {
	const server = await startServer({
		importKeyResponses: [json({ message: "temporary import failure" }, 503)],
		getKeyInfoResponses: [
			json(
				{
					code: "NoSuchAccessKey",
					message: "Access key not found: key-id",
				},
				404,
			),
		],
		createBucketResponses: [json({ id: "bucket-1" }, 201)],
		getBucketInfoResponses: [],
	});
	t.after(async () => {
		await server.close();
	});

	const result = await runBootstrap(t, server.url);
	assert.equal(result.code, 64);
	assert.match(result.stderr, /POST .*\/v2\/ImportKey failed with HTTP 503/);
	assert.doesNotMatch(result.stderr, /GetKeyInfo/);
	assert.doesNotMatch(result.stderr, /NoSuchAccessKey/);
});

test("garage bootstrap rethrows the original CreateBucket failure when the bucket is still missing", async (t) => {
	const server = await startServer({
		importKeyResponses: [json({ secretAccessKey: "secret-value" }, 201)],
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
});
