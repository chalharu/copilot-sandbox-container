import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const gitHooksDir = path.dirname(currentFile);
const repoRoot = path.resolve(gitHooksDir, "..", "..", "..", "..");
const sourceBundledGitDir = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"git",
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

function createIsolatedGitEnv(t, prefix) {
	const home = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
	t.after(() => {
		fs.rmSync(home, { recursive: true, force: true });
	});

	return {
		home,
		env: {
			...process.env,
			HOME: home,
			XDG_CONFIG_HOME: path.join(home, ".config"),
			GIT_CONFIG_NOSYSTEM: "1",
			GIT_CONFIG_GLOBAL: path.join(home, ".gitconfig"),
		},
	};
}

function setupRepo(t, initialBranch = "main") {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), "git-hook-repo-"));
	t.after(() => {
		fs.rmSync(repo, { recursive: true, force: true });
	});
	const { env } = createIsolatedGitEnv(t, "git-hook-bootstrap-home-");

	run("git", ["init", `--initial-branch=${initialBranch}`, "--quiet"], {
		cwd: repo,
		env,
	});
	run("git", ["config", "user.name", "test"], { cwd: repo, env });
	run("git", ["config", "user.email", "test@example.com"], { cwd: repo, env });
	fs.writeFileSync(path.join(repo, "README.md"), "# Title\n", "utf8");
	run("git", ["add", "README.md"], { cwd: repo, env });
	run("git", ["commit", "-m", "init"], { cwd: repo, env, stdio: "ignore" });

	return repo;
}

function setupBareRemote(t) {
	const remote = fs.mkdtempSync(path.join(os.tmpdir(), "git-hook-remote-"));
	t.after(() => {
		fs.rmSync(remote, { recursive: true, force: true });
	});

	run("git", ["init", "--bare", "--quiet"], { cwd: remote });
	return remote;
}

function setupGlobalHooks(t, repo) {
	const { home, env } = createIsolatedGitEnv(t, "git-hook-home-");

	const copilotHooksDir = path.join(home, ".copilot", "hooks");
	const bundledGitDir = path.join(copilotHooksDir, "git");
	fs.mkdirSync(copilotHooksDir, { recursive: true });
	fs.cpSync(sourceBundledGitDir, bundledGitDir, { recursive: true });
	fs.cpSync(
		sourceBundledPostToolUseDir,
		path.join(copilotHooksDir, "postToolUse"),
		{ recursive: true },
	);
	fs.chmodSync(path.join(bundledGitDir, "pre-commit"), 0o755);
	fs.chmodSync(path.join(bundledGitDir, "pre-push"), 0o755);
	run("git", ["config", "--global", "core.hooksPath", bundledGitDir], {
		cwd: repo,
		env,
	});

	return { home, env, bundledGitDir };
}

function createSuccessToolStubs(repo) {
	const binDir = path.join(repo, "bin");
	const hookLog = path.join(repo, "hook.log");
	fs.mkdirSync(binDir, { recursive: true });
	writeExecutable(
		path.join(binDir, "markdownlint-cli2"),
		[
			"#!/bin/sh",
			'printf "markdownlint-cli2 %s\\n" "$*" >> "$HOOK_LOG"',
			"exit 0",
		].join("\n"),
	);
	writeExecutable(
		path.join(binDir, "biome"),
		["#!/bin/sh", 'printf "biome %s\\n" "$*" >> "$HOOK_LOG"', "exit 0"].join(
			"\n",
		),
	);
	writeExecutable(
		path.join(binDir, "oxlint"),
		["#!/bin/sh", 'printf "oxlint %s\\n" "$*" >> "$HOOK_LOG"', "exit 0"].join(
			"\n",
		),
	);

	return {
		PATH: `${binDir}:${process.env.PATH}`,
		HOOK_LOG: hookLog,
		CONTROL_PLANE_HOOK_TMP_ROOT: path.join(repo, ".hook-cache"),
	};
}

function writeRepoHook(repo, hookName, lines) {
	const hookPath = path.join(repo, ".github", "git-hooks", hookName);
	writeExecutable(hookPath, lines.join("\n"));
	return hookPath;
}

function stageFeatureFiles(repo) {
	fs.writeFileSync(
		path.join(repo, "README.md"),
		"# Title\n\nchanged\n",
		"utf8",
	);
	fs.writeFileSync(
		path.join(repo, "index.ts"),
		"export const value = 1;\n",
		"utf8",
	);
	run("git", ["add", "README.md", "index.ts"], { cwd: repo });
}

