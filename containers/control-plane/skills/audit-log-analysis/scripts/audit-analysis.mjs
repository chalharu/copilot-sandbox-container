#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const SQLITE_BUSY_TIMEOUT_MS = 30_000;
const DEFAULT_MINIMUM_EVIDENCE_COUNT = 3;
const DEFAULT_REPEAT_THRESHOLD = 3;
const DEFAULT_LOOKBACK_EVENT_WINDOW = 200;
const MAX_PREVIEW_LENGTH = 140;
const EVENT_SCOPE_LOOKBACK = 6;
const ANALYSIS_CATEGORIES = new Set([
	"user-feedback",
	"error-resolution",
	"repeated-processing",
]);
const CANDIDATE_TYPES = new Set(["agent", "command", "skill"]);
const READINESS_ORDER = {
	create: 2,
	consider: 1,
};
const USER_FEEDBACK_CUES = [
	"again",
	"still",
	"retry",
	"repeated",
	"repeat",
	"not working",
	"doesn't work",
	"does not work",
	"broken",
	"failed",
	"failure",
	"error",
	"issue",
	"fix",
	"resolve",
	"regression",
	"wrong",
	"complaint",
	"complain",
	"指摘",
	"修正",
	"直して",
	"再度",
	"もう一度",
	"繰り返し",
	"エラー",
	"失敗",
	"不具合",
	"直らない",
	"再発",
	"改善",
];
const ERROR_RESULT_CUES = [
	"error",
	"failed",
	"failure",
	"traceback",
	"exception",
	"denied",
	"unsupported",
	"missing",
	"required",
	"invalid",
	"cannot",
	"can't",
	"not found",
	"timed out",
	"timeout",
	"エラー",
	"失敗",
	"例外",
	"拒否",
	"不足",
	"未設定",
	"無効",
	"見つから",
	"タイムアウト",
];
const WORD_REGEX =
	/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー]{2,}|[\p{Letter}\p{Number}][\p{Letter}\p{Number}._/-]{1,}/gu;
const STOPWORDS = new Set([
	"again",
	"still",
	"please",
	"error",
	"errors",
	"failed",
	"failure",
	"issue",
	"issues",
	"fix",
	"resolve",
	"retry",
	"repeated",
	"repeat",
	"wrong",
	"need",
	"with",
	"from",
	"that",
	"this",
	"into",
	"about",
	"after",
	"before",
	"while",
	"just",
	"have",
	"been",
	"please",
	"again,",
	"still,",
	"the",
	"and",
	"for",
	"audit",
	"指摘",
	"修正",
	"再度",
	"もう一度",
	"繰り返し",
	"エラー",
	"失敗",
	"不具合",
]);

function defaultAuditDbPath(homeDir) {
	return path.join(
		homeDir,
		".copilot",
		"session-state",
		"audit",
		"audit-log.db",
	);
}

function defaultAnalysisDbPath(homeDir) {
	return path.join(
		homeDir,
		".copilot",
		"session-state",
		"audit",
		"audit-analysis.db",
	);
}

function defaultConfigPath(homeDir) {
	return path.join(homeDir, ".copilot", "config.json");
}

function readJsonFile(filePath, { optional = false } = {}) {
	try {
		return JSON.parse(fs.readFileSync(filePath, "utf8"));
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

		throw error;
	}
}

function ensureDirectory(dirPath) {
	fs.mkdirSync(dirPath, { recursive: true, mode: 0o700 });
	fs.chmodSync(dirPath, 0o700);
}

function ensureRegularFileOrAbsent(filePath, description) {
	if (!fs.existsSync(filePath)) {
		return;
	}

	if (!fs.statSync(filePath).isFile()) {
		throw new Error(`${description} must be a regular file: ${filePath}`);
	}
}

function runSqlite(dbPath, sql) {
	const result = spawnSync(
		"sqlite3",
		["-cmd", `.timeout ${SQLITE_BUSY_TIMEOUT_MS}`, dbPath],
		{
			input: sql,
			encoding: "utf8",
			stdio: "pipe",
		},
	);

	if (result.error) {
		throw result.error;
	}

	if (result.status !== 0) {
		const output = (result.stderr || result.stdout || "").trim();
		throw new Error(
			`sqlite3 failed for ${dbPath}: ${output === "" ? `exit ${result.status}` : output}`,
		);
	}

	return result.stdout;
}

function queryJsonRows(dbPath, sql) {
	const output = runSqlite(dbPath, sql).trim();
	if (output === "") {
		return [];
	}

	return output
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line !== "")
		.map((line) => JSON.parse(line));
}

function querySingleValue(dbPath, sql) {
	return runSqlite(dbPath, sql).trim();
}

function sqlText(value) {
	if (value === null || value === undefined) {
		return "NULL";
	}

	return `'${String(value).replaceAll("'", "''")}'`;
}

function sqlInteger(value) {
	if (!Number.isSafeInteger(value)) {
		throw new Error(`Expected a safe integer, received: ${value}`);
	}

	return `${value}`;
}

function parseBoolean(value, label, fallbackValue) {
	if (value === undefined || value === null || value === "") {
		return fallbackValue;
	}

	if (typeof value === "boolean") {
		return value;
	}

	const normalized = String(value).trim().toLowerCase();
	if (["1", "true", "yes", "on"].includes(normalized)) {
		return true;
	}
	if (["0", "false", "no", "off"].includes(normalized)) {
		return false;
	}

	throw new Error(`${label} must be a boolean value: ${value}`);
}

function parsePositiveInteger(value, label, fallbackValue) {
	if (value === undefined || value === null || value === "") {
		return fallbackValue;
	}

	if (!/^[0-9]+$/.test(String(value))) {
		throw new Error(`${label} must be a positive integer: ${value}`);
	}

	const parsedValue = Number.parseInt(String(value), 10);
	if (!Number.isSafeInteger(parsedValue) || parsedValue <= 0) {
		throw new Error(`${label} must be a positive safe integer: ${value}`);
	}

	return parsedValue;
}

