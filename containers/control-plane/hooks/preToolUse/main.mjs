#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import jsYaml from "js-yaml";

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
const SHELL_WRAPPER_OPTIONS_WITH_VALUE = new Set([
	"-O",
	"-o",
	"--init-file",
	"--rcfile",
]);
const SHELL_COMMAND_SEPARATORS = new Set(["&&", "||", ";", "|", "&"]);
const SHELL_WRAPPER_COMMANDS = new Set(["bash", "sh", "/bin/bash", "/bin/sh"]);
const MAX_COMMAND_UNWRAP_DEPTH = 4;

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

function normalizePatternEntry(
	entry,
	configDescription,
	groupIndex,
	patternIndex,
) {
	const patternDescription = `pattern ${patternIndex + 1} in group ${groupIndex + 1} of ${configDescription}`;
	if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
		throw new Error(`${patternDescription} must be a JSON object.`);
	}

	if (
		!Array.isArray(entry.patterns) ||
		entry.patterns.length === 0 ||
		entry.patterns.some(
			(pattern) => typeof pattern !== "string" || pattern === "",
		)
	) {
		throw new Error(
			`${patternDescription} must define patterns as a non-empty array of strings.`,
		);
	}

	if (typeof entry.reason !== "string" || entry.reason === "") {
		throw new Error(
			`${patternDescription} must define a non-empty string reason.`,
		);
	}

	return {
		reason: entry.reason,
		regexes: entry.patterns.map((pattern, regexIndex) => {
			try {
				return new RegExp(pattern);
			} catch (error) {
				throw new Error(
					`Invalid regex pattern ${regexIndex + 1} in ${patternDescription}: ${error instanceof Error ? error.message : String(error)}`,
				);
			}
		}),
	};
}

function normalizeRuleGroup(group, configDescription, groupIndex) {
	const groupDescription = `group ${groupIndex + 1} in ${configDescription}`;
	if (!group || typeof group !== "object" || Array.isArray(group)) {
		throw new Error(`${groupDescription} must be a JSON object.`);
	}

	if (typeof group.toolName !== "string" || group.toolName === "") {
		throw new Error(
			`${groupDescription} must define a non-empty string toolName.`,
		);
	}

	if (typeof group.column !== "string" || group.column === "") {
		throw new Error(
			`${groupDescription} must define a non-empty string column.`,
		);
	}

	if (!Array.isArray(group.patterns) || group.patterns.length === 0) {
		throw new Error(
			`${groupDescription} must define patterns as a non-empty array.`,
		);
	}

	return {
		toolName: group.toolName,
		column: group.column,
		patterns: group.patterns.map((entry, patternIndex) =>
			normalizePatternEntry(entry, configDescription, groupIndex, patternIndex),
		),
	};
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
		parsed = jsYaml.load(raw);
	} catch (error) {
		throw new Error(
			`Failed to parse preToolUse rules config at ${configDescription}: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	if (!Array.isArray(parsed)) {
		throw new Error(
			`preToolUse rules config at ${configDescription} must contain a top-level YAML array.`,
		);
	}

	return parsed.map((group, groupIndex) =>
		normalizeRuleGroup(group, configDescription, groupIndex),
	);
}

function loadRules(repoRoot) {
	const bundledGroups = readRulesConfigFile(
		new URL("./deny-rules.yaml", import.meta.url),
	);
	const repoGroups =
		readRulesConfigFile(
			path.join(repoRoot, ".github", "pre-tool-use-rules.yaml"),
			{ optional: true },
		) ?? [];

	return [...bundledGroups, ...repoGroups];
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

function stripInvocationPrefixes(commandTokens) {
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

	return commandTokens.slice(index);
}

function isShellWrapperCommand(token) {
	return (
		SHELL_WRAPPER_COMMANDS.has(token) ||
		token.endsWith("/bash") ||
		token.endsWith("/sh")
	);
}

function resolveGitInvocation(commandTokens) {
	const invocationTokens = stripInvocationPrefixes(commandTokens);
	if (!isGitCommand(invocationTokens[0] ?? "")) {
		return null;
	}

	return invocationTokens;
}

function extractShellCommandString(commandTokens) {
	const invocationTokens = stripInvocationPrefixes(commandTokens);
	if (!isShellWrapperCommand(invocationTokens[0] ?? "")) {
		return null;
	}

	for (let index = 1; index < invocationTokens.length; index += 1) {
		const token = invocationTokens[index];
		if (token === "--") {
			break;
		}

		if (token === "-c") {
			return invocationTokens[index + 1] ?? null;
		}

		if (token === "-" || !token.startsWith("-")) {
			break;
		}

		if (SHELL_WRAPPER_OPTIONS_WITH_VALUE.has(token)) {
			index += 1;
			continue;
		}

		if (
			token.startsWith("--init-file=") ||
			token.startsWith("--rcfile=") ||
			(token.startsWith("-O") && token.length > 2) ||
			(token.startsWith("-o") && token.length > 2)
		) {
			continue;
		}

		if (token.startsWith("--")) {
			continue;
		}

		if (token.slice(1).includes("c")) {
			return invocationTokens[index + 1] ?? null;
		}
	}

	return null;
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

function buildGitPatternCandidate(parsedGitCommand) {
	return ["git", parsedGitCommand.subcommand, ...parsedGitCommand.args].join(
		" ",
	);
}

function buildCommandCandidates(command, depth = 0) {
	if (depth > MAX_COMMAND_UNWRAP_DEPTH) {
		return [];
	}

	const candidates = [];
	for (const commandTokens of splitShellCommands(
		tokenizeShellCommand(command),
	)) {
		if (commandTokens.length === 0) {
			continue;
		}
		const gitTokens = resolveGitInvocation(commandTokens);
		if (gitTokens !== null) {
			const parsedGitCommand = extractGitSubcommand(gitTokens);
			if (parsedGitCommand !== null) {
				candidates.push(buildGitPatternCandidate(parsedGitCommand));
				continue;
			}
		}

		candidates.push(commandTokens.join(" "));
		const nestedCommand = extractShellCommandString(commandTokens);
		if (nestedCommand !== null && nestedCommand !== command) {
			candidates.push(...buildCommandCandidates(nestedCommand, depth + 1));
		}
	}

	return candidates;
}

function matchesPatternEntry(patternEntry, candidates) {
	return patternEntry.regexes.some((regex) =>
		candidates.some((candidate) => regex.test(candidate)),
	);
}

function evaluateRules(rules, input) {
	const toolName = typeof input.toolName === "string" ? input.toolName : "";
	if (toolName === "") {
		return null;
	}

	const toolArgs = parseToolArgs(input.toolArgs);
	for (const ruleGroup of rules) {
		if (ruleGroup.toolName !== toolName || toolArgs === null) {
			continue;
		}

		const value =
			typeof toolArgs[ruleGroup.column] === "string"
				? toolArgs[ruleGroup.column]
				: null;
		if (value === null) {
			continue;
		}

		const candidates =
			ruleGroup.column === "command" && toolName === "bash"
				? buildCommandCandidates(value)
				: [value];

		for (const patternEntry of ruleGroup.patterns) {
			if (matchesPatternEntry(patternEntry, candidates)) {
				return patternEntry;
			}
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
