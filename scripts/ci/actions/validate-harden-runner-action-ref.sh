#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables load egress composites via .lgtm-ci-tooling checkout (#279)
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HARDEN_ACTION="$REPO_ROOT/.github/actions/harden-runner/action.yml"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

TOOLING_RESOLVE_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/resolve-egress-allowlist[[:space:]]*$'
TOOLING_HARDEN_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/harden-runner[[:space:]]*$'
IN_REPO_RESOLVE_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/resolve-egress-allowlist[[:space:]]*$'
IN_REPO_HARDEN_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/harden-runner[[:space:]]*$'
REMOTE_EGRESS_RE='lgtm-hq/lgtm-ci/\.github/actions/(harden-runner|resolve-egress-allowlist)@'

violations=0

discover_reusable_workflows() {
	find "$WORKFLOWS_DIR" -name 'reusable-*.yml' -print0
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
				tooling_line = 0
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
				tooling_line = 0
				resolve_line = 0
				next
			}
			$0 ~ /^[[:space:]]+- name: Checkout lgtm-ci egress tooling/ {
				tooling_line = NR
				next
			}
			$0 ~ /^[[:space:]]+- name: Checkout lgtm-ci tooling/ {
				if (resolve_line == 0) {
					tooling_line = NR
				}
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/resolve-egress-allowlist/ {
				if (tooling_line == 0 || tooling_line >= NR) {
					report("Checkout lgtm-ci tooling must precede resolve-egress-allowlist (resolve at line " NR ")")
				}
				resolve_line = NR
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/harden-runner/ {
				if (resolve_line == 0 || resolve_line >= NR) {
					report("resolve-egress-allowlist must appear before harden-runner (harden-runner at line " NR ")")
				}
				if (tooling_line == 0 || tooling_line >= NR) {
					report("Checkout lgtm-ci tooling must precede harden-runner (harden-runner at line " NR ")")
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
	done < <(grep -nE "$TOOLING_HARDEN_RE" "$workflow" | cut -d: -f1)
}

_check_release_two_phase_sparse() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	[[ -f "$workflow" ]] || return 0
	grep -q 'Checkout lgtm-ci egress tooling' "$workflow" || return 0

	while IFS= read -r msg; do
		[[ -z "$msg" ]] && continue
		echo "$msg" >&2
		violations=$((violations + 1))
	done < <(
		awk -v wf="$wf_name" '
			/Checkout lgtm-ci egress tooling/ { saw_egress = 1 }
			saw_egress && /- name: Checkout lgtm-ci tooling/ { block = 1 }
			saw_egress && /- name: Restore tooling for post-PR steps/ { block = 1 }
			block && /^[[:space:]]+sparse-checkout: scripts\/ci\/$/ {
				print wf ": sparse-checkout after egress tooling must include egress composites (not scripts/ci/ only)"
				block = 0
			}
			block && /^[[:space:]]+sparse-checkout: \|/ {
				in_sparse = 1
				has_scripts = 0
				has_harden = 0
				has_resolve = 0
				next
			}
			in_sparse && /scripts\/ci\// { has_scripts = 1 }
			in_sparse && /\.github\/actions\/harden-runner/ { has_harden = 1 }
			in_sparse && /\.github\/actions\/resolve-egress-allowlist/ { has_resolve = 1 }
			in_sparse && /^[[:space:]]+[a-zA-Z]/ && !/^[[:space:]]+\./ && !/^[[:space:]]+scripts/ {
				if (!has_scripts || !has_harden || !has_resolve) {
					print wf ": multiline sparse-checkout after egress tooling must include scripts/ci/, harden-runner, and resolve-egress-allowlist"
				}
				in_sparse = 0
				block = 0
			}
		' "$workflow"
	)
}

while IFS= read -r -d '' file; do
	line_num=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ "$line" =~ $REMOTE_EGRESS_RE ]]; then
			echo "$file:$line_num: do not use remote lgtm-hq/lgtm-ci egress action refs (use .lgtm-ci-tooling checkout)" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" == *".lgtm-ci-egress"* ]]; then
			echo "$file:$line_num: remove .lgtm-ci-egress workaround" >&2
			violations=$((violations + 1))
		fi
	done <"$file"
