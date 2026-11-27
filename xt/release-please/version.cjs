"use strict";

function perlVersion(version) {
	const parts = /^(0|[1-9]\d*)\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(
		String(version),
	);
	if (!parts)
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
