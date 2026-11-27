"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { buildStrategy } = require("release-please/build/src/factory");
const { parseConventionalCommits } = require("release-please/build/src/commit");
const { Version } = require("release-please/build/src/version");
const { TagName } = require("release-please/build/src/util/tag-name");
require("./strategy.cjs");
const root = path.resolve(__dirname, "../..");
const files = execFileSync("git", ["ls-files", "lib"], {
	cwd: root,
	encoding: "utf8",
})
	.trim()
	.split("\n")
	.filter((file) => file.endsWith(".pm"));
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const repo = {
	repository: { owner: "P4suta", repo: "Test-Mutation" },
	findFilesByGlobAndRef: async (pattern, ref) => {
		assert.equal(pattern, "lib/**/*.pm");
		assert.equal(ref, "main");
		return files;
	},
};
async function proposed(message, prior) {
	const strategy = await buildStrategy({
		github: repo,
		releaseType: "perl-distribution",
		targetBranch: "main",
		initialVersion: "0.1.0",
		includeComponentInTag: false,
	});
	const commits = parseConventionalCommits([
		{ message, sha: "1".repeat(40), files: ["lib/Test/Mutation.pm"] },
	]);
	const latest = prior && {
		tag: new TagName(Version.parse(prior)),
		sha: "2".repeat(40),
	};
	return strategy.buildReleasePullRequest(commits, latest);
}
test("bootstrap dates the authored Changes and includes all distributed modules", async () => {
	const proposal = await proposed("feat(release): publish Test-Mutation");
	assert.equal(proposal.version.toString(), "0.1.0");
	assert.equal(proposal.headRefName, "release-please--branches--main");
	assert.deepEqual(
		proposal.updates.map((u) => u.path).sort(),
		["Changes", ...files].sort(),
	);
	const ch = proposal.updates
		.find((u) => u.path === "Changes")
		.updater.updateContent(read("Changes"));
	assert.match(ch, /^0\.001 +\d{4}-\d{2}-\d{2}$/m);
	assert.equal(
		ch.replace(/^0\.001 +\d{4}-\d{2}-\d{2}$/m, "0.001"),
		read("Changes"),
	);
	for (const u of proposal.updates.filter((u) => u.path !== "Changes"))
		assert.equal(u.updater.updateContent(read(u.path)), read(u.path));
});
test("a fix after v0.1.0 advances every package and prepends a dated native entry", async () => {
	const proposal = await proposed("fix: compare an uncovered mutant", "0.1.0");
	assert.equal(proposal.version.toString(), "0.1.1");
	const changes = read("Changes").replace(/^0\.001$/m, "0.001  2026-01-01");
	for (const u of proposal.updates) {
		if (u.path === "Changes") {
			const newText = u.updater.updateContent(changes);
			assert.match(newText, /^0\.001001 +\d{4}-\d{2}-\d{2}\n/m);
			assert.match(newText, /^ {4}- .*compare an uncovered mutant/m);
			assert.ok(newText.endsWith(changes.slice(changes.indexOf("0.001  "))));
			assert.doesNotMatch(newText, /^#/m);
		} else {
			assert.match(
				u.updater.updateContent(read(u.path)),
				/^our \$VERSION = '0\.001001';$/m,
			);
			assert.throws(
				() => u.updater.updateContent("package Wrong; 1;\n"),
				/VERSION/,
			);
			assert.throws(
				() => u.updater.updateContent("our $VERSION = '9.000';\n"),
				/9.000/,
			);
		}
	}
});
test("feature and breaking releases follow upstream semantic versioning", async () => {
	assert.equal(
		(await proposed("feat: show misses", "0.1.0")).version.toString(),
		"0.2.0",
	);
	assert.equal(
		(await proposed("feat!: change the report", "0.1.0")).version.toString(),
		"1.0.0",
	);
});
