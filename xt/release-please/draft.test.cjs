"use strict";
const assert = require("node:assert/strict");
const { test } = require("node:test");
const { draftForMerge } = require("./draft.cjs");
const sha = "a".repeat(40),
	oldSha = "b".repeat(40),
	repository = "P4suta/Test-Mutation",
	slug = "release-please";
const pull = {
	number: 47,
	merged: true,
	state: "closed",
	merge_commit_sha: sha,
	user: { id: 1234, type: "Bot", login: `${slug}[bot]` },
	head: {
		ref: "release-please--branches--main",
		repo: { full_name: repository },
	},
	base: { ref: "main", repo: { full_name: repository } },
	labels: [{ name: "autorelease: pending" }],
};
function remote() {
	const remote = {
		tag: undefined,
		release: undefined,
		version: "0.1.0",
		before: "0.0.0",
		created: [],
		labels: 0,
		botId: async () => 1234,
		versions: async () => [remote.before, remote.version],
		tagSha: async () => remote.tag,
		findRelease: async () => remote.release,
		candidates: async () => [
			{
				path: ".",
				pullRequest: { number: 47 },
				sha,
				tag: { toString: () => "v0.1.0" },
				draft: true,
				forceTag: true,
			},
		],
		create: async (candidate) => {
			remote.created.push(candidate);
			remote.tag = sha;
			remote.release = {
				id: 5,
				author: { id: 1234, type: "Bot" },
				tag_name: "v0.1.0",
				draft: true,
				prerelease: false,
				target_commitish: sha,
			};
			return remote.release;
		},
		tagged: async () => {
			remote.labels++;
		},
	};
	return remote;
}
const run = (service, pr = pull, source = sha) =>
	draftForMerge({ pull: pr, repository, slug, source }, service);
test("only the merged same-repository preparation App proposal can create a draft", async () => {
	for (const pr of [
		undefined,
		{ ...pull, merged: false },
		{ ...pull, user: { ...pull.user, id: 9876 } },
		{ ...pull, head: { ...pull.head, ref: "feat/release" } },
		{ ...pull, user: { type: "User", login: "maintainer" } },
		{ ...pull, user: { type: "Bot", login: "another[bot]" } },
		{ ...pull, head: { ...pull.head, repo: { full_name: "fork/other" } } },
		{ ...pull, base: { ...pull.base, ref: "other" } },
	]) {
		const svc = remote();
		assert.equal(
			await draftForMerge({ pull: pr, repository, slug, source: sha }, svc),
			undefined,
		);
		assert.equal(svc.created.length, 0);
	}
	const svc = remote();
	const expected = {
		source_sha: sha,
		tag: "v0.1.0",
		release_id: "5",
		version: "0.001",
	};
	assert.deepEqual(await run(svc), expected);
	assert.equal(svc.created.length, 1);
	assert.deepEqual(await run(svc), expected);
	assert.equal(svc.created.length, 1);
	svc.release.draft = false;
	assert.equal(await run(svc), undefined);
	assert.equal(svc.created.length, 1);
});
test("rejects unrelated commits, releases, tags, versions and candidates before handing off", async () => {
	for (const [change, pattern] of [
		[
			(r) => {
				r.tag = oldSha;
			},
			/tag/,
		],
		[
			(r) => {
				r.before = r.version;
			},
			/version/,
		],
		[
			(r) => {
				r.before = "1.0.0";
			},
			/version/,
		],
		[
			(r) => {
				r.version = "0.1000.0";
			},
			/Perl/,
		],
		[
			(r) => {
				r.candidates = async () => [];
			},
			/candidate/,
		],
		[
			(r) => {
				r.release = {
					id: 7,
					draft: true,
					tag_name: "v0.1.0",
					target_commitish: oldSha,
				};
				r.tag = sha;
			},
			/draft|source/,
		],
		[
			(r) => {
				r.release = {
					id: 7,
					draft: true,
					tag_name: "v0.1.0",
					target_commitish: sha,
				};
			},
			/tag/,
		],
		[
			(r) => {
				const list = r.candidates;
				r.candidates = async () => [...(await list()), ...(await list())];
			},
			/candidate/,
		],
		[
			(r) => {
				r.candidates = async () => [
					{
						path: ".",
						pullRequest: { number: 48 },
						sha,
						tag: "v0.1.0",
						draft: true,
						forceTag: true,
					},
				];
			},
			/candidate/,
		],
	]) {
		const svc = remote();
		change(svc);
		await assert.rejects(run(svc), pattern);
		assert.equal(svc.created.length, 0);
	}
	await assert.rejects(run(remote(), pull, oldSha), /merge commit/);
});
test("checks the created draft and tag again after publication races", async () => {
	const svc = remote();
	const create = svc.create;
	svc.create = async (c) => {
		const draft = await create(c);
		svc.tag = oldSha;
		return draft;
	};
	await assert.rejects(run(svc), /tag/);
	assert.equal(svc.labels, 0);
});
test("refuses a matching draft created by another account", async () => {
	const svc = remote();
	await run(svc);
	svc.release.author = { id: 5678, type: "Bot" };
	await assert.rejects(run(svc), /author/);
	delete svc.release.author;
	await assert.rejects(run(svc), /author/);
	assert.equal(svc.labels, 1);
});
