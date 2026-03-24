#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const GIT_OPTIONS_WITH_VALUE = new Set([
	"-c",
	"-C",
	"--config-env",
	"--exec-path",
	"--git-dir",
	"--namespace",
	"--super-prefix",
	"--work-tree",
]);
const GIT_SUBCOMMAND_OPTIONS_WITH_VALUE = new Map([
	[
		"commit",
		{
			short: new Set(["-c", "-C", "-F", "-m", "-t"]),
			long: new Set([
				"--author",
				"--cleanup",
				"--date",
				"--file",
				"--fixup",
				"--message",
				"--pathspec-from-file",
				"--reedit-message",
				"--reuse-message",
				"--squash",
				"--template",
				"--trailer",
			]),
		},
	],
	[
		"push",
		{
			short: new Set(["-o"]),
			long: new Set(["--exec", "--push-option", "--receive-pack", "--repo"]),
		},
	],
]);
const SHELL_COMMAND_SEPARATORS = new Set(["&&", "||", ";", "|", "&"]);

function readStdin() {
	return new Promise((resolve, reject) => {
		let data = "";
		process.stdin.setEncoding("utf8");
		process.stdin.on("data", (chunk) => {
			data += chunk;
		});
		process.stdin.on("end", () => resolve(data));
		process.stdin.on("error", reject);
	});
}

