import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import jsYaml from "js-yaml";

const currentFile = fileURLToPath(import.meta.url);
const preToolUseDir = path.dirname(currentFile);
const repoRoot = path.resolve(preToolUseDir, "..", "..", "..", "..");
const bundledRulesConfigPath = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"preToolUse",
	"deny-rules.yaml",
);
const sourceBundledPreToolUseDir = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"preToolUse",
);
const sourceBundledNodeModulesDir = path.join(
	sourceBundledPreToolUseDir,
	"node_modules",
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
	const targetPreToolUseDir = path.join(
		repo,
		".copilot",
		"hooks",
		"preToolUse",
	);
	fs.cpSync(sourceBundledPreToolUseDir, targetPreToolUseDir, {
		recursive: true,
		filter: (source) => path.basename(source) !== "node_modules",
	});
	if (fs.existsSync(sourceBundledNodeModulesDir)) {
		fs.symlinkSync(
			sourceBundledNodeModulesDir,
			path.join(targetPreToolUseDir, "node_modules"),
			"dir",
		);
	}

	return repo;
}

function runHook(repo, input) {
	return run(process.execPath, [".copilot/hooks/preToolUse/main.mjs"], {
		cwd: repo,
		input: JSON.stringify({
			cwd: repo,
			...input,
		}),
	});
}

function parseHookOutput(result) {
	assert.equal(result.status, 0);
	assert.equal(result.stderr, "");
	return result.stdout.trim() === "" ? null : JSON.parse(result.stdout);
}

function writeRepoRules(repo, content) {
	fs.writeFileSync(
		path.join(repo, ".github", "pre-tool-use-rules.yaml"),
		content.trimStart(),
		"utf8",
	);
}

test("bundled preToolUse rules define git safety protections", () => {
	const rulesConfig = jsYaml.load(
		fs.readFileSync(bundledRulesConfigPath, "utf8"),
	);
	assert.equal(Array.isArray(rulesConfig), true);
	assert.equal(rulesConfig.length, 1);
	assert.equal(rulesConfig[0].toolName, "bash");
	assert.equal(rulesConfig[0].column, "command");
	assert.equal(rulesConfig[0].patterns.length, 3);
	assert.deepEqual(rulesConfig[0].patterns[0].patterns, [
		"^git commit(?: .+)? --no-verify(?: |$)",
		"^git commit(?: .+)? -n(?: |$)",
	]);
	assert.deepEqual(rulesConfig[0].patterns[2].patterns, [
		"^git push(?: .+)? --force(?: |$)",
		"^git push(?: .+)? -f(?: |$)",
	]);
});

test("hook denies git commit no-verify flags in long and short form", (t) => {
	const repo = setupRepo(t, "pre-tool-use-commit-");
	const longFormOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'git commit --no-verify -m "skip hooks"',
			}),
		}),
	);
	const shortFormOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'git commit -n -m "skip hooks"',
			}),
		}),
	);
	const clusteredShortFormOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'git commit -nm "skip hooks"',
			}),
		}),
	);

	assert.deepEqual(longFormOutput, {
		permissionDecision: "deny",
		permissionDecisionReason:
			"git commit --no-verify is blocked by control-plane policy. Run git commit without --no-verify so hooks stay enforced.",
	});
	assert.deepEqual(shortFormOutput, {
		permissionDecision: "deny",
		permissionDecisionReason:
			"git commit --no-verify is blocked by control-plane policy. Run git commit without --no-verify so hooks stay enforced.",
	});
	assert.deepEqual(clusteredShortFormOutput, {
		permissionDecision: "deny",
		permissionDecisionReason:
			"git commit --no-verify is blocked by control-plane policy. Run git commit without --no-verify so hooks stay enforced.",
	});
});

test("hook denies git push --no-verify and unsafe force pushes across command forms", (t) => {
	const repo = setupRepo(t, "pre-tool-use-push-");

	const noVerifyOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git push origin HEAD --no-verify",
			}),
		}),
	);
	const forceOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "FOO=1 git -C . push -f origin HEAD",
			}),
		}),
	);
	const forceWithLeaseOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "printf prepare && git push --force-with-lease origin HEAD",
			}),
		}),
	);

	assert.equal(noVerifyOutput.permissionDecision, "deny");
	assert.match(noVerifyOutput.permissionDecisionReason, /git push --no-verify/);
	assert.equal(forceOutput.permissionDecision, "deny");
	assert.match(
		forceOutput.permissionDecisionReason,
		/Force pushes are blocked/,
	);
	assert.equal(forceWithLeaseOutput, null);
});

