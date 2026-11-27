"use strict";
const fs = require("node:fs");
const { GitHub, Manifest } = require("release-please");
const { draftForMerge } = require("./draft.cjs");
require("./strategy.cjs");

function githubService(github, manifest) {
	const { owner, repo } = github.repository;
	const octokit = github.getGitHubApi().octokit;
	return {
		async botId(slug) {
			const { data } = await octokit.users.getByUsername({
				username: `${slug}[bot]`,
			});
			if (
				data.type !== "Bot" ||
				data.login !== `${slug}[bot]` ||
				!Number.isSafeInteger(data.id)
			)
				throw new Error("Cannot identify the release preparation App bot");
			return data.id;
		},
		async versions(source) {
			const { data } = await octokit.repos.getCommit({
				owner,
				repo,
				ref: source,
				per_page: 1,
			});
			const manifests = await Promise.all(
				[data.parents[0].sha, source].map((ref) =>
					github.getFileJson(".release-please-manifest.json", ref),
				),
			);
			return manifests.map((values) => values["."]);
		},
		async tagSha(tag) {
			try {
				const { data } = await octokit.git.getRef({
					owner,
					repo,
					ref: `tags/${tag}`,
				});
				if (data.object.type !== "commit")
					throw new Error(
						"The proposed tag must point directly to a release commit",
					);
				return data.object.sha;
			} catch (e) {
				if (e.status === 404) return;
				throw e;
			}
		},
		async findRelease(tag) {
			let found;
			for await (const page of octokit.paginate.iterator(
				octokit.repos.listReleases,
				{ owner, repo, per_page: 100 },
			)) {
				for (const release of page.data) {
					if (release.tag_name !== tag) continue;
					if (found)
						throw new Error(`More than one GitHub release uses ${tag}`);
					found = release;
				}
			}
			return found;
		},
		candidates: () => manifest.buildReleases(),
		async create(candidate) {
			const release = await github.createRelease(candidate, {
				draft: true,
				forceTag: true,
			});
			return (
				await octokit.repos.getRelease({ owner, repo, release_id: release.id })
			).data;
		},
		async tagged(number) {
			const labels = await octokit.paginate(octokit.issues.listLabelsOnIssue, {
				owner,
				repo,
				issue_number: number,
				per_page: 100,
			});
			if (!labels.some((label) => label.name === "autorelease: tagged"))
				await github.addIssueLabels(["autorelease: tagged"], number);
			if (labels.some((label) => label.name === "autorelease: pending"))
				await github.removeIssueLabels(["autorelease: pending"], number);
		},
	};
}

async function prepare(event, manifest, service) {
	if (event.ref !== "refs/heads/main")
		throw new Error("Release preparation requires main");
	if (["push", "workflow_dispatch"].includes(event.name)) {
		await manifest.createPullRequests();
		return;
	}
	if (event.name !== "pull_request" || event.action !== "closed")
		throw new Error("Unexpected release workflow event");
	return draftForMerge(event, service);
}
async function main() {
	const env = process.env;
	const [owner, repo] = env.GITHUB_REPOSITORY.split("/");
	const github = await GitHub.create({ owner, repo, token: env.GH_TOKEN });
	const manifest = await Manifest.fromManifest(github, "main");
	const payload = JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, "utf8"));
	const output = await prepare(
		{
			name: env.GITHUB_EVENT_NAME,
			ref: env.GITHUB_REF,
			source: env.GITHUB_SHA,
			slug: env.RELEASE_APP_SLUG,
			repository: env.GITHUB_REPOSITORY,
			action: payload.action,
			pull: payload.pull_request,
		},
		manifest,
		githubService(github, manifest),
	);
	if (output)
		fs.appendFileSync(
			env.GITHUB_OUTPUT,
			Object.entries(output)
				.map(([name, value]) => `${name}=${value}\n`)
				.join(""),
		);
}
if (require.main === module)
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
module.exports = { prepare, githubService };
