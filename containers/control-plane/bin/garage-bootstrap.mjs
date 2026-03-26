import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";

class HttpError extends Error {
	constructor(message, status) {
		super(message);
		this.name = "HttpError";
		this.status = status;
	}
}

function die(message) {
	console.error(`garage-bootstrap: ${message}`);
	process.exit(64);
}

function env(name, { defaultValue, required = false } = {}) {
	const value = process.env[name] ?? defaultValue;
	if (required && !value) {
		die(`${name} is required`);
	}
	if (value === undefined) {
		throw new Error(`${name} is undefined`);
	}
	return value;
}

function readSecret(path) {
	try {
		const value = readFileSync(path, "utf8").trim();
		if (!value) {
			die(`secret file must not be empty: ${path}`);
		}
		return value;
	} catch (error) {
		die(`secret file not found: ${path}`);
	}
}

function applyManifest(manifestJson, description) {
	try {
		execFileSync("kubectl", ["apply", "-f", "-"], {
			encoding: "utf8",
			input: manifestJson,
			stdio: ["pipe", "pipe", "pipe"],
		});
	} catch (error) {
		const stderr = typeof error?.stderr === "string" ? error.stderr.trim() : "";
		const stdout = typeof error?.stdout === "string" ? error.stdout.trim() : "";
		const details =
			stderr ||
			stdout ||
			(error instanceof Error ? error.message : String(error));
		throw new Error(`${description} failed: ${details}`);
	}
}

async function request(
	method,
	url,
	{ headers = {}, body, expected = [200] } = {},
) {
	let response;
	try {
		response = await fetch(url, {
			method,
			headers,
			body,
			signal: AbortSignal.timeout(5000),
		});
	} catch (error) {
		throw new Error(`${method} ${url} failed: ${error}`);
	}
	const responseBody = await response.text();
	if (expected !== null && !expected.includes(response.status)) {
		throw new HttpError(
			`${method} ${url} failed with HTTP ${response.status}: ${responseBody}`,
			response.status,
		);
	}
	return { status: response.status, body: responseBody };
}

async function adminJson(method, path, payload, expected = [200, 201, 204]) {
	const headers = { Authorization: `Bearer ${adminToken}` };
	let body;
	if (payload !== undefined) {
		headers["Content-Type"] = "application/json";
		body = JSON.stringify(payload);
	}
	const response = await request(method, `${adminUrl}${path}`, {
		headers,
		body,
		expected,
	});
	if (!response.body) {
		return null;
	}
	return JSON.parse(response.body);
}

async function waitFor(check, failureMessage) {
	const deadline = Date.now() + waitTimeoutSeconds * 1000;
	while (Date.now() < deadline) {
		try {
			await check();
			return;
		} catch {
			await new Promise((resolve) => setTimeout(resolve, 2000));
		}
	}
	die(failureMessage);
}

async function waitForAdmin() {
	await waitFor(
		() => adminJson("GET", "/v2/GetClusterStatus"),
		"Garage admin API did not become ready",
	);
}

async function waitForS3() {
	await waitFor(
		() => request("GET", s3Endpoint, { expected: [200, 301, 302, 307, 403] }),
		"Garage S3 API did not become ready",
	);
}

async function readExistingAfterCreateFailure(createError, readExisting) {
	try {
		return await readExisting();
	} catch (error) {
		if (error instanceof HttpError && error.status === 404) {
			throw createError;
		}
		throw error;
	}
}

function stableJson(value) {
	return JSON.stringify(value);
}

async function upsertLayout() {
	const statusJson = await adminJson("GET", "/v2/GetClusterStatus");
	const nodeId = statusJson?.nodes?.[0]?.id ?? "";
	if (!nodeId) {
		die("Garage did not report any cluster node");
	}

	let currentRole = {};
	for (const node of statusJson?.nodes ?? []) {
		if (node.id === nodeId) {
			currentRole = node.role ?? {};
			break;
		}
	}

	const normalizedCurrent = {
		zone: currentRole.zone ?? null,
		capacity: currentRole.capacity ?? null,
		tags: [...(currentRole.tags ?? [])].sort(),
	};
	const normalizedDesired = {
		zone: layoutZone,
		capacity: layoutCapacityBytes,
		tags: [...layoutTags].sort(),
	};
	if (stableJson(normalizedCurrent) === stableJson(normalizedDesired)) {
		return;
	}

	const layoutJson = await adminJson(
		"POST",
		"/v2/UpdateClusterLayout",
		{
			roles: [
				{
					id: nodeId,
					zone: layoutZone,
					capacity: layoutCapacityBytes,
					tags: layoutTags,
				},
			],
		},
		[200, 201],
	);
	const currentVersion = Number(layoutJson?.version);
	if (!Number.isFinite(currentVersion)) {
		die("Garage layout update did not return a version");
	}
	await adminJson(
		"POST",
		"/v2/ApplyClusterLayout",
		{ version: currentVersion + 1 },
		[200, 204],
	);
}

