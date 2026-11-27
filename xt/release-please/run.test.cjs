"use strict";
const assert = require("node:assert/strict");
const { test } = require("node:test");
const { prepare, githubService } = require("./run.cjs");
const good = "a".repeat(40);
test("an ordinary push and a manual request on main only prepare proposals", async () => {
	let proposals = 0,
		releases = 0;
	const manifest = {
		createPullRequests: async () => {
			proposals++;
		},
		buildReleases: async () => {
			releases++;
		},
	};
	for (const kind of ["push", "workflow_dispatch"]) {
		assert.equal(
			await prepare(
				{ name: kind, ref: "refs/heads/main", source: good },
				manifest,
			),
			undefined,
		);
	}
	assert.equal(proposals, 2);
	assert.equal(releases, 0);
	for (const ref of ["refs/heads/work", "refs/tags/v0.1.0"]) {
		await assert.rejects(
			prepare({ name: "workflow_dispatch", ref, source: good }, manifest),
			/main/,
		);
	}
	await assert.rejects(
		prepare(
			{ name: "schedule", ref: "refs/heads/main", source: good },
			manifest,
		),
		/event/,
	);
	assert.equal(proposals, 2);
});
test("the GitHub adapter reads exact parent and candidate manifests, release pages, and lightweight tags", async () => {
	const old = "b".repeat(40);
	const files = [];
	const data = {
		id: 9,
		tag_name: "v0.1.1",
		draft: true,
		target_commitish: good,
		prerelease: false,
	};
	const octokit = {
		repos: {
			getCommit: async ({ ref }) => {
				assert.equal(ref, good);
				return { data: { parents: [{ sha: old }] } };
			},
			listReleases: () => {},
			getRelease: async ({ release_id }) => {
				assert.equal(release_id, 9);
				return { data };
			},
		},
		git: {
			getRef: async ({ ref }) => {
				assert.equal(ref, "tags/v0.1.1");
				return { data: { object: { type: "commit", sha: good } } };
			},
		},
		paginate: {
			async *iterator() {
				yield { data: [{ id: 7, tag_name: "v0.1.0" }] };
				yield { data: [data] };
			},
		},
	};
	const api = {
		repository: { owner: "home", repo: "distribution" },
		getGitHubApi: () => ({ octokit }),
		getFileJson: async (file, ref) => {
			files.push([file, ref]);
			return { ".": ref === old ? "0.1.0" : "0.1.1" };
		},
		createRelease: async (c, opt) => {
			assert.deepEqual(opt, { draft: true, forceTag: true });
			assert.equal(c.sha, good);
			return { id: 9 };
		},
	};
	const svc = githubService(api, { buildReleases: async () => [] });
	assert.deepEqual(await svc.versions(good), ["0.1.0", "0.1.1"]);
	assert.deepEqual(
		files.map((f) => f[0]),
		[".release-please-manifest.json", ".release-please-manifest.json"],
	);
	assert.equal(await svc.tagSha("v0.1.1"), good);
	assert.equal(await svc.findRelease("v0.1.1"), data);
	assert.equal(await svc.create({ sha: good }), data);
	octokit.git.getRef = async () => {
		throw Object.assign(new Error("missing"), { status: 404 });
	};
	assert.equal(await svc.tagSha("v0.1.1"), undefined);
	octokit.git.getRef = async () => {
		throw Object.assign(new Error("denied"), { status: 403 });
	};
	await assert.rejects(svc.tagSha("v0.1.1"), /denied/);
});
