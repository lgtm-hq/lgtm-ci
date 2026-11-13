#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for the results storage hosts drift workflow (#1498).
#
# The workflow runs on a schedule, holds issues: write on its one job only,
# reaches nothing but github.com and api.github.com (in particular none of the
# results storage hosts it compares), pins every action to a SHA and keeps
# its logic in scripts/ci/maintenance/results-hosts-drift.sh.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/results-hosts-drift.yml"
PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"
SYNC="${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh"

# Evaluate a Python expression against the parsed workflow as `wf`.
wf() {
	python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))
' "$WORKFLOW" "$1"
}

@test "results-hosts-drift workflow: runs daily and on workflow_dispatch" {
	run wf "sorted(wf['on'])"
	assert_success
	assert_output "['schedule', 'workflow_dispatch']"
	run wf "[s['cron'] for s in wf['on']['schedule']]"
	assert_output --regexp "^\['[0-9]+ [0-9]+ \* \* \*'\]$"
}

@test "results-hosts-drift workflow: permissions are minimal" {
	run wf "wf['permissions']"
	assert_output "{}"
	run wf "list(wf['jobs'])"
	assert_output "['results-hosts-drift']"
	run wf "wf['jobs']['results-hosts-drift']['permissions']"
	assert_output "{'contents': 'read', 'issues': 'write'}"
}

@test "results-hosts-drift workflow: every action is pinned to a full SHA" {
	run grep -E '^\s*(- )?uses:' "$WORKFLOW"
	assert_success
	[[ "${#lines[@]}" -eq 2 ]]
	run grep -E '^\s*(- )?uses:' "$WORKFLOW"
	local line
	for line in "${lines[@]}"; do
		[[ "$line" =~ uses:\ [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\ \#\ v[0-9] ]] ||
			fail "unpinned action: $line"
	done
}

@test "results-hosts-drift workflow: hardens first in block mode with its own preset" {
	run wf "wf['jobs']['results-hosts-drift']['steps'][0]['uses'].split('@')[0]"
	assert_output "step-security/harden-runner"
	run wf "wf['jobs']['results-hosts-drift']['steps'][0]['with']['egress-policy']"
	assert_output "block"
	run grep -F "\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['results-hosts-drift'] }}" "$WORKFLOW"
	assert_success
	run wf "wf['jobs']['results-hosts-drift']['steps'][1]['name']"
	assert_output "Verify harden-runner agent"
	run wf "wf['jobs']['results-hosts-drift']['steps'][2]['with']['persist-credentials']"
	assert_output "False"
}

@test "results-hosts-drift preset: exactly the GitHub API pair, no results storage" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints results-hosts-drift"
	assert_success
	assert_output "$(printf 'github.com:443\napi.github.com:443')"
	refute_output --partial 'blob.core.windows.net'
	run grep -F '"results-hosts-drift":"github.com:443 api.github.com:443"' "$WORKFLOW"
	assert_success
	run bash "$SYNC" --check
	assert_success
}

@test "results-hosts-drift workflow: calls the script with the job token and no inline logic" {
	# The generated harden-runner agent check (#1203) is the one inline block.
	run wf "[s['run'] for s in wf['jobs']['results-hosts-drift']['steps'] if 'run' in s and s['name'] != 'Verify harden-runner agent']"
	assert_output "['bash scripts/ci/maintenance/results-hosts-drift.sh']"
	run wf "wf['jobs']['results-hosts-drift']['steps'][-1]['env']['GH_TOKEN']"
	assert_output '${{ github.token }}'
	[[ -x "${PROJECT_ROOT}/scripts/ci/maintenance/results-hosts-drift.sh" ]]
	run grep -F 'check-results-hosts-drift.py' "${PROJECT_ROOT}/scripts/ci/maintenance/results-hosts-drift.sh"
	assert_success
}