async function readKeyInfoByName({ required = true } = {}) {
	const keysJson = await adminJson("GET", "/v2/ListKeys");
	const matchingKeys = (Array.isArray(keysJson) ? keysJson : []).filter(
		(key) => key?.name === s3KeyName,
	);
	if (matchingKeys.length === 0) {
		if (!required) {
			return null;
		}
		throw new HttpError(`Garage key ${s3KeyName} not found`, 404);
	}
	if (matchingKeys.length > 1) {
		die(
			`Garage key name ${s3KeyName} matched multiple keys; delete duplicates and rerun bootstrap`,
		);
	}
	return await adminJson(
		"GET",
		`/v2/GetKeyInfo?id=${encodeURIComponent(matchingKeys[0].id)}&showSecretKey=true`,
	);
}

function parseKeyCredentials(keyJson) {
	const accessKeyId = keyJson?.accessKeyId ?? "";
	if (!accessKeyId) {
		die(`Garage key ${s3KeyName} did not report an access key id`);
	}
	const secretAccessKey = keyJson?.secretAccessKey ?? "";
	if (!secretAccessKey) {
		die(`Garage key ${s3KeyName} did not report a secret access key`);
	}
	return { accessKeyId, secretAccessKey };
}

async function upsertKey() {
	const existingKeyJson = await readKeyInfoByName({ required: false });
	if (existingKeyJson) {
		return parseKeyCredentials(existingKeyJson);
	}

	let keyJson;
	try {
		keyJson = await adminJson(
			"POST",
			"/v2/CreateKey",
			{ name: s3KeyName },
			[200, 201],
		);
	} catch (error) {
		keyJson = await readExistingAfterCreateFailure(error, () =>
			readKeyInfoByName(),
		);
	}
	return parseKeyCredentials(keyJson);
}

async function upsertBucket(accessKeyId) {
	let bucketJson;
	try {
		bucketJson = await adminJson(
			"POST",
			"/v2/CreateBucket",
			{ globalAlias: s3Bucket },
			[200, 201],
		);
	} catch (error) {
		bucketJson = await readExistingAfterCreateFailure(error, () =>
			adminJson(
				"GET",
				`/v2/GetBucketInfo?globalAlias=${encodeURIComponent(s3Bucket)}`,
			),
		);
	}

	const bucketId = bucketJson?.id ?? "";
	if (!bucketId) {
		die(`Garage bucket ${s3Bucket} did not report an id`);
	}

	await adminJson(
		"POST",
		`/v2/UpdateBucket?id=${encodeURIComponent(bucketId)}`,
		{ quotas: { maxSize: cacheQuotaBytes, maxObjects: null } },
		[200, 204],
	);
	await adminJson(
		"POST",
		"/v2/AllowBucketKey",
		{
			bucketId,
			accessKeyId,
			permissions: { owner: true, read: true, write: true },
		},
		[200, 204],
	);
}

function escapeXml(value) {
	return value
		.replaceAll("&", "&amp;")
		.replaceAll("<", "&lt;")
		.replaceAll(">", "&gt;")
		.replaceAll('"', "&quot;")
		.replaceAll("'", "&apos;");
}

function sha256Hex(value) {
	return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value) {
	return createHmac("sha256", key).update(value).digest();
}

function getSignatureKey(secretKey, dateStamp, regionName, serviceName) {
	const dateKey = hmac(`AWS4${secretKey}`, dateStamp);
	const regionKey = hmac(dateKey, regionName);
	const serviceKey = hmac(regionKey, serviceName);
	return hmac(serviceKey, "aws4_request");
}

function iso8601Basic(date) {
	return date
		.toISOString()
		.replaceAll("-", "")
		.replaceAll(":", "")
		.replace(/\.\d{3}Z$/, "Z");
}

function dateStamp(date) {
	return date.toISOString().slice(0, 10).replaceAll("-", "");
}

