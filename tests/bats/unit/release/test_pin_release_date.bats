#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/pin-release-date.sh (#1624)

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/pin-release-date.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

@test "pin-release-date.sh: writes today's date as date=YYYY-MM-DD" {
	run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --regexp '^date=[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

@test "pin-release-date.sh: writes what date +%Y-%m-%d gives" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf '#!/usr/bin/env bash\n[[ "$1" == +%%Y-%%m-%%d ]] && echo 2026-11-17\n' \
		>"${BATS_TEST_TMPDIR}/bin/date"
	chmod +x "${BATS_TEST_TMPDIR}/bin/date"

	run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output "date=2026-11-17"
}

@test "pin-release-date.sh: fails when date fails, writing nothing" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/date"
	chmod +x "${BATS_TEST_TMPDIR}/bin/date"

	run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash "$SCRIPT"
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output ""
}

@test "pin-release-date.sh: fails without GITHUB_OUTPUT" {
	run env -u GITHUB_OUTPUT bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_OUTPUT is required"
}
