#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/detect-changes.sh (dorny wrapper helpers)

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/detect-changes.sh"

YAML_FILTERS=$'tests:\n  - \'tests/**\'\ndocs:\n  - \'docs/**\'\n  - \'*.md\''

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_detect() {
	run env "$@" bash "${PROJECT_ROOT}/${SCRIPT}"
}

@test "detect-changes: fails without STEP" {
	run env -u STEP FILTERS="$YAML_FILTERS" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "detect-changes: fails without FILTERS on resolve" {
	run env -u FILTERS STEP=resolve bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "FILTERS is required"
}

@test "detect-changes: resolve rejects legacy line format" {
	run_detect STEP=resolve FILTERS="tests=tests/* src/*" BASE_SHA="abc"
	assert_failure
	assert_output --partial "legacy line format"
	assert_output --partial "dorny YAML"
}

@test "detect-changes: resolve fails on empty filter list" {
	run_detect STEP=resolve FILTERS=$'\n  \n' BASE_SHA="abc"
	assert_failure
	assert_output --partial "no filter names"
}

@test "detect-changes: resolve extracts YAML filter names" {
	run_detect STEP=resolve FILTERS="$YAML_FILTERS" BASE_SHA="abc123" HEAD_SHA="def456" \
		EVENT_NAME=pull_request
	assert_success
	run get_github_output "filter-names"
	assert_output "tests docs"
	run get_github_output "fail-open"
	assert_output "false"
	run get_github_output "base"
	assert_output "abc123"
	run get_github_output "ref"
	assert_output "def456"
}

@test "detect-changes: resolve empty base fails open" {
	run_detect STEP=resolve FILTERS="$YAML_FILTERS" BASE_SHA="" EVENT_NAME=push
	assert_success
	assert_output --partial "BASE_SHA is empty; failing open"
	run get_github_output "fail-open"
	assert_output "true"
	run get_github_output "filter-names"
	assert_output "tests docs"
}

@test "detect-changes: resolve unreachable base fails open on push" {
	cd "$BATS_TEST_TMPDIR"
	git init -q repo
	cd repo
	git config user.email "test@example.com"
	git config user.name "Test"
	git commit -q --allow-empty -m init
	run env \
		STEP=resolve \
		FILTERS="$YAML_FILTERS" \
		BASE_SHA="0000000000000000000000000000000000000001" \
		EVENT_NAME=push \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "cannot resolve base"
	run get_github_output "fail-open"
	assert_output "true"
}

@test "detect-changes: resolve null before-SHA stays closed for dorny first-push" {
	# GitHub sends the null SHA as event.before on the first push of a branch.
	# Dorny handles that natively; the wrapper must not fail-open and skip it.
	run_detect STEP=resolve FILTERS="$YAML_FILTERS" \
		BASE_SHA="0000000000000000000000000000000000000000" \
		EVENT_NAME=push
	assert_success
	run get_github_output "fail-open"
	assert_output "false"
	run get_github_output "base"
	assert_output "0000000000000000000000000000000000000000"
}

@test "detect-changes: resolve skips git reachability check on pull_request" {
	run_detect STEP=resolve FILTERS="$YAML_FILTERS" \
		BASE_SHA="0000000000000000000000000000000000000001" \
		EVENT_NAME=pull_request
	assert_success
	run get_github_output "fail-open"
	assert_output "false"
}

@test "detect-changes: resolve reachable base stays closed on push" {
	cd "$BATS_TEST_TMPDIR"
	git init -q repo
	cd repo
	git config user.email "test@example.com"
	git config user.name "Test"
	git commit -q --allow-empty -m init
	base="$(git rev-parse HEAD)"
	run env \
		STEP=resolve \
		FILTERS="$YAML_FILTERS" \
		BASE_SHA="$base" \
		EVENT_NAME=push \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	run get_github_output "fail-open"
	assert_output "false"
}

@test "detect-changes: map fail-open reports all filters true" {
	run_detect STEP=map FAIL_OPEN=true FILTER_NAMES="tests docs"
	assert_success
	assert_output --partial "fail-open active"
	run get_github_output "changes"
	assert_output '{"tests":true,"docs":true}'
	run get_github_output "any-changed"
	assert_output "true"
}

@test "detect-changes: map converts dorny changes array to object" {
	run_detect STEP=map FAIL_OPEN=false FILTER_NAMES="tests docs" \
		DORNY_CHANGES='["tests"]'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true,"docs":false}'
	run get_github_output "any-changed"
	assert_output "true"
}

@test "detect-changes: map with no dorny matches reports all false" {
	run_detect STEP=map FAIL_OPEN=false FILTER_NAMES="tests docs" \
		DORNY_CHANGES='[]'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":false,"docs":false}'
	run get_github_output "any-changed"
	assert_output "false"
}

@test "detect-changes: map treats missing DORNY_CHANGES as empty array" {
	run env -u DORNY_CHANGES STEP=map FAIL_OPEN=false FILTER_NAMES="tests" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":false}'
	run get_github_output "any-changed"
	assert_output "false"
}


@test "detect-changes: resolve extracts dotted and quoted YAML filter names" {
	local filters=$'frontend.app:\n  - \'packages/frontend/**\'\n"api/v2":\n  - \'packages/api/**\'\n\'docs-site\':\n  - \'docs/**\''
	run_detect STEP=resolve FILTERS="$filters" BASE_SHA="abc123" HEAD_SHA="def456" \
		EVENT_NAME=pull_request
	assert_success
	run get_github_output "filter-names"
	assert_output "frontend.app api/v2 docs-site"
}

@test "detect-changes: map preserves dotted filter names in changes JSON" {
	run_detect STEP=map FAIL_OPEN=false FILTER_NAMES="frontend.app api/v2" \
		DORNY_CHANGES='["frontend.app"]'
	assert_success
	run get_github_output "changes"
	assert_output '{"frontend.app":true,"api/v2":false}'
	run get_github_output "any-changed"
	assert_output "true"
}

@test "detect-changes: script is executable (action invokes it directly)" {
	# The composite action runs "$SCRIPTS_DIR/ci/actions/detect-changes.sh"
	# with no bash prefix, so a missing execute bit fails at runtime (126).
	[[ -x "${PROJECT_ROOT}/${SCRIPT}" ]]
}
