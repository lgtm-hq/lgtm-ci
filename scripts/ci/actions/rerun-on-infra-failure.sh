#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Re-run failed jobs of a workflow run when — and only when — the
#          failure logs match a known transient-infrastructure signature.
#
# Transient GitHub-side outages ("Failed to resolve action download info",
# runner shutdowns, …) fail workflows outright and previously needed a human
# to press re-run. This script inspects the failed-job logs of a completed
# run and, when a known infra signature matches, re-runs only the failed
# jobs. RUN_ATTEMPT gating caps automation at MAX_RERUNS re-runs per run so
# a persistent outage can never loop.
#
# Environment variables:
#   RUN_ID            - Workflow run id to inspect and potentially re-run (required)
#   RUN_ATTEMPT       - Attempt number of the failed run (required)
#   MAX_RERUNS        - Maximum automatic re-runs per run (default: 1)
#   SIGNATURES        - Extra newline-separated log signatures appended to the
#                       built-in defaults (optional)
#   GITHUB_REPOSITORY - owner/repo (provided by GitHub Actions)
#   GH_TOKEN          - Token with actions:write scope

set -euo pipefail

: "${RUN_ID:?RUN_ID is required}"
: "${RUN_ATTEMPT:?RUN_ATTEMPT is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${MAX_RERUNS:=1}"
: "${SIGNATURES:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/github/summary.sh
source "$SCRIPT_DIR/../lib/github/summary.sh"

# Known transient infra failure signatures (fixed strings, one per line).
DEFAULT_SIGNATURES="Failed to resolve action download info
The runner has received a shutdown signal
Error resolving allowed domain
lost communication with the server"

# Build the effective signature list: defaults plus optional SIGNATURES
# extensions, blank lines dropped.
build_signatures() {
	printf '%s\n' "$DEFAULT_SIGNATURES"
	if [[ -n "$SIGNATURES" ]]; then
		printf '%s\n' "$SIGNATURES"
	fi
}

fetch_failed_logs() {
	gh run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log-failed
}

# Print the first signature found in the logs on stdin; return 1 when none
# match.
match_signature() {
	local logs="$1" signature
	while IFS= read -r signature; do
		[[ -z "$signature" ]] && continue
		if grep -qF -- "$signature" <<<"$logs"; then
			printf '%s\n' "$signature"
			return 0
		fi
	done < <(build_signatures)
	return 1
}

main() {
	if [[ "$RUN_ATTEMPT" -gt "$MAX_RERUNS" ]]; then
		log_info "Run ${RUN_ID} attempt ${RUN_ATTEMPT} exceeds MAX_RERUNS=${MAX_RERUNS}; not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "Attempt ${RUN_ATTEMPT} exceeds the max of ${MAX_RERUNS} automatic re-run(s); leaving run ${RUN_ID} failed for a human."
		return 0
	fi

	local logs
	if ! logs="$(fetch_failed_logs)"; then
		die "Failed to fetch failed-job logs for run ${RUN_ID}"
	fi

	local matched
	if ! matched="$(match_signature "$logs")"; then
		log_info "No infra signature matched in failed-job logs of run ${RUN_ID}; not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "No infra signature matched in the failed-job logs of run ${RUN_ID}; not re-running. The failure looks real — investigate it."
		return 0
	fi

	log_info "Infra signature matched for run ${RUN_ID}: ${matched}"
	gh run rerun "$RUN_ID" --repo "$GITHUB_REPOSITORY" --failed
	echo "::notice::Re-ran failed jobs of run ${RUN_ID} (attempt ${RUN_ATTEMPT}): matched infra signature '${matched}'"
	add_github_summary "## Auto re-run on infra failure"
	add_github_summary ""
	add_github_summary "Matched transient infra signature \`${matched}\` in the failed-job logs of run ${RUN_ID} (attempt ${RUN_ATTEMPT}); re-ran the failed jobs."
	log_success "Re-ran failed jobs of run ${RUN_ID}"
}

main "$@"
