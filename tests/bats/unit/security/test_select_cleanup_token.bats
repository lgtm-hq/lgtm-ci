#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/select-cleanup-token.sh (#1687, #1691)
#
# The source of the generated "Check cleanup token credential" step in
# reusable-vuln-suppression-check.yml; tests/python/test_vuln_suppression_app_token.py
# runs the inline copy, and sync_inline_blocks.py --check keeps it equal to this body.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/select-cleanup-token.sh"

setup() {
	OUT_FILE="${BATS_TEST_TMPDIR}/github-output"
	: >"$OUT_FILE"
}

# _select APP_MODE APP_ID_SET APP_KEY_SET GH_TOKEN_SET
_select() {
	run env APP_MODE="$1" APP_ID_SET="$2" APP_KEY_SET="$3" GH_TOKEN_SET="$4" \
		GITHUB_OUTPUT="$OUT_FILE" bash "$SCRIPT"
}

@test "select-cleanup-token: input on with a complete credential selects the App" {
	local gh
	for gh in true false; do
		: >"$OUT_FILE"
		_select true true true "$gh"
		assert_success
		assert_output ""
		run cat "$OUT_FILE"
		assert_output "mode=app"
	done
}

@test "select-cleanup-token: input on with an incomplete credential fails, GH_TOKEN or not" {
	local id key gh
	for id in true false; do
		for key in true false; do
			[[ "$id/$key" == true/true ]] && continue
			for gh in true false; do
				: >"$OUT_FILE"
				_select true "$id" "$key" "$gh"
				assert_failure 1
				assert_output --partial "::error title=incomplete App credential::"
				assert_output --partial "GH_TOKEN is not used in this mode"
				[ ! -s "$OUT_FILE" ]
			done
		done
	done
}

@test "select-cleanup-token: input off with GH_TOKEN ignores any App secrets" {
	local id key
	for id in true false; do
		for key in true false; do
			: >"$OUT_FILE"
			_select false "$id" "$key" true
			assert_success
			assert_output ""
			run cat "$OUT_FILE"
			assert_output "mode=github-token"
		done
	done
}

@test "select-cleanup-token: input off without GH_TOKEN fails naming both options and the input" {
	local id key
	for id in true false; do
		for key in true false; do
			: >"$OUT_FILE"
			_select false "$id" "$key" false
			assert_failure 1
			assert_output --partial "::error title=missing cleanup token::"
			assert_output --partial "GH_TOKEN"
			assert_output --partial "cleanup-app-token"
			assert_output --partial "RELEASE_APP_PRIVATE_KEY"
			[ ! -s "$OUT_FILE" ]
		done
	done
}

@test "select-cleanup-token: a flag that is not true or false fails" {
	_unexpected() {
		: >"$OUT_FILE"
		_select "$@"
		assert_failure 1
		assert_output --partial "::error title=unexpected cleanup token state::"
		[ ! -s "$OUT_FILE" ]
	}
	_unexpected yes true true true
	_unexpected true 1 true true
	_unexpected true true "" true
	_unexpected false true true TRUE
	_unexpected "" false false true
	_unexpected "true/true" true true true
}

@test "select-cleanup-token: an unset flag fails" {
	run env -i PATH="$PATH" APP_MODE=false APP_ID_SET=false APP_KEY_SET=false \
		GITHUB_OUTPUT="$OUT_FILE" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "::error title=unexpected cleanup token state::"
	[ ! -s "$OUT_FILE" ]
}
