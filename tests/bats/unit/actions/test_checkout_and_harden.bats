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

@test "checkout-and-harden: does not nest step-security/harden-runner " {
	run grep -E 'step-security/harden-runner|/\.github/actions/harden-runner' "$ACTION"
	# Sparse path mention of harden-runner directory is required for resolve sibling;
	# the composite must not *invoke* the local harden-runner action or step-security.
	run awk '
		/uses:[[:space:]]+step-security\/harden-runner/ { bad = 1 }
		/uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/harden-runner/ { bad = 1 }
		END { exit bad }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: resolve step runs and exposes allowed-endpoints" {
	run grep -F \
		"uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist" \
		"$ACTION"
	assert_success
	run grep -F \
		"value: \${{ steps.egress.outputs['allowed-endpoints'] }}" \
		"$ACTION"
	assert_success
}

@test "checkout-and-harden: documents direct step-security follow-up " {
	run grep -F 'step-security/harden-runner@' "$ACTION"
	assert_success
}

@test "checkout-and-harden: tooling checkout is pinned to the workflow checkout SHA" {
	local pin
	pin=$(grep -oE 'actions/checkout@[0-9a-f]{40}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml" | head -1)
	run grep -F "$pin" "$ACTION"
	assert_success
}
