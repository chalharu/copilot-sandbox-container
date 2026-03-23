#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import {
	getChangedFiles,
	getRepoRoot,
	listDirtyFiles,
	loadState,
	readStdin,
	resolveStateFilePath,
	runCommand,
	saveState,
	toRelativeRepoPath,
	writeResultOutput,
} from "./lib/incremental-files.mjs";

const STATE_SUBPATH = [".copilot-hooks", "post-tool-use-state.json"];

function describeConfigPath(configPath) {
	return configPath instanceof URL ? configPath.pathname : configPath;
}

function validateConfigEntries(entries, entryKind, configDescription) {
	const entryLabel = entryKind.slice(0, -1);
	const seenIds = new Set();

	if (!Array.isArray(entries)) {
		throw new Error(
			`Linters config at ${configDescription} must define ${entryKind} as an array.`,
		);
	}

	for (const entry of entries) {
		if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
			throw new Error(
				`Each ${entryLabel} in ${configDescription} must be a JSON object.`,
			);
		}

		if (typeof entry.id !== "string" || entry.id === "") {
			throw new Error(
				`Each ${entryLabel} in ${configDescription} must define a non-empty string id.`,
			);
		}

		if (seenIds.has(entry.id)) {
			throw new Error(
				`Duplicate ${entryLabel} id in ${configDescription}: ${entry.id}`,
			);
		}

		seenIds.add(entry.id);
	}
}

