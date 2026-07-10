#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Guard that validator HARDEN_SHA matches the canonical workflow pin

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh"
CANONICAL_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-validate.yml"

@test "harden-runner SHA: validator HARDEN_SHA matches canonical reusable-validate.yml pin" {
	local validator_sha workflow_sha
	validator_sha="$(
		sed -nE "s/^HARDEN_SHA='([a-f0-9]{40})'.*/\1/p" "$VALIDATOR" | head -1
	)"
	workflow_sha="$(
		sed -nE 's/.*step-security\/harden-runner@([a-f0-9]{40}).*/\1/p' \
			"$CANONICAL_WORKFLOW" | head -1
	)"
	[[ -n "$validator_sha" ]]
	[[ -n "$workflow_sha" ]]
	if [[ "$validator_sha" != "$workflow_sha" ]]; then
		echo "HARDEN_SHA drift: validator=${validator_sha} workflow=${workflow_sha}" >&2
		return 1
	fi
}
