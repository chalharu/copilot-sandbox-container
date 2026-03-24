#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const SKILL_NAME = "audit-log-analysis";
const SKILL_SCRIPT_RELATIVE_PATH = path.join("scripts", "audit-analysis.mjs");
const SUPPORTED_TRIGGER_SOURCES = new Set([
	"agentStop",
	"errorOccurred",
	"manual",
	"postToolUse",
	"sessionEnd",
	"subagentStop",
]);

function resolveCandidateSkillScriptPaths() {
	const home = process.env.HOME ?? "/home/copilot";
	return [
		path.join(
			home,
			".copilot",
			"skills",
			SKILL_NAME,
			SKILL_SCRIPT_RELATIVE_PATH,
		),
		path.join(
			"/usr",
			"local",
			"share",
			"control-plane",
			"skills",
			SKILL_NAME,
			SKILL_SCRIPT_RELATIVE_PATH,
		),
	];
}

function resolveSkillScriptPath() {
	for (const candidatePath of resolveCandidateSkillScriptPaths()) {
		if (!fs.existsSync(candidatePath)) {
			continue;
		}
		if (!fs.statSync(candidatePath).isFile()) {
			throw new Error(
				`Audit analysis skill helper is not a file: ${candidatePath}`,
			);
		}
		return candidatePath;
	}

	throw new Error(
		`Audit analysis skill helper not found. Checked: ${resolveCandidateSkillScriptPaths().join(", ")}`,
	);
}

function resolveTriggerSource(argv = process.argv.slice(2)) {
	const triggerSource = argv[0] ?? "manual";
	if (!SUPPORTED_TRIGGER_SOURCES.has(triggerSource)) {
		throw new Error(
			`Unsupported audit analysis hook trigger: ${triggerSource}`,
		);
	}
	return triggerSource;
}

function main(argv = process.argv.slice(2)) {
	const skillScriptPath = resolveSkillScriptPath();
	const triggerSource = resolveTriggerSource(argv);
	const result = spawnSync(
		"node",
		[skillScriptPath, "refresh", "--trigger-source", triggerSource, "--quiet"],
		{
			encoding: "utf8",
			stdio: "pipe",
			env: process.env,
		},
	);

	if (result.error) {
		throw result.error;
	}

	if (result.status !== 0) {
		const output = (result.stderr || result.stdout || "").trim();
		throw new Error(
			output === ""
				? `Audit analysis skill helper exited with status ${result.status}`
				: output,
		);
	}
}

try {
	main();
} catch (error) {
	console.error(
		`control-plane audit analysis hook: ${error instanceof Error ? error.message : String(error)}`,
	);
	process.exit(1);
}
