"use strict";
const { execFileSync } = require("node:child_process");
const { Manifest, setLogger } = require("release-please");
const { CheckpointLogger } = require("release-please/build/src/util/logger");
const { perlVersion } = require("./version.cjs");
require("./strategy.cjs");

async function preview(root) {
	const git = (...args) =>
		execFileSync("git", args, { cwd: root, encoding: "utf8" });
	const head = git("rev-parse", "HEAD").trim();
	const read = (name) => git("show", `${head}:${name}`);
	const modules = git("ls-tree", "-r", "-z", "--name-only", head, "--", "lib")
		.split("\0")
		.filter((file) => file.endsWith(".pm"));
	const github = {
		repository: {
			owner: "P4suta",
			repo: "Test-Mutation",
			defaultBranch: "main",
		},
		getFileJson: async (name) => JSON.parse(read(name)),
		getFileContentsOnBranch: async (name) => ({ parsedContent: read(name) }),
		findFilesByGlobAndRef: async () => modules,
		releaseIterator: () => [],
		*tagIterator() {
			const tags = git(
				"for-each-ref",
				"--format=%(refname:strip=2)%00%(*objectname)%00%(objectname)",
				"refs/tags",
			).trimEnd();
			for (const line of tags.split("\n")) {
				if (!line) continue;
				const [name, peeled, object] = line.split("\0");
				yield { name, sha: peeled || object };
			}
		},
		*mergeCommitIterator(_branch, { maxResults }) {
			const fields = git(
				"log",
				"--first-parent",
				`--max-count=${maxResults}`,
				"--format=%H%x00%B%x00",
				head,
			).split("\0");
			for (let i = 0; i + 1 < fields.length; i += 2) {
				const sha = fields[i].trim();
				const files = git(
					"diff-tree",
					"--root",
					"--no-commit-id",
					"--name-only",
					"-r",
					"-z",
					sha,
				)
					.split("\0")
					.filter(Boolean);
				yield { sha, message: fields[i + 1], files };
			}
		},
	};
	const manifest = await Manifest.fromManifest(github, "main");
	const proposals = await manifest.buildPullRequests();
	if (proposals.length === 0) return null;
	if (proposals.length !== 1)
		throw new Error("Expected a single distribution proposal");
	const [proposal] = proposals;
	const files = {};
	for (const { path, updater } of proposal.updates) {
		const original = read(path);
		const next = updater.updateContent(original);
		if (next !== original) files[path] = next;
	}
	return {
		tag: `v${proposal.version}`,
		version: perlVersion(proposal.version),
		packages: modules.length,
		files,
	};
}
if (require.main === module) {
	const logger = new CheckpointLogger();
	logger.info = console.error;
	setLogger(logger);
	preview(process.cwd())
		.then((output) => console.log(JSON.stringify(output, null, 2)))
		.catch((error) => {
			console.error(error.message);
			process.exitCode = 1;
		});
}
module.exports = { preview };
