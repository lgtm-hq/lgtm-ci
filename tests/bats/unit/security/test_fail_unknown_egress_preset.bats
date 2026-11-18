#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/fail-unknown-egress-preset.sh (#913, #1624)
#
# The script is the source of the generated "Fail on unknown egress-preset"
# blocks; sync_inline_blocks.py --check keeps every copy equal to its body.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/fail-unknown-egress-preset.sh"

@test "fail-unknown-egress-preset.sh: names the preset and fails" {
	run env EGRESS_PRESET=no-such-preset bash "$SCRIPT"
	assert_failure 1
	assert_output "::error title=unknown egress-preset::not a preset - 'no-such-preset'"
}

@test "fail-unknown-egress-preset.sh: prints a hostile name as data" {
	# shellcheck disable=SC2016 # the dollar must reach the script unexpanded
	run env EGRESS_PRESET='$(touch pwned)' bash -c 'cd "$1" && bash "$0"' "$SCRIPT" "$BATS_TEST_TMPDIR"
	assert_failure 1
	assert_output --partial "'\$(touch pwned)'"
	[[ ! -e "${BATS_TEST_TMPDIR}/pwned" ]]
}

@test "fail-unknown-egress-preset.sh: every workflow copy is generated and named" {
	run grep -rlF "lgtm-ci-inline:begin fail-unknown-egress-preset" "${PROJECT_ROOT}/.github/workflows"
	assert_success
	local steps copies
	steps="$(grep -rhF -- "- name: Fail on unknown egress-preset" "${PROJECT_ROOT}/.github/workflows" | wc -l | tr -d ' ')"
	copies="$(grep -rhF "lgtm-ci-inline:begin fail-unknown-egress-preset" "${PROJECT_ROOT}/.github/workflows" | wc -l | tr -d ' ')"
	assert_equal "$copies" "$steps"
	# Only "some": the exact count is enforced by Block.copies in
	# scripts/ci/bootstrap/sync_inline_blocks.py (its --check).
	(( copies > 0 ))
}
