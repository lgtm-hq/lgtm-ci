#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables invoke step-security/harden-runner directly (#412/#420)
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Overridable so tests can point the validator at a fixture directory. The
# release-specific checks below tolerate missing files, so a fixture
# dir containing only reusable-*.yml is safe.
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

HARDEN_SHA='e14015d583714f6e62063499dc959a02595150a1' # v2.21.1
# Tag is parsed from the HARDEN_SHA comment so Renovate's one-line bump
# stays the error-message SSoT (do not hardcode vX.Y.Z here).
HARDEN_TAG="$(sed -nE "s/^HARDEN_SHA='[a-f0-9]{40}' # (v[0-9.]+).*/\1/p" "${BASH_SOURCE[0]}")"
if [[ -z "$HARDEN_TAG" ]]; then
	echo "validate-harden-runner-action-ref: failed to parse version comment on HARDEN_SHA" >&2
	exit 1
fi
STEP_SECURITY_HARDEN_RE="^[[:space:]]+uses:[[:space:]]+step-security/harden-runner@${HARDEN_SHA}([[:space:]]+#.*)?[[:space:]]*$"
# resolve-egress-allowlist and the bundled harden-runner composite were
# removed in #913; any reference is a stale pattern that cannot enforce.
TOOLING_RESOLVE_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/resolve-egress-allowlist[[:space:]]*$'
TOOLING_HARDEN_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/harden-runner[[:space:]]*$'
IN_REPO_RESOLVE_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/resolve-egress-allowlist[[:space:]]*$'
IN_REPO_HARDEN_RE='^[[:space:]]+uses:[[:space:]]+\./\.github/actions/harden-runner[[:space:]]*$'
REMOTE_EGRESS_RE='lgtm-hq/lgtm-ci/\.github/actions/(harden-runner|resolve-egress-allowlist)@'
TOOLING_CAH_RE='^[[:space:]]+uses:[[:space:]]+\./\.lgtm-ci-tooling/\.github/actions/checkout-and-harden[[:space:]]*$'
ANY_STEP_SECURITY_HARDEN_RE='^[[:space:]]+uses:[[:space:]]+step-security/harden-runner@'

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
				cah_line = 0
				job_indent = -1
			}
			/^jobs:/ {
				in_jobs = 1
				next
			}
			!in_jobs {
				next
			}
			# Job-key boundary at the actual job indent, detected from the
			# first key under jobs:. This resets carried state for 2-space,
			# 4-space, or quoted job keys alike, so a deeper-indented job
			# cannot inherit a prior job tooling checkout and bypass the
			# contract (\047 = single quote).
			{
				if ($0 ~ /^ +(["\047][^"\047]*["\047]|[a-zA-Z_][a-zA-Z0-9_-]*): *$/) {
					lead = $0
					sub(/[^ ].*$/, "", lead)
					if (job_indent < 0) {
						job_indent = length(lead)
					}
					if (length(lead) == job_indent) {
						tooling_line = 0
						resolve_line = 0
						cah_line = 0
						next
					}
				}
			}
			$0 ~ /^[[:space:]]+- name: Checkout lgtm-ci bootstrap tooling/ {
				tooling_line = NR
				next
			}
			$0 ~ /^[[:space:]]+- name: Checkout lgtm-ci tooling/ {
				if (resolve_line == 0 && cah_line == 0) {
					tooling_line = NR
				}
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+\.\/\.lgtm-ci-tooling\/\.github\/actions\/checkout-and-harden/ {
				if (tooling_line == 0 || tooling_line >= NR) {
					report("Checkout lgtm-ci tooling must precede checkout-and-harden (checkout-and-harden at line " NR ")")
				}
				cah_line = NR
				next
			}
			$0 ~ /^[[:space:]]+uses:[[:space:]]+step-security\/harden-runner@/ {
				# Harden may be first (required) while tooling/cah come later for
				# scripts-dir resolution; do not require cah/resolve before harden.
				resolve_line = 0
				cah_line = 0
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
		# harden-runner's pre hook runs at job start, before any step exists.
		# #913 contract: allowed-endpoints is an expression that selects a
		# preset from the workflow's literal env map (optionally combined with
		# inputs.*); never a hand-maintained host list, never step outputs.
		local ae_block
		ae_block="$(awk '/^[[:space:]]+allowed-endpoints:/ { on = 1 } on' <<<"$block")"
		if [[ -z "$ae_block" ]]; then
			echo "${wf_name}:${line_num}: step-security/harden-runner must set allowed-endpoints" >&2
			violations=$((violations + 1))
			continue
		fi
		if ! grep -qF 'fromJSON(env.LGTM_CI_EGRESS_PRESETS)' <<<"$ae_block"; then
			echo "${wf_name}:${line_num}: step-security/harden-runner allowed-endpoints must select a preset via fromJSON(env.LGTM_CI_EGRESS_PRESETS) (#913); hand-maintained host lists drift" >&2
			violations=$((violations + 1))
		fi
		if grep -qE '(steps|needs|job|vars|matrix|strategy|runner)\.' <<<"$ae_block"; then
			echo "${wf_name}:${line_num}: step-security/harden-runner allowed-endpoints may reference only inputs.* and env.* (pre hook sees nothing computed in a step)" >&2
			violations=$((violations + 1))
		fi
		# A bare host:port token outside an expression is a literal list.
		if grep -vE '\$\{\{|\}\}|^[[:space:]]*#' <<<"$ae_block" | grep -qE '^[[:space:]]*[A-Za-z0-9*][A-Za-z0-9.*-]*:[0-9]+[[:space:]]*$'; then
			echo "${wf_name}:${line_num}: step-security/harden-runner allowed-endpoints contains a literal host:port; add it to a preset in scripts/ci/lib/egress/presets.sh instead" >&2
			violations=$((violations + 1))
		fi
	done < <(grep -nE "$ANY_STEP_SECURITY_HARDEN_RE" "$workflow" | cut -d: -f1)
}

_check_release_two_phase_sparse() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	[[ -f "$workflow" ]] || return 0
	grep -q 'Checkout lgtm-ci bootstrap tooling' "$workflow" || return 0

	while IFS= read -r msg; do
		[[ -z "$msg" ]] && continue
		echo "$msg" >&2
		violations=$((violations + 1))
	done < <(
		awk -v wf="$wf_name" '
			/Checkout lgtm-ci bootstrap tooling/ { saw_egress = 1 }
			saw_egress && /- name: Checkout lgtm-ci tooling/ { block = 1 }
			saw_egress && /- name: Restore tooling for post-PR steps/ { block = 1 }
			block && /^[[:space:]]+sparse-checkout: \|/ {
				in_sparse = 1
				has_scripts = 0
				has_stale = 0
				next
			}
			in_sparse && /scripts\/ci\// { has_scripts = 1 }
			in_sparse && /\.github\/actions\/(harden-runner|resolve-egress-allowlist)/ { has_stale = 1 }
			in_sparse && /^[[:space:]]+[a-zA-Z]/ && !/^[[:space:]]+\./ && !/^[[:space:]]+scripts/ {
				if (!has_scripts) {
					print wf ": multiline sparse-checkout after bootstrap tooling must include scripts/ci/"
				}
				if (has_stale) {
					print wf ": sparse-checkout lists a removed egress composite (harden-runner / resolve-egress-allowlist, #913)"
				}
				in_sparse = 0
				block = 0
			}
		' "$workflow"
	)
}

_check_checkout_and_harden() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	grep -qE "$TOOLING_CAH_RE" "$workflow" || return 0
	if ! grep -qE 'Checkout lgtm-ci (bootstrap )?tooling' "$workflow"; then
		echo "${wf_name}: missing bootstrap Checkout lgtm-ci tooling step before checkout-and-harden" >&2
		violations=$((violations + 1))
	fi
	if ! awk '
		BEGIN { in_jobs = 0; tooling = 0; job_indent = -1 }
		/^jobs:/ { in_jobs = 1; next }
		!in_jobs { next }
		# Job-key boundary: reset the tooling checkout carried from a
		# previous job. The boundary indent is detected from the first key
		# under jobs:, so bare or quoted job keys at any indentation
		# (2-space, 4-space, single- or double-quoted "release":) reset the
		# carried checkout and cannot bypass this contract (\047 = single quote).
		{
			if ($0 ~ /^ +(["\047][^"\047]*["\047]|[a-zA-Z_][a-zA-Z0-9_-]*): *$/) {
				lead = $0
				sub(/[^ ].*$/, "", lead)
				if (job_indent < 0) { job_indent = length(lead) }
				if (length(lead) == job_indent) { tooling = 0; next }
			}
		}
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

_check_harden_is_first_step() {
	local workflow="$1"
	local wf_name="${workflow##*/}"

	# step-security/harden-runner pre installs a stub policy at job start; its
	# main step must run before any network (checkout). Require it as the first
	# step in every job that hardens.
	while IFS= read -r msg; do
		[[ -z "$msg" ]] && continue
		echo "$msg" >&2
		violations=$((violations + 1))
	done < <(
		awk -v wf="$wf_name" '
			BEGIN {
				in_jobs = 0
				in_steps = 0
				job_indent = -1
				step_count = 0
				first_is_harden = 0
				job_has_harden = 0
				job_name = ""
			}
			function flush_job() {
				if (job_has_harden && step_count > 0 && !first_is_harden) {
					print wf ": job '" job_name "' must start with step-security/harden-runner (pre installs agent; main must run before checkout)"
				}
				in_steps = 0
				step_count = 0
				first_is_harden = 0
				job_has_harden = 0
			}
			/^jobs:/ { in_jobs = 1; next }
			!in_jobs { next }
			{
				if ($0 ~ /^ +(["\047][^"\047]*["\047]|[a-zA-Z_][a-zA-Z0-9_-]*): *$/) {
					lead = $0
					sub(/[^ ].*$/, "", lead)
					if (job_indent < 0) { job_indent = length(lead) }
					if (length(lead) == job_indent) {
						flush_job()
						job_name = $0
						sub(/^ +/, "", job_name)
						sub(/: *$/, "", job_name)
						next
					}
				}
			}
			/^[[:space:]]+steps:[[:space:]]*$/ {
				in_steps = 1
				step_count = 0
				first_is_harden = 0
				job_has_harden = 0
				next
			}
			in_steps && /^[[:space:]]+- name:/ {
				step_count++
				next
			}
			in_steps && /^[[:space:]]+- uses:/ {
				step_count++
				if (step_count == 1 && $0 ~ /step-security\/harden-runner@/) {
					first_is_harden = 1
					job_has_harden = 1
				}
				next
			}
			in_steps && /^[[:space:]]+uses:[[:space:]]+step-security\/harden-runner@/ {
				job_has_harden = 1
				if (step_count == 1) {
					first_is_harden = 1
				}
				next
			}
			END { flush_job() }
		' "$workflow"
	)
}
while IFS= read -r -d '' file; do
	line_num=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ "$line" =~ $REMOTE_EGRESS_RE ]]; then
			echo "$file:$line_num: do not use remote lgtm-hq/lgtm-ci egress action refs (use .lgtm-ci-tooling checkout + direct step-security/harden-runner)" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" == *".lgtm-ci-egress"* ]]; then
			echo "$file:$line_num: remove .lgtm-ci-egress workaround" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" =~ $TOOLING_HARDEN_RE ]] || [[ "$line" =~ $IN_REPO_HARDEN_RE ]]; then
			echo "$file:$line_num: do not use local harden-runner action path; use step-security/harden-runner@${HARDEN_SHA}" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" =~ $ANY_STEP_SECURITY_HARDEN_RE ]] && ! [[ "$line" =~ $STEP_SECURITY_HARDEN_RE ]]; then
			echo "$file:$line_num: step-security/harden-runner must be pinned to ${HARDEN_SHA} # ${HARDEN_TAG}" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
	done <"$file"
done < <(find "$WORKFLOWS_DIR" -name 'reusable-*.yml' -print0)

while IFS= read -r -d '' workflow; do
	[[ -f "$workflow" ]] || continue
	wf_name="${workflow##*/}"
	_check_checkout_and_harden "$workflow"
	_check_harden_is_first_step "$workflow"

	if grep -qE "$TOOLING_RESOLVE_RE" "$workflow" || grep -qE '\.github/actions/(harden-runner|resolve-egress-allowlist)[[:space:]]*$' "$workflow"; then
		echo "${wf_name}: references the removed resolve-egress-allowlist / bundled harden-runner composite (#913)" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qE "$ANY_STEP_SECURITY_HARDEN_RE" "$workflow"; then
		# Some reusables may not harden (nested-only callers); skip only if
		# they also lack checkout-and-harden.
		if grep -qE "$TOOLING_CAH_RE" "$workflow"; then
			echo "${wf_name}: uses checkout-and-harden but missing step-security/harden-runner@${HARDEN_SHA}" >&2
			violations=$((violations + 1))
		fi
		continue
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

if [[ $violations -gt 0 ]]; then
	exit 1
fi

echo "All reusables use direct step-security/harden-runner@${HARDEN_SHA}"
