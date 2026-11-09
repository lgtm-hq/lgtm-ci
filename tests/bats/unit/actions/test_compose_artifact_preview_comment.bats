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

run_preview() {
	run env \
		ARTIFACT_NAME="site-preview" \
		ARTIFACT_URL="https://example/artifacts/9" \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		"$@" \
		bash "$SCRIPT"
}

@test "compose-artifact-preview: heading defaults to the artifact name" {
	run_preview
	assert_success
	assert_equal "$(head -n 1 "$COMMENT_OUTPUT")" "## site-preview"
}

@test "compose-artifact-preview: TITLE overrides the heading" {
	run_preview TITLE="Site preview"
	assert_success
	assert_equal "$(head -n 1 "$COMMENT_OUTPUT")" "## Site preview"
}

@test "compose-artifact-preview: no UPSTREAM_RESULT means no status line" {
	run_preview
	assert_success
	run grep -F "Status:" "$COMMENT_OUTPUT"
	assert_failure
}

@test "compose-artifact-preview: UPSTREAM_RESULT=success renders PASSED" {
	run_preview UPSTREAM_RESULT=success
	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "### 📊 Status: ✅ PASSED"
}

@test "compose-artifact-preview: UPSTREAM_RESULT=failure renders FAILED" {
	run_preview UPSTREAM_RESULT=failure
	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "### 📊 Status: ❌ FAILED"
}

@test "compose-artifact-preview: UPSTREAM_RESULT=cancelled and skipped render skip marker" {
	run_preview UPSTREAM_RESULT=cancelled
	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "### 📊 Status: ⏭️"
	run_preview UPSTREAM_RESULT=skipped
	assert_success
	assert_file_contains_literal "$COMMENT_OUTPUT" "### 📊 Status: ⏭️"
}

@test "compose-artifact-preview: footer names the workflow" {
	run_preview WORKFLOW_NAME="Site CI"
	assert_success
	assert_equal "$(tail -n 1 "$COMMENT_OUTPUT")" "<sub>Generated by Site CI workflow</sub>"
}

@test "compose-artifact-preview: body order is heading, summary, link, footer" {
	run_preview SUMMARY="Built 42 pages"
	assert_success
	local heading summary link footer
	heading="$(grep -n '^## ' "$COMMENT_OUTPUT" | head -n 1 | cut -d: -f1)"
	summary="$(grep -nF 'Built 42 pages' "$COMMENT_OUTPUT" | cut -d: -f1)"
	link="$(grep -nF 'Download site-preview' "$COMMENT_OUTPUT" | cut -d: -f1)"
	footer="$(grep -nF 'Generated by' "$COMMENT_OUTPUT" | cut -d: -f1)"
	((heading < summary && summary < link && link < footer))
}

@test "compose-artifact-preview: empty url still writes empty body with title set" {
	run env \
		ARTIFACT_NAME="site-preview" \
		ARTIFACT_URL="" \
		TITLE="Site preview" \
		UPSTREAM_RESULT=success \
		COMMENT_OUTPUT="$COMMENT_OUTPUT" \
		bash "$SCRIPT"
	assert_success
	[[ ! -s "$COMMENT_OUTPUT" ]]
}
