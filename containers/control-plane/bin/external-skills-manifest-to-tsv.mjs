import process from "node:process";

const manifestPath = process.argv[2] ?? "<manifest>";

function fail(message) {
	process.stderr.write(`${manifestPath}: ${message}\n`);
	process.exit(1);
}

async function readStdin() {
	let input = "";

	for await (const chunk of process.stdin) {
		input += chunk;
	}

	return input;
}

const input = await readStdin();
let manifest;

try {
	manifest = JSON.parse(input);
} catch (error) {
	fail(`failed to parse js-yaml output as JSON: ${error.message}`);
}

if (!Array.isArray(manifest)) {
	fail("manifest root must be an array");
}

for (const [entryIndex, entry] of manifest.entries()) {
	const entryLabel = `entry ${entryIndex + 1}`;

	if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
		fail(`${entryLabel} must be an object`);
	}

	if (typeof entry.repository !== "string" || entry.repository.trim() === "") {
		fail(`${entryLabel} is missing repository`);
	}

	if (typeof entry.ref !== "string" || entry.ref.trim() === "") {
		fail(`${entryLabel} is missing ref`);
	}

	if (!Array.isArray(entry.skills) || entry.skills.length === 0) {
		fail(`${entryLabel} must define a non-empty skills array`);
	}

	for (const [skillIndex, skillPath] of entry.skills.entries()) {
		if (typeof skillPath !== "string" || skillPath.trim() === "") {
			fail(`${entryLabel} skill ${skillIndex + 1} must be a non-empty string`);
		}

		process.stdout.write(
			`${entry.repository.trim()}\t${entry.ref.trim()}\t${skillPath.trim()}\n`,
		);
	}
}
