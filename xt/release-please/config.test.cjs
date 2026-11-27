"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { Manifest, configSchema, manifestSchema } = require("release-please");
const Ajv = require("ajv");
const addFormats = require("ajv-formats");
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
