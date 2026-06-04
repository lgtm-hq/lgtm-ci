#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables use local harden-runner (same-repository composite pattern)
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HARDEN_ACTION="$REPO_ROOT/.github/actions/harden-runner/action.yml"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

HARDEN_USES_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/harden-runner([[:space:]]|$)'
RESOLVE_USES_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/resolve-egress-allowlist([[:space:]]|$)'

violations=0

discover_workflow_files() {
	find "$WORKFLOWS_DIR" \( -name 'reusable-*.yml' -o -name 'renovate.yml' \) -print0
}

_check_job_egress_order() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	while IFS= read -r msg; do
		[[ -z "$msg" ]] && continue
		echo "$msg" >&2
		violations=$((violations + 1))
	done < <(
		awk -v wf="$wf_name" '
			function report(msg) {
				print wf ": " msg
			}
			BEGIN {
				in_jobs = 0
				resolve_line = 0
			}
			/^jobs:/ {
				in_jobs = 1
				next
			}
			!in_jobs {
				next
			}
			/^  [a-zA-Z_][a-zA-Z0-9_-]*: *$/ {
				resolve_line = 0
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+\.\/\.github\/actions\/resolve-egress-allowlist([[:space:]]|$)/ {
				resolve_line = NR
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+\.\/\.github\/actions\/harden-runner([[:space:]]|$)/ {
				if (resolve_line == 0 || resolve_line >= NR) {
					report("resolve-egress-allowlist must appear before harden-runner (harden-runner at line " NR ")")
				}
				resolve_line = 0
				next
			}
		' "$workflow"
	)
}

_check_harden_with_blocks() {
	local workflow="$1"
	local wf_name="${workflow##*/}"
	local line_num
	local block
	local next_step_re='^[[:space:]]{6}- (name|uses|run):'

	while IFS= read -r line_num; do
		[[ -z "$line_num" ]] && continue
		block="$(
			awk -v start="$line_num" -v stop_re="$next_step_re" '
				NR == start { print; next }
				NR > start {
					if ($0 ~ stop_re) {
						exit
					}
					print
				}
			' "$workflow"
		)"
		if grep -qE 'egress-preset:' <<<"$block"; then
			echo "${wf_name}:${line_num}: pass egress-preset to resolve-egress-allowlist, not harden-runner" >&2
			violations=$((violations + 1))
		fi
	done < <(grep -nE "$HARDEN_USES_RE" "$workflow" | cut -d: -f1)
}

while IFS= read -r -d '' file; do
	line_num=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ "$line" == *"lgtm-hq/lgtm-ci/.github/actions/harden-runner@"* ]]; then
			echo "$file:$line_num: use ./.github/actions/harden-runner (remote @sha breaks PR refs)" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" == *".lgtm-ci-egress"* ]]; then
			echo "$file:$line_num: remove .lgtm-ci-egress workaround" >&2
			violations=$((violations + 1))
		fi
	done <"$file"
done < <(discover_workflow_files)

if grep -qE "steps\.resolve\.outputs\['allowed-endpoints'\]" "$HARDEN_ACTION"; then
	echo "harden-runner/action.yml: must pass inputs['allowed-endpoints'] (pre-hook cannot read composite step outputs)" >&2
	violations=$((violations + 1))
fi

if ! grep -qE 'allowed-endpoints:[[:space:]]+\$\{\{[[:space:]]+inputs\[.allowed-endpoints.\]' "$HARDEN_ACTION"; then
	echo "harden-runner/action.yml: must forward allowed-endpoints from inputs['allowed-endpoints']" >&2
	violations=$((violations + 1))
fi

if grep -qE "^\s+egress-preset:" "$HARDEN_ACTION"; then
	echo "harden-runner/action.yml: egress-preset belongs on resolve-egress-allowlist, not harden-runner" >&2
	violations=$((violations + 1))
fi

while IFS= read -r -d '' workflow; do
	[[ -f "$workflow" ]] || continue
	if ! grep -qE "$HARDEN_USES_RE" "$workflow"; then
		continue
	fi
	if ! grep -qE "$RESOLVE_USES_RE" "$workflow"; then
		echo "${workflow##*/}: uses harden-runner but missing resolve-egress-allowlist step" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qF "steps.egress.outputs['allowed-endpoints']" "$workflow"; then
		echo "${workflow##*/}: harden-runner must use steps.egress.outputs['allowed-endpoints']" >&2
		violations=$((violations + 1))
	fi
	_check_job_egress_order "$workflow"
	_check_harden_with_blocks "$workflow"
done < <(discover_workflow_files)

while IFS= read -r -d '' workflow; do
	[[ -f "$workflow" ]] || continue
	if ! grep -qE '^[[:space:]]*steps:[[:space:]]*$' "$workflow"; then
		continue
	fi
	if ! grep -qE "$HARDEN_USES_RE" "$workflow"; then
		echo "${workflow##*/}: missing ./.github/actions/harden-runner step" >&2
		violations=$((violations + 1))
	fi
done < <(find "$WORKFLOWS_DIR" -name 'reusable-*.yml' -print0)

if [[ $violations -gt 0 ]]; then
	exit 1
fi

echo "All reusables use resolve-egress-allowlist + ./.github/actions/harden-runner"