for (const branchName of ["main", "master"]) {
	test(`global pre-commit blocks commits on ${branchName}`, (t) => {
		const repo = setupRepo(t, branchName);
		const { env } = setupGlobalHooks(t, repo);

		fs.appendFileSync(path.join(repo, "README.md"), "\nblocked\n", "utf8");
		run("git", ["add", "README.md"], { cwd: repo });
		const result = run("git", ["commit", "-m", "blocked"], {
			cwd: repo,
			env,
		});

		assert.equal(result.status, 1);
		assert.match(
			result.stderr,
			new RegExp(`Refusing to commit directly to ${branchName}`),
		);
	});
}

test("global pre-commit runs bundled linter and repository hook on feature branches", (t) => {
	const repo = setupRepo(t, "main");
	const { env: hookEnv } = setupGlobalHooks(t, repo);
	const repoHookLog = path.join(repo, "repo-hook.log");
	const toolEnv = createSuccessToolStubs(repo);

	run("git", ["switch", "-c", "feature/global-hooks"], {
		cwd: repo,
		env: hookEnv,
	});
	stageFeatureFiles(repo);
	writeRepoHook(repo, "pre-commit", [
		"#!/bin/sh",
		'printf "repo-pre-commit\\n" >> "$REPO_HOOK_LOG"',
		"exit 0",
	]);

	const result = run("git", ["commit", "-m", "feature commit"], {
		cwd: repo,
		env: {
			...hookEnv,
			...toolEnv,
			REPO_HOOK_LOG: repoHookLog,
		},
	});

	assert.equal(result.status, 0);
	assert.match(
		fs.readFileSync(toolEnv.HOOK_LOG, "utf8"),
		/biome check --write index\.ts/,
	);
	assert.match(
		fs.readFileSync(toolEnv.HOOK_LOG, "utf8"),
		/markdownlint-cli2 --fix README\.md/,
	);
	assert.match(fs.readFileSync(repoHookLog, "utf8"), /repo-pre-commit/);
});

test("global pre-push blocks protected branches and passes through repository hooks", (t) => {
	const repo = setupRepo(t, "main");
	const remote = setupBareRemote(t);
	const { bundledGitDir, env: hookEnv } = setupGlobalHooks(t, repo);
	const repoHookLog = path.join(repo, "repo-pre-push.log");

	run("git", ["switch", "-c", "feature/global-hooks"], {
		cwd: repo,
		env: hookEnv,
	});
	run("git", ["remote", "add", "origin", remote], {
		cwd: repo,
		env: hookEnv,
	});
	writeRepoHook(repo, "pre-push", [
		"#!/bin/sh",
		'printf "args:%s %s\\n" "$1" "$2" >> "$REPO_HOOK_LOG"',
		"while IFS= read -r line; do",
		'  printf "stdin:%s\\n" "$line" >> "$REPO_HOOK_LOG"',
		"done",
		"exit 0",
	]);

	let result = run(
		"git",
		["push", "-u", "origin", "HEAD:feature/global-hooks"],
		{
			cwd: repo,
			env: {
				...hookEnv,
				REPO_HOOK_LOG: repoHookLog,
			},
		},
	);

	assert.equal(result.status, 0);
	assert.match(fs.readFileSync(repoHookLog, "utf8"), /args:origin /);

	fs.appendFileSync(path.join(repo, "README.md"), "\npush update\n", "utf8");
	run("git", ["add", "README.md"], { cwd: repo });
	run("git", ["commit", "--no-verify", "-m", "push update"], {
		cwd: repo,
		env: hookEnv,
	});
	result = run(path.join(bundledGitDir, "pre-push"), ["origin", remote], {
		cwd: repo,
		env: {
			...hookEnv,
			REPO_HOOK_LOG: repoHookLog,
		},
		input: [
			"refs/heads/feature/global-hooks local-oid refs/heads/feature/global-hooks remote-oid",
			"",
		].join("\n"),
	});
	assert.equal(result.status, 0);
	assert.match(
		fs.readFileSync(repoHookLog, "utf8"),
		/stdin:refs\/heads\/feature\/global-hooks /,
	);

	const preBlockedLog = fs.readFileSync(repoHookLog, "utf8");
	result = run("git", ["push", "origin", "HEAD:main"], {
		cwd: repo,
		env: {
			...hookEnv,
			REPO_HOOK_LOG: repoHookLog,
		},
	});
	assert.equal(result.status, 1);
	assert.match(result.stderr, /Refusing to push directly to main/);
	assert.equal(fs.readFileSync(repoHookLog, "utf8"), preBlockedLog);

	result = run("git", ["push", "origin", "HEAD:master"], {
		cwd: repo,
		env: {
			...hookEnv,
			REPO_HOOK_LOG: repoHookLog,
		},
	});
	assert.equal(result.status, 1);
	assert.match(result.stderr, /Refusing to push directly to master/);
	assert.equal(fs.readFileSync(repoHookLog, "utf8"), preBlockedLog);
});