function resolveAbsolutePath(value, label) {
	if (!path.isAbsolute(value)) {
		throw new Error(`${label} must be an absolute path: ${value}`);
	}

	return value;
}

function previewText(value, maxLength = MAX_PREVIEW_LENGTH) {
	if (value === null || value === undefined) {
		return "";
	}

	const normalized = String(value).replace(/\s+/gu, " ").trim();
	if (normalized.length <= maxLength) {
		return normalized;
	}

	return `${normalized.slice(0, maxLength - 1)}…`;
}

function stableHash(value) {
	return crypto.createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function findMatchingCues(value, cues) {
	const normalized = String(value ?? "").toLowerCase();
	return cues.filter((cue) => normalized.includes(cue.toLowerCase()));
}

function tokenizeText(value) {
	return [...String(value ?? "").matchAll(WORD_REGEX)]
		.map((match) => match[0].toLowerCase())
		.filter((token) => !STOPWORDS.has(token));
}

function scopeKeyFromText(value, fallback = "general") {
	const tokens = [];
	const seenTokens = new Set();
	for (const token of tokenizeText(value)) {
		if (seenTokens.has(token)) {
			continue;
		}
		tokens.push(token);
		seenTokens.add(token);
		if (tokens.length === 4) {
			break;
		}
	}

	return tokens.length > 0 ? tokens.join("/") : fallback;
}

function normalizeToolArgsText(rawValue) {
	if (rawValue === null || rawValue === undefined || rawValue === "") {
		return "";
	}

	if (typeof rawValue !== "string") {
		return previewText(JSON.stringify(rawValue));
	}

	try {
		const parsed = JSON.parse(rawValue);
		return previewText(JSON.stringify(parsed));
	} catch {
		return previewText(rawValue);
	}
}

function normalizedToolArgsHash(rawValue) {
	return stableHash(normalizeToolArgsText(rawValue));
}

function haveMeaningfulTokenOverlap(
	leftValue,
	rightValue,
	minimumSharedTokens = 2,
) {
	const leftTokens = new Set(tokenizeText(leftValue));
	if (leftTokens.size === 0) {
		return false;
	}

	let sharedTokenCount = 0;
	for (const token of tokenizeText(rightValue)) {
		if (!leftTokens.has(token)) {
			continue;
		}
		sharedTokenCount += 1;
		if (sharedTokenCount >= minimumSharedTokens) {
			return true;
		}
	}

	return false;
}

function chooseRepositoryUrlFromRemotes(remotesJson) {
	if (!remotesJson) {
		return null;
	}

	try {
		const remotes = JSON.parse(remotesJson);
		if (!Array.isArray(remotes) || remotes.length === 0) {
			return null;
		}

		const originRemote = remotes.find(
			(remote) =>
				remote && typeof remote === "object" && remote.name === "origin",
		);
		if (
			originRemote &&
			typeof originRemote.url === "string" &&
			originRemote.url !== ""
		) {
			return originRemote.url;
		}

		const firstRemote = remotes.find(
			(remote) =>
				remote &&
				typeof remote === "object" &&
				typeof remote.url === "string" &&
				remote.url !== "",
		);
		return firstRemote?.url ?? null;
	} catch {
		return null;
	}
}

function resolveTargetRepositoryUrl(config) {
	if (config.targetRepositoryUrl) {
		return config.targetRepositoryUrl;
	}

	if (fs.existsSync(config.auditDbPath)) {
		const rows = queryJsonRows(
			config.auditDbPath,
			[
				"SELECT json_object('gitRemotesJson', git_remotes_json)",
				"FROM audit_events",
				"WHERE git_remotes_json IS NOT NULL",
				"ORDER BY id DESC",
				"LIMIT 10;",
			].join("\n"),
		);
		for (const row of rows) {
			const candidateUrl = chooseRepositoryUrlFromRemotes(row.gitRemotesJson);
			if (candidateUrl) {
				return candidateUrl;
			}
		}
	}

	const gitRemote = spawnSync("git", ["config", "--get", "remote.origin.url"], {
		cwd: process.cwd(),
		encoding: "utf8",
		stdio: "pipe",
	});
	if (!gitRemote.error && gitRemote.status === 0) {
		const url = gitRemote.stdout.trim();
		if (url !== "") {
			return url;
		}
	}

	return `self:${path.resolve(process.cwd())}`;
}

export function resolveAnalysisConfig(env = process.env) {
	const homeDir = env.HOME ?? "/home/copilot";
	const configPath = resolveAbsolutePath(
		env.CONTROL_PLANE_AUDIT_ANALYSIS_CONFIG_FILE ?? defaultConfigPath(homeDir),
		"CONTROL_PLANE_AUDIT_ANALYSIS_CONFIG_FILE",
	);
	const rawConfig = readJsonFile(configPath, { optional: true });
	if (
		rawConfig !== null &&
		(!rawConfig || typeof rawConfig !== "object" || Array.isArray(rawConfig))
	) {
		throw new Error(
			`Audit analysis config at ${configPath} must contain a top-level JSON object.`,
		);
	}

	const rawAuditAnalysisConfig = rawConfig?.controlPlane?.auditAnalysis;
	if (
		rawAuditAnalysisConfig !== undefined &&
		(!rawAuditAnalysisConfig ||
			typeof rawAuditAnalysisConfig !== "object" ||
			Array.isArray(rawAuditAnalysisConfig))
	) {
		throw new Error(
			`Audit analysis config at ${configPath} must define controlPlane.auditAnalysis as a JSON object.`,
		);
	}

	const targetRepositoryValue =
		env.CONTROL_PLANE_AUDIT_ANALYSIS_TARGET_REPOSITORY_URL ??
		(typeof rawAuditAnalysisConfig?.targetRepository === "string"
			? rawAuditAnalysisConfig.targetRepository
			: rawAuditAnalysisConfig?.targetRepository?.url);

	const minimumEvidenceCount = parsePositiveInteger(
		env.CONTROL_PLANE_AUDIT_ANALYSIS_MINIMUM_EVIDENCE_COUNT ??
			rawAuditAnalysisConfig?.minimumEvidenceCount,
		"CONTROL_PLANE_AUDIT_ANALYSIS_MINIMUM_EVIDENCE_COUNT",
		DEFAULT_MINIMUM_EVIDENCE_COUNT,
	);

	return {
		enabled: parseBoolean(
			env.CONTROL_PLANE_AUDIT_ANALYSIS_ENABLED ??
				rawAuditAnalysisConfig?.enabled,
			"CONTROL_PLANE_AUDIT_ANALYSIS_ENABLED",
			true,
		),
		configPath,
		auditDbPath: resolveAbsolutePath(
			env.CONTROL_PLANE_AUDIT_LOG_DB_PATH ??
				rawAuditAnalysisConfig?.auditLogDbPath ??
				defaultAuditDbPath(homeDir),
			"CONTROL_PLANE_AUDIT_LOG_DB_PATH",
		),
		analysisDbPath: resolveAbsolutePath(
			env.CONTROL_PLANE_AUDIT_ANALYSIS_DB_PATH ??
				rawAuditAnalysisConfig?.analysisDbPath ??
				defaultAnalysisDbPath(homeDir),
			"CONTROL_PLANE_AUDIT_ANALYSIS_DB_PATH",
		),
		minimumEvidenceCount,
		considerationThreshold: parsePositiveInteger(
			env.CONTROL_PLANE_AUDIT_ANALYSIS_CONSIDERATION_THRESHOLD ??
				rawAuditAnalysisConfig?.considerationThreshold,
			"CONTROL_PLANE_AUDIT_ANALYSIS_CONSIDERATION_THRESHOLD",
			Math.max(1, minimumEvidenceCount - 1),
		),
		repeatThreshold: parsePositiveInteger(
			env.CONTROL_PLANE_AUDIT_ANALYSIS_REPEAT_THRESHOLD ??
				rawAuditAnalysisConfig?.repeatThreshold,
			"CONTROL_PLANE_AUDIT_ANALYSIS_REPEAT_THRESHOLD",
			DEFAULT_REPEAT_THRESHOLD,
		),
		lookbackEventWindow: parsePositiveInteger(
			env.CONTROL_PLANE_AUDIT_ANALYSIS_LOOKBACK_EVENT_WINDOW ??
				rawAuditAnalysisConfig?.lookbackEventWindow,
			"CONTROL_PLANE_AUDIT_ANALYSIS_LOOKBACK_EVENT_WINDOW",
			DEFAULT_LOOKBACK_EVENT_WINDOW,
		),
		targetRepositoryUrl:
			typeof targetRepositoryValue === "string" &&
			targetRepositoryValue.trim() !== ""
				? targetRepositoryValue.trim()
				: null,
	};
}

export function ensureAnalysisDatabase(dbPath) {
	ensureDirectory(path.dirname(dbPath));
	ensureRegularFileOrAbsent(dbPath, "Audit analysis database path");
	runSqlite(
		dbPath,
		[
			"CREATE TABLE IF NOT EXISTS analysis_state (",
			"\tkey TEXT PRIMARY KEY,",
			"\tvalue TEXT NOT NULL",
			");",
			"CREATE TABLE IF NOT EXISTS analysis_runs (",
			"\tid INTEGER PRIMARY KEY AUTOINCREMENT,",
			"\tstarted_at_ms INTEGER NOT NULL,",
			"\tcompleted_at_ms INTEGER NOT NULL,",
			"\tprocessed_from_event_id INTEGER,",
			"\tprocessed_to_event_id INTEGER,",
			"\tprocessed_event_count INTEGER NOT NULL,",
			"\ttrigger_source TEXT NOT NULL,",
			"\ttarget_repository_url TEXT NOT NULL,",
			"\tcandidate_count INTEGER NOT NULL,",
			"\tsummary_json TEXT NOT NULL",
			");",
			"CREATE TABLE IF NOT EXISTS analysis_patterns (",
			"\tid INTEGER PRIMARY KEY AUTOINCREMENT,",
			"\tcategory TEXT NOT NULL CHECK (category IN ('user-feedback', 'error-resolution', 'repeated-processing')),",
			"\tscope_key TEXT NOT NULL,",
			"\tfingerprint TEXT NOT NULL,",
			"\tseverity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),",
			"\ttitle TEXT NOT NULL,",
			"\tdetail_json TEXT NOT NULL,",
			"\tfirst_seen_at_ms INTEGER NOT NULL,",
			"\tlast_seen_at_ms INTEGER NOT NULL,",
			"\tfirst_event_id INTEGER,",
			"\tlast_event_id INTEGER,",
			"\toccurrence_count INTEGER NOT NULL,",
			"\tUNIQUE(category, fingerprint)",
			");",
			"CREATE INDEX IF NOT EXISTS analysis_patterns_category_scope_idx ON analysis_patterns (category, scope_key, last_seen_at_ms);",
			"CREATE INDEX IF NOT EXISTS analysis_patterns_last_seen_idx ON analysis_patterns (last_seen_at_ms, id);",
			"CREATE TABLE IF NOT EXISTS automation_candidates (",
			"\tid INTEGER PRIMARY KEY AUTOINCREMENT,",
			"\tcandidate_type TEXT NOT NULL CHECK (candidate_type IN ('agent', 'command', 'skill')),",
			"\tscope_key TEXT NOT NULL,",
			"\ttarget_repository_url TEXT NOT NULL,",
			"\treadiness TEXT NOT NULL CHECK (readiness IN ('consider', 'create')),",
			"\toccurrence_count INTEGER NOT NULL,",
			"\tevidence_json TEXT NOT NULL,",
			"\trationale TEXT NOT NULL,",
			"\tcreated_at_ms INTEGER NOT NULL,",
			"\tupdated_at_ms INTEGER NOT NULL,",
			"\tUNIQUE(candidate_type, scope_key, target_repository_url)",
			");",
			"CREATE INDEX IF NOT EXISTS automation_candidates_readiness_idx ON automation_candidates (readiness, candidate_type, updated_at_ms);",
		].join("\n"),
	);
	fs.chmodSync(dbPath, 0o600);
}

function readStateInteger(dbPath, key) {
	const output = querySingleValue(
		dbPath,
		`SELECT value FROM analysis_state WHERE key = ${sqlText(key)} LIMIT 1;`,
	);
	if (output === "") {
		return null;
	}

	const value = Number.parseInt(output, 10);
	if (!Number.isSafeInteger(value)) {
		throw new Error(
			`Expected integer analysis state for ${key}, received: ${output}`,
		);
	}

	return value;
}

function writeState(dbPath, key, value) {
	runSqlite(
		dbPath,
		[
			"INSERT INTO analysis_state (key, value)",
			`VALUES (${sqlText(key)}, ${sqlText(String(value))})`,
			"ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
		].join("\n"),
	);
}

function readAuditEvents(auditDbPath, startEventId) {
	return queryJsonRows(
		auditDbPath,
		[
			"SELECT json_object(",
			"  'id', id,",
			"  'eventType', event_type,",
			"  'createdAtMs', created_at_ms,",
			"  'cwd', cwd,",
			"  'repoPath', repo_path,",
			"  'ppid', ppid,",
			"  'gitRemotesJson', git_remotes_json,",
			"  'userPrompt', user_prompt,",
			"  'toolName', tool_name,",
			"  'toolArgsJson', tool_args_json,",
			"  'toolResultType', tool_result_type,",
			"  'toolResultText', tool_result_text",
			")",
			"FROM audit_events",
			`WHERE id >= ${sqlInteger(startEventId)}`,
			"ORDER BY id ASC;",
		].join("\n"),
	);
}

function inferScopeKey(events, eventIndex, fallbackScope) {
	for (
		let index = eventIndex;
		index >= 0 && index >= eventIndex - EVENT_SCOPE_LOOKBACK;
		index -= 1
	) {
		const event = events[index];
		if (event.eventType === "userPromptSubmitted" && event.userPrompt) {
			const scopeKey = scopeKeyFromText(event.userPrompt, fallbackScope);
			if (scopeKey !== "general") {
				return scopeKey;
			}
		}
	}

	return fallbackScope;
}

function inferResolutionScopeKey(
	events,
	failureIndex,
	successIndex,
	fallbackScope,
) {
	if (successIndex !== -1) {
		for (let index = successIndex; index >= failureIndex; index -= 1) {
			const event = events[index];
			if (event.eventType === "userPromptSubmitted" && event.userPrompt) {
				return scopeKeyFromText(event.userPrompt, fallbackScope);
			}
		}
	}

	return inferScopeKey(events, failureIndex, fallbackScope);
}

function isToolFailure(event) {
	if (event.eventType !== "postToolUse") {
		return false;
	}

	const resultType = String(event.toolResultType ?? "")
		.trim()
		.toLowerCase();
	if (resultType !== "" && resultType !== "success") {
		return true;
	}

	return (
		findMatchingCues(event.toolResultText ?? "", ERROR_RESULT_CUES).length > 0
	);
}

function isToolSuccess(event) {
	if (event.eventType !== "postToolUse") {
		return false;
	}

	const resultType = String(event.toolResultType ?? "")
		.trim()
		.toLowerCase();
	if (resultType === "success") {
		return true;
	}

	if (resultType !== "") {
		return false;
	}

	return (
		findMatchingCues(event.toolResultText ?? "", ERROR_RESULT_CUES).length === 0
	);
}

function detectUserFeedbackPatterns(events) {
	const patterns = [];

	for (let index = 0; index < events.length; index += 1) {
		const event = events[index];
		if (event.eventType !== "userPromptSubmitted" || !event.userPrompt) {
			continue;
		}

		const matchedCues = findMatchingCues(event.userPrompt, USER_FEEDBACK_CUES);
		if (matchedCues.length === 0) {
			continue;
		}

		const scopeKey = scopeKeyFromText(event.userPrompt, "general");
		patterns.push({
			category: "user-feedback",
			scopeKey,
			fingerprint: `${event.id}`,
			severity:
				matchedCues.includes("again") || matchedCues.includes("still")
					? "critical"
					: "warning",
			title: `User prompt flagged unresolved work in ${scopeKey}`,
			detail: {
				promptExcerpt: previewText(event.userPrompt),
				matchedCues,
				toolNames: [],
			},
			firstEventId: event.id,
			lastEventId: event.id,
			firstSeenAtMs: event.createdAtMs,
			lastSeenAtMs: event.createdAtMs,
			occurrenceCount: 1,
		});
	}

	return patterns;
}

function classifyResolutionMethod(
	failureEvent,
	successEvent,
	interveningEvents,
) {
	if (!successEvent) {
		return "unresolved";
	}

	if (
		interveningEvents.some(
			(event) => event.eventType === "userPromptSubmitted" && event.userPrompt,
		)
	) {
		return "user-guided-correction";
	}

	if (successEvent.toolName === failureEvent.toolName) {
		if (
			normalizedToolArgsHash(successEvent.toolArgsJson) ===
			normalizedToolArgsHash(failureEvent.toolArgsJson)
		) {
			return "retry-same-tool";
		}

		return "adjusted-args";
	}

	return "switched-tool";
}

function areRelatedResolutionEvents(
	failureEvent,
	candidateEvent,
	interveningEvents,
) {
	const sameArgsHash =
		normalizedToolArgsHash(candidateEvent.toolArgsJson) ===
		normalizedToolArgsHash(failureEvent.toolArgsJson);
	if (sameArgsHash) {
		return true;
	}

	const hasInterveningPrompt = interveningEvents.some(
		(event) => event.eventType === "userPromptSubmitted" && event.userPrompt,
	);
	const overlappingArgs = haveMeaningfulTokenOverlap(
		normalizeToolArgsText(candidateEvent.toolArgsJson),
		normalizeToolArgsText(failureEvent.toolArgsJson),
		2,
	);

	if (candidateEvent.toolName === failureEvent.toolName) {
		return overlappingArgs || hasInterveningPrompt;
	}

	return overlappingArgs && hasInterveningPrompt;
}

function detectErrorResolutionPatterns(events) {
	const patterns = [];
	const lookaheadLimit = 12;

	for (let index = 0; index < events.length; index += 1) {
		const event = events[index];
		if (!isToolFailure(event)) {
			continue;
		}

		const fallbackScope = scopeKeyFromText(
			`${event.toolName ?? "tool"} ${event.toolResultText ?? ""}`,
			event.toolName ?? "general",
		);
		let successEvent = null;
		let successIndex = -1;

		for (
			let candidateIndex = index + 1;
			candidateIndex < events.length &&
			candidateIndex <= index + lookaheadLimit;
			candidateIndex += 1
		) {
			const candidateEvent = events[candidateIndex];
			const interveningCandidateEvents = events.slice(
				index + 1,
				candidateIndex,
			);
			if (
				isToolSuccess(candidateEvent) &&
				areRelatedResolutionEvents(
					event,
					candidateEvent,
					interveningCandidateEvents,
				)
			) {
				successEvent = candidateEvent;
				successIndex = candidateIndex;
				break;
			}
		}

		const interveningEvents =
			successIndex === -1 ? [] : events.slice(index + 1, successIndex);
		const resolutionMethod = classifyResolutionMethod(
			event,
			successEvent,
			interveningEvents,
		);
		const scopeKey = inferResolutionScopeKey(
			events,
			index,
			successIndex,
			fallbackScope,
		);

		patterns.push({
			category: "error-resolution",
			scopeKey,
			fingerprint: `${event.id}`,
			severity: resolutionMethod === "unresolved" ? "critical" : "warning",
			title:
				resolutionMethod === "unresolved"
					? `Unresolved tool failure observed in ${scopeKey}`
					: `Recovered tool failure observed in ${scopeKey}`,
			detail: {
				failureToolName: event.toolName ?? null,
				successToolName: successEvent?.toolName ?? null,
				toolNames: [event.toolName, successEvent?.toolName].filter(Boolean),
				failureResultType: event.toolResultType ?? null,
				failureExcerpt: previewText(
					event.toolResultText ?? event.toolArgsJson ?? "",
				),
				successExcerpt: previewText(
					successEvent?.toolResultText ?? successEvent?.toolArgsJson ?? "",
				),
				resolutionMethod,
			},
			firstEventId: event.id,
			lastEventId: successEvent?.id ?? event.id,
			firstSeenAtMs: event.createdAtMs,
			lastSeenAtMs: successEvent?.createdAtMs ?? event.createdAtMs,
			occurrenceCount: 1,
		});
	}

	return patterns;
}

function detectRepeatedProcessingPatterns(events, config) {
	const preToolEvents = events
		.map((event, index) => ({ ...event, analysisIndex: index }))
		.filter((event) => event.eventType === "preToolUse" && event.toolName);
	const patterns = [];

	for (let index = 0; index < preToolEvents.length; index += 1) {
		const startEvent = preToolEvents[index];
		const scopeKey = inferScopeKey(
			events,
			startEvent.analysisIndex,
			startEvent.toolName ?? "general",
		);
		const argsHash = normalizedToolArgsHash(startEvent.toolArgsJson);
		let endEvent = startEvent;
		let count = 1;

		while (index + count < preToolEvents.length) {
			const candidateEvent = preToolEvents[index + count];
			const candidateScope = inferScopeKey(
				events,
				candidateEvent.analysisIndex,
				candidateEvent.toolName ?? scopeKey,
			);
			if (
				candidateEvent.toolName !== startEvent.toolName ||
				normalizedToolArgsHash(candidateEvent.toolArgsJson) !== argsHash ||
				candidateScope !== scopeKey
			) {
				break;
			}
			endEvent = candidateEvent;
			count += 1;
		}

		if (count >= config.repeatThreshold) {
			patterns.push({
				category: "repeated-processing",
				scopeKey,
				fingerprint: `${startEvent.id}`,
				severity: count >= config.repeatThreshold + 1 ? "critical" : "warning",
				title: `Repeated ${startEvent.toolName} processing observed in ${scopeKey}`,
				detail: {
					toolName: startEvent.toolName,
					toolNames: [startEvent.toolName],
					repeatedCount: count,
					argsPreview: normalizeToolArgsText(startEvent.toolArgsJson),
				},
				firstEventId: startEvent.id,
				lastEventId: endEvent.id,
				firstSeenAtMs: startEvent.createdAtMs,
				lastSeenAtMs: endEvent.createdAtMs,
				occurrenceCount: count,
			});
		}

		index += count - 1;
	}

	return patterns;
}

function collectPatterns(events, config) {
	return [
		...detectUserFeedbackPatterns(events),
		...detectErrorResolutionPatterns(events),
		...detectRepeatedProcessingPatterns(events, config),
	];
}

function upsertPatterns(dbPath, patterns) {
	for (const pattern of patterns) {
		if (!ANALYSIS_CATEGORIES.has(pattern.category)) {
			throw new Error(`Unsupported analysis category: ${pattern.category}`);
		}

		runSqlite(
			dbPath,
			[
				"INSERT INTO analysis_patterns (",
				"  category, scope_key, fingerprint, severity, title, detail_json,",
				"  first_seen_at_ms, last_seen_at_ms, first_event_id, last_event_id, occurrence_count",
				") VALUES (",
				`  ${sqlText(pattern.category)}, ${sqlText(pattern.scopeKey)}, ${sqlText(pattern.fingerprint)}, ${sqlText(pattern.severity)}, ${sqlText(pattern.title)}, ${sqlText(JSON.stringify(pattern.detail))},`,
				`  ${sqlInteger(pattern.firstSeenAtMs)}, ${sqlInteger(pattern.lastSeenAtMs)}, ${sqlInteger(pattern.firstEventId)}, ${sqlInteger(pattern.lastEventId)}, ${sqlInteger(pattern.occurrenceCount)}`,
				")",
				"ON CONFLICT(category, fingerprint) DO UPDATE SET",
				"  scope_key = excluded.scope_key,",
				"  severity = excluded.severity,",
				"  title = excluded.title,",
				"  detail_json = excluded.detail_json,",
				"  first_seen_at_ms = MIN(analysis_patterns.first_seen_at_ms, excluded.first_seen_at_ms),",
				"  last_seen_at_ms = MAX(analysis_patterns.last_seen_at_ms, excluded.last_seen_at_ms),",
				"  first_event_id = MIN(analysis_patterns.first_event_id, excluded.first_event_id),",
				"  last_event_id = MAX(analysis_patterns.last_event_id, excluded.last_event_id),",
				"  occurrence_count = MAX(analysis_patterns.occurrence_count, excluded.occurrence_count);",
			].join("\n"),
		);
	}
}

function readAllPatterns(dbPath) {
	return queryJsonRows(
		dbPath,
		[
			"SELECT json_object(",
			"  'id', id,",
			"  'category', category,",
			"  'scopeKey', scope_key,",
			"  'fingerprint', fingerprint,",
			"  'severity', severity,",
			"  'title', title,",
			"  'detail', json(detail_json),",
			"  'firstSeenAtMs', first_seen_at_ms,",
			"  'lastSeenAtMs', last_seen_at_ms,",
			"  'firstEventId', first_event_id,",
			"  'lastEventId', last_event_id,",
			"  'occurrenceCount', occurrence_count",
			")",
			"FROM analysis_patterns",
			"ORDER BY last_seen_at_ms DESC, id DESC;",
		].join("\n"),
	);
}

function deriveAutomationCandidates(
	patterns,
	config,
	targetRepositoryUrl,
	nowMs,
) {
	const groups = new Map();

	for (const pattern of patterns) {
		const scopeKey = pattern.scopeKey || "general";
		if (!groups.has(scopeKey)) {
			groups.set(scopeKey, {
				scopeKey,
				totalEvidence: 0,
				categoryCounts: {
					"user-feedback": 0,
					"error-resolution": 0,
					"repeated-processing": 0,
				},
				categoryKinds: new Set(),
				repeatedPatterns: [],
				toolNames: new Set(),
				patterns: [],
			});
		}

		const group = groups.get(scopeKey);
		group.totalEvidence += pattern.occurrenceCount;
		group.categoryCounts[pattern.category] += pattern.occurrenceCount;
		group.categoryKinds.add(pattern.category);
		for (const toolName of pattern.detail?.toolNames ?? []) {
			group.toolNames.add(toolName);
		}
		group.patterns.push(pattern);
		if (pattern.category === "repeated-processing") {
			group.repeatedPatterns.push(pattern);
		}
	}

	const candidates = [];
	const readinessFor = (evidenceCount) => {
		if (evidenceCount >= config.minimumEvidenceCount) {
			return "create";
		}
		if (evidenceCount >= config.considerationThreshold) {
			return "consider";
		}
		return null;
	};

	for (const group of groups.values()) {
		const repeatedPattern = [...group.repeatedPatterns].sort(
			(left, right) => right.occurrenceCount - left.occurrenceCount,
		)[0];

		if (repeatedPattern) {
			const readiness = readinessFor(repeatedPattern.occurrenceCount);
			if (readiness) {
				candidates.push({
					candidateType: "command",
					scopeKey: group.scopeKey,
					targetRepositoryUrl,
					readiness,
					occurrenceCount: repeatedPattern.occurrenceCount,
					rationale: `${repeatedPattern.detail?.toolName ?? "tool"} repeated the same input ${repeatedPattern.occurrenceCount} times under ${group.scopeKey}, so a command wrapper would remove manual repetition.`,
					evidence: {
						primaryPatternId: repeatedPattern.id,
						categoryCounts: group.categoryCounts,
						toolNames: [...group.toolNames],
						patternIds: [repeatedPattern.id],
					},
					createdAtMs: nowMs,
					updatedAtMs: nowMs,
				});
			}
		}

		const skillReadiness = readinessFor(group.totalEvidence);
		if (
			skillReadiness &&
			group.categoryKinds.size >= 2 &&
			group.categoryCounts["error-resolution"] >= 1 &&
			group.categoryCounts["repeated-processing"] >= 1
		) {
			candidates.push({
				candidateType: "skill",
				scopeKey: group.scopeKey,
				targetRepositoryUrl,
				readiness: skillReadiness,
				occurrenceCount: group.totalEvidence,
				rationale: `${group.scopeKey} now has recurring failures, recoveries, and repeated processing, which suggests a reusable multi-step skill rather than ad-hoc manual fixes.`,
				evidence: {
					categoryCounts: group.categoryCounts,
					toolNames: [...group.toolNames],
					patternIds: group.patterns.map((pattern) => pattern.id),
				},
				createdAtMs: nowMs,
				updatedAtMs: nowMs,
			});
		}

		const agentEvidence =
			group.categoryCounts["user-feedback"] +
			group.categoryCounts["error-resolution"] +
			Math.min(group.categoryCounts["repeated-processing"], 2);
		const agentReadiness = readinessFor(agentEvidence);
		if (
			agentReadiness &&
			group.categoryCounts["user-feedback"] >= 1 &&
			group.categoryKinds.size >= 2 &&
			group.toolNames.size >= 2
		) {
			candidates.push({
				candidateType: "agent",
				scopeKey: group.scopeKey,
				targetRepositoryUrl,
				readiness: agentReadiness,
				occurrenceCount: agentEvidence,
				rationale: `${group.scopeKey} mixes repeated user feedback with multiple tools (${[...group.toolNames].join(", ")}), so a dedicated agent could own the investigation loop end-to-end.`,
				evidence: {
					categoryCounts: group.categoryCounts,
					toolNames: [...group.toolNames],
					patternIds: group.patterns.map((pattern) => pattern.id),
				},
				createdAtMs: nowMs,
				updatedAtMs: nowMs,
			});
		}
	}

	return candidates.sort((left, right) => {
		const readinessDelta =
			READINESS_ORDER[right.readiness] - READINESS_ORDER[left.readiness];
		if (readinessDelta !== 0) {
			return readinessDelta;
		}
		if (left.candidateType !== right.candidateType) {
			return left.candidateType.localeCompare(right.candidateType);
		}
		return right.occurrenceCount - left.occurrenceCount;
	});
}

function replaceAutomationCandidates(dbPath, candidates) {
	runSqlite(dbPath, "DELETE FROM automation_candidates;");

	for (const candidate of candidates) {
		if (!CANDIDATE_TYPES.has(candidate.candidateType)) {
			throw new Error(`Unsupported candidate type: ${candidate.candidateType}`);
		}

		runSqlite(
			dbPath,
			[
				"INSERT INTO automation_candidates (",
				"  candidate_type, scope_key, target_repository_url, readiness, occurrence_count,",
				"  evidence_json, rationale, created_at_ms, updated_at_ms",
				") VALUES (",
				`  ${sqlText(candidate.candidateType)}, ${sqlText(candidate.scopeKey)}, ${sqlText(candidate.targetRepositoryUrl)}, ${sqlText(candidate.readiness)}, ${sqlInteger(candidate.occurrenceCount)},`,
				`  ${sqlText(JSON.stringify(candidate.evidence))}, ${sqlText(candidate.rationale)}, ${sqlInteger(candidate.createdAtMs)}, ${sqlInteger(candidate.updatedAtMs)}`,
				");",
			].join("\n"),
		);
	}
}

function readCandidates(dbPath) {
	return queryJsonRows(
		dbPath,
		[
			"SELECT json_object(",
			"  'id', id,",
			"  'candidateType', candidate_type,",
			"  'scopeKey', scope_key,",
			"  'targetRepositoryUrl', target_repository_url,",
			"  'readiness', readiness,",
			"  'occurrenceCount', occurrence_count,",
			"  'evidence', json(evidence_json),",
			"  'rationale', rationale,",
			"  'createdAtMs', created_at_ms,",
			"  'updatedAtMs', updated_at_ms",
			")",
			"FROM automation_candidates",
			"ORDER BY CASE readiness WHEN 'create' THEN 0 ELSE 1 END, occurrence_count DESC, candidate_type ASC;",
		].join("\n"),
	);
}

function insertAnalysisRun(
	dbPath,
	{
		startedAtMs,
		completedAtMs,
		processedFromEventId,
		processedToEventId,
		processedEventCount,
		triggerSource,
		targetRepositoryUrl,
		candidateCount,
		summaryJson,
	},
) {
	runSqlite(
		dbPath,
		[
			"INSERT INTO analysis_runs (",
			"  started_at_ms, completed_at_ms, processed_from_event_id, processed_to_event_id,",
			"  processed_event_count, trigger_source, target_repository_url, candidate_count, summary_json",
			") VALUES (",
			`  ${sqlInteger(startedAtMs)}, ${sqlInteger(completedAtMs)}, ${processedFromEventId === null ? "NULL" : sqlInteger(processedFromEventId)}, ${processedToEventId === null ? "NULL" : sqlInteger(processedToEventId)},`,
			`  ${sqlInteger(processedEventCount)}, ${sqlText(triggerSource)}, ${sqlText(targetRepositoryUrl)}, ${sqlInteger(candidateCount)}, ${sqlText(JSON.stringify(summaryJson))}`,
			");",
		].join("\n"),
	);
}

function readLastRun(dbPath) {
	return (
		queryJsonRows(
			dbPath,
			[
				"SELECT json_object(",
				"  'id', id,",
				"  'startedAtMs', started_at_ms,",
				"  'completedAtMs', completed_at_ms,",
				"  'processedFromEventId', processed_from_event_id,",
				"  'processedToEventId', processed_to_event_id,",
				"  'processedEventCount', processed_event_count,",
				"  'triggerSource', trigger_source,",
				"  'targetRepositoryUrl', target_repository_url,",
				"  'candidateCount', candidate_count,",
				"  'summary', json(summary_json)",
				")",
				"FROM analysis_runs",
				"ORDER BY id DESC",
				"LIMIT 1;",
			].join("\n"),
		)[0] ?? null
	);
}

function summarizePatterns(patterns) {
	const patternCounts = {
		"user-feedback": 0,
		"error-resolution": 0,
		"repeated-processing": 0,
	};
	const patternEvidenceCounts = {
		"user-feedback": 0,
		"error-resolution": 0,
		"repeated-processing": 0,
	};

	for (const pattern of patterns) {
		patternCounts[pattern.category] += 1;
		patternEvidenceCounts[pattern.category] += pattern.occurrenceCount;
	}

	return {
		patternCounts,
		patternEvidenceCounts,
	};
}

export function buildStatus(config) {
	const targetRepositoryUrl = resolveTargetRepositoryUrl(config);
	if (!fs.existsSync(config.analysisDbPath)) {
		return {
			config: {
				...config,
				targetRepositoryUrl,
			},
			lastRun: null,
			patternCounts: {
				"user-feedback": 0,
				"error-resolution": 0,
				"repeated-processing": 0,
			},
			patternEvidenceCounts: {
				"user-feedback": 0,
				"error-resolution": 0,
				"repeated-processing": 0,
			},
			patterns: [],
			candidates: [],
		};
	}

	const patterns = readAllPatterns(config.analysisDbPath);
	const { patternCounts, patternEvidenceCounts } = summarizePatterns(patterns);
	return {
		config: {
			...config,
			targetRepositoryUrl,
		},
		lastRun: readLastRun(config.analysisDbPath),
		patternCounts,
		patternEvidenceCounts,
		patterns: patterns.slice(0, 10),
		candidates: readCandidates(config.analysisDbPath),
	};
}

export function refreshAnalysis({
	env = process.env,
	triggerSource = "manual",
} = {}) {
	const startedAtMs = Date.now();
	const config = resolveAnalysisConfig(env);
	const targetRepositoryUrl = resolveTargetRepositoryUrl(config);
	ensureAnalysisDatabase(config.analysisDbPath);

	if (!config.enabled || !fs.existsSync(config.auditDbPath)) {
		insertAnalysisRun(config.analysisDbPath, {
			startedAtMs,
			completedAtMs: Date.now(),
			processedFromEventId: null,
			processedToEventId: null,
			processedEventCount: 0,
			triggerSource,
			targetRepositoryUrl,
			candidateCount: 0,
			summaryJson: {
				enabled: config.enabled,
				auditDbPresent: fs.existsSync(config.auditDbPath),
			},
		});
		return buildStatus(config);
	}

	const maxEventIdOutput = querySingleValue(
		config.auditDbPath,
		"SELECT COALESCE(MAX(id), 0) FROM audit_events;",
	);
	const maxEventId = Number.parseInt(maxEventIdOutput || "0", 10);
	if (!Number.isSafeInteger(maxEventId) || maxEventId < 0) {
		throw new Error(`Invalid max audit event id: ${maxEventIdOutput}`);
	}

	const lastProcessedEventId = readStateInteger(
		config.analysisDbPath,
		"last_processed_event_id",
	);
	const startEventId =
		maxEventId === 0
			? 1
			: Math.max(1, maxEventId - config.lookbackEventWindow + 1);
	const auditEvents =
		maxEventId === 0 ? [] : readAuditEvents(config.auditDbPath, startEventId);
	const detectedPatterns = collectPatterns(auditEvents, config);
	upsertPatterns(config.analysisDbPath, detectedPatterns);

	const persistedPatterns = readAllPatterns(config.analysisDbPath);
	const candidates = deriveAutomationCandidates(
		persistedPatterns,
		config,
		targetRepositoryUrl,
		Date.now(),
	);
	replaceAutomationCandidates(config.analysisDbPath, candidates);
	writeState(config.analysisDbPath, "last_processed_event_id", maxEventId);
	writeState(
		config.analysisDbPath,
		"target_repository_url",
		targetRepositoryUrl,
	);

	const summaryJson = {
		detectedPatternCount: detectedPatterns.length,
		persistedPatternCount: persistedPatterns.length,
		candidateCount: candidates.length,
		lastProcessedEventId,
		maxEventId,
	};
	insertAnalysisRun(config.analysisDbPath, {
		startedAtMs,
		completedAtMs: Date.now(),
		processedFromEventId: lastProcessedEventId,
		processedToEventId: maxEventId,
		processedEventCount:
			maxEventId === 0
				? 0
				: Math.max(0, maxEventId - (lastProcessedEventId ?? 0)),
		triggerSource,
		targetRepositoryUrl,
		candidateCount: candidates.length,
		summaryJson,
	});

	return buildStatus(config);
}

function formatTextStatus(status) {
	const lines = [];
	lines.push("# Audit analysis status");
	lines.push(`Target repository: ${status.config.targetRepositoryUrl}`);
	lines.push(
		`Patterns: feedback=${status.patternCounts["user-feedback"]}, errors=${status.patternCounts["error-resolution"]}, repeated=${status.patternCounts["repeated-processing"]}`,
	);
	if (status.candidates.length === 0) {
		lines.push("Candidates: none ready for consideration yet");
	} else {
		lines.push("Candidates:");
		for (const candidate of status.candidates) {
			lines.push(
				`- ${candidate.readiness.toUpperCase()} ${candidate.candidateType} (${candidate.scopeKey}, evidence=${candidate.occurrenceCount})`,
			);
		}
	}
	return lines.join("\n");
}

function parseCliArgs(argv) {
	const options = {
		command: "status",
		format: "text",
		quiet: false,
		refreshBeforeStatus: true,
		triggerSource: "manual",
	};

	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		switch (arg) {
			case "refresh":
				options.command = "refresh";
				break;
			case "status":
				options.command = "status";
				break;
			case "--json":
				options.format = "json";
				break;
			case "--quiet":
				options.quiet = true;
				break;
			case "--no-refresh":
				options.refreshBeforeStatus = false;
				break;
			case "--trigger-source":
				index += 1;
				if (index >= argv.length) {
					throw new Error("--trigger-source requires a value");
				}
				options.triggerSource = argv[index];
				break;
			case "--help":
			case "-h":
				options.command = "help";
				break;
			default:
				throw new Error(`Unknown argument: ${arg}`);
		}
	}

	return options;
}

