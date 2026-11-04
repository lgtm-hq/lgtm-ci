#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for the actual auto-tag version resolver

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

run_resolve() {
	run env VERSION_SOURCE=commit COMMIT_MESSAGE="$1" \
		"$PROJECT_ROOT/scripts/ci/release/resolve-auto-tag-version.sh"
}

assert_resolved_version() {
	assert_success
	assert_line "version=$1"
	assert_line "found=true"
	assert_github_output "version" "$1"
	assert_github_output "found" "true"
}

@test "resolve-auto-tag: observed prepare subject resolves through actual git HEAD fallback" {
	setup_mock_git_repo
	add_commit "chore(release): prepare v0.83.11 (#1321)"
	cd "$MOCK_GIT_REPO"

	run env -u COMMIT_MESSAGE -u VERSION_SOURCE \
		"$PROJECT_ROOT/scripts/ci/release/resolve-auto-tag-version.sh"
	assert_resolved_version "0.83.11"
}

@test "resolve-auto-tag: observed prepare subject resolves with explicit commit override" {
	run_resolve "chore(release): prepare v0.83.11 (#1321)"
	assert_resolved_version "0.83.11"
}

@test "resolve-auto-tag: empty override uses actual git HEAD like the workflow" {
	setup_mock_git_repo
	add_commit "chore(release): prepare v0.83.11 (#1321)"
	cd "$MOCK_GIT_REPO"

	run_resolve ""
	assert_resolved_version "0.83.11"
}

@test "resolve-auto-tag: canonical release subject remains supported" {
	run_resolve "chore(release): version 0.83.11 (#1321)"
	assert_resolved_version "0.83.11"
}

@test "resolve-auto-tag: canonical git HEAD fallback remains supported" {
	setup_mock_git_repo
	add_commit "chore(release): version 0.83.11 (#1321)"
	cd "$MOCK_GIT_REPO"

	run env -u COMMIT_MESSAGE VERSION_SOURCE=commit \
		"$PROJECT_ROOT/scripts/ci/release/resolve-auto-tag-version.sh"
	assert_resolved_version "0.83.11"
}

@test "resolve-auto-tag: manual version subject overrides unrelated HEAD" {
	setup_mock_git_repo
	add_commit "feat: unrelated change"
	cd "$MOCK_GIT_REPO"

	# The workflow maps inputs.version to this canonical COMMIT_MESSAGE.
	run_resolve "chore(release): version 1.2.3"
	assert_resolved_version "1.2.3"
}

@test "resolve-auto-tag: unrelated git HEAD fails closed" {
	setup_mock_git_repo
	add_commit "feat: prepare v0.83.11 (#1321)"
	cd "$MOCK_GIT_REPO"

	run env -u COMMIT_MESSAGE VERSION_SOURCE=commit \
		"$PROJECT_ROOT/scripts/ci/release/resolve-auto-tag-version.sh"
	assert_failure 1
	assert_line "version="
	assert_line "found=false"
	assert_equal $'version=\nfound=false' "$(cat "$GITHUB_OUTPUT")"
}

@test "resolve-auto-tag: malformed or missing prepare version fails closed" {
	local subject
	for subject in "chore(release): prepare" "chore(release): prepare v0.83.11 (#bad)"; do
		: >"$GITHUB_OUTPUT"
		run_resolve "$subject"
		assert_failure 1
		assert_line "version="
		assert_line "found=false"
		assert_equal $'version=\nfound=false' "$(cat "$GITHUB_OUTPUT")"
	done
}