done < <(find "$WORKFLOWS_DIR" \( -name 'reusable-*.yml' -o -name 'renovate.yml' \) -print0)

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

TOOLING_CAH_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/checkout-and-harden[[:space:]]*$'

_check_checkout_and_harden() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	grep -qE "$TOOLING_CAH_RE" "$workflow" || return 0
	if ! grep -qE 'Checkout lgtm-ci (egress )?tooling' "$workflow"; then
		echo "${wf_name}: missing bootstrap Checkout lgtm-ci tooling step before checkout-and-harden" >&2
		violations=$((violations + 1))
	fi
	if ! awk '
		BEGIN { in_jobs = 0; tooling = 0 }
		/^jobs:/ { in_jobs = 1; next }
		!in_jobs { next }
		/^  [a-zA-Z_][a-zA-Z0-9_-]*: *$/ { tooling = 0; next }
		/- name: Checkout lgtm-ci tooling/ { tooling = NR }
		/uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/checkout-and-harden/ {
			if (tooling == 0 || tooling >= NR) {
				bad = 1
			}
			tooling = 0
		}
		END { exit bad }
	' "$workflow"; then
		echo "${wf_name}: Checkout lgtm-ci tooling must precede checkout-and-harden" >&2
		violations=$((violations + 1))
	fi
	if grep -qE "$IN_REPO_RESOLVE_RE" "$workflow" || grep -qE "$IN_REPO_HARDEN_RE" "$workflow"; then
		echo "${wf_name}: caller-local ./.github/actions egress paths are forbidden in reusables" >&2
		violations=$((violations + 1))
	fi
}

while IFS= read -r -d '' workflow; do
	[[ -f "$workflow" ]] || continue
	wf_name="${workflow##*/}"
	_check_checkout_and_harden "$workflow"
	if ! grep -qE "$TOOLING_HARDEN_RE" "$workflow"; then
		continue
	fi
	if ! grep -qE "$TOOLING_RESOLVE_RE" "$workflow"; then
		echo "${wf_name}: uses harden-runner but missing resolve-egress-allowlist step" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qF "steps.egress.outputs['allowed-endpoints']" "$workflow"; then
		echo "${wf_name}: harden-runner must use steps.egress.outputs['allowed-endpoints']" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qE 'Checkout lgtm-ci (egress )?tooling' "$workflow"; then
		echo "${wf_name}: missing Checkout lgtm-ci tooling step before egress composites" >&2
		violations=$((violations + 1))
	fi
	if grep -qE "$IN_REPO_RESOLVE_RE" "$workflow" || grep -qE "$IN_REPO_HARDEN_RE" "$workflow"; then
		echo "${wf_name}: caller-local ./.github/actions egress paths are forbidden in reusables" >&2
		violations=$((violations + 1))
	fi
	_check_job_egress_order "$workflow"
	_check_harden_with_blocks "$workflow"
done < <(discover_reusable_workflows)

_check_release_two_phase_sparse "$WORKFLOWS_DIR/reusable-release-auto-tag.yml"
_check_release_two_phase_sparse "$WORKFLOWS_DIR/reusable-release-version-pr.yml"

renovate="$WORKFLOWS_DIR/renovate.yml"
if [[ -f "$renovate" ]]; then
	if ! grep -qE "$IN_REPO_RESOLVE_RE" "$renovate"; then
		echo "renovate.yml: missing ./.github/actions/resolve-egress-allowlist step" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qE "$IN_REPO_HARDEN_RE" "$renovate"; then
		echo "renovate.yml: missing ./.github/actions/harden-runner step" >&2
		violations=$((violations + 1))
	fi
	if grep -qE "$TOOLING_HARDEN_RE" "$renovate"; then
		echo "renovate.yml: must use in-repo ./.github/actions (runs in lgtm-ci)" >&2
		violations=$((violations + 1))
	fi
fi

if [[ $violations -gt 0 ]]; then
	exit 1
fi

echo "All reusables use .lgtm-ci-tooling egress composites; renovate uses in-repo paths"
