#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-quality-lint egress and timeout inputs

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml"

@test "reusable-quality-lint: egress-policy defaults to block" {
	run awk '/^      egress-policy:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "block"'
}

@test "reusable-quality-lint: egress-preset defaults to quality" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "quality"'
}

@test "reusable-quality-lint: timeout-minutes defaults to 45" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 45'
}

@test "reusable-quality-lint: quality job uses timeout-minutes input" {
	run awk '
		/^  quality:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality:/ { in_job = 0 }
		in_job && /^    timeout-minutes: \$\{\{ inputs\.timeout-minutes \}\}$/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: hardens via checkout-and-harden composite" {
	run grep -E '^\s*uses:\s*\./\.lgtm-ci-tooling/\.github/actions/checkout-and-harden\s*$' "$WORKFLOW"
	assert_success
	run grep -F 'egress-preset: ${{ inputs.egress-preset }}' "$WORKFLOW"
	assert_success
	run grep -F 'allowed-endpoints: ${{ inputs.allowed-endpoints }}' "$WORKFLOW"
	assert_success
	run awk '
		/- name: Checkout repository/ { checkout = 1 }
		/- name: Checkout lgtm-ci tooling/ { tooling = 1 }
		tooling && /- name: Checkout and harden/ { found = 1 }
		END { exit !(checkout && tooling && found) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: tools is canonical; lintro-tools alias removed" {
	run grep -qE '^      tools:' "$WORKFLOW"
	assert_success
	run grep -qE '^      lintro-tools:' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.lintro-tools' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.tools' "$WORKFLOW"
	assert_success
}

# The report artifact is optional: reusable-publish-quality-summary downloads
# it with continue-on-error and warns when absent. A fatal upload here would
# make it mandatory to produce but optional to consume, failing builds whose
# lint actually passed (#686).
@test "reusable-quality-lint: report upload is non-fatal" {
	run awk '
		/- name: Upload linting report/ { in_step = 1 }
		in_step && /^      - name: / && !/Upload linting report/ { exit }
		in_step && /continue-on-error: true/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

# A caller may invoke this workflow twice in one run (bounded lint retry).
# Without overwrite the retry's upload 409s, continue-on-error swallows it, and
# the artifact keeps the first attempt's report — consumers then resolve a stale
# report instead of the authoritative latest one (#717).
@test "reusable-quality-lint: report upload overwrites a prior attempt" {
	run awk '
		/- name: Upload linting report/ { in_step = 1 }
		in_step && /^      - name: / && !/Upload linting report/ { exit }
		in_step && /^          overwrite: true$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

# Scoped to the warn step: workflow-wide greps would still pass if the guard
# and the warning drifted into unrelated steps.
@test "reusable-quality-lint: failed report upload warns instead of failing" {
	run awk '
		/- name: Warn on failed report upload/ { in_step = 1 }
		in_step && /^      - name: / && !/Warn on failed report upload/ { exit }
		in_step && /if: steps\.upload-report\.outcome == .failure./ { guarded = 1 }
		in_step && /::warning::Linting report upload failed/ { warned = 1 }
		END { exit !(guarded && warned) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: no failure-reason classifier output" {
	# Superseded by the non-fatal upload — transience is removed, not guessed.
	run grep -qF 'failure-reason' "$WORKFLOW"
	assert_failure
}
