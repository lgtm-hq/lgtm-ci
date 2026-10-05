#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-auto-rerun-on-infra-failure.yml

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-auto-rerun-on-infra-failure.yml"

@test "auto-rerun: requires run-id and run-attempt inputs" {
	local input
	for input in run-id run-attempt; do
		run awk -v name="${input}:" '
			$1 == name { in_input = 1; next }
			in_input && /required: true/ { found = 1; exit }
			in_input && /^      [a-z-]+:/ { in_input = 0 }
			END { exit !found }
		' "$WORKFLOW"
		assert_success
	done
}

@test "auto-rerun: rerun job grants actions write" {
	run grep -F "actions: write" "$WORKFLOW"
	assert_success
	run grep -F "contents: read" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: hardens egress before re-running" {
	run grep -F "harden-runner" "$WORKFLOW"
	assert_success
	run grep -F "checkout-and-harden" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: harden step selects the github-results preset by default" {
	# The first harden-runner step composes its allowlist from inputs and the
	# embedded preset map at job start (#913); an empty caller allowed-endpoints
	# falls back to the github-results preset rather than blocking checkout.
	run grep -F "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'github-results']" "$WORKFLOW"
	assert_success
	run awk '/^      egress-preset:$/{f=1;next} f&&/^      [a-z-]+:/{exit} f{print}' "$WORKFLOW"
	assert_output --partial 'default: "github-results"'
}

@test "auto-rerun: allows the results storage the #794 probe needs" {
	# `GET /actions/jobs/{id}/logs` answers 302 straight to GitHub's results
	# blob storage. Under the default block policy without it every probe dies
	# at the network layer, and the evidence table reads "unavailable" for every
	# job — indistinguishable from the raw endpoint genuinely having nothing,
	# which is the one conclusion the probe must not fake.
	#
	# Wildcarded because the redirect target is sharded (productionresultssa4
	# and productionresultssa11 observed live); the unsharded host is never the
	# target. The host lives in the github-results preset, not in a literal.
	run bash -c "source '${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh' && egress_preset_endpoints github-results"
	assert_success
	assert_output --partial "*.blob.core.windows.net:443"
	assert_output --partial "api.github.com:443"
}

@test "auto-rerun: delegates to the rerun script with no inline shell" {
	run grep -F "rerun-on-infra-failure.sh" "$WORKFLOW"
	assert_success
	run grep -F "RUN_ID: \${{ inputs.run-id }}" "$WORKFLOW"
	assert_success
	run grep -F "RUN_ATTEMPT: \${{ inputs.run-attempt }}" "$WORKFLOW"
	assert_success
	run grep -F "MAX_RERUNS: \${{ inputs.max-reruns }}" "$WORKFLOW"
	assert_success
	run grep -F "SIGNATURES: \${{ inputs.signatures }}" "$WORKFLOW"
	assert_success
	run grep -F "PROTECTED_WORKFLOWS: \${{ inputs.protected-workflows }}" "$WORKFLOW"
	assert_success
	run grep -F "PROTECTED_JOB_PATTERN: \${{ inputs.protected-job-pattern }}" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: rerun job grants checks read for the acquisition annotations (#967)" {
	run grep -cE "^      checks: read$" "$WORKFLOW"
	assert_success
	assert_output "1"
}

@test "auto-rerun: protects publish, promote, release and upload jobs by default (#967)" {
	run awk '
		/^      protected-job-pattern:/ { in_input = 1; next }
		in_input && /default: "publish\|promote\|release\|upload"/ { found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "auto-rerun: protected-workflows is opt-in and empty by default" {
	run awk '
		/^      protected-workflows:/ { in_input = 1; next }
		in_input && /default: ""/ { found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "auto-rerun: tooling checkout includes the rerun script" {
	run grep -F "sparse-checkout" "$WORKFLOW"
	assert_success
	run grep -F "scripts/ci/" "$WORKFLOW"
	assert_success
}

@test "auto-rerun: keeps the job timeout above the script's own wall-clock bounds" {
	# The script bounds itself to a ~5.5 min worst case (#743), so this job
	# timeout is an outer backstop and must stay comfortably above it — it must
	# never again be the thing that kills the safety net mid-fetch.
	run awk '
		/^      timeout-minutes:/ { in_input = 1; next }
		in_input && /^        default: / { print $2; found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	[ "$output" -ge 8 ]
}

@test "auto-rerun: the script's watchdog trips before the job timeout does" {
	# The watchdog only buys anything if it fires first. Lose that ordering and
	# the job timeout is the binding bound again — a red job and no diagnostics,
	# which is exactly the silent ten minutes of #776.
	local script="${PROJECT_ROOT}/scripts/ci/actions/rerun-on-infra-failure.sh"
	run grep -oE 'WATCHDOG_DEADLINE:=[0-9]+' "$script"
	assert_success
	local watchdog="${output##*=}"

	run awk '
		/^      timeout-minutes:/ { in_input = 1; next }
		in_input && /^        default: / { print $2; found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	[ "$watchdog" -lt $((output * 60)) ]
}

@test "auto-rerun: caps automatic re-runs at one by default" {
	run awk '
		/^      max-reruns:/ { in_input = 1; next }
		in_input && /default: "1"/ { found = 1; exit }
		in_input && /^      [a-z-]+:/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}
