#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when reusable workflow jobs combine skip conditions with dynamic job.name expressions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
WORKFLOWS_DIR="${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}"

if [[ ! -d "${WORKFLOWS_DIR}" ]]; then
	echo "ERROR: workflows directory not found: ${WORKFLOWS_DIR}" >&2
	exit 1
fi

# Documented exceptions: workflow:job-id pairs intentionally allowed to combine
# an expression-based name: with a job-level if:. Each entry MUST have team
# sign-off and a rationale in docs/workflow-contract.md.
#
# Draft-PR skip pattern (always runs on non-PR events; callers document the
# check is not required on drafts):
#   reusable-test-node.yml:test-vitest
#   reusable-site-quality.yml:site-build-link
#   reusable-site-quality.yml:site-test
#   reusable-test-python.yml:test
#   reusable-test-node-custom.yml:test
#   reusable-test-shell.yml:test
#   reusable-rust-test.yml:test
#   reusable-test-e2e.yml:test
#   reusable-test-rust-build.yml:build
#
# Event-gated (check is not required so skip does not block merge):
#   reusable-dependency-review.yml:dependency-review
#
# Uses always() — never actually skips; conditional-success gate:
#   reusable-required-check.yml:gate
STATIC_JOB_NAME_EXCEPTIONS="${STATIC_JOB_NAME_EXCEPTIONS-reusable-dependency-review.yml:dependency-review reusable-required-check.yml:gate reusable-test-e2e.yml:test reusable-test-rust-build.yml:build reusable-test-node.yml:test-vitest reusable-site-quality.yml:site-build-link reusable-site-quality.yml:site-test reusable-test-python.yml:test reusable-test-node-custom.yml:test reusable-test-shell.yml:test reusable-rust-test.yml:test}"

violations=0

while IFS= read -r -d '' workflow; do
	rel_file="${workflow#"${WORKFLOWS_DIR%/}/"}"
	awk_output="$(
		awk -v file="${rel_file}" -v exceptions="${STATIC_JOB_NAME_EXCEPTIONS}" '
		BEGIN {
			n = split(exceptions, arr, " ")
			for (i = 1; i <= n; i++) {
				if (arr[i] != "") exempt[arr[i]] = 1
			}
		}
		function flush_job() {
			if (in_job && has_if && name ~ /\$\{\{/) {
				key = file ":" job_id
				if (!(key in exempt)) {
					printf("%s:%d: job %s uses dynamic job.name with if:\n  %s\n", file, name_line, job_id, name)
					violations++
				}
			}
			in_job = 0
			has_if = 0
			name = ""
			job_id = ""
			name_line = 0
		}
		function append_pending(line) {
			if (pending == "") {
				pending = line
			} else {
				pending = pending " " line
			}
		}
		function finalize_name() {
			if (pending != "") {
				name = pending
				pending = ""
			}
		}
		/^  [a-zA-Z0-9_-]+:$/ {
			flush_job()
			job_id = $1
			sub(/:$/, "", job_id)
			in_job = 1
			next
		}
		in_job && /^    if:/ {
			has_if = 1
			next
		}
		in_job && /^    name:/ {
			name = $0
			sub(/^    name:[[:space:]]*/, "", name)
			name_line = NR
			pending = ""
			if (name ~ /^[>|][-+]?$/) {
				while ((getline continuation) > 0) {
					if (continuation ~ /^    if:/) {
						has_if = 1
					}
					if (continuation ~ /^    [a-zA-Z0-9_-]+:/) {
						break
					}
					if (continuation !~ /^[[:space:]]/) {
						break
					}
					sub(/^[[:space:]]+/, "", continuation)
					append_pending(continuation)
				}
				finalize_name()
			}
			next
		}
		END {
			flush_job()
			printf("VIOLATIONS:%d\n", violations)
		}
	' "${workflow}"
	)"
	awk_count="${awk_output##*VIOLATIONS:}"
	awk_count="${awk_count%%$'\n'*}"
	if [[ -z "${awk_count}" || ! "${awk_count}" =~ ^[0-9]+$ ]]; then
		echo "ERROR: failed to parse violations from ${workflow}" >&2
		printf '%s\n' "${awk_output}" >&2
		exit 1
	fi
	if [[ "${awk_count}" -gt 0 ]]; then
		printf '%s\n' "${awk_output}" | grep -v '^VIOLATIONS:' >&2 || true
	fi
	violations=$((violations + awk_count))
done < <(find "${WORKFLOWS_DIR}" -maxdepth 1 -name 'reusable-*.yml' -print0)

if [[ ${violations} -gt 0 ]]; then
	echo "ERROR: ${violations} reusable workflow job(s) violate static job.name policy" >&2
	exit 1
fi

echo "OK: reusable workflow job names satisfy static-name policy"
