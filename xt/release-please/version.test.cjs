"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { perlVersion } = require("./version.cjs");

test("maps stable tags to ordered Perl decimal versions", () => {
	for (const [version, expected] of [
		["0.1.0", "0.001"],
		["0.1.1", "0.001001"],
		["0.2.0", "0.002"],
		["1.0.0", "1.000"],
		["2.35.48", "2.035048"],
		["2.999.999", "2.999999"],
		["2147483647.0.0", "2147483647.000"],
	])
		assert.equal(perlVersion(version), expected);
	for (const version of [
		"0.1",
		"v0.1.0",
		"0.01.0",
		"1.1000.0",
		"1.0.1000",
		"2147483648.0.0",
		"1.0.0-rc.1",
		"1.0.0+build",
	]) {
		assert.throws(() => perlVersion(version), /Perl decimal version/);
	}
});
