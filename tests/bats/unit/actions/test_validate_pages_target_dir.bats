#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-pages-target-dir.sh (#754)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-pages-target-dir.sh"

@test "validate-pages-target-dir: accepts the workflow default" {
	run env PAGES_TARGET_DIR="playwright" bash "$SCRIPT"

	assert_success
	assert_output --partial "Pages target dir: playwright"
}

# Unlike artifact-prefix, this value is not glob-matched, so the hyphen carries
# no meaning here and a nested path is a legitimate site layout.
@test "validate-pages-target-dir: accepts hyphens, dots and nested paths" {
	local target
	for target in e2e-nightly playwright_2 pw.smoke reports/e2e/nightly .; do
		run env PAGES_TARGET_DIR="$target" bash "$SCRIPT"
		assert_success
	done
}

@test "validate-pages-target-dir: rejects an absolute path" {
	run env PAGES_TARGET_DIR="/etc/playwright" bash "$SCRIPT"

	assert_failure
	assert_output --partial "pages-target-dir must be a relative path"
}

# A bare leading slash is the same escape as a full absolute path: the value is
# appended to the staged site root, so it must never start the path over.
@test "validate-pages-target-dir: rejects a leading slash" {
	run env PAGES_TARGET_DIR="/playwright" bash "$SCRIPT"

	assert_failure
	assert_output --partial "pages-target-dir must be a relative path"
}

@test "validate-pages-target-dir: rejects traversal segments" {
	local target
	for target in ".." "../playwright" "reports/../../playwright" "playwright/.."; do
		run env PAGES_TARGET_DIR="$target" bash "$SCRIPT"
		assert_failure
		assert_output --partial "must not contain '..' segments"
	done
}

# Traversal is rejected segment-wise, so a name that merely contains two dots is
# not collateral damage.
@test "validate-pages-target-dir: a dotted name is not mistaken for traversal" {
	run env PAGES_TARGET_DIR="pw..smoke" bash "$SCRIPT"

	assert_success
}

@test "validate-pages-target-dir: rejects shell, glob and separator metacharacters" {
	local target
	for target in 'pw*' 'pw?' 'pw report' 'pw;rm' '$PWD' 'pw\report' '~/playwright'; do
		run env PAGES_TARGET_DIR="$target" bash "$SCRIPT"
		assert_failure
		assert_output --partial "pages-target-dir must match"
	done
}

@test "validate-pages-target-dir: rejects an empty value" {
	run env PAGES_TARGET_DIR="" bash "$SCRIPT"

	assert_failure
	assert_output --partial "pages-target-dir must not be empty"
}

@test "validate-pages-target-dir: rejects an unset value" {
	run env -u PAGES_TARGET_DIR bash "$SCRIPT"

	assert_failure
	assert_output --partial "pages-target-dir must not be empty"
}
