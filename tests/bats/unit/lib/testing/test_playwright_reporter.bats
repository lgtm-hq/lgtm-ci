#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/playwright_reporter.sh (#1474):
#          the one reporter normalisation the run, parse and e2e setup share.

load "../../../../helpers/common"

setup() {
	source "${PROJECT_ROOT}/scripts/ci/lib/testing/playwright_reporter.sh"
}

@test "playwright_effective_reporter: supported reporters ignore case and whitespace" {
	local entry
	for entry in json:json html:html junit:junit JUnit:junit " HTML ":html "	Json	":json; do
		run playwright_effective_reporter "${entry%:*}"
		assert_success
		assert_output "${entry##*:}"
	done
}

# run-playwright.sh runs the JSON reporter for every other value, so these
# must parse as JSON and keep the merge's shard check.
@test "playwright_effective_reporter: every other value is the JSON the run executes" {
	local reporter
	for reporter in blob Blob list "html,junit" "junit,html" "junit, html"; do
		run playwright_effective_reporter "$reporter"
		assert_output "json"
	done
}

@test "playwright_effective_reporter: an empty value takes the default" {
	run playwright_effective_reporter ""
	assert_output "json"
	run playwright_effective_reporter "  " html
	assert_output "html"
}
