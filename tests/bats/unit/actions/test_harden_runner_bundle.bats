#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for harden-runner action bundle sync

load "../../../helpers/common"

SYNC="${PROJECT_ROOT}/scripts/ci/actions/sync-harden-runner-bundle.sh"
VALIDATE="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-bundle.sh"
BUNDLE_RESOLVE="${PROJECT_ROOT}/.github/actions/harden-runner/resolve-egress-endpoints.sh"

teardown() {
	if [[ -n "${output_file:-}" && -f "$output_file" ]]; then
		rm -f "$output_file"
	fi
	git -C "$PROJECT_ROOT" checkout -- \
		.github/actions/harden-runner/lib \
		.github/actions/harden-runner/resolve-egress-endpoints.sh 2>/dev/null || true
}

@test "validate-harden-runner-bundle: passes when bundle matches canonical lib" {
	run bash "$VALIDATE"
	assert_success
}

@test "harden-runner action: passes allowed-endpoints from inputs not step outputs" {
	run grep -F "allowed-endpoints: \${{ inputs['allowed-endpoints'] }}" \
		"${PROJECT_ROOT}/.github/actions/harden-runner/action.yml"
	assert_success
	run grep -F "steps.resolve.outputs" "${PROJECT_ROOT}/.github/actions/harden-runner/action.yml"
	assert_failure
}

@test "sync-harden-runner-bundle: bundle resolver resolves quality preset" {
	run bash "$SYNC"
	assert_success
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET=quality \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$BUNDLE_RESOLVE"
	assert_success
	run grep -E '^docker\.io:443$' "$output_file"
	assert_success
}
