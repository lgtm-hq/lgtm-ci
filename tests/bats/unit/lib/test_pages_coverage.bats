#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for pages_coverage.sh helpers

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	# shellcheck source=../../../../../scripts/ci/lib/pages_coverage.sh
	source "${PROJECT_ROOT}/scripts/ci/lib/pages_coverage.sh"
}

@test "resolve_pages_coverage_should_upload: push-main allows push to main" {
	run resolve_pages_coverage_should_upload push-main push refs/heads/main
	assert_success
	assert_output "true"
}

@test "resolve_pages_coverage_should_upload: push-main blocks pull requests" {
	run resolve_pages_coverage_should_upload push-main pull_request refs/pull/1/merge
	assert_success
	assert_output "false"
}

@test "resolve_pages_coverage_should_upload: rejects unknown upload-on values" {
	run resolve_pages_coverage_should_upload always push refs/heads/main
	assert_failure
	assert_output --partial "Unsupported pages-coverage-upload-on"
}
