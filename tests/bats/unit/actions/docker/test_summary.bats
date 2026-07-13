#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/summary.sh (per-step edge cases)

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/summary.sh"

setup() {
	setup_temp_dir
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export PLATFORMS="linux/amd64"
	export PUSH="false"
	unset TAGS DIGEST COSIGN_SIGNED SCAN_ENABLED VALIDATE_ON_PR MATRIX HEALTH_CHECK_ENABLED || true
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "summary.sh: writes base docker build results table" {
	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "## Docker Build Results"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| Image | \`ghcr.io/org/repo\` |"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| Platforms | \`linux/amd64\` |"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| Pushed | false |"
	run grep -F -- "PR validation" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "summary.sh: includes PR validation row when enabled" {
	export VALIDATE_ON_PR="true"

	run bash "$SCRIPT"
	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| PR validation | enabled |"
}

@test "summary.sh: includes digest section when DIGEST set" {
	export DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	run bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Digest"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "\`sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\`"
}

@test "summary.sh: lists matrix platforms when MATRIX is non-empty" {
	export MATRIX='[{"platform":"linux/amd64"},{"platform":"linux/arm64"}]'

	run bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Per-platform build matrix"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "\`linux/amd64\`"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "\`linux/arm64\`"
}

@test "summary.sh: skips matrix section for empty array" {
	export MATRIX='[]'

	run bash "$SCRIPT"
	assert_success
	run grep -F "Per-platform build matrix" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "summary.sh: lists tags and ignores blank lines" {
	export TAGS=$'ghcr.io/org/repo:main\n\nghcr.io/org/repo:sha-abc\n'

	run bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Tags"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "\`ghcr.io/org/repo:main\`"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "\`ghcr.io/org/repo:sha-abc\`"
}

@test "summary.sh: includes cosign verify snippet when signed with digest" {
	export DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	export COSIGN_SIGNED="true"
	export GITHUB_REPOSITORY="acme/widgets"

	run bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Image signature"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "cosign verify ghcr.io/org/repo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "https://github.com/acme/widgets/.*"
}

@test "summary.sh: omits cosign section without digest even when signed" {
	export COSIGN_SIGNED="true"
	unset DIGEST || true

	run bash "$SCRIPT"
	assert_success
	run grep -F "Image signature" "$GITHUB_STEP_SUMMARY"
	assert_failure
}

@test "summary.sh: includes scan and health-check sections when enabled" {
	export SCAN_ENABLED="true"
	export HEALTH_CHECK_ENABLED="true"

	run bash "$SCRIPT"
	assert_success
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Vulnerability scan"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "### Health check"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "Trivy scanned CRITICAL/HIGH"
	assert_file_contains "$GITHUB_STEP_SUMMARY" "Detached-container health check passed"
}
