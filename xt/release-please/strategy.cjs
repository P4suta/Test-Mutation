"use strict";
const { registerReleaseType } = require("release-please");
const { BaseStrategy } = require("release-please/build/src/strategies/base");
const { perlVersion } = require("./version.cjs");

function moduleVersion(path, previous, next) {
	return {
		path,
		createIfMissing: true,
		updater: {
			updateContent(content) {
				const declaration = /^(our \$VERSION = ')([^']+)(';[ \t]*)$/gm;
				const matches = [...(content ?? "").matchAll(declaration)];
				if (matches.length !== 1 || matches[0][2] !== previous) {
					throw new Error(
						path +
							" must declare one $VERSION of " +
							previous +
							"; found " +
							matches.map((m) => m[2]).join(", "),
					);
				}
				return content.replace(
					declaration,
					(_line, prefix, _old, suffix) => prefix + next + suffix,
				);
			},
		},
	};
}

function nativeChanges(path, previous, next, date, notes) {
	return {
		path,
		createIfMissing: true,
		updater: {
			updateContent(content) {
				const heading =
					/^(0|[1-9]\d*)\.(\d+)(?:[ \t]+(\d{4}-\d{2}-\d{2}))?[ \t]*$/m;
				const current = heading.exec(content ?? "");
				if (!current) throw new Error(`${path} has no Perl release heading`);
				const version = `${current[1]}.${current[2]}`;
				if (!previous && version === next && !current[3]) {
					return content.replace(heading, `${next}  ${date}`);
				}
				if (!current[3] || version !== previous)
					throw new Error(
						`${path} does not begin with the previous release ${previous}`,
					);
				const lines = [];
				for (const part of notes.split("\n")) {
					const line = part.trim();
					if (!line || /^#{1,2}\s/.test(line)) continue;
					if (/^###\s/.test(line)) lines.push(`    [${line.slice(4)}]`);
					else if (/^[*-]\s/.test(line)) lines.push(`    - ${line.slice(2)}`);
					else lines.push(`      ${line}`);
				}
				if (!lines.some((line) => line.startsWith("    - ")))
					throw new Error("The release has no changes to record");
				return (
					content.slice(0, current.index) +
					next +
					"  " +
					date +
					"\n" +
					lines.join("\n") +
					"\n\n" +
					content.slice(current.index)
				);
			},
		},
	};
}

class PerlDistribution extends BaseStrategy {
	async buildUpdates({ newVersion, latestVersion, changelogEntry }) {
		const next = perlVersion(newVersion);
		const previous = latestVersion ? perlVersion(latestVersion) : undefined;
		const paths = await this.github.findFilesByGlobAndRef(
			"lib/**/*.pm",
			this.targetBranch,
		);
		if (!paths.includes("lib/Test/Mutation.pm"))
			throw new Error("Cannot find the distribution version source");
		const date = new Date().toISOString().slice(0, 10);
		return [
			nativeChanges("Changes", previous, next, date, changelogEntry),
			...paths.map((path) => moduleVersion(path, previous ?? next, next)),
		];
	}
}
registerReleaseType(
	"perl-distribution",
	(options) => new PerlDistribution(options),
);
