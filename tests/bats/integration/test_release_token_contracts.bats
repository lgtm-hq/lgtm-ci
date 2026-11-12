#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Workflow contracts for how the reusable workflows obtain tokens (#1367).
#
# 1. `secrets.*` is not available to `if:` expressions on steps in a reusable
#    workflow in the way authors expect (an unset secret evaluates to an empty
#    string, so a "was it provided" guard silently skips). Credential choice
#    is therefore written to a step output by a fail-closed step, and `if:`
#    conditions never reference `secrets.`.
# 2. Every release-pipeline job that pushes a commit, creates a tag or release
#    or merges must use a token minted in the same job (GitHub App installation
#    token). `github.token` writes do not start downstream workflows, so a
#    release that "succeeds" with it leaves CI, tag and publish workflows
#    silently un-triggered.

load "../../helpers/common"

# Print "file:line: text" for every `if:` expression (single-line or folded /
# block scalar continuation) in the given workflow that references `secrets.`.
_secrets_in_if() {
	python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path).read().splitlines()
i = 0
while i < len(lines):
    m = re.match(r"^(\s*)(?:-\s+)?if:\s*(.*)$", lines[i])
    if not m:
        i += 1
        continue
    indent = len(m.group(1))
    chunk = [m.group(2)]
    j = i + 1
    while j < len(lines):
        nxt = lines[j]
        if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
            break
        chunk.append(nxt)
        j += 1
    body = "\n".join(c for c in chunk if not c.strip().startswith("#"))
    if "secrets." in body:
        print(f"{path}:{i + 1}: {chunk[0]}")
    i = j
PY
}

# Print "workflow job writer mint ghtoken" for every job that performs a
# release-pipeline write (script or inline command), with counts of
# create-github-app-token steps and github.token references in that job.
_write_jobs() {
	python3 - "$@" <<'PY'
import os
import re
import sys

WRITE = re.compile(
    r"(create-tag|create-github-release|update-floating-tag|enable-auto-merge"
    r"|create-signed-commit)\.sh"
    r"|git push|gh release (create|upload|edit)|gh pr merge|git tag [^-]"
)
TOOLING_TOKEN = "token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}"
for path in sys.argv[1:]:
    jobs = {}
    job = None
    in_jobs = False
    for line in open(path):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if in_jobs and m:
            job = m.group(1)
            jobs[job] = [0, 0, 0]
            continue
        if not (in_jobs and job) or line.strip().startswith("#"):
            continue
        if WRITE.search(line):
            jobs[job][0] += 1
        if "actions/create-github-app-token" in line:
            jobs[job][1] += 1
        # The read-only tooling checkout (#1451) falls back to github.token
        # to read lgtm-ci; it is not a release write.
        if line.strip() == TOOLING_TOKEN:
            continue
        if re.search(r"github\.token|secrets\.GITHUB_TOKEN", line):
            jobs[job][2] += 1
    for name, (writes, mints, ghtok) in jobs.items():
        if writes:
            print(os.path.basename(path), name, writes, mints, ghtok)
PY
}

@test "no reusable workflow references secrets in an if: expression" {
	local offenders="" found wf
	for wf in "${PROJECT_ROOT}"/.github/workflows/reusable-*.yml; do
		found="$(_secrets_in_if "$wf")"
		[ -z "$found" ] || offenders+="${found}"$'\n'
	done

	[ -z "$offenders" ] || {
		echo "secrets.* referenced in if: expressions:" >&2
		echo "$offenders" >&2
		false
	}
}

@test "secrets-in-if detector flags a violating fixture" {
	local fixture="${BATS_TEST_TMPDIR}/bad.yml"
	cat >"$fixture" <<'YAML'
jobs:
  a:
    steps:
      - name: x
        if: >-
          secrets.FOO != ''
        run: true
YAML

	run _secrets_in_if "$fixture"
	assert_success
	assert_output --partial "bad.yml"
}

@test "release-pipeline jobs that push, tag, release or merge use a step-minted token" {
	# Allow-list (job names are `<workflow file>:<job>`). Each entry needs a
	# reason; do not extend it to dodge the contract.
	#  - reusable-release-recover-resume.yml:resume-github-release republishes
	#    the GitHub release for a tag that already exists during recovery. It
	#    runs only after a human dispatches recovery, so a missing downstream
	#    trigger is recoverable by re-running; it is tracked separately.
	# The failure-notifier workflows (reusable-release-failure-notifier.yml,
	# reusable-main-failure-notifier.yml) only open or comment on issues and
	# are excluded because they perform none of the guarded writes.
	local allow=" reusable-release-recover-resume.yml:resume-github-release "
	local bad="" count=0
	local wf job writes mints ghtok
	while read -r wf job writes mints ghtok; do
		[ -n "$wf" ] || continue
		if [[ "$allow" == *" ${wf}:${job} "* ]]; then
			continue
		fi
		count=$((count + 1))
		if [ "$mints" -lt 1 ] || [ "$ghtok" -gt 0 ]; then
			bad+="${wf}:${job} (mint steps=${mints}, github.token refs=${ghtok})"$'\n'
		fi
	done < <(_write_jobs "${PROJECT_ROOT}"/.github/workflows/reusable-release-*.yml)

	# Guard against the scan silently matching nothing.
	[ "$count" -ge 3 ]
	[ -z "$bad" ] || {
		echo "release writes without a step-minted token:" >&2
		echo "$bad" >&2
		false
	}
}

@test "write-job scan finds the auto-tag, version-pr and multi-ecosystem jobs" {
	run _write_jobs "${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml" \
		"${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml" \
		"${PROJECT_ROOT}/.github/workflows/reusable-release-multi-ecosystem.yml"
	assert_success
	assert_output --partial "reusable-release-auto-tag.yml auto-tag"
	assert_output --partial "reusable-release-version-pr.yml version-pr"
	assert_output --partial "reusable-release-multi-ecosystem.yml version-pr"
}
