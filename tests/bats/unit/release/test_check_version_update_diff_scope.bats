#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/check-version-update-diff-scope.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/check-version-update-diff-scope.sh"

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

# Produce a diff of the given edit (a shell snippet run inside the repo).
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

@test "check-version-update-diff-scope: fails without DIFF_PATH" {
	run env -u DIFF_PATH bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIFF_PATH is required"
}

@test "check-version-update-diff-scope: fails when the diff file is missing" {
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/nope.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "diff not found"
}

@test "check-version-update-diff-scope: accepts an empty diff" {
	: >"${BATS_TEST_TMPDIR}/empty.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/empty.diff" bash "$SCRIPT"
	assert_success
	assert_output --partial "empty"
}

@test "check-version-update-diff-scope: accepts edits, new files and renames inside the repo" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt; echo new >src/extra.txt; git mv README.md docs.md')"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_success
	assert_output --partial "in scope (4 path(s))"
}

@test "check-version-update-diff-scope: rejects edits under .github/workflows" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt; echo tampered >.github/workflows/ci.yml')"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error title=version-update-script out of scope::.github/workflows/ci.yml"
	assert_output --partial "refusing to apply"
}

@test "check-version-update-diff-scope: rejects a new file under .github/workflows" {
	local diff
	diff="$(diff_of 'echo x >.github/workflows/new.yml')"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial ".github/workflows/new.yml"
}

@test "check-version-update-diff-scope: rejects a rename out of .github/workflows" {
	local diff
	diff="$(diff_of 'git mv .github/workflows/ci.yml src/ci.yml')"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial ".github/workflows/ci.yml"
}

@test "check-version-update-diff-scope: decodes a C-quoted rename source before checking it" {
	local diff
	diff="$(diff_of 'git mv .github/workflows/ci.yml src/ci.yml')"
	# A workflow name with a non-ASCII byte is C-quoted by git; the decoded
	# path still starts with .github/ and must be rejected.
	sed 's#^rename from .github/workflows/ci.yml$#rename from ".github/workflows/ci\\303\\251.yml"#' "$diff" \
		>"${BATS_TEST_TMPDIR}/quoted.diff"
	run grep -c '^rename from "' "${BATS_TEST_TMPDIR}/quoted.diff"
	assert_output "1"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/quoted.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial ".github/workflows/cié.yml"
}

@test "check-version-update-diff-scope: a C-quoted in-scope rename source is accepted" {
	local diff
	diff="$(diff_of 'git mv README.md docs.md')"
	# Tab, quote, backslash and octal escapes all decode to ordinary bytes.
	sed 's#^rename from README.md$#rename from "src/re\\tad\\"me\\\\\\303\\251.md"#' "$diff" \
		>"${BATS_TEST_TMPDIR}/quoted-ok.diff"
	run grep -c '^rename from "' "${BATS_TEST_TMPDIR}/quoted-ok.diff"
	assert_output "1"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/quoted-ok.diff" bash "$SCRIPT"
	assert_success
	assert_output --partial "in scope (2 path(s))"
}

@test "check-version-update-diff-scope: an unknown escape in a quoted source is rejected" {
	local diff
	diff="$(diff_of 'git mv README.md docs.md')"
	sed 's#^rename from README.md$#rename from "src/bad\\qname.md"#' "$diff" >"${BATS_TEST_TMPDIR}/quoted-bad.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/quoted-bad.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "unknown escape"
}

@test "check-version-update-diff-scope: rejects case variants of protected paths" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt')"
	sed 's#src/version.txt#.GitHub/Workflows/evil.yml#g' "$diff" >"${BATS_TEST_TMPDIR}/case1.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/case1.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial ".GitHub/Workflows/evil.yml"
	sed 's#src/version.txt#.LGTM-CI-TOOLING/scripts/ci/release/x.sh#g' "$diff" >"${BATS_TEST_TMPDIR}/case2.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/case2.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "tooling checkout"
}

@test "check-version-update-diff-scope: rejects composite actions and CODEOWNERS under .github" {
	local diff
	diff="$(diff_of 'mkdir -p .github/actions/a; echo x >.github/actions/a/action.yml; echo "* @me" >.github/CODEOWNERS')"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial ".github/actions/a/action.yml"
	assert_output --partial ".github/CODEOWNERS"
}

@test "check-version-update-diff-scope: rejects symlinks" {
	local diff
	diff="$(diff_of 'ln -s /etc/passwd src/link')"
	run grep -c "120000" "$diff"
	assert_output "1"
	run env DIFF_PATH="$diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "symlinks and gitlinks are not allowed"
}

@test "check-version-update-diff-scope: rejects the tooling checkout" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt')"
	sed 's#src/version.txt#.lgtm-ci-tooling/scripts/ci/release/x.sh#g' "$diff" >"${BATS_TEST_TMPDIR}/tooling.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/tooling.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "lgtm-ci tooling checkout is not caller content"
}

@test "check-version-update-diff-scope: rejects paths escaping the repository" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt')"
	sed 's#src/version.txt#../escape.txt#g' "$diff" >"${BATS_TEST_TMPDIR}/escape.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/escape.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "escapes the repository"
}

@test "check-version-update-diff-scope: rejects git metadata" {
	local diff
	diff="$(diff_of 'echo 2.0.0 >src/version.txt')"
	sed 's#src/version.txt#.git/hooks/pre-commit#g' "$diff" >"${BATS_TEST_TMPDIR}/git.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/git.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "git metadata"
}

@test "check-version-update-diff-scope: rejects content git cannot parse" {
	echo "not a patch" >"${BATS_TEST_TMPDIR}/garbage.diff"
	run env DIFF_PATH="${BATS_TEST_TMPDIR}/garbage.diff" bash "$SCRIPT"
	assert_failure
	assert_output --partial "could not parse"
}