test("hook allows safe git commands, git push -n, and non-bash tools", (t) => {
	const repo = setupRepo(t, "pre-tool-use-allow-");

	const safeGitOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git push origin HEAD",
			}),
		}),
	);
	const dryRunOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git push -n origin HEAD",
			}),
		}),
	);
	const nonBashOutput = parseHookOutput(
		runHook(repo, {
			toolName: "view",
			toolArgs: JSON.stringify({
				path: "/workspace/README.md",
			}),
		}),
	);

	assert.equal(safeGitOutput, null);
	assert.equal(dryRunOutput, null);
	assert.equal(nonBashOutput, null);
});

test("hook ignores tokens after git -- separator when matching deny rules", (t) => {
	const repo = setupRepo(t, "pre-tool-use-double-dash-");

	const commitPathspecOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git commit --amend -- --no-verify",
			}),
		}),
	);

	assert.equal(commitPathspecOutput, null);
});

test("hook does not treat commit message values as deny-rule flags", (t) => {
	const repo = setupRepo(t, "pre-tool-use-commit-message-");

	const shortFlagMessageOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'git commit -m "-n"',
			}),
		}),
	);
	const longFlagMessageOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'git commit -m "--no-verify"',
			}),
		}),
	);

	assert.equal(shortFlagMessageOutput, null);
	assert.equal(longFlagMessageOutput, null);
});

test("hook unwraps sh -c and bash -lc wrappers before matching deny rules", (t) => {
	const repo = setupRepo(t, "pre-tool-use-shell-wrapper-");

	const wrappedCommitOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: 'bash -lc "git commit --no-verify -m \\"skip hooks\\""',
			}),
		}),
	);
	const wrappedForcePushOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "sh -c 'git push -f origin HEAD'",
			}),
		}),
	);
	const wrappedForceWithLeaseOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "env FOO=1 bash -lc 'git push --force-with-lease origin HEAD'",
			}),
		}),
	);

	assert.equal(wrappedCommitOutput.permissionDecision, "deny");
	assert.match(
		wrappedCommitOutput.permissionDecisionReason,
		/git commit --no-verify/,
	);
	assert.equal(wrappedForcePushOutput.permissionDecision, "deny");
	assert.match(
		wrappedForcePushOutput.permissionDecisionReason,
		/Force pushes are blocked/,
	);
	assert.equal(wrappedForceWithLeaseOutput, null);
});

test("hook merges bundled rules with repo-local additions", (t) => {
	const repo = setupRepo(t, "pre-tool-use-override-");
	writeRepoRules(
		repo,
		`
- toolName: bash
  column: command
  patterns:
    - patterns:
        - '^git status(?: .+)? --short(?: |$)'
      reason: repo-local policy
`,
	);

	const statusOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git status --short",
			}),
		}),
	);
	const bundledOutput = parseHookOutput(
		runHook(repo, {
			toolName: "bash",
			toolArgs: JSON.stringify({
				command: "git commit --no-verify -m test",
			}),
		}),
	);

	assert.deepEqual(statusOutput, {
		permissionDecision: "deny",
		permissionDecisionReason: "repo-local policy",
	});
	assert.equal(bundledOutput.permissionDecision, "deny");
	assert.match(
		bundledOutput.permissionDecisionReason,
		/git commit --no-verify/,
	);
});

test("hook rejects repo-local configs with invalid regex patterns", (t) => {
	const repo = setupRepo(t, "pre-tool-use-invalid-regex-");
	writeRepoRules(
		repo,
		`
- toolName: bash
  column: command
  patterns:
    - patterns:
        - '('
      reason: broken regex
`,
	);

	const result = runHook(repo, {
		toolName: "bash",
		toolArgs: JSON.stringify({
			command: "git status --short",
		}),
	});

	assert.equal(result.status, 1);
	assert.equal(result.stdout, "");
	assert.match(result.stderr, /Invalid regex pattern 1/);
});
