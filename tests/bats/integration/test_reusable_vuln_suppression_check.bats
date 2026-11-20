#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-vuln-suppression-check workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-vuln-suppression-check.yml"

@test "reusable-vuln-suppression-check: osv-version defaults to empty" {
	run awk '/^      osv-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-vuln-suppression-check: egress-policy defaults to block" {
	run awk '/^      egress-policy:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "block"'
}

@test "reusable-vuln-suppression-check: egress-preset defaults to osv-scanner" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "osv-scanner"'
}

@test "reusable-vuln-suppression-check: allowed-endpoints-mode defaults to append" {
	run awk '/^      allowed-endpoints-mode:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "append"'
}

@test "reusable-vuln-suppression-check: declares GH_TOKEN and the App secrets optional" {
	local name
	for name in GH_TOKEN RELEASE_APP_ID RELEASE_APP_CLIENT_ID RELEASE_APP_PRIVATE_KEY; do
		run awk -v key="      ${name}:" '
			$0 == key { found = 1; next }
			found && /^      [A-Za-z_][A-Za-z0-9_-]+:/ { exit }
			found && /^        required: false$/ { ok = 1 }
			END { exit !ok }
		' "$WORKFLOW"
		assert_success
	done
}

@test "reusable-vuln-suppression-check: job grants contents and pull-requests write" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /contents: write/ { contents = 1 }
		in_job && /pull-requests: write/ { prs = 1 }
		END { exit !(contents && prs) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: checkout uses the App token, else caller GH_TOKEN" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1; next }
		checkout && /- name:/ { exit }
		checkout && /steps\.app-token\.outputs\.token/ { app = 1 }
		checkout && /\|\| secrets\.GH_TOKEN \}\}/ { fallback = 1 }
		END { exit !(app && fallback) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: default check script points to tooling script" {
	run grep -F \
		'default: ".lgtm-ci-tooling/scripts/ci/security/check-vuln-suppressions.sh"' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: hardens via checkout-and-harden composite" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1 }
		in_job && /- name: Checkout lgtm-ci tooling/ { tooling = 1 }
		in_job && tooling && /- name: Checkout and harden/ { found = 1 }
		END { exit !(checkout && tooling && found) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: installs osv-scanner before check step" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Install osv-scanner/ { install = 1 }
		install && /- name: Check suppression staleness/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: cleanup-pr-labels defaults to security labels" {
	run awk '/^      cleanup-pr-labels:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "security,dependencies,automation"'
}

@test "reusable-vuln-suppression-check: passes cleanup-pr-labels to check script" {
	run awk '
		/- name: Check suppression staleness/ { step = 1 }
		step && /CLEANUP_PR_LABELS:/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: repository checkout does not persist credentials" {
	run awk '
		/^  vuln-suppression-check:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  vuln-suppression-check:/ { in_job = 0 }
		in_job && /- name: Checkout repository/ { checkout = 1; next }
		checkout && /- name:/ { exit }
		checkout && /persist-credentials: false/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-vuln-suppression-check: default osv-scanner preset includes api.github.com" {
	run grep -F "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'osv-scanner']" "$WORKFLOW"
	assert_success
	run bash -c "source '${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh' && egress_preset_endpoints osv-scanner"
	assert_success
	assert_output --partial 'api.github.com:443'
}

@test "reusable-vuln-suppression-check: serializes cleanup runs per repository" {
	run grep -A3 '^    concurrency:$' "$WORKFLOW"
	assert_success
	assert_output --partial 'vuln-suppression-cleanup-${{ github.repository }}${{ inputs.concurrency-scope'
	assert_output --partial 'cancel-in-progress: false'
}

# Empty scope keeps the per-repository group exactly; a scope is appended
# after a `-` separator that appears only when the scope is set (#1134).
@test "reusable-vuln-suppression-check: concurrency-scope suffixes the group and defaults to per-repository" {
	run awk '/^      concurrency-scope:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'required: false'
	assert_output --partial 'type: string'
	assert_output --partial 'default: ""'
	run grep -A3 '^    concurrency:$' "$WORKFLOW"
	assert_line "        vuln-suppression-cleanup-\${{ github.repository }}\${{ inputs.concurrency-scope != '' && '-' || '' }}\${{ inputs.concurrency-scope }}"
	local eval="${PROJECT_ROOT}/tests/helpers/gha_expr.py"
	# The evaluator prints truthiness, so compare the rendered separator.
	run python3 "$eval" --value "(inputs.concurrency-scope != '' && '-' || '') == ''" "inputs.concurrency-scope="
	assert_output "true"
	run python3 "$eval" --value "(inputs.concurrency-scope != '' && '-' || '') == '-'" "inputs.concurrency-scope=refs/heads/canary/abc"
	assert_output "true"
	run python3 "$eval" --value "(inputs.concurrency-scope != '' && '-' || '') == '-'" "inputs.concurrency-scope="
	assert_output "false"
}
