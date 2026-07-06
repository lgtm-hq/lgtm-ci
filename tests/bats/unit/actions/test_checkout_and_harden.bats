#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the checkout-and-harden composite action

load "../../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/checkout-and-harden/action.yml"

@test "checkout-and-harden: action.yml exists" {
	[ -f "$ACTION" ]
}

@test "checkout-and-harden: declares the contract inputs" {
	for input in tooling-ref egress-policy egress-preset allowed-endpoints \
		allowed-endpoints-mode sparse-checkout-extra persist-credentials; do
		run grep -E "^  ${input}:" "$ACTION"
		assert_success
	done
}

@test "checkout-and-harden: declares allowed-endpoints and scripts-dir outputs" {
	run grep -E "^  allowed-endpoints:" "$ACTION"
	assert_success
	run grep -E "^  scripts-dir:" "$ACTION"
	assert_success
}

@test "checkout-and-harden: egress-policy defaults to block" {
	run awk '
		/^  egress-policy:/ { found = 1 }
		found && /^    default: "block"/ { ok = 1; exit }
		found && /^  [a-z]/ && !/^  egress-policy:/ { exit }
		END { exit !ok }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: allowed-endpoints-mode defaults to replace" {
	run awk '
		/^  allowed-endpoints-mode:/ { found = 1 }
		found && /^    default: "replace"/ { ok = 1; exit }
		found && /^  [a-z]/ && !/^  allowed-endpoints-mode:/ { exit }
		END { exit !ok }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: tooling checkout falls back to github.workflow_sha" {
	run grep -F \
		"ref: \${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.workflow_sha }}" \
		"$ACTION"
	assert_success
}

@test "checkout-and-harden: base sparse checkout covers egress composites and itself" {
	for path in ".github/actions/checkout-and-harden" \
		".github/actions/harden-runner" \
		".github/actions/resolve-egress-allowlist"; do
		run grep -F "          ${path}" "$ACTION"
		assert_success
	done
}

@test "checkout-and-harden: appends sparse-checkout-extra to the sparse set" {
	run grep -F '${{ inputs.sparse-checkout-extra }}' "$ACTION"
	assert_success
}

@test "checkout-and-harden: resolve step runs before harden step" {
	run awk '
		/uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/resolve-egress-allowlist/ { resolve = NR }
		/uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/harden-runner/ { harden = NR }
		END { exit !(resolve && harden && resolve < harden) }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: harden step consumes the resolve sibling output" {
	run grep -F \
		"allowed-endpoints: \${{ steps.egress.outputs['allowed-endpoints'] }}" \
		"$ACTION"
	assert_success
}

@test "checkout-and-harden: tooling checkout is pinned to the workflow checkout SHA" {
	local pin
	pin=$(grep -oE 'actions/checkout@[0-9a-f]{40}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml" | head -1)
	run grep -F "$pin" "$ACTION"
	assert_success
}
