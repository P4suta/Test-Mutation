"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { Manifest, configSchema, manifestSchema } = require("release-please");
const Ajv = require("ajv");
const addFormats = require("ajv-formats");
require("./strategy.cjs");
const root = path.resolve(__dirname, "../..");
const read = (name) =>
	JSON.parse(fs.readFileSync(path.join(root, name), "utf8"));

test("upstream accepts one stable Perl distribution with an initial version and a draft tag", async () => {
	const config = read("release-please-config.json");
	const versions = read(".release-please-manifest.json");
	const ajv = addFormats(new Ajv({ strict: false }));
	for (const [schema, file] of [
		[configSchema, config],
		[manifestSchema, versions],
	]) {
		const valid = ajv.validate(schema, file);
		assert.equal(valid, true, ajv.errorsText());
	}
	const api = {
		repository: { owner: "P4suta", repo: "Test-Mutation" },
		getFileJson: async (file) => read(file),
	};
	const parsed = await Manifest.fromManifest(api, "main");
	assert.deepEqual(Object.keys(parsed.repositoryConfig), ["."]);
	const unit = parsed.repositoryConfig["."];
	assert.equal(unit.releaseType, "perl-distribution");
	assert.equal(unit.initialVersion, "0.1.0");
	assert.equal(unit.includeComponentInTag, false);
	assert.equal(unit.draft, true);
	assert.equal(unit.forceTag, true);
	assert.match(versions["."], /^\d+\.\d+\.\d+$/);
	assert.match(config["bootstrap-sha"], /^[a-f0-9]{40}$/);
});

for (const published of ["0.0.0", "0.1.0"]) {
	test(`refreshes the open proposal from main with identical notes at manifest ${published}`, async () => {
		const base = read("release-please-config.json")["bootstrap-sha"];
		const added = "lib/Test/Mutation/Report.pm";
		const commits = [
			{
				sha: "1".repeat(40),
				message: "fix: show the report",
				files: ["lib/Test/Mutation.pm"],
			},
			{ sha: base, message: "chore: prepare the distribution", files: [] },
		];
		let open;
		let updatedPaths = [];
		const api = {
			repository: {
				owner: "P4suta",
				repo: "Test-Mutation",
				defaultBranch: "main",
			},
			getFileJson: (name) =>
				name === ".release-please-manifest.json"
					? { ".": published }
					: read(name),
			getFileContentsOnBranch: () => ({
				parsedContent: "0.001\n    - Measure Perl modules.\n",
			}),
			findFilesByGlobAndRef: () => commits.flatMap((commit) => commit.files),
			mergeCommitIterator: () => commits,
			releaseIterator: () =>
				published === "0.0.0" ? [] : [{ tagName: "v0.1.0", sha: base }],
			tagIterator: () => [],
			pullRequestIterator: (_branch, state) =>
				open && state === "OPEN" ? [open] : [],
			createPullRequest(proposal) {
				assert.equal(open, undefined);
				open = { ...proposal, number: 1 };
				return open;
			},
			updatePullRequest(number, proposal, branch) {
				assert.equal(number, open.number);
				assert.equal(branch, "main");
				assert.equal(proposal.headRefName, open.headBranchName);
				assert.equal(proposal.body.toString(), open.body);
				updatedPaths = proposal.updates.map((update) => update.path);
				return open;
			},
		};
		const prepare = async () =>
			(await Manifest.fromManifest(api, "main")).createPullRequests();
		await prepare();
		assert.ok(open);
		commits.unshift({
			sha: "2".repeat(40),
			message: "refactor: extract the report",
			files: [added],
		});
		await prepare();
		assert.ok(
			updatedPaths.includes(added),
			"the existing proposal includes the module added to main",
		);
	});
}
