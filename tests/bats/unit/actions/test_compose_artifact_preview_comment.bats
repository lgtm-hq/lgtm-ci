#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/compose-artifact-preview-comment.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/compose-artifact-preview-comment.sh"

setup() {
	setup_temp_dir
	export COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md"
}

teardown() {
	teardown_temp_dir
}

@test "compose-artifact-preview: renders download link with artifact name" {
	run env \
		ARTIFACT_NAME="site-preview" \
		ARTIFACT_URL="https://github.com/o/r/actions/runs/1/artifacts/2" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "Download site-preview"
	assert_file_contains_literal "$COMMENT_OUTPUT" \
		"https://github.com/o/r/actions/runs/1/artifacts/2"
	assert_file_contains_literal "$COMMENT_OUTPUT" "⬇"
}

@test "compose-artifact-preview: documents login-required zip constraint" {
	run env \
		ARTIFACT_NAME="site-preview" \
		ARTIFACT_URL="https://github.com/o/r/actions/runs/1/artifacts/2" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "signed in to GitHub"
	assert_file_contains_literal "$COMMENT_OUTPUT" ".zip"
}

@test "compose-artifact-preview: prepends inline summary" {
	run env \
		ARTIFACT_NAME="bundle" \
		ARTIFACT_URL="https://example/artifacts/9" \
		SUMMARY="Built 42 pages in 3s" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "Built 42 pages in 3s"
	assert_file_contains_literal "$COMMENT_OUTPUT" "Download bundle"
}

@test "compose-artifact-preview: summary-file takes precedence over inline summary" {
	local summary_file="${BATS_TEST_TMPDIR}/summary.md"
	printf '## Site build\nfrom file\n' >"$summary_file"

	run env \
		ARTIFACT_NAME="bundle" \
		ARTIFACT_URL="https://example/artifacts/9" \
		SUMMARY="inline should be ignored" \
		SUMMARY_FILE="$summary_file" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "from file"
	run grep -F "inline should be ignored" "$COMMENT_OUTPUT"
	assert_failure
}

@test "compose-artifact-preview: falls back to inline summary when file missing" {
	run env \
		ARTIFACT_NAME="bundle" \
		ARTIFACT_URL="https://example/artifacts/9" \
		SUMMARY="inline fallback" \
		SUMMARY_FILE="${BATS_TEST_TMPDIR}/does-not-exist.md" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "inline fallback"
}

@test "compose-artifact-preview: empty artifact-url warns and writes empty body" {
	run env \
		ARTIFACT_NAME="bundle" \
		ARTIFACT_URL="" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "::warning::"
	assert_file_exists "$COMMENT_OUTPUT"
	[[ ! -s "$COMMENT_OUTPUT" ]]
}

@test "compose-artifact-preview: missing artifact-name with url errors" {
	run env \
		ARTIFACT_NAME="" \
		ARTIFACT_URL="https://example/artifacts/9" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "::error::"
}

@test "compose-artifact-preview: prints to stdout when COMMENT_OUTPUT unset" {
	run env -u COMMENT_OUTPUT \
		ARTIFACT_NAME="site" \
		ARTIFACT_URL="https://example/artifacts/9" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Download site"
}
