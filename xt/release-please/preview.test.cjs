"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { preview } = require("./preview.cjs");
test("previews the upstream proposal from committed inputs without changing the checkout", async (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "release-proposal-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	let timestamp = 1_700_000_000;
	const git = (...args) =>
		execFileSync(
			"git",
			[
				"-c",
				"user.name=Release test",
				"-c",
				"user.email=release@example.invalid",
				"-c",
				"commit.gpgsign=false",
				"-c",
				"core.hooksPath=/dev/null",
				...args,
			],
			{
				cwd: root,
				encoding: "utf8",
				env: { ...process.env, GIT_COMMITTER_DATE: `${timestamp++} +0000` },
			},
		);
	const write = (name, contents) =>
		fs.writeFileSync(path.join(root, name), contents);
	git("init", "--quiet", "--initial-branch=main");
	git("commit", "--allow-empty", "-m", "chore: start the distribution");
	const config = JSON.parse(
		fs.readFileSync(
			path.resolve(__dirname, "../../release-please-config.json"),
		),
	);
	config["bootstrap-sha"] = git("rev-parse", "HEAD").trim();
	write("release-please-config.json", JSON.stringify(config));
	write(".release-please-manifest.json", JSON.stringify({ ".": "0.0.0" }));
	fs.mkdirSync(path.join(root, "lib/Test"), { recursive: true });
	write(
		"lib/Test/Mutation.pm",
		"package Test::Mutation;\nour $VERSION = '0.001';\n1;\n",
	);
	write(
		"Changes",
		"Revision history for Test-Mutation\n\n0.001\n    - Measure Perl.\n",
	);
	git("add", ".");
	git("commit", "-m", "feat: measure Perl");
	write("Changes", "Local edits are not release inputs.\n");
	const initial = await preview(root);
	assert.equal(initial.tag, "v0.1.0");
	assert.equal(initial.version, "0.001");
	assert.equal(initial.packages, 1);
	assert.deepEqual(Object.keys(initial.files).sort(), [
		".release-please-manifest.json",
		"Changes",
	]);
	assert.equal(
		JSON.parse(initial.files[".release-please-manifest.json"])["."],
		"0.1.0",
	);
	assert.match(initial.files.Changes, /^0\.001 +\d{4}-\d{2}-\d{2}$/m);
	assert.equal(
		fs.readFileSync(path.join(root, "Changes"), "utf8"),
		"Local edits are not release inputs.\n",
	);
	for (const [name, contents] of Object.entries(initial.files))
		write(name, contents);
	git("commit", "-am", "chore(main): release 0.1.0");
	git("tag", "--no-sign", "v0.1.0");
	assert.equal(await preview(root), null);
	git("commit", "--allow-empty", "-m", "fix: retain covered mutants");
	const patch = await preview(root);
	assert.equal(patch.tag, "v0.1.1");
	assert.equal(patch.version, "0.001001");
	assert.match(
		patch.files["lib/Test/Mutation.pm"],
		/our \$VERSION = '0\.001001'/,
	);
	assert.match(patch.files.Changes, /retain covered mutants/);

	git("switch", "--quiet", "--create", "report");
	git("commit", "--allow-empty", "-m", "feat: report skipped mutants");
	git("switch", "--quiet", "main");
	git("merge", "--no-ff", "-m", "Merge branch 'report'", "report");
	const merged = await preview(root);
	assert.equal(merged.tag, "v0.2.0");
	assert.equal(merged.version, "0.002");
	assert.match(merged.files.Changes, /retain covered mutants/);
	assert.match(merged.files.Changes, /report skipped mutants/);
});
