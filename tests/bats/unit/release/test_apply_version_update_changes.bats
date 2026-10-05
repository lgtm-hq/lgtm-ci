#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/apply-version-update-changes.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/apply-version-update-changes.sh"

setup() {
	setup_temp_dir
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		mkdir -p .github/workflows src
		echo "name: ci" >.github/workflows/ci.yml
		echo "1.0.0" >src/version.txt
		git add -A
		git commit -q -m "chore: seed"
	)
}

teardown() {
	teardown_temp_dir
}

diff_of() {
	local snippet="$1"
	local out="${BATS_TEST_TMPDIR}/change.diff"
	(
		cd "$MOCK_GIT_REPO" || exit 1
		eval "$snippet"
		git add -A
		git diff --cached --binary >"$out"
		git reset -q --hard
		git clean -qfd
	)
	printf '%s\n' "$out"
}

run_apply() {
	local diff="$1"
	run bash -c "cd '$MOCK_GIT_REPO' && DIFF_PATH='$diff' bash '$SCRIPT' 2>&1"
}

@test "apply-version-update-changes: fails without DIFF_PATH" {
	run env -u DIFF_PATH bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIFF_PATH is required"
}

@test "apply-version-update-changes: fails when the artifact is missing" {
	run_apply "${BATS_TEST_TMPDIR}/missing.diff"
	assert_failure
	assert_output --partial "version-update diff not found"
}

@test "apply-version-update-changes: empty diff is a no-op" {
	: >"${BATS_TEST_TMPDIR}/empty.diff"
	run_apply "${BATS_TEST_TMPDIR}/empty.diff"
	assert_success
	assert_output --partial "nothing to apply"
	run git -C "$MOCK_GIT_REPO" status --porcelain
	assert_output ""
}

@test "apply-version-update-changes: applies an in-scope diff to the working tree" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt; echo new >src/extra.txt')"
	run_apply "$diff"
	assert_success
	assert_output --partial "Applied version-update-script changes"
	run cat "$MOCK_GIT_REPO/src/version.txt"
	assert_output "2.0.0"
	assert_file_exists "$MOCK_GIT_REPO/src/extra.txt"
}

@test "apply-version-update-changes: refuses a diff touching .github/workflows before applying" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt; echo tampered >.github/workflows/ci.yml')"
	run_apply "$diff"
	assert_failure
	assert_output --partial ".github/workflows/ci.yml"
	# Nothing was applied, not even the in-scope part.
	run cat "$MOCK_GIT_REPO/src/version.txt"
	assert_output "1.0.0"
	run git -C "$MOCK_GIT_REPO" status --porcelain
	assert_output ""
}

@test "apply-version-update-changes: refuses a diff that does not apply cleanly" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt')"
	echo "9.9.9" >"$MOCK_GIT_REPO/src/version.txt"
	run_apply "$diff"
	assert_failure
	assert_output --partial "does not apply cleanly"
}
