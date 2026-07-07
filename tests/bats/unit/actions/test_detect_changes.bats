#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/detect-changes.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/detect-changes.sh"

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

@test "detect-changes: fails without FILTERS" {
	run env -u FILTERS bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "FILTERS is required"
}

@test "detect-changes: fails on invalid filter line" {
	run_detect FILTERS="no-equals-sign" CHANGED_FILES="a.txt"
	assert_failure
	assert_output --partial "invalid filter line"
}

@test "detect-changes: fails on JSON-unsafe filter name" {
	run_detect FILTERS='bad"name=tests/*' CHANGED_FILES="a.txt"
	assert_failure
	assert_output --partial "invalid filter name"
}

@test "detect-changes: fails on empty filter list" {
	run_detect FILTERS=$'\n  \n' CHANGED_FILES="a.txt"
	assert_failure
	assert_output --partial "no filter lines"
}

@test "detect-changes: matching filter reports true" {
	run_detect \
		FILTERS="tests=tests/* src/*" \
		CHANGED_FILES=$'tests/unit/a_test.rs'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true}'
	run get_github_output "any-changed"
	assert_output "true"
}

@test "detect-changes: non-matching filter reports false" {
	run_detect \
		FILTERS="tests=tests/* src/*" \
		CHANGED_FILES=$'docs/readme.md'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":false}'
	run get_github_output "any-changed"
	assert_output "false"
}

@test "detect-changes: multiple filters evaluated independently" {
	run_detect \
		FILTERS=$'tests=tests/* src/*\ndocs=docs/* *.md' \
		CHANGED_FILES=$'docs/guide.md\nsrc/main.rs'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true,"docs":true}'
}

@test "detect-changes: glob star crosses directory separators" {
	run_detect \
		FILTERS="examples=examples/*" \
		CHANGED_FILES=$'examples/react/src/App.tsx'
	assert_success
	run get_github_output "changes"
	assert_output '{"examples":true}'
}

@test "detect-changes: comments and blank filter lines are ignored" {
	run_detect \
		FILTERS=$'# tests below\n  # indented comment\n\ntests=tests/*' \
		CHANGED_FILES=$'tests/a.rs'
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true}'
}

@test "detect-changes: set-but-empty CHANGED_FILES means no changes" {
	run_detect \
		FILTERS=$'tests=tests/*\ndocs=docs/*' \
		CHANGED_FILES=""
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":false,"docs":false}'
	run get_github_output "any-changed"
	assert_output "false"
}

@test "detect-changes: empty base fails open (all filters true)" {
	run_detect \
		FILTERS=$'tests=tests/*\ndocs=docs/*' \
		BASE_SHA=""
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true,"docs":true}'
	run get_github_output "any-changed"
	assert_output "true"
}

@test "detect-changes: unreachable base fails open" {
	cd "$BATS_TEST_TMPDIR"
	git init -q repo
	cd repo
	git config user.email "test@example.com"
	git config user.name "Test"
	git commit -q --allow-empty -m init
	run env \
		FILTERS="tests=tests/*" \
		BASE_SHA="0000000000000000000000000000000000000001" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true}'
}

@test "detect-changes: computes diff from git when no seam provided" {
	cd "$BATS_TEST_TMPDIR"
	git init -q repo
	cd repo
	git config user.email "test@example.com"
	git config user.name "Test"
	git commit -q --allow-empty -m init
	base="$(git rev-parse HEAD)"
	mkdir -p tests
	echo "x" >tests/a.rs
	git add tests/a.rs
	git commit -q -m "add test"
	run env \
		FILTERS=$'tests=tests/*\ndocs=docs/*' \
		BASE_SHA="$base" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	run get_github_output "changes"
	assert_output '{"tests":true,"docs":false}'
}

@test "detect-changes: script is executable (action invokes it directly)" {
	# The composite action runs "$SCRIPTS_DIR/ci/actions/detect-changes.sh"
	# with no bash prefix, so a missing execute bit fails at runtime (126).
	[[ -x "${PROJECT_ROOT}/${SCRIPT}" ]]
}