function parseHookInput(rawInput) {
	if (rawInput.trim() === "") {
		return {};
	}

	let parsed;
	try {
		parsed = JSON.parse(rawInput);
	} catch (error) {
		throw new Error(
			`Failed to parse preToolUse hook input JSON: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error("preToolUse hook input must be a top-level JSON object.");
	}

	return parsed;
}

function parseToolArgs(toolArgs) {
	if (toolArgs === undefined || toolArgs === null || toolArgs === "") {
		return null;
	}

	if (typeof toolArgs === "string") {
		let parsed;
		try {
			parsed = JSON.parse(toolArgs);
		} catch (error) {
			throw new Error(
				`Failed to parse preToolUse toolArgs JSON: ${error instanceof Error ? error.message : String(error)}`,
			);
		}

		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			throw new Error("preToolUse toolArgs must decode to a JSON object.");
		}

		return parsed;
	}

	if (typeof toolArgs === "object" && !Array.isArray(toolArgs)) {
		return toolArgs;
	}

	throw new Error(
		"preToolUse toolArgs must be a JSON object or JSON object string.",
	);
}

function runCommand(command, args, cwd) {
	return spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		stdio: "pipe",
	});
}

function resolveRepoRoot(cwd) {
	const result = runCommand("git", ["rev-parse", "--show-toplevel"], cwd);
	if (result.error) {
		throw result.error;
	}

	if (result.status !== 0) {
		return cwd;
	}

	const repoRoot = result.stdout.trim();
	return repoRoot === "" ? cwd : repoRoot;
}

function describeConfigPath(configPath) {
	return configPath instanceof URL ? configPath.pathname : configPath;
}

function validateRuleShape(rule, configDescription, seenIds) {
	if (!rule || typeof rule !== "object" || Array.isArray(rule)) {
		throw new Error(`Each rule in ${configDescription} must be a JSON object.`);
	}

	if (typeof rule.id !== "string" || rule.id === "") {
		throw new Error(
			`Each rule in ${configDescription} must define a non-empty string id.`,
		);
	}

	if (seenIds.has(rule.id)) {
		throw new Error(`Duplicate rule id in ${configDescription}: ${rule.id}`);
	}
	seenIds.add(rule.id);

	if (
		!Array.isArray(rule.toolNames) ||
		rule.toolNames.length === 0 ||
		rule.toolNames.some(
			(toolName) => typeof toolName !== "string" || toolName === "",
		)
	) {
		throw new Error(
			`Rule "${rule.id}" in ${configDescription} must define toolNames as a non-empty array of strings.`,
		);
	}

	if (typeof rule.reason !== "string" || rule.reason === "") {
		throw new Error(
			`Rule "${rule.id}" in ${configDescription} must define a non-empty string reason.`,
		);
	}

	if (
		!rule.match ||
		typeof rule.match !== "object" ||
		Array.isArray(rule.match)
	) {
		throw new Error(
			`Rule "${rule.id}" in ${configDescription} must define match as a JSON object.`,
		);
	}

	if (rule.match.kind !== "gitCli") {
		throw new Error(
			`Rule "${rule.id}" in ${configDescription} must use match.kind "gitCli".`,
		);
	}

	if (
		typeof rule.match.subcommand !== "string" ||
		rule.match.subcommand === ""
	) {
		throw new Error(
			`Rule "${rule.id}" in ${configDescription} must define a non-empty gitCli subcommand.`,
		);
	}

	for (const fieldName of ["allOfArgs", "anyOfArgs"]) {
		const value = rule.match[fieldName];
		if (
			value !== undefined &&
			(!Array.isArray(value) ||
				value.some((entry) => typeof entry !== "string" || entry === ""))
		) {
			throw new Error(
				`Rule "${rule.id}" in ${configDescription} must define ${fieldName} as an array of non-empty strings when present.`,
			);
		}
	}
}

function readRulesConfigFile(configPath, { optional = false } = {}) {
	const configDescription = describeConfigPath(configPath);
	let raw;

	try {
		raw = fs.readFileSync(configPath, "utf8");
	} catch (error) {
		if (
			optional &&
			error &&
			typeof error === "object" &&
			"code" in error &&
			error.code === "ENOENT"
		) {
			return null;
		}

		throw new Error(
			`Failed to read preToolUse rules config at ${configDescription}: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	let parsed;
	try {
		parsed = JSON.parse(raw);
	} catch (error) {
		throw new Error(
			`Failed to parse preToolUse rules config at ${configDescription}: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error(
			`preToolUse rules config at ${configDescription} must contain a top-level JSON object.`,
		);
	}

	if (!Array.isArray(parsed.rules)) {
		throw new Error(
			`preToolUse rules config at ${configDescription} must define rules as an array.`,
		);
	}

	const seenIds = new Set();
	for (const rule of parsed.rules) {
		validateRuleShape(rule, configDescription, seenIds);
	}

	return parsed;
}

function mergeRules(baseRules, repoRules, repoConfigDescription) {
	const bundledRuleIds = new Set(baseRules.map((rule) => rule.id));

	for (const rule of repoRules) {
		if (bundledRuleIds.has(rule.id)) {
			throw new Error(
				`preToolUse rules config at ${repoConfigDescription} cannot override bundled rule id: ${rule.id}`,
			);
		}
	}

	return [...baseRules, ...repoRules];
}

function loadRules(repoRoot) {
	const bundledConfig = readRulesConfigFile(
		new URL("./deny-rules.json", import.meta.url),
	);
	const repoConfig = readRulesConfigFile(
		path.join(repoRoot, ".github", "pre-tool-use-rules.json"),
		{ optional: true },
	);
	const repoConfigPath = path.join(
		repoRoot,
		".github",
		"pre-tool-use-rules.json",
	);

	return mergeRules(
		bundledConfig.rules,
		repoConfig?.rules ?? [],
		repoConfigPath,
	).map((rule) => ({
		...rule,
		match: {
			...rule.match,
			subcommand: rule.match.subcommand.toLowerCase(),
			allOfArgs: rule.match.allOfArgs ?? [],
			anyOfArgs: rule.match.anyOfArgs ?? [],
		},
	}));
}

function tokenizeShellCommand(command) {
	const tokens = [];
	let current = "";
	let quote = null;

	for (let index = 0; index < command.length; index += 1) {
		const char = command[index];

		if (quote === "'") {
			if (char === "'") {
				quote = null;
				continue;
			}

			current += char;
			continue;
		}

		if (quote === '"') {
			if (char === '"') {
				quote = null;
				continue;
			}

			if (char === "\\") {
				const nextChar = command[index + 1];
				if (nextChar !== undefined) {
					current += nextChar;
					index += 1;
					continue;
				}
			}

			current += char;
			continue;
		}

		if (char === "'" || char === '"') {
			quote = char;
			continue;
		}

		if (char === "\\") {
			const nextChar = command[index + 1];
			if (nextChar !== undefined) {
				current += nextChar;
				index += 1;
				continue;
			}
		}

		if (char === "\n") {
			if (current !== "") {
				tokens.push(current);
				current = "";
			}
			tokens.push(";");
			continue;
		}

		if (/\s/.test(char)) {
			if (current !== "") {
				tokens.push(current);
				current = "";
			}
			continue;
		}

		if (char === "&" || char === "|" || char === ";") {
			if (current !== "") {
				tokens.push(current);
				current = "";
			}

			const nextChar = command[index + 1];
			if ((char === "&" || char === "|") && nextChar === char) {
				tokens.push(`${char}${char}`);
				index += 1;
				continue;
			}

			tokens.push(char);
			continue;
		}

		current += char;
	}

	if (current !== "") {
		tokens.push(current);
	}

	return tokens;
}

function splitShellCommands(tokens) {
	const commands = [];
	let current = [];

	for (const token of tokens) {
		if (SHELL_COMMAND_SEPARATORS.has(token)) {
			if (current.length > 0) {
				commands.push(current);
				current = [];
			}
			continue;
		}

		current.push(token);
	}

	if (current.length > 0) {
		commands.push(current);
	}

	return commands;
}

function isEnvironmentAssignment(token) {
	return /^[A-Za-z_][A-Za-z0-9_]*=.*/.test(token);
}

function isGitCommand(token) {
	return token === "git" || token.endsWith("/git");
}

function resolveGitInvocation(commandTokens) {
	let index = 0;

	while (
		index < commandTokens.length &&
		isEnvironmentAssignment(commandTokens[index])
	) {
		index += 1;
	}

	if (commandTokens[index] === "env") {
		index += 1;
		while (index < commandTokens.length) {
			const token = commandTokens[index];
			if (token === "-i") {
				index += 1;
				continue;
			}
			if (token === "-u" || token === "--unset") {
				index += 2;
				continue;
			}
			if (token === "-C" || token === "--chdir") {
				index += 2;
				continue;
			}
			if (isEnvironmentAssignment(token)) {
				index += 1;
				continue;
			}
			break;
		}
	}

	if (!isGitCommand(commandTokens[index] ?? "")) {
		return null;
	}

	return commandTokens.slice(index);
}

function extractGitSubcommand(gitTokens) {
	let index = 1;

	while (index < gitTokens.length) {
		const token = gitTokens[index];
		if (token === "--") {
			index += 1;
			break;
		}

		if (!token.startsWith("-")) {
			break;
		}

		if (
			GIT_OPTIONS_WITH_VALUE.has(token) ||
			token === "--literal-pathspecs-from-file"
		) {
			index += 2;
			continue;
		}

		if (
			token.startsWith("--config-env=") ||
			token.startsWith("--exec-path=") ||
			token.startsWith("--git-dir=") ||
			token.startsWith("--namespace=") ||
			token.startsWith("--super-prefix=") ||
			token.startsWith("--work-tree=")
		) {
			index += 1;
			continue;
		}

		index += 1;
	}

	const subcommand = gitTokens[index] ?? null;
	if (subcommand === null) {
		return null;
	}
	const normalizedSubcommand = subcommand.toLowerCase();

	return {
		subcommand: normalizedSubcommand,
		args: normalizeGitArgs(normalizedSubcommand, gitTokens.slice(index + 1)),
	};
}

function normalizeGitArgs(subcommand, args) {
	const optionSpec = GIT_SUBCOMMAND_OPTIONS_WITH_VALUE.get(subcommand) ?? {
		short: new Set(),
		long: new Set(),
	};
	const normalizedArgs = [];

	for (let index = 0; index < args.length; index += 1) {
		const token = args[index];
		if (token === "--") {
			break;
		}

		if (token === "-" || !token.startsWith("-")) {
			continue;
		}

		if (token.startsWith("--")) {
			const equalsIndex = token.indexOf("=");
			const optionName =
				equalsIndex === -1 ? token : token.slice(0, equalsIndex);
			normalizedArgs.push(optionName);
			if (equalsIndex === -1 && optionSpec.long.has(optionName)) {
				index += 1;
			}
			continue;
		}

		for (let shortIndex = 1; shortIndex < token.length; shortIndex += 1) {
			const optionName = `-${token[shortIndex]}`;
			normalizedArgs.push(optionName);
			if (optionSpec.short.has(optionName)) {
				if (shortIndex === token.length - 1) {
					index += 1;
				}
				break;
			}
		}
	}

	return normalizedArgs;
}

function argumentMatches(token, expected) {
	return token === expected;
}

function matchesGitRule(rule, command) {
	const shellCommands = splitShellCommands(tokenizeShellCommand(command));

	for (const commandTokens of shellCommands) {
		const gitTokens = resolveGitInvocation(commandTokens);
		if (gitTokens === null) {
			continue;
		}

		const parsedGitCommand = extractGitSubcommand(gitTokens);
		if (
			parsedGitCommand === null ||
			parsedGitCommand.subcommand !== rule.match.subcommand
		) {
			continue;
		}

		if (
			!rule.match.allOfArgs.every((expectedArg) =>
				parsedGitCommand.args.some((arg) => argumentMatches(arg, expectedArg)),
			)
		) {
			continue;
		}

		if (
			rule.match.anyOfArgs.length > 0 &&
			!rule.match.anyOfArgs.some((expectedArg) =>
				parsedGitCommand.args.some((arg) => argumentMatches(arg, expectedArg)),
			)
		) {
			continue;
		}

		return true;
	}

	return false;
}

function evaluateRules(rules, input) {
	const toolName = typeof input.toolName === "string" ? input.toolName : "";
	if (toolName === "") {
		return null;
	}

	const toolArgs = parseToolArgs(input.toolArgs);
	const command =
		toolArgs &&
		typeof toolArgs === "object" &&
		typeof toolArgs.command === "string"
			? toolArgs.command
			: null;

	for (const rule of rules) {
		if (!rule.toolNames.includes(toolName) || command === null) {
			continue;
		}

		if (rule.match.kind === "gitCli" && matchesGitRule(rule, command)) {
			return rule;
		}
	}

	return null;
}

async function main() {
	const input = parseHookInput(await readStdin());
	const cwd =
		typeof input.cwd === "string" && input.cwd !== ""
			? path.resolve(input.cwd)
			: process.cwd();
	const repoRoot = resolveRepoRoot(cwd);
	const matchedRule = evaluateRules(loadRules(repoRoot), input);

	if (matchedRule === null) {
		return;
	}

	process.stdout.write(
		JSON.stringify({
			permissionDecision: "deny",
			permissionDecisionReason: matchedRule.reason,
		}),
	);
}

main().catch((error) => {
	console.error(
		`control-plane preToolUse hook: ${error instanceof Error ? error.message : String(error)}`,
	);
	process.exitCode = 1;
});
