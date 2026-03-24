import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const auditDir = path.dirname(currentFile);
const repoRoot = path.resolve(auditDir, "..", "..", "..", "..");
const bundledHooksConfigPath = path.join(
	repoRoot,
	"containers",
	"control-plane",
	"hooks",
	"hooks.json",
);

test("hooks config wires audit hooks, lifecycle analysis hooks, and bundled postToolUse hook", () => {
	const hooksConfig = JSON.parse(
		fs.readFileSync(bundledHooksConfigPath, "utf8"),
	);
	assert.equal(hooksConfig.hooks.sessionStart.length, 1);
	assert.equal(hooksConfig.hooks.userPromptSubmitted.length, 1);
	assert.equal(hooksConfig.hooks.preToolUse.length, 1);
	assert.equal(hooksConfig.hooks.postToolUse.length, 2);
	assert.equal(hooksConfig.hooks.agentStop.length, 1);
	assert.equal(hooksConfig.hooks.subagentStop.length, 1);
	assert.equal(hooksConfig.hooks.sessionEnd.length, 1);
	assert.equal(hooksConfig.hooks.errorOccurred.length, 1);

	assert.match(hooksConfig.hooks.sessionStart[0].bash, /COPILOT_HOME/);
	assert.match(
		hooksConfig.hooks.sessionStart[0].bash,
		/\/hooks\/audit\/main\.mjs/,
	);
	assert.match(hooksConfig.hooks.sessionStart[0].bash, /\.copilot/);
	assert.match(
		hooksConfig.hooks.sessionStart[0].bash,
		/node "\$hook_script" sessionStart/,
	);
	assert.match(
		hooksConfig.hooks.userPromptSubmitted[0].bash,
		/\/hooks\/audit\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.userPromptSubmitted[0].bash,
		/node "\$hook_script" userPromptSubmitted/,
	);
	assert.match(
		hooksConfig.hooks.preToolUse[0].bash,
		/\/hooks\/audit\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.preToolUse[0].bash,
		/node "\$hook_script" preToolUse/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[0].bash,
		/\/hooks\/audit\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[0].bash,
		/node "\$hook_script" postToolUse/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[1].bash,
		/\/hooks\/postToolUse\/main\.mjs/,
	);
	assert.match(hooksConfig.hooks.postToolUse[1].bash, /node "\$hook_script"$/);
	assert.match(
		hooksConfig.hooks.agentStop[0].bash,
		/\/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.agentStop[0].bash,
		/node "\$hook_script" agentStop$/,
	);
	assert.match(
		hooksConfig.hooks.subagentStop[0].bash,
		/\/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.subagentStop[0].bash,
		/node "\$hook_script" subagentStop$/,
	);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].bash,
		/\/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].bash,
		/node "\$hook_script" sessionEnd$/,
	);
	assert.match(
		hooksConfig.hooks.errorOccurred[0].bash,
		/\/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.errorOccurred[0].bash,
		/node "\$hook_script" errorOccurred$/,
	);
	assert.equal(
		hooksConfig.hooks.postToolUse[1].bash.includes(".github/hooks"),
		false,
	);

	for (const hook of [
		hooksConfig.hooks.sessionStart[0],
		hooksConfig.hooks.userPromptSubmitted[0],
		hooksConfig.hooks.preToolUse[0],
		hooksConfig.hooks.postToolUse[0],
		hooksConfig.hooks.postToolUse[1],
		hooksConfig.hooks.agentStop[0],
		hooksConfig.hooks.subagentStop[0],
		hooksConfig.hooks.sessionEnd[0],
		hooksConfig.hooks.errorOccurred[0],
	]) {
		assert.doesNotMatch(hook.bash, /NODE_COMPILE_CACHE=|NPM_CONFIG_CACHE=/);
		assert.doesNotMatch(
			hook.bash,
			/CONTROL_PLANE_HOOK_TMP_ROOT|CONTROL_PLANE_TMP_ROOT/,
		);
		assert.doesNotMatch(hook.powershell, /NODE_COMPILE_CACHE|NPM_CONFIG_CACHE/);
		assert.doesNotMatch(
			hook.powershell,
			/CONTROL_PLANE_HOOK_TMP_ROOT|CONTROL_PLANE_TMP_ROOT/,
		);
	}

	assert.match(hooksConfig.hooks.postToolUse[0].powershell, /COPILOT_HOME/);
	assert.match(
		hooksConfig.hooks.postToolUse[0].powershell,
		/hooks\/audit\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[0].powershell,
		/node \$hookScript postToolUse/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[1].powershell,
		/hooks\/postToolUse\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[1].powershell,
		/node \$hookScript$/,
	);
	assert.match(
		hooksConfig.hooks.agentStop[0].powershell,
		/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.agentStop[0].powershell,
		/node \$hookScript agentStop$/,
	);
	assert.match(
		hooksConfig.hooks.subagentStop[0].powershell,
		/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.subagentStop[0].powershell,
		/node \$hookScript subagentStop$/,
	);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].powershell,
		/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].powershell,
		/node \$hookScript sessionEnd$/,
	);
	assert.match(
		hooksConfig.hooks.errorOccurred[0].powershell,
		/hooks\/auditAnalysis\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.errorOccurred[0].powershell,
		/node \$hookScript errorOccurred$/,
	);
	assert.equal(
		hooksConfig.hooks.postToolUse[1].powershell.includes(".github/hooks"),
		false,
	);
});
