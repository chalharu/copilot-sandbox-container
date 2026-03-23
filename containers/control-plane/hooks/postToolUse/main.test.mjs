import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const postToolUseDir = path.dirname(currentFile);
const repoRoot = path.resolve(postToolUseDir, "..", "..", "..", "..");
const bundledLintersConfigPath = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"postToolUse",
	"linters.json",
);
const sourceBundledPostToolUseDir = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"postToolUse",
);

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		encoding: "utf8",
		...options,
	});

	if (result.error) {
		throw result.error;
	}

	return result;
}

function writeExecutable(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function setupRepo(t, prefix) {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
	t.after(() => {
		fs.rmSync(repo, { recursive: true, force: true });
	});

	run("git", ["init", "--quiet"], { cwd: repo });
	run("git", ["config", "user.name", "test"], { cwd: repo });
	run("git", ["config", "user.email", "test@example.com"], { cwd: repo });
	fs.mkdirSync(path.join(repo, ".github"), {
		recursive: true,
	});
	fs.mkdirSync(path.join(repo, ".copilot", "hooks"), {
		recursive: true,
	});
	fs.cpSync(
		sourceBundledPostToolUseDir,
		path.join(repo, ".copilot", "hooks", "postToolUse"),
		{
			recursive: true,
		},
	);
	fs.appendFileSync(
		path.join(repo, ".git", "info", "exclude"),
		["bin/", "hook.log", ".copilot/hooks/"].join("\n") + "\n",
		"utf8",
	);

	return repo;
}

function createToolStubs(
	repo,
	{
		markdownlint = true,
		biome = true,
		oxlint = true,
		eslint = false,
		ruff = false,
		containerizedBash = false,
		hadolint = false,
		firstTool = false,
		secondTool = false,
	} = {},
) {
	const binDir = path.join(repo, "bin");
	const logFile = path.join(repo, "hook.log");

	if (markdownlint) {
		writeExecutable(
			path.join(binDir, "markdownlint-cli2"),
			[
				"#!/bin/sh",
				'printf "%s\\n" "$*" >> "$HOOK_LOG"',
				'if [ "$1" = "--fix" ]; then',
				"  exit 0",
				"fi",
				'printf "remaining markdown issue in %s\\n" "$1" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (biome) {
		writeExecutable(
			path.join(binDir, "biome"),
			[
				"#!/bin/sh",
				'printf "biome %s\\n" "$*" >> "$HOOK_LOG"',
				'file="$2"',
				'if [ "$2" = "--write" ]; then',
				'  file="$3"',
				"  exit 0",
				"fi",
				'printf "biome unresolved in %s\\n" "$file" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (oxlint) {
		writeExecutable(
			path.join(binDir, "oxlint"),
			[
				"#!/bin/sh",
				'printf "oxlint %s\\n" "$*" >> "$HOOK_LOG"',
				'if [ "$1" = "--fix" ]; then',
				"  exit 0",
				"fi",
				'printf "oxlint unresolved in %s\\n" "$1" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (eslint) {
		writeExecutable(
			path.join(binDir, "eslint"),
			[
				"#!/bin/sh",
				'printf "eslint %s\\n" "$*" >> "$HOOK_LOG"',
				'if [ "$1" = "--fix" ]; then',
				"  exit 0",
				"fi",
				'printf "eslint unresolved in %s\\n" "$1" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (ruff) {
		writeExecutable(
			path.join(binDir, "ruff"),
			[
				"#!/bin/sh",
				'printf "ruff %s\\n" "$*" >> "$HOOK_LOG"',
				'if [ "$1" = "format" ]; then',
				"  exit 0",
				"fi",
				'if [ "$1" = "check" ] && [ "$2" = "--fix" ]; then',
				"  exit 0",
				"fi",
				'printf "ruff unresolved in %s\\n" "$2" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (containerizedBash) {
		writeExecutable(
			path.join(binDir, "bash"),
			[
				"#!/bin/sh",
				'printf "bash %s\\n" "$*" >> "$HOOK_LOG"',
				'printf "NODE_COMPILE_CACHE=%s\\n" "${NODE_COMPILE_CACHE:-}" >> "$HOOK_LOG"',
				'printf "NPM_CONFIG_CACHE=%s\\n" "${NPM_CONFIG_CACHE:-}" >> "$HOOK_LOG"',
				'if [ "$1" = "containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh" ] && [ "$2" = "fmt" ]; then',
				"  exit 0",
				"fi",
				'if [ "$1" = "containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh" ] && [ "$2" = "clippy-fix" ]; then',
				"  exit 0",
				"fi",
				'if [ "$1" = "containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh" ] && [ "$2" = "clippy" ]; then',
				'  printf "clippy unresolved\\n" >&2',
				"  exit 1",
				"fi",
				'if [ "$1" = "containers/control-plane/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh" ]; then',
				'  printf "yamllint unresolved in %s\\n" "$2" >&2',
				"  exit 1",
				"fi",
				'exec /usr/bin/bash "$@"',
			].join("\n"),
		);
	}

	if (hadolint) {
		writeExecutable(
			path.join(binDir, "hadolint"),
			[
				"#!/bin/sh",
				'printf "hadolint %s\\n" "$*" >> "$HOOK_LOG"',
				'printf "hadolint unresolved in %s\\n" "$1" >&2',
				"exit 1",
			].join("\n"),
		);
	}

	if (firstTool) {
		writeExecutable(
			path.join(binDir, "first-tool"),
			[
				"#!/bin/sh",
				'printf "first-tool %s\\n" "$*" >> "$HOOK_LOG"',
				"exit 0",
			].join("\n"),
		);
	}

	if (secondTool) {
		writeExecutable(
			path.join(binDir, "second-tool"),
			[
				"#!/bin/sh",
				'printf "second-tool %s\\n" "$*" >> "$HOOK_LOG"',
				"exit 0",
			].join("\n"),
		);
	}

	return {
		env: {
			...process.env,
			CONTROL_PLANE_HOOK_TMP_ROOT: path.join(repo, ".hook-cache"),
			PATH: `${binDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
			HOOK_LOG: logFile,
		},
		logFile,
	};
}

function seedRepo(repo) {
	fs.writeFileSync(path.join(repo, "README.md"), "# Title\n", "utf8");
	fs.writeFileSync(
		path.join(repo, "index.ts"),
		"export const value = 1;\n",
		"utf8",
	);
	run("git", ["add", "README.md", "index.ts"], { cwd: repo });
	run("git", ["commit", "-m", "init"], { cwd: repo, stdio: "ignore" });
}

function makeFilesDirty(repo) {
	fs.writeFileSync(
		path.join(repo, "README.md"),
		"# Title\n\nchanged\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "index.ts"),
		"export const value=1\n",
		"utf8",
	);
}

function changeDirtyFilesAgain(repo) {
	fs.appendFileSync(path.join(repo, "README.md"), "\nchanged again\n", "utf8");
	fs.appendFileSync(
		path.join(repo, "index.ts"),
		"console.log(value)\n",
		"utf8",
	);
}

function seedPythonRustDockerRepo(repo) {
	fs.mkdirSync(path.join(repo, "src"), { recursive: true });
	fs.writeFileSync(path.join(repo, "app.py"), "value = 1\n", "utf8");
	fs.writeFileSync(
		path.join(repo, "sample.yaml"),
		"kind: Config\nmetadata:\n  name: demo\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "Cargo.toml"),
		[
			"[package]",
			'name = "demo"',
			'version = "0.1.0"',
			'edition = "2021"',
			"",
		].join("\n"),
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "src", "lib.rs"),
		"pub fn value() -> i32 { 1 }\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "Dockerfile"),
		"FROM alpine:3.20\nRUN echo hello\n",
		"utf8",
	);
	run(
		"git",
		["add", "app.py", "sample.yaml", "Cargo.toml", "src/lib.rs", "Dockerfile"],
		{
			cwd: repo,
		},
	);
	run("git", ["commit", "-m", "init"], { cwd: repo, stdio: "ignore" });
}

function makePythonRustDockerDirty(repo) {
	fs.writeFileSync(path.join(repo, "app.py"), "value=1\n", "utf8");
	fs.writeFileSync(
		path.join(repo, "sample.yaml"),
		"kind Config\nmetadata:\n name demo\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "src", "lib.rs"),
		"pub fn value()->i32{1}\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "Dockerfile"),
		"FROM alpine:3.20\nRUN apk add curl\n",
		"utf8",
	);
}

function runHook(repo, env, toolResultType = "success") {
	return run(process.execPath, [".copilot/hooks/postToolUse/main.mjs"], {
		cwd: repo,
		env,
		input: JSON.stringify({
			cwd: repo,
			toolName: "bash",
			toolResult: { resultType: toolResultType },
		}),
	});
}

test("linters config defines concrete tools and language pipelines", () => {
	const lintersConfig = JSON.parse(
		fs.readFileSync(bundledLintersConfigPath, "utf8"),
	);
	const markdownlintFixNpx = lintersConfig.tools.find(
		(tool) => tool.id === "markdownlint-fix-npx",
	);
	const containerizedRustFmt = lintersConfig.tools.find(
		(tool) => tool.id === "containerized-rust-fmt",
	);
	const containerizedYamllint = lintersConfig.tools.find(
		(tool) => tool.id === "containerized-yamllint-check",
	);
	const markdownPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "markdown",
	);
	const scriptsPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "scripts",
	);
	const yamlPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "yaml",
	);
	const pythonPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "python",
	);
	const rustPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "rust",
	);
	const dockerPipeline = lintersConfig.pipelines.find(
		(pipeline) => pipeline.id === "dockerfile",
	);

	assert.equal(markdownlintFixNpx.command, "npx");
	assert.deepEqual(markdownlintFixNpx.args, [
		"--yes",
		"markdownlint-cli2",
		"--fix",
	]);
	assert.equal(containerizedRustFmt.command, "bash");
	assert.deepEqual(containerizedRustFmt.args, [
		"containers/control-plane/skills/containerized-rust-ops/scripts/podman-rust.sh",
		"fmt",
	]);
	assert.equal(containerizedRustFmt.appendFiles, false);
	assert.equal(containerizedYamllint.command, "bash");
	assert.equal(markdownPipeline.id, "markdown");
	assert.deepEqual(markdownPipeline.matcher, ["\\.(?:md|markdown)$"]);
	assert.deepEqual(markdownPipeline.steps[0].tools, [
		"markdownlint-fix",
		"markdownlint-fix-npx",
	]);
	assert.equal(scriptsPipeline.id, "scripts");
	assert.deepEqual(scriptsPipeline.matcher, ["\\.(?:[cm]?[jt]s|[jt]sx)$"]);
	assert.deepEqual(scriptsPipeline.steps[1].tools, [
		"oxlint-fix",
		"eslint-fix",
		"eslint-fix-npx",
		"oxlint-fix-npx",
	]);
	assert.equal(yamlPipeline.id, "yaml");
	assert.deepEqual(yamlPipeline.matcher, ["\\.(?:ya?ml)$"]);
	assert.deepEqual(yamlPipeline.steps[0].tools, [
		"containerized-yamllint-check",
	]);
	assert.deepEqual(pythonPipeline.matcher, ["\\.(?:py|pyi|pyw)$"]);
	assert.deepEqual(rustPipeline.matcher, ["\\.rs$"]);
	assert.deepEqual(rustPipeline.steps[0].tools, ["containerized-rust-fmt"]);
	assert.deepEqual(rustPipeline.steps[1].tools, [
		"containerized-rust-clippy-fix",
	]);
	assert.deepEqual(rustPipeline.steps[3].tools, [
		"containerized-rust-clippy-check",
	]);
	assert.deepEqual(dockerPipeline.matcher, [
		"(?:^|/)Dockerfile(?:\\.[^/]+)?$",
		"(?:^|/)[^/]+\\.Dockerfile$",
	]);
	assert.equal(lintersConfig.pipelines.length, 6);
});

test("main hook parses input once and runs configured linters incrementally", (t) => {
	const repo = setupRepo(t, "hook-main-");
	seedRepo(repo);
	makeFilesDirty(repo);

	const { env, logFile } = createToolStubs(repo);

	const firstRun = runHook(repo, env);
	const firstLog = fs.readFileSync(logFile, "utf8");

	const secondRun = runHook(repo, env);
	const secondLog = fs.readFileSync(logFile, "utf8");

	changeDirtyFilesAgain(repo);
	const thirdRun = runHook(repo, env);
	const thirdLog = fs.readFileSync(logFile, "utf8");

	assert.equal(firstRun.status, 1);
	assert.equal(secondRun.status, 0);
	assert.equal(thirdRun.status, 1);

	assert.equal(firstLog.trim().split("\n").length, 7);
	assert.equal(secondLog.trim().split("\n").length, 7);
	assert.equal(thirdLog.trim().split("\n").length, 14);

	assert.match(firstLog, /--fix README\.md/);
	assert.match(firstLog, /biome check --write index\.ts/);
	assert.match(firstLog, /oxlint --fix index\.ts/);

	assert.match(firstRun.stderr, /remaining markdown issue in README\.md/);
	assert.match(firstRun.stderr, /Biome reported unresolved issues:/);
	assert.match(
		firstRun.stderr,
		/JavaScript\/TypeScript linter reported unresolved issues:/,
	);
	assert.equal(secondRun.stderr, "");
	assert.match(thirdRun.stderr, /README\.md/);
	assert.match(thirdRun.stderr, /index\.ts/);
});

test("main hook can fall back from oxlint to eslint", (t) => {
	const repo = setupRepo(t, "hook-eslint-fallback-");
	seedRepo(repo);
	fs.writeFileSync(
		path.join(repo, "index.ts"),
		"export const value=1\n",
		"utf8",
	);

	const { env, logFile } = createToolStubs(repo, {
		oxlint: false,
		eslint: true,
	});
	const result = runHook(repo, env);
	const hookLog = fs.readFileSync(logFile, "utf8");

	assert.equal(result.status, 1);
	assert.equal(hookLog.includes("oxlint --fix index.ts"), false);
	assert.match(hookLog, /eslint --fix index\.ts/);
	assert.match(
		result.stderr,
		/JavaScript\/TypeScript linter reported unresolved issues:/,
	);
	assert.match(result.stderr, /eslint unresolved in index\.ts/);
});

test("main hook runs Python Rust YAML and Dockerfile pipelines", (t) => {
	const repo = setupRepo(t, "hook-extra-languages-");
	seedPythonRustDockerRepo(repo);
	makePythonRustDockerDirty(repo);

	const { env, logFile } = createToolStubs(repo, {
		markdownlint: false,
		biome: false,
		oxlint: false,
		eslint: false,
		ruff: true,
		containerizedBash: true,
		hadolint: true,
	});
	const result = runHook(repo, env);
	const hookLog = fs.readFileSync(logFile, "utf8");

	assert.equal(result.status, 1);
	assert.match(hookLog, /ruff format app\.py/);
	assert.match(hookLog, /ruff check --fix app\.py/);
	assert.match(
		hookLog,
		/bash containers\/control-plane\/skills\/containerized-rust-ops\/scripts\/podman-rust\.sh fmt/,
	);
	assert.match(
		hookLog,
		/bash containers\/control-plane\/skills\/containerized-rust-ops\/scripts\/podman-rust\.sh clippy-fix/,
	);
	assert.match(
		hookLog,
		/bash containers\/control-plane\/skills\/containerized-rust-ops\/scripts\/podman-rust\.sh clippy/,
	);
	assert.match(
		hookLog,
		/bash containers\/control-plane\/skills\/containerized-yamllint-ops\/scripts\/podman-yamllint\.sh sample\.yaml/,
	);
	assert.match(hookLog, /hadolint Dockerfile/);
	assert.match(hookLog, /NODE_COMPILE_CACHE=.+node-compile-cache/);
	assert.match(hookLog, /NPM_CONFIG_CACHE=.+npm-cache/);
	assert.match(result.stderr, /Ruff reported unresolved issues:/);
	assert.match(
		result.stderr,
		/Containerized Rust linter reported unresolved issues:/,
	);
	assert.match(result.stderr, /Yamllint reported unresolved issues:/);
	assert.match(result.stderr, /Hadolint reported unresolved issues:/);
	assert.match(result.stderr, /ruff unresolved in app\.py/);
	assert.match(result.stderr, /clippy unresolved/);
	assert.match(result.stderr, /yamllint unresolved in sample\.yaml/);
	assert.match(result.stderr, /hadolint unresolved in Dockerfile/);
});

test("main hook merges bundled linters config with .github overrides", (t) => {
	const repo = setupRepo(t, "hook-config-merge-");
	seedRepo(repo);
	makeFilesDirty(repo);
	fs.writeFileSync(
		path.join(repo, ".github", "linters.json"),
		JSON.stringify(
			{
				tools: [
					{ id: "repo-scripts-check", command: "second-tool", args: ["check"] },
				],
				pipelines: [
					{
						id: "scripts",
						matcher: ["\\.(?:[cm]?[jt]s|[jt]sx)$"],
						steps: [{ tools: ["repo-scripts-check"] }],
					},
				],
			},
			null,
			2,
		),
		"utf8",
	);

	const { env, logFile } = createToolStubs(repo, {
		biome: false,
		oxlint: false,
		eslint: false,
		secondTool: true,
	});
	const result = runHook(repo, env);
	const hookLog = fs.readFileSync(logFile, "utf8");

	assert.equal(result.status, 1);
	assert.match(hookLog, /--fix README\.md/);
	assert.match(hookLog, /second-tool check index\.ts/);
	assert.equal(hookLog.includes("biome check --write index.ts"), false);
	assert.equal(hookLog.includes("oxlint --fix index.ts"), false);
	assert.match(result.stderr, /remaining markdown issue in README\.md/);
	assert.equal(
		result.stderr.includes(
			"JavaScript/TypeScript linter reported unresolved issues:",
		),
		false,
	);
});

test("main hook skips all work when tool use is denied", (t) => {
	const repo = setupRepo(t, "hook-denied-");
	seedRepo(repo);
	makeFilesDirty(repo);

	const { env, logFile } = createToolStubs(repo);
	const result = runHook(repo, env, "denied");

	assert.equal(result.status, 0);
	assert.equal(fs.existsSync(logFile), false);
	assert.equal(result.stdout, "");
	assert.equal(result.stderr, "");
});
