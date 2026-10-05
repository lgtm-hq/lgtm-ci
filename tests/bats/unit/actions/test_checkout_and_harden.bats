#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the checkout-and-harden composite action

load "../../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/checkout-and-harden/action.yml"

@test "checkout-and-harden: action.yml exists" {
	[ -f "$ACTION" ]
}

@test "checkout-and-harden: declares the contract inputs" {
	for input in tooling-ref tooling-repository tooling-ref-override \
		sparse-checkout-extra persist-credentials; do
		run grep -E "^  ${input}:" "$ACTION"
		assert_success
	done
}

@test "checkout-and-harden: takes no egress inputs and emits no allowlist (#913)" {
	# harden-runner's pre hook cannot see anything this composite produces,
	# so offering egress inputs here would be decorative.
	for key in egress-policy egress-preset allowed-endpoints allowed-endpoints-mode; do
		run grep -E "^  ${key}:" "$ACTION"
		assert_failure
	done
	run grep -F "resolve-egress-allowlist" "$ACTION"
	assert_failure
}

@test "checkout-and-harden: declares the scripts-dir output only" {
	run grep -E "^  scripts-dir:" "$ACTION"
	assert_success
	run grep -E "^  allowed-endpoints:" "$ACTION"
	assert_failure
}

@test "checkout-and-harden: tooling checkout uses the resolved inputs, never caller context (#995)" {
	run grep -F 'repository: ${{ inputs.tooling-repository }}' "$ACTION"
	assert_success
	run grep -F 'ref: ${{ inputs.tooling-ref }}' "$ACTION"
	assert_success
	run grep -E 'github\.workflow_sha|job\.workflow_sha' "$ACTION"
	# Only the input description may mention job.workflow_sha; no expression does.
	refute_output --partial '${{'
}

@test "checkout-and-harden: tooling-ref is required and tooling-repository defaults to lgtm-ci" {
	run awk '
		/^  tooling-ref:/ { found = 1 }
		found && /^    required: true/ { ok = 1; exit }
		found && /^  [a-z]/ && !/^  tooling-ref:/ { exit }
		END { exit !ok }
	' "$ACTION"
	assert_success
	run awk '
		/^  tooling-repository:/ { found = 1 }
		found && /^    default: "lgtm-hq\/lgtm-ci"/ { ok = 1; exit }
		found && /^  [a-z]/ && !/^  tooling-repository:/ { exit }
		END { exit !ok }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: warns when the caller still passes tooling-ref" {
	run grep -F "inputs.tooling-ref-override != ''" "$ACTION"
	assert_success
	run grep -F "hashFiles('.lgtm-ci-tooling/scripts/ci/actions/warn-tooling-ref-override.sh') != ''" "$ACTION"
	assert_success
	run grep -F "scripts/ci/actions/warn-tooling-ref-override.sh" "$ACTION"
	assert_success
	# The warning script lives under scripts/ci/actions, so that path must be
	# in the composite's own sparse set (callers may not add it).
	run grep -F "          scripts/ci/actions" "$ACTION"
	assert_success
}

@test "checkout-and-harden: base sparse checkout covers itself and scripts/ci/actions" {
	for path in ".github/actions/checkout-and-harden" "scripts/ci/actions"; do
		run grep -F "          ${path}" "$ACTION"
		assert_success
	done
	run grep -E '\.github/actions/(harden-runner|resolve-egress-allowlist)' "$ACTION"
	assert_failure
}

@test "checkout-and-harden: appends sparse-checkout-extra to the sparse set" {
	run grep -F '${{ inputs.sparse-checkout-extra }}' "$ACTION"
	assert_success
}

@test "checkout-and-harden: does not nest step-security/harden-runner " {
	# The composite must not *invoke* step-security (nested pre/post hooks are
	# skipped) nor any local harden-runner action.
	run awk '
		/uses:[[:space:]]+step-security\/harden-runner/ { bad = 1 }
		/uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/harden-runner/ { bad = 1 }
		END { exit bad }
	' "$ACTION"
	assert_success
}

@test "checkout-and-harden: documents that the direct step-security step runs first" {
	run grep -F 'step-security/harden-runner@' "$ACTION"
	assert_success
	run grep -F 'FIRST' "$ACTION"
	assert_success
}

@test "checkout-and-harden: tooling checkout is pinned to the workflow checkout SHA" {
	local pin
	pin=$(grep -oE 'actions/checkout@[0-9a-f]{40}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml" | head -1)
	run grep -F "$pin" "$ACTION"
	assert_success
}

@test "checkout-and-harden: fails before any checkout when the resolved tooling-ref is empty" {
	run grep -F "if: inputs.tooling-ref == ''" "$ACTION"
	assert_success
	run awk '/Require a resolved tooling ref/ { seen_guard = NR } /Checkout lgtm-ci tooling/ { if (seen_guard && NR > seen_guard) ok = 1 } END { exit !ok }' "$ACTION"
	assert_success
	run bash "${PROJECT_ROOT}/.github/actions/checkout-and-harden/require-tooling-ref.sh"
	assert_failure
	assert_output --partial "::error title=tooling-ref required::"
}
