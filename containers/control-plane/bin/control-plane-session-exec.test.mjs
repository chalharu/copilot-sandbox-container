import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const binDir = path.dirname(currentFile);
const sessionExecPath = path.join(binDir, "control-plane-session-exec");

function writeExecutable(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function expectedPodName(ownerPodName, sessionKey) {
	const checksum = createHash("sha256")
		.update(`${ownerPodName}:${sessionKey}`)
		.digest("hex")
		.slice(0, 10);
	return `control-plane-exec-${checksum}-${sessionKey}`;
}

function escapeRegex(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function setupHarness(
	t,
	execResponse = { stdout: "", stderr: "", exitCode: 0 },
) {
	const tempDir = fs.mkdtempSync(
		path.join(os.tmpdir(), "control-plane-session-exec-test-"),
	);
	t.after(() => {
		fs.rmSync(tempDir, { recursive: true, force: true });
	});

	const homeDir = path.join(tempDir, "home");
	const fakeBinDir = path.join(tempDir, "fake-bin");
	const kubectlStateFile = path.join(tempDir, "kubectl-state.json");
	const kubectlCommandsLog = path.join(tempDir, "kubectl-commands.log");
	const kubectlManifestFile = path.join(tempDir, "kubectl-create.yaml");
	const execApiArgsFile = path.join(tempDir, "exec-api-args.log");

	fs.mkdirSync(homeDir, { recursive: true });
	fs.mkdirSync(fakeBinDir, { recursive: true });
	fs.writeFileSync(kubectlStateFile, JSON.stringify({ pods: {} }), "utf8");

	writeExecutable(
		path.join(fakeBinDir, "kubectl"),
		`#!/usr/bin/env node
import fs from "node:fs";

const args = process.argv.slice(2);
const stateFile = process.env.KUBECTL_TEST_STATE_FILE;
const commandsLog = process.env.KUBECTL_TEST_COMMANDS_LOG;
const manifestFile = process.env.KUBECTL_TEST_MANIFEST_FILE;

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return { pods: {} };
  }
}

function saveState(state) {
  fs.writeFileSync(stateFile, JSON.stringify(state), "utf8");
}

function argAfter(flag) {
  const index = args.indexOf(flag);
  return index === -1 ? "" : args[index + 1];
}

function podNameFromArgs(startIndex) {
  for (let index = startIndex; index < args.length; index += 1) {
    if (args[index] === "--namespace") {
      index += 1;
      continue;
    }
    if (!args[index].startsWith("-")) {
      return args[index];
    }
  }
  return "";
}

fs.appendFileSync(commandsLog, \`\${JSON.stringify(args)}\\n\`, "utf8");

if (args[0] === "get" && args[1] === "pod") {
  const podName = podNameFromArgs(2);
  const state = loadState();
  const pod = state.pods[podName];
  if (!pod) {
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(pod));
  process.exit(0);
}

if (args[0] === "create" && args[1] === "-f" && args[2] === "-") {
  const manifest = fs.readFileSync(0, "utf8");
  fs.writeFileSync(manifestFile, manifest, "utf8");
  const manifestMatch = manifest.match(/^metadata:\\n  name: '([^']+)'\\n  namespace: '([^']+)'/m);
  if (!manifestMatch) {
    console.error("unable to parse pod manifest metadata");
    process.exit(1);
  }

  const [, podName, namespace] = manifestMatch;
  const state = loadState();
  state.pods[podName] = {
    metadata: {
      name: podName,
      namespace,
    },
    spec: {
      nodeName: process.env.CONTROL_PLANE_NODE_NAME || "kind-control-plane",
    },
    status: {
      phase: "Running",
      podIP: process.env.KUBECTL_TEST_POD_IP || "10.20.30.40",
      containerStatuses: [
        {
          name: "execution",
          ready: true,
        },
      ],
    },
  };
  saveState(state);
  process.exit(0);
}

if (args[0] === "wait") {
  const podName = args.find((value) => value.startsWith("pod/"))?.slice(4) || "";
  const state = loadState();
  process.exit(state.pods[podName] ? 0 : 1);
}

if (args[0] === "delete" && args[1] === "pod") {
  const podName = podNameFromArgs(2);
  const state = loadState();
  delete state.pods[podName];
  saveState(state);
  process.exit(0);
}

if (args[0] === "describe" || args[0] === "logs") {
  process.exit(0);
}

console.error(\`unexpected kubectl invocation: \${JSON.stringify(args)}\`);
process.exit(1);
`,
	);

	writeExecutable(
		path.join(fakeBinDir, "control-plane-exec-api"),
		`#!/usr/bin/env node
import fs from "node:fs";

const args = process.argv.slice(2);
const argsFile = process.env.EXEC_API_TEST_ARGS_FILE;
const execResponse = process.env.EXEC_API_TEST_RESPONSE || '{"stdout":"","stderr":"","exitCode":0}';
const bootstrapResponse = process.env.EXEC_API_TEST_BOOTSTRAP_RESPONSE || '{"stdout":"","stderr":"","exitCode":0}';

function argAfter(flag) {
  const index = args.indexOf(flag);
  return index === -1 ? "" : args[index + 1];
}

if (argsFile) {
  fs.appendFileSync(argsFile, \`\${JSON.stringify(args)}\\n\`, "utf8");
}

if (args[0] === "health") {
  process.exit(0);
}

if (args[0] === "exec") {
  const commandBase64 = argAfter("--command-base64");
  const command = commandBase64
    ? Buffer.from(commandBase64, "base64").toString("utf8")
    : "";
  process.stdout.write(
    command.includes("runtime-ready") ? bootstrapResponse : execResponse,
  );
  process.exit(0);
}

console.error(\`unexpected control-plane-exec-api invocation: \${JSON.stringify(args)}\`);
process.exit(1);
`,
	);

	return {
		env: {
			...process.env,
			HOME: homeDir,
			PATH: `${fakeBinDir}:${process.env.PATH ?? ""}`,
			KUBECTL_TEST_STATE_FILE: kubectlStateFile,
			KUBECTL_TEST_COMMANDS_LOG: kubectlCommandsLog,
			KUBECTL_TEST_MANIFEST_FILE: kubectlManifestFile,
			KUBECTL_TEST_POD_IP: "10.20.30.40",
			EXEC_API_TEST_ARGS_FILE: execApiArgsFile,
			EXEC_API_TEST_RESPONSE: JSON.stringify(execResponse),
			EXEC_API_TEST_BOOTSTRAP_RESPONSE: JSON.stringify({
				stdout: "",
				stderr: "",
				exitCode: 0,
			}),
			CONTROL_PLANE_FAST_EXECUTION_ENABLED: "1",
			CONTROL_PLANE_WORKSPACE_PVC: "control-plane-workspace-pvc",
			CONTROL_PLANE_WORKSPACE_SUBPATH: "workspace",
			CONTROL_PLANE_COPILOT_SESSION_PVC: "control-plane-copilot-session-pvc",
			CONTROL_PLANE_COPILOT_SESSION_GH_SUBPATH: "state/gh",
			CONTROL_PLANE_COPILOT_SESSION_SSH_SUBPATH: "state/ssh",
			CONTROL_PLANE_POD_NAME: "control-plane-0",
			CONTROL_PLANE_POD_UID: "pod-uid-1",
			CONTROL_PLANE_POD_NAMESPACE: "copilot-sandbox",
			CONTROL_PLANE_NODE_NAME: "kind-control-plane",
			CONTROL_PLANE_FAST_EXECUTION_IMAGE: "ghcr.io/example/control-plane:test",
			CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE:
				"ghcr.io/example/control-plane-bootstrap:test",
			CONTROL_PLANE_FAST_EXECUTION_IMAGE_PULL_POLICY: "Never",
			CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_IMAGE_PULL_POLICY: "IfNotPresent",
			CONTROL_PLANE_FAST_EXECUTION_HOME: "/root",
			CONTROL_PLANE_FAST_EXECUTION_BOOTSTRAP_ROOT:
				"/var/run/control-plane-bootstrap",
			CONTROL_PLANE_FAST_EXECUTION_CPU_REQUEST: "250m",
			CONTROL_PLANE_FAST_EXECUTION_CPU_LIMIT: "1",
			CONTROL_PLANE_FAST_EXECUTION_MEMORY_REQUEST: "256Mi",
			CONTROL_PLANE_FAST_EXECUTION_MEMORY_LIMIT: "1Gi",
			CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC: "3600",
		},
		kubectlCommandsLog,
		kubectlManifestFile,
		kubectlStateFile,
		execApiArgsFile,
		homeDir,
	};
}

function runSessionExec(args, env) {
	const result = spawnSync(sessionExecPath, args, {
		encoding: "utf8",
		env,
	});
	assert.equal(result.error, undefined);
	return result;
}

function readJsonLines(filePath) {
	const content = fs.readFileSync(filePath, "utf8").trim();
	if (content === "") {
		return [];
	}
	return content
		.split("\n")
		.filter(Boolean)
		.map((line) => JSON.parse(line));
}

test("prepare renders the execution pod manifest and caches the pod state", (t) => {
	const harness = setupHarness(t);
	const sessionKey = "session-42";
	const podName = expectedPodName(
		harness.env.CONTROL_PLANE_POD_NAME,
		sessionKey,
	);

	const result = runSessionExec(
		["prepare", "--session-key", sessionKey],
		harness.env,
	);

	assert.equal(result.status, 0);
	assert.equal(result.stdout, "");

	const state = JSON.parse(
		fs.readFileSync(
			path.join(
				harness.homeDir,
				".copilot",
				"session-state",
				"session-exec.json",
			),
			"utf8",
		),
	);
	assert.equal(state.sessions[sessionKey].podName, podName);
	assert.equal(state.sessions[sessionKey].podIp, "10.20.30.40");
	assert.match(state.sessions[sessionKey].authToken, /^[A-Za-z0-9+/=]+$/);
	assert.equal(state.sessions[sessionKey].namespace, "copilot-sandbox");
	assert.equal(
		state.sessions[sessionKey].ownerPodName,
		harness.env.CONTROL_PLANE_POD_NAME,
	);
	assert.equal(
		state.sessions[sessionKey].ownerPodUid,
		harness.env.CONTROL_PLANE_POD_UID,
	);

	const manifest = fs.readFileSync(harness.kubectlManifestFile, "utf8");
	assert.match(manifest, new RegExp(`name: '${podName}'`));
	assert.match(manifest, /namespace: 'copilot-sandbox'/);
	assert.match(manifest, /control-plane.github.io\/session-key: 'session-42'/);
	assert.match(manifest, /ownerReferences:/);
	assert.match(manifest, /name: 'control-plane-0'/);
	assert.match(manifest, /uid: 'pod-uid-1'/);
	assert.match(manifest, /nodeName: 'kind-control-plane'/);
	assert.match(manifest, /image: 'ghcr.io\/example\/control-plane:test'/);
	assert.match(
		manifest,
		/image: 'ghcr.io\/example\/control-plane-bootstrap:test'/,
	);
	assert.match(manifest, /imagePullPolicy: 'Never'/);
	assert.match(manifest, /initContainers:/);
	assert.match(manifest, /name: bootstrap-assets/);
	assert.match(
		manifest,
		/cp \/usr\/local\/bin\/control-plane-exec-api '\/var\/run\/control-plane-bootstrap\/bin\/control-plane-exec-api'/,
	);
	assert.match(manifest, /grpc:/);
	assert.doesNotMatch(manifest, /httpGet:/);
	assert.match(manifest, /- name: workspace/);
	assert.match(manifest, /claimName: 'control-plane-workspace-pvc'/);
	assert.match(manifest, /- name: copilot-session/);
	assert.match(manifest, /claimName: 'control-plane-copilot-session-pvc'/);
	assert.match(manifest, /- name: bootstrap/);
	assert.match(manifest, /mountPath: '\/var\/run\/control-plane-bootstrap'/);
	const volumeMountsSection = manifest.match(
		/ {6}volumeMounts:\n([\s\S]*?)\n {6}env:/,
	);
	assert.ok(volumeMountsSection);
	assert.match(volumeMountsSection[1], /mountPath: '\/root\/.config\/gh'/);
	assert.match(volumeMountsSection[1], /mountPath: '\/root\/.ssh'/);
	assert.match(manifest, /name: HOME/);
	assert.match(manifest, /value: '\/root'/);
	assert.match(manifest, /name: GIT_CONFIG_GLOBAL/);
	assert.match(manifest, /value: '\/root\/.gitconfig'/);
	assert.match(manifest, /mkdir -p '\/root' '\/root\/.config'/);
	assert.ok(
		manifest.indexOf("chown 0:0 '/root' '/root/.config'") <
			manifest.indexOf("chmod 700 '/root' '/root/.config'"),
	);
	assert.ok(
		manifest.indexOf("chmod 700 '/root' '/root/.config'") <
			manifest.indexOf("chown 1000:1000 '/root' '/root/.config'"),
	);
	assert.ok(
		manifest.indexOf("chown 0:0 '/root/.gitconfig'") <
			manifest.indexOf("chmod 600 '/root/.gitconfig'"),
	);
	assert.ok(
		manifest.indexOf("chmod 600 '/root/.gitconfig'") <
			manifest.indexOf("chown 1000:1000 '/root/.gitconfig'"),
	);
	const envSection = manifest.match(/ {6}env:\n([\s\S]*?)\n {2}volumes:/);
	assert.ok(envSection);
	assert.doesNotMatch(envSection[1], /mountPath:/);
	assert.doesNotMatch(envSection[1], /subPath:/);
	assert.doesNotMatch(envSection[1], /readOnly:/);
	assert.doesNotMatch(manifest, /control-plane-auth/);
	assert.doesNotMatch(manifest, /control-plane-config/);
	assert.doesNotMatch(manifest, /garage-sccache-auth/);
	assert.doesNotMatch(manifest, /envFrom:/);
	assert.match(manifest, /name: CONTROL_PLANE_EXEC_API_TOKEN/);
	assert.match(
		manifest,
		/name: CONTROL_PLANE_FAST_EXECUTION_REQUEST_TIMEOUT_SEC/,
	);
	assert.match(manifest, /value: '3600'/);
	assert.match(manifest, /name: CONTROL_PLANE_FAST_EXECUTION_RUN_AS_UID/);
	assert.match(manifest, /value: '1000'/);
	assert.match(manifest, /name: CONTROL_PLANE_FAST_EXECUTION_RUN_AS_GID/);
	assert.match(
		manifest,
		new RegExp(`value: '${escapeRegex(state.sessions[sessionKey].authToken)}'`),
	);
});

test("proxy reuses the cached execution pod and cleanup removes it", (t) => {
	const harness = setupHarness(t, {
		stdout: "proxy stdout\n",
		stderr: "proxy stderr\n",
		exitCode: 7,
	});
	const sessionKey = "session-43";
	const command = "printf 'hello from proxy\\n'; exit 7";
	const commandBase64 = Buffer.from(command, "utf8").toString("base64");

	assert.equal(
		runSessionExec(["prepare", "--session-key", sessionKey], harness.env)
			.status,
		0,
	);

	const proxyResult = runSessionExec(
		[
			"proxy",
			"--session-key",
			sessionKey,
			"--cwd",
			"/workspace/subdir",
			"--command-base64",
			commandBase64,
		],
		harness.env,
	);

	assert.equal(proxyResult.status, 7);
	assert.equal(proxyResult.stdout, "proxy stdout\n");
	assert.equal(proxyResult.stderr, "proxy stderr\n");

	const execApiCalls = readJsonLines(harness.execApiArgsFile);
	const execArgs = execApiCalls.find(
		(args) =>
			args[0] === "exec" &&
			args.includes("--command-base64") &&
			args[args.indexOf("--command-base64") + 1] === commandBase64,
	);
	assert.ok(execArgs);
	assert.deepEqual(execArgs, [
		"exec",
		"--addr",
		"http://10.20.30.40:8080",
		"--timeout-sec",
		"3600",
		"--token",
		JSON.parse(
			fs.readFileSync(
				path.join(
					harness.homeDir,
					".copilot",
					"session-state",
					"session-exec.json",
				),
				"utf8",
			),
		).sessions[sessionKey].authToken,
		"--cwd",
		"/workspace/subdir",
		"--command-base64",
		commandBase64,
	]);

	const commandLog = readJsonLines(harness.kubectlCommandsLog);
	assert.equal(commandLog.filter((args) => args[0] === "create").length, 1);

	const cleanupResult = runSessionExec(
		["cleanup", "--session-key", sessionKey],
		harness.env,
	);
	assert.equal(cleanupResult.status, 0);

	const state = JSON.parse(
		fs.readFileSync(
			path.join(
				harness.homeDir,
				".copilot",
				"session-state",
				"session-exec.json",
			),
			"utf8",
		),
	);
	assert.equal(state.sessions[sessionKey], undefined);

	const kubectlState = JSON.parse(
		fs.readFileSync(harness.kubectlStateFile, "utf8"),
	);
	assert.deepEqual(kubectlState.pods, {});
});
