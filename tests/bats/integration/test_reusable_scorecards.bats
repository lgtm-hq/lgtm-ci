#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-scorecards workflow (#329)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-scorecards.yml"

@test "reusable-scorecards: results-file defaults to results.sarif" {
	run awk '/^      results-file:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "results.sarif"'
}

@test "reusable-scorecards: scorecard step passes repo_token" {
	run awk '
		/^  scorecards:/ { in_job = 1; scorecard = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; scorecard = 0 }
		in_job && /- name: Run OpenSSF Scorecard/ { scorecard = 1 }
		in_job && scorecard && /repo_token: \$\{\{ github\.token \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: scorecard step passes results_file" {
	run awk '
		/^  scorecards:/ { in_job = 1; scorecard = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; scorecard = 0 }
		in_job && /- name: Run OpenSSF Scorecard/ { scorecard = 1 }
		in_job && scorecard && /results_file: \$\{\{ inputs\.results-file \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: upload-sarif conditional checks upload-sarif and results-format" {
	run awk '
		/^  scorecards:/ { in_job = 1; upload = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; upload = 0 }
		in_job && /- name: Upload SARIF/ { upload = 1 }
		in_job && upload && /^        if:/ {
			if ($0 ~ /inputs\.upload-sarif/ && $0 ~ /inputs\.results-format == '\''sarif'\''/) {
				found = 1
				exit
			}
		}
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: upload-sarif uses results-file input" {
	run awk '
		/^  scorecards:/ { in_job = 1; upload = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0; upload = 0 }
		in_job && /- name: Upload SARIF/ { upload = 1 }
		in_job && upload && /sarif_file: \$\{\{ inputs\.results-file \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: scorecard job uses only publish-allowlisted actions" {
	# ossf/scorecard-action publish path forbids any step besides checkout,
	# upload-artifact, upload-sarif, scorecard-action, harden-runner (#518).
	run awk '
		/^  scorecards:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0 }
		in_job && /^        uses: / {
			ok = /uses: (actions\/checkout|actions\/upload-artifact|github\/codeql-action\/upload-sarif|ossf\/scorecard-action|step-security\/harden-runner)@/
			if (!ok) { print "unallowed: " $0; bad = 1 }
		}
		END { exit bad }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-scorecards: no tooling-ref, but enforced egress inputs via the embedded preset map" {
	# The scorecard publish allowlist forbids lgtm-ci composites (#540), so
	# there is no tooling checkout to pin. The egress inputs are back since
	# #913: the preset map is a workflow literal, not a composite.
	run grep -qE '^      tooling-ref:' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.tooling-ref' "$WORKFLOW"
	assert_failure
	run grep -qF '.lgtm-ci-tooling' "$WORKFLOW"
	assert_failure
	run grep -F "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'scorecard']" "$WORKFLOW"
	assert_success
}

# PyYAML: system python3 on GitHub-hosted runners, the dev venv locally.
require_python_yaml() {
	PY=""
	local candidate
	for candidate in python3 "${PROJECT_ROOT}/.venv/bin/python"; do
		if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import yaml' 2>/dev/null; then
			PY="${candidate}"
			break
		fi
	done
	if [[ -z "${PY}" ]]; then
		# Skipping in CI would hide the contract.
		if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
			fail "no python3 with PyYAML in CI"
		fi
		skip "no python3 with PyYAML (install the dev extra)"
	fi
}

@test "reusable-scorecards: passes the Scorecard API publish verifier rules" {
	# Mirrors ossf/scorecard-infra verifyScorecardWorkflow
	# (api/app/server/verify_workflow.go): the API re-verifies this file at the
	# caller's pinned ref and drops published results on any violation, while
	# the job itself stays green (#1173, #535).
	require_python_yaml
	run "$PY" - "$WORKFLOW" <<'PY'
import sys

import yaml

ALLOWED = {
    "actions/checkout",
    "actions/create-github-app-token",
    "ossf/scorecard-action",
    "actions/upload-artifact",
    "github/codeql-action/upload-sarif",
    "step-security/harden-runner",
}
wf = yaml.safe_load(open(sys.argv[1]))
errors = []
for key in ("env", "defaults"):
    if key in wf:
        errors.append(f"workflow-level {key}")
perms = wf.get("permissions")
if perms == "write-all":
    errors.append("workflow-level write-all")
elif isinstance(perms, dict):
    errors.extend(f"workflow-level {k}: write" for k, v in perms.items() if v == "write")
jobs = wf["jobs"]
scorecard = [
    jid
    for jid, job in jobs.items()
    if any(str(s.get("uses", "")).startswith("ossf/scorecard-action@") for s in job.get("steps", []))
]
if len(scorecard) != 1:
    errors.append(f"expected one scorecard job, found {scorecard}")
else:
    job = jobs[scorecard[0]]
    for key in ("env", "defaults", "container", "services"):
        if key in job:
            errors.append(f"scorecard job {key}")
    if job.get("runs-on") != "ubuntu-latest":
        errors.append(f"scorecard job runs-on {job.get('runs-on')!r}")
    for step in job["steps"]:
        uses = step.get("uses")
        if not uses:
            errors.append(f"step without uses: {step.get('name')}")
        elif uses.split("@", 1)[0] not in ALLOWED:
            errors.append(f"unallowed step: {uses}")
for jid, job in jobs.items():
    if jid not in scorecard and (job.get("permissions") or {}).get("id-token") == "write":
        errors.append(f"{jid} has id-token: write")
print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
	assert_success
	assert_output ""
}

@test "reusable-scorecards: scorecard job takes the egress-preset job's composed allowlist" {
	# The map and the unknown-preset guard live in the egress-preset job; its
	# output carries the canonical replace/append expression (#913, #1173).
	run grep -cF "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'scorecard']" "$WORKFLOW"
	assert_output "3"
	run awk '
		/^  scorecards:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  scorecards:/ { in_job = 0 }
		in_job && /^    needs: egress-preset$/ { needs = 1 }
		in_job && /^          allowed-endpoints: \$\{\{ needs\.egress-preset\.outputs\.allowed-endpoints \}\}$/ { ae = 1 }
		END { exit !(needs && ae) }
	' "$WORKFLOW"
	assert_success
	run awk '
		/^  egress-preset:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  egress-preset:/ { in_job = 0 }
		in_job && /^    permissions: \{\}$/ { perms = 1 }
		in_job && /^      allowed-endpoints: >-$/ { out = 1 }
		in_job && /- name: Fail on unknown egress-preset/ { guard = 1 }
		END { exit !(perms && out && guard) }
	' "$WORKFLOW"
	assert_success
}
