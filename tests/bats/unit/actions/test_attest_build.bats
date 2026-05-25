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
	grep -q '^subject-path=' "$GITHUB_OUTPUT"
	grep -q '^subject-name=' "$GITHUB_OUTPUT"
	! grep -q '^subject-digest=' "$GITHUB_OUTPUT"
}

@test "attest-build prepare: outputs subject-digest when digest provided" {
	_run_prepare "${BATS_TEST_TMPDIR}/artifact.txt" "sha256:deadbeef"

	assert_success
	grep -q '^subject-digest=sha256:deadbeef' "$GITHUB_OUTPUT"
	grep -q '^subject-name=' "$GITHUB_OUTPUT"
	! grep -q '^subject-path=' "$GITHUB_OUTPUT"
}
