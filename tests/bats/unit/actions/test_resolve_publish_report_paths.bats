#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/resolve-publish-report-paths.sh (#770)
#
# The shared Pages publisher takes its path inputs relative to the downloaded
# artifact's root and resolves them against the extraction directory here. Two
# properties matter: '.' and the empty string must stay distinguishable, and a
# caller-supplied path must not be able to escape the artifact.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/resolve-publish-report-paths.sh"

setup() {
	OUTPUT_FILE="${BATS_TEST_TMPDIR}/github_output"
	: >"$OUTPUT_FILE"
}

_run_resolver() {
	run env DOWNLOAD_DIR=publish-input GITHUB_OUTPUT="$OUTPUT_FILE" "$@" \
		bash "$SCRIPT"
}

_output_value() {
	local key="$1"
	grep -E "^${key}=" "$OUTPUT_FILE" | head -1 | cut -d= -f2-
}

# The e2e-matrix migration: the merged report is the whole artifact.
@test "resolve-publish-report-paths: '.' resolves to the extraction directory" {
	_run_resolver RESULTS_PATH="."
	assert_success

	[ "$(_output_value results-path)" = "publish-input" ]
}

# The coverage migration at the repo root: coverage at the artifact root, badge
# in a subdirectory of it.
@test "resolve-publish-report-paths: resolves the coverage and badge pair" {
	_run_resolver COVERAGE_PATH="." BADGE_PATH="coverage"
	assert_success

	[ "$(_output_value coverage-path)" = "publish-input" ]
	[ "$(_output_value badge-path)" = "publish-input/coverage" ]
}

# The coverage migration from a working-directory: both inputs carry the same
# prefix the old publish job built with a format() expression.
@test "resolve-publish-report-paths: resolves a working-directory prefix" {
	_run_resolver COVERAGE_PATH="packages/api" BADGE_PATH="packages/api/coverage"
	assert_success

	[ "$(_output_value coverage-path)" = "publish-input/packages/api" ]
	[ "$(_output_value badge-path)" = "publish-input/packages/api/coverage" ]
}

# The distinction the whole sentinel exists for: an unset kind of content must
# stay empty, because publish-test-results reads the empty string as "skip".
# Collapsing it into '.' would make every coverage publisher also claim to hold
# a test report sitting at the artifact root.
@test "resolve-publish-report-paths: an unset path stays empty, not the root" {
	_run_resolver RESULTS_PATH="."
	assert_success

	[ "$(_output_value results-path)" = "publish-input" ]
	[ -z "$(_output_value coverage-path)" ]
	[ -z "$(_output_value badge-path)" ]
}

# Deploying nothing is not a no-op: the publisher uploads a full site artifact
# that replaces the whole published site, so an empty one takes the live site
# down. Better to fail before the deploy than to publish a blank site.
@test "resolve-publish-report-paths: rejects having neither results nor coverage" {
	_run_resolver
	assert_failure
	assert_output --partial "at least one of results-path or coverage-path"
}

@test "resolve-publish-report-paths: badge alone is not enough to publish" {
	_run_resolver BADGE_PATH="coverage"
	assert_failure
	assert_output --partial "at least one of results-path or coverage-path"
}

@test "resolve-publish-report-paths: rejects an absolute path" {
	_run_resolver RESULTS_PATH="/etc"
	assert_failure
	assert_output --partial "must be relative to the artifact root"
}

@test "resolve-publish-report-paths: rejects traversal out of the artifact" {
	local escape
	for escape in ".." "../secrets" "reports/../../etc" "a/b/../../.."; do
		_run_resolver RESULTS_PATH="$escape"
		assert_failure
		assert_output --partial "must not contain '..' segments"
	done
}

# Segment-wise traversal detection, so a legitimate directory name that merely
# contains two dots is not collateral damage.
@test "resolve-publish-report-paths: a dotted name is not a traversal" {
	_run_resolver RESULTS_PATH="pw..smoke"
	assert_success

	[ "$(_output_value results-path)" = "publish-input/pw..smoke" ]
}

@test "resolve-publish-report-paths: rejects shell and glob metacharacters" {
	local bad
	for bad in 'a b' 'a;rm -rf /' 'a$(id)' 'a*' 'a|b' 'a\b' '~/reports'; do
		_run_resolver RESULTS_PATH="$bad"
		assert_failure
		assert_output --partial "must match [A-Za-z0-9._/-]+"
	done
}

# Every path input is validated, not just the first: a permissive badge-path
# would stage content from outside the artifact just as effectively.
@test "resolve-publish-report-paths: validates badge-path too" {
	_run_resolver COVERAGE_PATH="." BADGE_PATH="../../etc"
	assert_failure
	assert_output --partial "badge-path"
}

@test "resolve-publish-report-paths: requires DOWNLOAD_DIR" {
	run env -u DOWNLOAD_DIR RESULTS_PATH="." bash "$SCRIPT"
	assert_failure
	assert_output --partial "DOWNLOAD_DIR is required"
}
