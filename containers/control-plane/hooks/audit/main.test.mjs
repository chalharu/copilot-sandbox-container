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

test("hooks config wires audit hooks and cleanup without lifecycle analysis hooks", () => {
	const hooksConfig = JSON.parse(
		fs.readFileSync(bundledHooksConfigPath, "utf8"),
	);

	assert.equal(hooksConfig.hooks.sessionStart.length, 1);
	assert.equal(hooksConfig.hooks.userPromptSubmitted.length, 1);
	assert.equal(hooksConfig.hooks.preToolUse.length, 3);
	assert.equal(hooksConfig.hooks.postToolUse.length, 2);
	assert.equal(hooksConfig.hooks.sessionEnd.length, 1);
	assert.equal(hooksConfig.hooks.agentStop, undefined);
	assert.equal(hooksConfig.hooks.subagentStop, undefined);
	assert.equal(hooksConfig.hooks.errorOccurred, undefined);

	assert.match(hooksConfig.hooks.sessionStart[0].bash, /COPILOT_HOME/);
	assert.match(
		hooksConfig.hooks.sessionStart[0].bash,
		/\/hooks\/audit\/main\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.sessionStart[0].bash,
		/node "\$hook_script" sessionStart$/,
	);
	assert.match(
		hooksConfig.hooks.userPromptSubmitted[0].bash,
		/node "\$hook_script" userPromptSubmitted$/,
	);
	assert.match(
		hooksConfig.hooks.preToolUse[0].bash,
		/node "\$hook_script" preToolUse$/,
	);
	assert.match(
		hooksConfig.hooks.preToolUse[1].bash,
		/\/hooks\/preToolUse\/main/,
	);
	assert.match(hooksConfig.hooks.preToolUse[1].bash, /"\$hook_script"$/);
	assert.match(
		hooksConfig.hooks.preToolUse[2].bash,
		/CONTROL_PLANE_HOOK_SESSION_KEY="\$PPID" node "\$hook_script"$/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[0].bash,
		/node "\$hook_script" postToolUse$/,
	);
	assert.match(
		hooksConfig.hooks.postToolUse[1].bash,
		/\/hooks\/postToolUse\/main\.mjs/,
	);
	assert.match(hooksConfig.hooks.postToolUse[1].bash, /node "\$hook_script"$/);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].bash,
		/\/hooks\/sessionEnd\/cleanup\.mjs/,
	);
	assert.match(
		hooksConfig.hooks.sessionEnd[0].bash,
		/CONTROL_PLANE_HOOK_SESSION_KEY="\$PPID" node "\$hook_script"$/,
	);

	for (const hook of [
		hooksConfig.hooks.sessionStart[0],
		hooksConfig.hooks.userPromptSubmitted[0],
		hooksConfig.hooks.preToolUse[0],
		hooksConfig.hooks.preToolUse[1],
		hooksConfig.hooks.preToolUse[2],
		hooksConfig.hooks.postToolUse[0],
		hooksConfig.hooks.postToolUse[1],
		hooksConfig.hooks.sessionEnd[0],
	]) {
		assert.equal("powershell" in hook, false);
		assert.doesNotMatch(hook.bash, /NODE_COMPILE_CACHE=|NPM_CONFIG_CACHE=/);
		assert.doesNotMatch(
			hook.bash,
			/CONTROL_PLANE_HOOK_TMP_ROOT|CONTROL_PLANE_TMP_ROOT/,
		);
	}

	assert.equal(
		hooksConfig.hooks.postToolUse[1].bash.includes(".github/hooks"),
		false,
	);
	assert.equal(JSON.stringify(hooksConfig).includes("auditAnalysis"), false);
});
