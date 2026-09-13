#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/attest-build.sh prepare step

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	printf 'artifact-contents\n' >"${BATS_TEST_TMPDIR}/artifact.txt"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_run_prepare() {
	local subject_path="${1:-${BATS_TEST_TMPDIR}/artifact.txt}"
	local subject_digest="${2:-}"
	local subject_name="${3:-}"
	run env \
		STEP=prepare \
		SUBJECT_PATH="$subject_path" \
		SUBJECT_DIGEST="$subject_digest" \
		SUBJECT_NAME="$subject_name" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/attest-build.sh"
}

@test "attest-build prepare: outputs subject-path when digest not provided" {
	_run_prepare

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^subject-path='
	assert_file_contains "$GITHUB_OUTPUT" '^subject-name='
	run grep -qE -- '^subject-digest=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "attest-build prepare: outputs subject-digest when digest provided" {
	_run_prepare "${BATS_TEST_TMPDIR}/artifact.txt" "sha256:deadbeef"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^subject-digest=sha256:deadbeef'
	assert_file_contains "$GITHUB_OUTPUT" '^subject-name='
	run grep -qE -- '^subject-path=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "attest-build prepare: accepts a subject-path glob that matches files (#963)" {
	mkdir -p "${BATS_TEST_TMPDIR}/dist"
	printf 'w' >"${BATS_TEST_TMPDIR}/dist/a.whl"
	printf 's' >"${BATS_TEST_TMPDIR}/dist/a.tar.gz"
	STEP=prepare SUBJECT_PATH="${BATS_TEST_TMPDIR}/dist/*" \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/attest-build.sh"
	assert_success
	run grep "subject-path=${BATS_TEST_TMPDIR}/dist/\*" "$GITHUB_OUTPUT"
	assert_success
	# No name for a glob: attest-build-provenance derives each file's own.
	run grep "^subject-name=$" "$GITHUB_OUTPUT"
	assert_success
}

@test "attest-build prepare: passes a recursive glob through untouched" {
	# @actions/glob expands ** itself; bash must not pre-judge the pattern.
	STEP=prepare SUBJECT_PATH="dist/**/pkg-*" \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/attest-build.sh"
	assert_success
	run grep 'subject-path=dist/\*\*/pkg-\*' "$GITHUB_OUTPUT"
	assert_success
}

@test "attest-build prepare: rejects subject-digest combined with a glob" {
	mkdir -p "${BATS_TEST_TMPDIR}/dist"
	printf 'w' >"${BATS_TEST_TMPDIR}/dist/a.whl"
	STEP=prepare SUBJECT_PATH="${BATS_TEST_TMPDIR}/dist/*" SUBJECT_DIGEST="sha256:abc" \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/attest-build.sh"
	assert_failure
	assert_output --partial "cannot be combined"
}
