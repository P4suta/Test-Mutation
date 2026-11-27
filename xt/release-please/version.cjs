"use strict";

const maxPerlVersionComponent = 2_147_483_647;

function perlVersion(version) {
	const parts = /^(0|[1-9]\d*)\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(
		String(version),
	);
	if (!parts || Number(parts[1]) > maxPerlVersionComponent)
		throw new Error(
			`Cannot represent ${version} as a stable Perl decimal version`,
		);
	const [, major, minor, patch] = parts;
	return (
		major +
		"." +
		minor.padStart(3, "0") +
		(patch === "0" ? "" : patch.padStart(3, "0"))
	);
}

module.exports = { perlVersion };