function readLintersConfigFile(configPath, { optional = false } = {}) {
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
			`Failed to read linters config at ${configDescription}: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	let parsed;
	try {
		parsed = JSON.parse(raw);
	} catch (error) {
		throw new Error(
			`Failed to parse linters config at ${configDescription}: ${error instanceof Error ? error.message : String(error)}`,
		);
	}

	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error(
			`Linters config at ${configDescription} must contain a top-level JSON object.`,
		);
	}

	if (parsed.tools !== undefined) {
		validateConfigEntries(parsed.tools, "tools", configDescription);
	}

	if (parsed.pipelines !== undefined) {
		validateConfigEntries(parsed.pipelines, "pipelines", configDescription);
	}

	return parsed;
}

function mergeConfigEntries(baseEntries, overrideEntries) {
	const mergedEntries = new Map();

	for (const entry of [...baseEntries, ...overrideEntries]) {
		mergedEntries.set(entry.id, entry);
	}

	return [...mergedEntries.values()];
}

function normalizeToolDefinitions(toolDefinitions) {
	const tools = new Map();

	for (const tool of toolDefinitions) {
		if (tool.args !== undefined && !Array.isArray(tool.args)) {
			throw new Error(`Tool "${tool.id}" args must be an array.`);
		}

		if (
			tool.appendFiles !== undefined &&
			typeof tool.appendFiles !== "boolean"
		) {
			throw new Error(`Tool "${tool.id}" appendFiles must be a boolean.`);
		}

		tools.set(tool.id, {
			...tool,
			args: tool.args ?? [],
			appendFiles: tool.appendFiles ?? true,
		});
	}

	return tools;
}

function normalizePipelineDefinitions(pipelineDefinitions, tools) {
	const pipelines = [];

	for (const pipeline of pipelineDefinitions) {
		if (!Array.isArray(pipeline.steps) || pipeline.steps.length === 0) {
			throw new Error(
				`Pipeline "${pipeline.id}" must define at least one step.`,
			);
		}

		for (const step of pipeline.steps) {
			if (!Array.isArray(step.tools) || step.tools.length === 0) {
				throw new Error(
					`Each step in pipeline "${pipeline.id}" must define at least one tool.`,
				);
			}

			for (const toolId of step.tools) {
				if (!tools.has(toolId)) {
					throw new Error(
						`Unknown tool referenced by pipeline "${pipeline.id}": ${toolId}`,
					);
				}
			}
		}

		pipelines.push({
			...pipeline,
			matcher: compileMatcher(pipeline.id, pipeline.matcher),
		});
	}

	return {
		pipelines,
	};
}

function loadLintersConfig(repoRoot) {
	const bundledConfig = readLintersConfigFile(
		new URL("./linters.json", import.meta.url),
	);
	const repoConfig = readLintersConfigFile(
		path.join(repoRoot, ".github", "linters.json"),
		{ optional: true },
	);
	const tools = normalizeToolDefinitions(
		mergeConfigEntries(bundledConfig.tools ?? [], repoConfig?.tools ?? []),
	);
	const { pipelines } = normalizePipelineDefinitions(
		mergeConfigEntries(
			bundledConfig.pipelines ?? [],
			repoConfig?.pipelines ?? [],
		),
		tools,
	);

	return {
		tools,
		pipelines,
	};
}

function compileMatcher(pipelineId, matcher) {
	if (!Array.isArray(matcher) || matcher.length === 0) {
		throw new Error(
			`Pipeline "${pipelineId}" must define matcher as a non-empty array.`,
		);
	}

	if (
		matcher.some((pattern) => typeof pattern !== "string" || pattern === "")
	) {
		throw new Error(
			`Pipeline "${pipelineId}" matcher entries must be non-empty regex strings.`,
		);
	}

	return new RegExp(matcher.map((pattern) => `(?:${pattern})`).join("|"));
}

function matchesPipeline(pipeline, relativePath) {
	return pipeline.matcher.test(relativePath);
}

function classifyFilesByPipeline(config, repoRoot, files) {
	const filesByPipeline = new Map(
		config.pipelines.map((pipeline) => [pipeline.id, []]),
	);
	const matchedFiles = [];

	for (const filePath of files) {
		const relativePath = toRelativeRepoPath(repoRoot, filePath);
		for (const pipeline of config.pipelines) {
			if (!matchesPipeline(pipeline, relativePath)) {
				continue;
			}

			filesByPipeline.get(pipeline.id).push(relativePath);
			matchedFiles.push(filePath);
			break;
		}
	}

	return { matchedFiles, filesByPipeline };
}

function getCurrentRelevantFiles(config, repoRoot) {
	return classifyFilesByPipeline(config, repoRoot, listDirtyFiles(repoRoot));
}

function resolveHookCacheRoot() {
	return (
		process.env.CONTROL_PLANE_HOOK_TMP_ROOT ??
		path.join(
			process.env.CONTROL_PLANE_TMP_ROOT ?? "/var/tmp/control-plane",
			"hooks",
		)
	);
}

function buildToolEnv() {
	const hookCacheRoot = resolveHookCacheRoot();
	const npmCache = path.join(hookCacheRoot, "npm-cache");
	const nodeCompileCache = path.join(hookCacheRoot, "node-compile-cache");

	fs.mkdirSync(hookCacheRoot, { recursive: true });
	fs.mkdirSync(npmCache, { recursive: true });
	fs.mkdirSync(nodeCompileCache, { recursive: true });

	return {
		...process.env,
		TMPDIR: process.env.TMPDIR ?? hookCacheRoot,
		NODE_COMPILE_CACHE: process.env.NODE_COMPILE_CACHE ?? nodeCompileCache,
		NPM_CONFIG_CACHE: process.env.NPM_CONFIG_CACHE ?? npmCache,
		npm_config_cache:
			process.env.npm_config_cache ?? process.env.NPM_CONFIG_CACHE ?? npmCache,
	};
}

function runStepWithFallback(config, repoRoot, toolIds, files) {
	const attempted = [];
	const toolEnv = buildToolEnv();

	for (const toolId of toolIds) {
		const tool = config.tools.get(toolId);
		const args = tool.appendFiles ? [...tool.args, ...files] : tool.args;
		const result = runCommand(tool.command, args, repoRoot, { env: toolEnv });

		if (!result.error) {
			return result;
		}

		if (result.error.code !== "ENOENT") {
			throw result.error;
		}

		attempted.push(`${toolId} (${tool.command})`);
	}

	return {
		status: 1,
		stdout: "",
		stderr: `No available tool found. Tried: ${attempted.join(", ")}\n`,
	};
}

function runPipelines(config, repoRoot, filesByPipeline) {
	let exitCode = 0;
	let hasReportedFailure = false;

	for (const pipeline of config.pipelines) {
		const files = filesByPipeline.get(pipeline.id) ?? [];
		if (files.length === 0) {
			continue;
		}

		for (const step of pipeline.steps) {
			const result = runStepWithFallback(config, repoRoot, step.tools, files);

			if ((result.status ?? 0) === 0 || !step.reportFailure) {
				continue;
			}

			if (step.failureLabel) {
				if (hasReportedFailure) {
					process.stderr.write("\n");
				}
				process.stderr.write(`${step.failureLabel}\n`);
			}

			writeResultOutput(result);
			exitCode = Math.max(exitCode, result.status ?? 1);
			hasReportedFailure = true;
		}
	}

	return exitCode;
}

async function main() {
	const rawInput = await readStdin();
	if (rawInput.trim() === "") {
		return;
	}

	const input = JSON.parse(rawInput);
	if (input.toolResult?.resultType === "denied") {
		return;
	}

	const cwd =
		typeof input.cwd === "string" && input.cwd !== ""
			? input.cwd
			: process.cwd();
	const repoRoot = getRepoRoot(cwd);
	const config = loadLintersConfig(repoRoot);
	const stateFilePath = resolveStateFilePath(repoRoot, STATE_SUBPATH);
	const previousSignatures = loadState(stateFilePath);
	const currentRelevantFiles = getCurrentRelevantFiles(config, repoRoot);
	const changedFiles = getChangedFiles(
		repoRoot,
		currentRelevantFiles.matchedFiles,
		previousSignatures,
	);

	if (changedFiles.length === 0) {
		saveState(stateFilePath, repoRoot, currentRelevantFiles.matchedFiles);
		return;
	}

	process.exitCode = runPipelines(
		config,
		repoRoot,
		classifyFilesByPipeline(config, repoRoot, changedFiles).filesByPipeline,
	);
	saveState(
		stateFilePath,
		repoRoot,
		getCurrentRelevantFiles(config, repoRoot).matchedFiles,
	);
}

main().catch((error) => {
	const message =
		error instanceof Error ? (error.stack ?? error.message) : String(error);
	console.error(message);
	process.exitCode = 1;
});