function printUsage() {
	process.stdout.write(
		[
			"Usage:",
			"  node audit-analysis.mjs status [--json] [--no-refresh]",
			"  node audit-analysis.mjs refresh [--json] [--quiet] [--trigger-source <name>]",
		].join("\n"),
	);
}

export function runCli(argv = process.argv.slice(2), env = process.env) {
	const options = parseCliArgs(argv);
	if (options.command === "help") {
		printUsage();
		return null;
	}

	let status;
	if (options.command === "refresh") {
		status = refreshAnalysis({ env, triggerSource: options.triggerSource });
	} else {
		const config = resolveAnalysisConfig(env);
		status = options.refreshBeforeStatus
			? refreshAnalysis({ env, triggerSource: options.triggerSource })
			: buildStatus(config);
	}

	if (!options.quiet) {
		process.stdout.write(
			options.format === "json"
				? `${JSON.stringify(status, null, 2)}\n`
				: `${formatTextStatus(status)}\n`,
		);
	}

	return status;
}

const invokedAsMain =
	process.argv[1] !== undefined &&
	import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (invokedAsMain) {
	try {
		runCli();
	} catch (error) {
		console.error(
			`control-plane audit analysis: ${error instanceof Error ? error.message : String(error)}`,
		);
		process.exit(1);
	}
}
