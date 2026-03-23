#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const SUPPORTED_EVENT_TYPES = new Set([
	"sessionStart",
	"userPromptSubmitted",
	"preToolUse",
	"postToolUse",
]);
const TOOL_EVENT_TYPES = new Set(["preToolUse", "postToolUse"]);
const DEFAULT_MAX_RECORDS = 10_000;
const DEFAULT_DB_PATH = path.join(
	process.env.HOME ?? "/home/copilot",
	".copilot",
	"session-state",
	"audit",
	"audit-log.db",
);
const SQLITE_BUSY_TIMEOUT_MS = 30_000;

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

function runCommand(command, args, cwd, options = {}) {
	return spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		stdio: "pipe",
		...options,
	});
}

function requireSupportedEventType(eventType) {
	if (!SUPPORTED_EVENT_TYPES.has(eventType)) {
		throw new Error(`Unsupported audit hook event: ${eventType}`);
	}
}

function parseHookInput(rawInput, eventType) {
	let parsed = {};

	if (rawInput.trim() !== "") {
		try {
			parsed = JSON.parse(rawInput);
		} catch (error) {
			throw new Error(
				`Failed to parse ${eventType} hook input JSON: ${error instanceof Error ? error.message : String(error)}`,
			);
		}
	}

	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error(`${eventType} hook input must be a top-level JSON object.`);
	}

	return parsed;
}

function resolveAuditLogDbPath() {
	const dbPath = process.env.CONTROL_PLANE_AUDIT_LOG_DB_PATH ?? DEFAULT_DB_PATH;
	if (!path.isAbsolute(dbPath)) {
		throw new Error(
			`CONTROL_PLANE_AUDIT_LOG_DB_PATH must be an absolute path: ${dbPath}`,
		);
	}

	return dbPath;
}

function resolveAuditLogMaxRecords() {
	const rawValue =
		process.env.CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS ?? `${DEFAULT_MAX_RECORDS}`;

	if (!/^[0-9]+$/.test(rawValue)) {
		throw new Error(
			`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive integer: ${rawValue}`,
		);
	}

	const value = Number.parseInt(rawValue, 10);
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new Error(
			`CONTROL_PLANE_AUDIT_LOG_MAX_RECORDS must be a positive safe integer: ${rawValue}`,
		);
	}

	return value;
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
			encoding: "utf8",
			input: sql,
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

function querySingleInteger(dbPath, sql) {
	const output = runSqlite(dbPath, sql).trim();
	if (output === "") {
		return null;
	}

	const value = Number.parseInt(output, 10);
	if (!Number.isSafeInteger(value)) {
		throw new Error(
			`Expected sqlite3 to return a safe integer, received: ${output}`,
		);
	}

	return value;
}

function tableHasColumn(dbPath, tableName, columnName) {
	const output = runSqlite(dbPath, `PRAGMA table_info(${tableName});`);
	return output
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line !== "")
		.some((line) => line.split("|")[1] === columnName);
}

function ensureDatabase(dbPath) {
	ensureDirectory(path.dirname(dbPath));
	ensureRegularFileOrAbsent(dbPath, "Audit log database path");
	runSqlite(
		dbPath,
		[
			"CREATE TABLE IF NOT EXISTS audit_events (",
			"\tid INTEGER PRIMARY KEY AUTOINCREMENT,",
			"\tevent_type TEXT NOT NULL CHECK (event_type IN ('sessionStart', 'userPromptSubmitted', 'preToolUse', 'postToolUse')),",
			"\tcreated_at_ms INTEGER NOT NULL,",
			"\tcwd TEXT NOT NULL,",
			"\trepo_path TEXT NOT NULL,",
			"\tppid INTEGER,",
			"\tgit_remotes_json TEXT,",
			"\tsession_source TEXT,",
			"\tinitial_prompt TEXT,",
			"\tuser_prompt TEXT,",
			"\ttool_name TEXT,",
			"\ttool_args_json TEXT,",
			"\ttool_result_type TEXT,",
			"\ttool_result_text TEXT",
			");",
			"CREATE INDEX IF NOT EXISTS audit_events_event_type_created_at_idx ON audit_events (event_type, created_at_ms);",
			"CREATE INDEX IF NOT EXISTS audit_events_created_at_idx ON audit_events (created_at_ms, id);",
		].join("\n"),
	);
	if (!tableHasColumn(dbPath, "audit_events", "ppid")) {
		runSqlite(dbPath, "ALTER TABLE audit_events ADD COLUMN ppid INTEGER;");
	}
	runSqlite(
		dbPath,
		"CREATE INDEX IF NOT EXISTS audit_events_ppid_created_at_idx ON audit_events (ppid, created_at_ms);",
	);
	fs.chmodSync(dbPath, 0o600);
}

function normalizeText(value) {
	if (value === undefined || value === null) {
		return null;
	}

	return String(value);
}

function normalizeTimestamp(value) {
	if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
		return value;
	}

	return Date.now();
}

function normalizeToolArgs(toolArgs) {
	if (toolArgs === undefined || toolArgs === null || toolArgs === "") {
		return null;
	}

	if (typeof toolArgs === "string") {
		return toolArgs;
	}

	return JSON.stringify(toolArgs);
}

function resolveRepoPath(cwd) {
	const result = runCommand("git", ["rev-parse", "--show-toplevel"], cwd);
	if (result.error) {
		throw result.error;
	}

	if (result.status !== 0) {
		return cwd;
	}

	const repoPath = result.stdout.trim();
	return repoPath === "" ? cwd : repoPath;
}