async function applyLifecycle(accessKeyId, secretAccessKey) {
	const lifecycleXml = `<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule>
    <ID>sccache-expiry</ID>
    <Status>Enabled</Status>
    <Filter>
      <Prefix>${escapeXml(s3KeyPrefix)}</Prefix>
    </Filter>
    <Expiration>
      <Days>${cacheExpirationDays}</Days>
    </Expiration>
    <AbortIncompleteMultipartUpload>
      <DaysAfterInitiation>${abortMultipartDays}</DaysAfterInitiation>
    </AbortIncompleteMultipartUpload>
  </Rule>
</LifecycleConfiguration>`;
	const lifecycleBody = Buffer.from(lifecycleXml, "utf8");
	const endpoint = new URL(s3Endpoint);
	const canonicalUri = `/${s3Bucket}`;
	const canonicalQuery = "lifecycle=";
	const payloadHash = sha256Hex(lifecycleBody);
	const now = new Date();
	const amzDate = iso8601Basic(now);
	const shortDate = dateStamp(now);
	const canonicalHeaders = {
		"content-type": "application/xml",
		host: endpoint.host,
		"x-amz-content-sha256": payloadHash,
		"x-amz-date": amzDate,
	};
	const signedHeaderNames = Object.keys(canonicalHeaders).sort();
	const canonicalHeadersBlock = signedHeaderNames
		.map((name) => `${name}:${canonicalHeaders[name]}\n`)
		.join("");
	const signedHeaders = signedHeaderNames.join(";");
	const canonicalRequest = [
		"PUT",
		canonicalUri,
		canonicalQuery,
		canonicalHeadersBlock,
		signedHeaders,
		payloadHash,
	].join("\n");
	const credentialScope = `${shortDate}/${s3Region}/s3/aws4_request`;
	const stringToSign = [
		"AWS4-HMAC-SHA256",
		amzDate,
		credentialScope,
		sha256Hex(Buffer.from(canonicalRequest, "utf8")),
	].join("\n");
	const signature = createHmac(
		"sha256",
		getSignatureKey(secretAccessKey, shortDate, s3Region, "s3"),
	)
		.update(stringToSign)
		.digest("hex");
	const authorization =
		`AWS4-HMAC-SHA256 Credential=${accessKeyId}/${credentialScope}, ` +
		`SignedHeaders=${signedHeaders}, Signature=${signature}`;

	await request(
		"PUT",
		`${s3Endpoint.replace(/\/$/, "")}${canonicalUri}?lifecycle=`,
		{
			headers: {
				Authorization: authorization,
				"Content-Type": "application/xml",
				Host: endpoint.host,
				"X-Amz-Content-Sha256": payloadHash,
				"X-Amz-Date": amzDate,
			},
			body: lifecycleBody,
			expected: [200],
		},
	);
}

function syncS3AuthSecret(accessKeyId, secretAccessKey) {
	const manifestJson = JSON.stringify({
		apiVersion: "v1",
		kind: "Secret",
		metadata: {
			name: s3AuthSecretName,
			namespace: kubernetesNamespace,
		},
		type: "Opaque",
		stringData: {
			"access-key-id": accessKeyId,
			"secret-access-key": secretAccessKey,
		},
	});
	applyManifest(
		manifestJson,
		`kubectl apply Secret/${s3AuthSecretName} in namespace ${kubernetesNamespace}`,
	);
}

const adminUrl = env("GARAGE_ADMIN_URL", { required: true });
const s3Endpoint = env("GARAGE_S3_ENDPOINT", { required: true });
const s3Region = env("GARAGE_S3_REGION", { defaultValue: "garage" });
const s3Bucket = env("GARAGE_S3_BUCKET", { required: true });
const s3KeyName = env("GARAGE_S3_KEY_NAME", { defaultValue: s3Bucket });
const s3KeyPrefix = env("GARAGE_S3_KEY_PREFIX", { defaultValue: "sccache/" });
const layoutZone = env("GARAGE_LAYOUT_ZONE", { defaultValue: "dc1" });
const layoutTags = env("GARAGE_LAYOUT_TAGS", {
	defaultValue: "control-plane,sccache",
})
	.split(",")
	.map((tag) => tag.trim())
	.filter(Boolean);
const layoutCapacityBytes = Number(
	env("GARAGE_LAYOUT_CAPACITY_BYTES", { defaultValue: "5368709120" }),
);
const cacheQuotaBytes = Number(
	env("GARAGE_CACHE_QUOTA_BYTES", { defaultValue: "4294967296" }),
);
const cacheExpirationDays = Number(
	env("GARAGE_CACHE_EXPIRATION_DAYS", { defaultValue: "30" }),
);
const abortMultipartDays = Number(
	env("GARAGE_ABORT_MULTIPART_DAYS", { defaultValue: "1" }),
);
const kubernetesNamespace = env("POD_NAMESPACE", { required: true });
const s3AuthSecretName = env("GARAGE_S3_AUTH_SECRET_NAME", {
	defaultValue: "garage-sccache-auth",
});
const waitTimeoutSeconds = Number(
	env("GARAGE_WAIT_TIMEOUT_SECONDS", { defaultValue: "120" }),
);
const adminToken = readSecret(
	env("GARAGE_ADMIN_TOKEN_FILE", { required: true }),
);

try {
	await waitForAdmin();
	await upsertLayout();
	const key = await upsertKey();
	await upsertBucket(key.accessKeyId);
	await waitForS3();
	await applyLifecycle(key.accessKeyId, key.secretAccessKey);
	syncS3AuthSecret(key.accessKeyId, key.secretAccessKey);
	console.log("garage-bootstrap: bootstrap complete");
} catch (error) {
	die(error instanceof Error ? error.message : String(error));
}
