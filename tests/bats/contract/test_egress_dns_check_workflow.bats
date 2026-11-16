#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for the egress allow-list DNS check workflow (#1548).
#
# The workflow runs on a schedule, holds issues: write on its one job only,
# reaches nothing but github.com, api.github.com and the two DNS-over-HTTPS
# resolvers (none of the hosts it checks), pins every action to a SHA, passes
# its dispatch input through env only and keeps its logic in
# scripts/ci/maintenance/egress-dns-check.sh.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/egress-dns-check.yml"
PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"
SYNC="${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh"
JOB="wf['jobs']['egress-dns-check']"

# Evaluate a Python expression against the parsed workflow as `wf`.
wf() {
	python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))
' "$WORKFLOW" "$1"
}

@test "egress-dns-check workflow: runs daily and on workflow_dispatch" {
	run wf "sorted(wf['on'])"
	assert_success
	assert_output "['schedule', 'workflow_dispatch']"
	run wf "[s['cron'] for s in wf['on']['schedule']]"
	assert_output --regexp "^\['[0-9]+ [0-9]+ \* \* \*'\]$"
}

@test "egress-dns-check workflow: its schedule minute is not shared with another workflow" {
	local cron minute
	cron="$(wf "wf['on']['schedule'][0]['cron']")"
	minute="${cron%% *}"
	run grep -lE "cron: '${minute} " "${PROJECT_ROOT}/.github/workflows"/*.yml
	assert_output "$WORKFLOW"
}

@test "egress-dns-check workflow: permissions are minimal" {
	run wf "wf['permissions']"
	assert_output "{}"
	run wf "list(wf['jobs'])"
	assert_output "['egress-dns-check', 'notify-failure']"
	run wf "${JOB}['permissions']"
	assert_output "{'contents': 'read', 'issues': 'write'}"
	run wf "${JOB}['timeout-minutes'] <= 10"
	assert_output "True"
}

@test "egress-dns-check workflow: every action is pinned to a full SHA" {
	run grep -E '^\s*(- )?uses:' "$WORKFLOW"
	assert_success
	[[ "${#lines[@]}" -eq 3 ]]
	local line
	for line in "${lines[@]}"; do
		# The failure notifier is this repository's own reusable workflow.
		[[ "$line" == *"uses: ./.github/workflows/reusable-main-failure-notifier.yml" ]] && continue
		[[ "$line" =~ uses:\ [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\ \#\ v[0-9] ]] ||
			fail "unpinned action: $line"
	done
}

@test "egress-dns-check workflow: a run without a verdict reaches the failure notifier" {
	local notify="wf['jobs']['notify-failure']"
	run wf "${notify}['needs']"
	assert_output "['egress-dns-check']"
	run wf "${notify}['uses']"
	assert_output "./.github/workflows/reusable-main-failure-notifier.yml"
	run wf "${notify}['with']['workflow-key']"
	assert_output "egress-dns-check"
	run wf "${notify}['permissions']"
	assert_output "{'actions': 'read', 'contents': 'read', 'issues': 'write'}"
	# Not for failing hosts (the tracking issue reports those), not for an
	# extra-hosts test run, and only on main.
	run wf "' '.join(${notify}['if'].split())"
	assert_output "failure() && github.ref == 'refs/heads/main' && needs.egress-dns-check.outputs.result != 'hosts-fail' && !(github.event_name == 'workflow_dispatch' && inputs.extra-hosts != '')"
	run wf "${JOB}['outputs']['result']"
	assert_output "\${{ steps.check.outputs.result }}"
	run wf "[s.get('id') for s in ${JOB}['steps'] if s.get('run', '').startswith('bash scripts/ci/maintenance/egress-dns-check.sh')]"
	assert_output "['check']"
}

@test "egress-dns-check workflow: hardens first in block mode with its own preset" {
	run wf "${JOB}['steps'][0]['uses'].split('@')[0]"
	assert_output "step-security/harden-runner"
	run wf "${JOB}['steps'][0]['with']['egress-policy']"
	assert_output "block"
	run grep -F "\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['egress-dns-check'] }}" "$WORKFLOW"
	assert_success
	run wf "${JOB}['steps'][1]['name']"
	assert_output "Verify harden-runner agent"
	run wf "${JOB}['steps'][2]['with']['persist-credentials']"
	assert_output "False"
	run wf "${JOB}['steps'][-1]['name']"
	assert_output "Recheck harden-runner agent"
}

@test "egress-dns-check preset: GitHub API pair plus the agent's resolvers only" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints egress-dns-check"
	assert_success
	assert_output "$(printf 'github.com:443\napi.github.com:443\ndns.google:443\ncloudflare-dns.com:443')"
	refute_output --partial '*'
	run grep -F '"egress-dns-check":"github.com:443 api.github.com:443 dns.google:443 cloudflare-dns.com:443"' "$WORKFLOW"
	assert_success
	run bash "$SYNC" --check
	assert_success
}

@test "egress-dns-check workflow: the dispatch input reaches the script through env only" {
	run wf "wf['on']['workflow_dispatch']['inputs']['extra-hosts']['type']"
	assert_output "string"
	run wf "${JOB}['steps'][-2]['env']['EXTRA_HOSTS']"
	assert_output '${{ inputs.extra-hosts }}'
	# No run: script interpolates an expression from inputs.
	run wf "[s['name'] for s in ${JOB}['steps'] if 'inputs.' in s.get('run', '')]"
	assert_output "[]"
}

@test "egress-dns-check workflow: calls the script with the job token and no inline logic" {
	# The generated harden-runner agent check and recheck (#1203) are the only
	# inline blocks; the recheck is the last step.
	run wf "[s['run'] for s in ${JOB}['steps'] if 'run' in s and s['name'] not in ('Verify harden-runner agent', 'Recheck harden-runner agent')]"
	assert_output "['bash scripts/ci/maintenance/egress-dns-check.sh']"
	run wf "${JOB}['steps'][-2]['env']['GH_TOKEN']"
	assert_output '${{ github.token }}'
	[[ -x "${PROJECT_ROOT}/scripts/ci/maintenance/egress-dns-check.sh" ]]
	run grep -F 'check-egress-dns.py' "${PROJECT_ROOT}/scripts/ci/maintenance/egress-dns-check.sh"
	assert_success
}
