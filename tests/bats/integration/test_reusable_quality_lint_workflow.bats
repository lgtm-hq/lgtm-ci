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
# and the warning drifted into unrelated steps. The guard requires always() —
# without it, the implicit success() check skips this warning whenever the
# job is already failing, i.e. exactly when the upload failure matters most
# (#740).
@test "reusable-quality-lint: failed report upload warns instead of failing" {
	run awk '
		/- name: Warn on failed report upload/ { in_step = 1 }
		in_step && /^      - name: / && !/Warn on failed report upload/ { exit }
		in_step && /if: always\(\) && steps\.upload-report\.outcome == .failure./ { guarded = 1 }
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

# --------------------------------------------------------------------------
# Timeout verdict (#746)
# --------------------------------------------------------------------------

@test "reusable-quality-lint: exposes timeout-flake and timed-out-tools outputs" {
	run awk '
		/^    outputs:$/ { in_outputs = 1 }
		in_outputs && /^      timeout-flake:$/ { flake = 1 }
		in_outputs && /^      timed-out-tools:$/ { tools = 1 }
		END { exit !(flake && tools) }
	' "$WORKFLOW"
	assert_success
	run grep -F 'value: ${{ jobs.quality.outputs.timeout-flake }}' "$WORKFLOW"
	assert_success
	run grep -F 'value: ${{ jobs.quality.outputs.timed-out-tools }}' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: job forwards the classifier step outputs" {
	run grep -F 'timeout-flake: ${{ steps.classify-timeout.outputs.timeout-flake }}' \
		"$WORKFLOW"
	assert_success
	run grep -F 'timed-out-tools: ${{ steps.classify-timeout.outputs.timed-out-tools }}' \
		"$WORKFLOW"
	assert_success
}

# A timeout is exactly the case where the lint step exits non-zero, so the
# classifier must run on failure. Without always() the implicit success()
# check skips it precisely when the verdict is needed.
@test "reusable-quality-lint: classifier runs even when lint fails" {
	run awk '
		/- name: Classify lint timeout/ { in_step = 1 }
		in_step && /^      - name: / && !/Classify lint timeout/ { exit }
		in_step && /^        if: always\(\)$/ { guarded = 1 }
		in_step && /classify-lint-timeout\.py/ { invoked = 1 }
		END { exit !(guarded && invoked) }
	' "$WORKFLOW"
	assert_success
}

# The verdict is advisory. A classifier fault must never turn red a lint run
# whose code actually passed, so the step absorbs its own failure and leaves
# the outputs empty — which consumers compare as fail-closed.
@test "reusable-quality-lint: classifier cannot fail the job" {
	run awk '
		/- name: Classify lint timeout/ { in_step = 1 }
		in_step && /^      - name: / && !/Classify lint timeout/ { exit }
		in_step && /^        continue-on-error: true$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: run-quality classifier absorbs its own failure" {
	local action="${PROJECT_ROOT}/.github/actions/run-quality/action.yml"
	run awk '
		/- name: Classify lint timeout/ { in_step = 1 }
		in_step && /^    - name: / && !/Classify lint timeout/ { exit }
		in_step && /\|\| echo "::warning::lint timeout classification failed"/ {
			found = 1
		}
		END { exit !found }
	' "$action"
	assert_success
}

@test "reusable-quality-lint: classifier reads this run's own report" {
	run awk '
		/- name: Classify lint timeout/ { in_step = 1 }
		in_step && /^      - name: / && !/Classify lint timeout/ { exit }
		in_step && /REPORT: \.lintro\/artifacts\/json\/results\.json/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: upload-json-report defaults to true" {
	run awk '/^      upload-json-report:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "default: true"
	assert_output --partial "type: boolean"
}

# The verdict must not depend on the artifact: a caller may want the outputs
# with upload-json-report disabled.
@test "reusable-quality-lint: classifier is not gated on upload-json-report" {
	run awk '
		/- name: Classify lint timeout/ { in_step = 1 }
		in_step && /^      - name: / && !/Classify lint timeout/ { exit }
		in_step && /upload-json-report/ { found = 1 }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: JSON report upload is non-fatal and overwrites" {
	run awk '
		/- name: Upload lint JSON report/ { in_step = 1 }
		in_step && /^      - name: / && !/Upload lint JSON report/ { exit }
		in_step && /continue-on-error: true/ { nonfatal = 1 }
		in_step && /^          overwrite: true$/ { overwrite = 1 }
		in_step && /name: linting-json-report/ { named = 1 }
		END { exit !(nonfatal && overwrite && named) }
	' "$WORKFLOW"
	assert_success
}

# Backwards compatibility: a caller that sets no new inputs and reads no new
# outputs must behave exactly as today. Every new input is optional with a
# default, and the pre-existing outputs keep their names and wiring.
@test "reusable-quality-lint: new inputs are optional" {
	run awk '/^      upload-json-report:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "required: false"
}

@test "reusable-quality-lint: pre-existing outputs are unchanged" {
	run grep -F 'value: ${{ jobs.quality.outputs.exit-code }}' "$WORKFLOW"
	assert_success
	run grep -F 'value: ${{ jobs.quality.outputs.status }}' "$WORKFLOW"
	assert_success
	run grep -F 'exit-code: ${{ steps.quality.outputs.exit-code }}' "$WORKFLOW"
	assert_success
	run grep -F 'status: ${{ steps.quality.outputs.status }}' "$WORKFLOW"
	assert_success
}

@test "reusable-quality-lint: every workflow_call input has a default" {
	run awk '
		/^  workflow_call:$/ { in_call = 1 }
		in_call && /^    inputs:$/ { in_inputs = 1; next }
		in_inputs && /^    [a-z]/ { in_inputs = 0 }
		in_inputs && /^      [a-z0-9-]+:$/ {
			if (name != "" && !has_default) { print "missing default: " name; bad = 1 }
			name = $1; has_default = 0
		}
		in_inputs && /^        default:/ { has_default = 1 }
		END {
			if (name != "" && !has_default) { print "missing default: " name; bad = 1 }
			exit bad
		}
	' "$WORKFLOW"
	assert_success
	assert_output ""
}

@test "reusable-quality-lint: run-quality action exposes the same verdict outputs" {
	local action="${PROJECT_ROOT}/.github/actions/run-quality/action.yml"
	run grep -F 'value: ${{ steps.classify-timeout.outputs.timeout-flake }}' "$action"
	assert_success
	run grep -F 'value: ${{ steps.classify-timeout.outputs.timed-out-tools }}' "$action"
	assert_success
	run grep -F 'classify-lint-timeout.py' "$action"
	assert_success
}
