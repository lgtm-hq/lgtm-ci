#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/select-app-credential.sh (#1450)
#
# The source script of the generated "Select GitHub App credential" steps.
# integration/test_release_app_credential_select.bats runs every inline copy;
# sync_inline_blocks.py --check keeps those copies equal to this body.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/select-app-credential.sh"

setup() {
	OUT_FILE="${BATS_TEST_TMPDIR}/github-output"
	: >"$OUT_FILE"
}

# The workflow step always defines both variables, empty when the secret is.
_select() {
	run env APP_ID="$1" APP_CLIENT_ID="$2" GITHUB_OUTPUT="$OUT_FILE" bash "$SCRIPT"
}

@test "select-app-credential: only the App ID set selects it" {
	_select "12345" ""
	assert_success
	assert_output ""
	run cat "$OUT_FILE"
	assert_output "$(printf 'app-id=12345\nclient-id=')"
}

@test "select-app-credential: only the client ID set selects it" {
	_select "" "Iv23liABC"
	assert_success
	assert_output ""
	run cat "$OUT_FILE"
	assert_output "$(printf 'app-id=\nclient-id=Iv23liABC')"
}

@test "select-app-credential: both set prefers the client ID with a notice" {
	_select "12345" "Iv23liABC"
	assert_success
	assert_output "::notice title=RELEASE_APP_ID ignored::both are set; using RELEASE_APP_CLIENT_ID"
	run cat "$OUT_FILE"
	assert_output "$(printf 'app-id=\nclient-id=Iv23liABC')"
}

@test "select-app-credential: neither set fails with an error and writes no output" {
	_select "" ""
	assert_failure 1
	assert_output "::error title=missing App credential::set RELEASE_APP_CLIENT_ID or RELEASE_APP_ID"
	[ ! -s "$OUT_FILE" ]
}
