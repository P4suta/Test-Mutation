"use strict";
const { Version } = require("release-please/build/src/version");
const { perlVersion } = require("./version.cjs");

async function draftForMerge({ pull, repository, slug, source }, service) {
	if (
		!pull?.merged ||
		pull.state !== "closed" ||
		pull.base?.ref !== "main" ||
		pull.head?.ref !== "release-please--branches--main" ||
		pull.head?.repo?.full_name !== repository ||
		pull.base?.repo?.full_name !== repository ||
		!slug ||
		pull.user?.type !== "Bot" ||
		pull.user.login !== `${slug}[bot]`
	)
		return;
	if (
		!Number.isSafeInteger(pull.user.id) ||
		pull.user.id !== (await service.botId(slug))
	)
		return;
	if (!/^[a-f0-9]{40}$/.test(source) || pull.merge_commit_sha !== source)
		throw new Error("Release source must equal the merge commit");
	const [before, next] = await service.versions(source);
	const version = perlVersion(next);
	if (Version.parse(next).compare(Version.parse(before)) <= 0)
		throw new Error("The merged proposal did not advance the manifest version");
	const tag = `v${next}`;
	const held = await service.tagSha(tag);
	if (held !== undefined && held !== source)
		throw new Error("The existing tag points to another commit");
	let release = await service.findRelease(tag);
	if (!release) {
		const matches = (await service.candidates()).filter(
			(item) =>
				item.path === "." &&
				item.pullRequest.number === pull.number &&
				item.sha === source &&
				String(item.tag) === tag &&
				item.draft === true &&
				item.forceTag === true,
		);
		if (matches.length !== 1)
			throw new Error(
				"Expected one release-please candidate for the merged proposal",
			);
		release = await service.create(matches[0]);
	}
	if ((await service.tagSha(tag)) !== source)
		throw new Error("The release tag does not identify the proposal merge");
	if (
		!release ||
		!Number.isSafeInteger(release.id) ||
		release.id <= 0 ||
		release.tag_name !== tag ||
		release.target_commitish !== source ||
		release.prerelease !== false ||
		typeof release.draft !== "boolean"
	)
		throw new Error(
			"The GitHub draft does not match the intended release source",
		);
	if (!release.draft) return;
	await service.tagged(pull.number);
	return { source_sha: source, tag, release_id: String(release.id), version };
}
module.exports = { draftForMerge };
