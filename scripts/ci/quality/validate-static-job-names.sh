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

violations=0

while IFS= read -r -d '' workflow; do
	awk_output="$(
		awk -v file="${workflow#"${WORKFLOWS_DIR%/}/"}" '
		function flush_job() {
			if (in_job && has_if && name ~ /\$\{\{|format\(/) {
				if (name ~ /matrix\./ || name ~ /format\(/ || name ~ /&&.*\|\|/) {
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