function resolveGitRemotes(repoPath) {
	const result = runCommand(
		"git",
		["config", "--get-regexp", "^remote\\..*\\.url$"],
		repoPath,
	);
	if (result.error) {
		throw result.error;
	}

	if (result.status !== 0) {
		return null;
	}

	const remotes = result.stdout
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line !== "")
		.map((line) => {
			const firstSpace = line.indexOf(" ");
			if (firstSpace === -1) {
				return null;
			}

			const key = line.slice(0, firstSpace);
			const url = line.slice(firstSpace + 1);
			const parts = key.split(".");
			if (parts.length !== 3 || parts[0] !== "remote" || parts[2] !== "url") {
				return null;
			}

			return {
				name: parts[1],
				url,
			};
		})
		.filter(Boolean);

	return remotes.length > 0 ? JSON.stringify(remotes) : null;
}

function sqlText(value) {
	if (value === null || value === undefined) {
		return "NULL";
	}

	return `'${String(value).replaceAll("'", "''")}'`;
}

function sqlInteger(value) {
	if (!Number.isSafeInteger(value)) {
		throw new Error(`Expected a safe integer value, received: ${value}`);
	}

	return `${value}`;
}

function sqlNullableInteger(value) {
	return value === null || value === undefined ? "NULL" : sqlInteger(value);
}

function buildAuditEvent(eventType, payload) {
	const cwd = path.resolve(normalizeText(payload.cwd) ?? process.cwd());
	const repoPath = resolveRepoPath(cwd);

	return {
		eventType,
		createdAtMs: normalizeTimestamp(payload.timestamp),
		cwd,
		repoPath,
		ppid: Number.isSafeInteger(process.ppid) ? process.ppid : null,
		gitRemotesJson: resolveGitRemotes(repoPath),
		sessionSource:
			eventType === "sessionStart" ? normalizeText(payload.source) : null,
		initialPrompt:
			eventType === "sessionStart"
				? normalizeText(payload.initialPrompt)
				: null,
		userPrompt:
			eventType === "userPromptSubmitted"
				? normalizeText(payload.prompt)
				: null,
		toolName: TOOL_EVENT_TYPES.has(eventType)
			? normalizeText(payload.toolName)
			: null,
		toolArgsJson: TOOL_EVENT_TYPES.has(eventType)
			? normalizeToolArgs(payload.toolArgs)
			: null,
		toolResultType:
			eventType === "postToolUse"
				? normalizeText(payload.toolResult?.resultType)
				: null,
		toolResultText:
			eventType === "postToolUse"
				? normalizeText(payload.toolResult?.textResultForLlm)
				: null,
	};
}

function buildPruneAuditSql(maxRecords, protectedId) {
	const retainedRecords = Math.max(1, maxRecords - Math.ceil(maxRecords / 4));
	return [
		"DELETE FROM audit_events",
		"WHERE id IN (",
		"\tSELECT id",
		"\tFROM audit_events",
		`\tWHERE id != ${sqlInteger(protectedId)}`,
		"\tORDER BY created_at_ms ASC, id ASC",
		"\tLIMIT (",
		"\t\tSELECT CASE",
		`\t\t\tWHEN COUNT(*) > ${sqlInteger(maxRecords)} THEN COUNT(*) - ${sqlInteger(retainedRecords)}`,
		"\t\t\tELSE 0",
		"\t\tEND",
		"\t\tFROM audit_events",
		"\t)",
		");",
	];
}

function insertAuditEvent(dbPath, event, maxRecords) {
	const insertedId = querySingleInteger(
		dbPath,
		[
			"INSERT INTO audit_events (",
			"\tevent_type,",
			"\tcreated_at_ms,",
			"\tcwd,",
			"\trepo_path,",
			"\tppid,",
			"\tgit_remotes_json,",
			"\tsession_source,",
			"\tinitial_prompt,",
			"\tuser_prompt,",
			"\ttool_name,",
			"\ttool_args_json,",
			"\ttool_result_type,",
			"\ttool_result_text",
			") VALUES (",
			`\t${sqlText(event.eventType)},`,
			`\t${sqlInteger(event.createdAtMs)},`,
			`\t${sqlText(event.cwd)},`,
			`\t${sqlText(event.repoPath)},`,
			`\t${sqlNullableInteger(event.ppid)},`,
			`\t${sqlText(event.gitRemotesJson)},`,
			`\t${sqlText(event.sessionSource)},`,
			`\t${sqlText(event.initialPrompt)},`,
			`\t${sqlText(event.userPrompt)},`,
			`\t${sqlText(event.toolName)},`,
			`\t${sqlText(event.toolArgsJson)},`,
			`\t${sqlText(event.toolResultType)},`,
			`\t${sqlText(event.toolResultText)}`,
			");",
			"SELECT last_insert_rowid();",
		].join("\n"),
	);
	fs.chmodSync(dbPath, 0o600);
	if (TOOL_EVENT_TYPES.has(event.eventType)) {
		runSqlite(dbPath, buildPruneAuditSql(maxRecords, insertedId).join("\n"));
		fs.chmodSync(dbPath, 0o600);
	}
}

async function main() {
	const eventType = process.argv[2] ?? "";
	requireSupportedEventType(eventType);

	const input = parseHookInput(await readStdin(), eventType);
	const dbPath = resolveAuditLogDbPath();
	const maxRecords = resolveAuditLogMaxRecords();

	ensureDatabase(dbPath);
	const event = buildAuditEvent(eventType, input);
	insertAuditEvent(dbPath, event, maxRecords);
}

main().catch((error) => {
	console.error(
		`control-plane audit hook: ${error instanceof Error ? error.message : String(error)}`,
	);
	process.exit(1);
});
