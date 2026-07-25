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
#   LOG_FETCH_ATTEMPTS - Max failed-job log fetch attempts, at least 1 (default: 5)
#   LOG_FETCH_DELAY   - Seconds to wait between log fetch attempts (default: 5)
#   GITHUB_REPOSITORY - owner/repo (provided by GitHub Actions)
#   GH_TOKEN          - Token with actions:write scope

set -euo pipefail

: "${RUN_ID:?RUN_ID is required}"
: "${RUN_ATTEMPT:?RUN_ATTEMPT is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${MAX_RERUNS:=1}"
: "${SIGNATURES:=}"
: "${LOG_FETCH_ATTEMPTS:=5}"
: "${LOG_FETCH_DELAY:=5}"

# RUN_ATTEMPT, MAX_RERUNS and the log-fetch bounds feed arithmetic; reject
# non-integers up front so workflow-input typos fail loudly instead of raising
# an arithmetic error under set -e.
if [[ ! "$RUN_ATTEMPT" =~ ^[0-9]+$ ]]; then
	echo "::error::RUN_ATTEMPT must be a non-negative integer (got '${RUN_ATTEMPT}')"
	exit 1
fi
if [[ ! "$MAX_RERUNS" =~ ^[0-9]+$ ]]; then
	echo "::error::MAX_RERUNS must be a non-negative integer (got '${MAX_RERUNS}')"
	exit 1
fi
# Zero attempts would mean the safety net silently never inspects the logs, so
# this bound is positive rather than merely non-negative.
if [[ ! "$LOG_FETCH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::LOG_FETCH_ATTEMPTS must be a positive integer (got '${LOG_FETCH_ATTEMPTS}')"
	exit 1
fi
if [[ ! "$LOG_FETCH_DELAY" =~ ^[0-9]+$ ]]; then
	echo "::error::LOG_FETCH_DELAY must be a non-negative integer (got '${LOG_FETCH_DELAY}')"
	exit 1
fi

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

# Outputs of fetch_failed_logs_with_retry: the log payload and why the loop
# ended ("ok", "empty" or "error"). Set as globals because the payload can be
# large and command substitution would strip the outcome.
FETCHED_LOGS=""
FETCH_OUTCOME="empty"

# Fetch the failed-job logs, retrying while GitHub has not made them available
# yet. The workflow_run:completed event fires before log ingestion is
# guaranteed complete, so an empty payload (or an outright `gh` error) is
# retryable rather than terminal.
#
# Retries stop at the first non-empty payload: signature matching runs against
# it immediately, which keeps the happy path free of any sleeping. Sets
# FETCHED_LOGS/FETCH_OUTCOME; returns 0 when a non-empty payload was obtained.
fetch_failed_logs_with_retry() {
	local attempt logs status

	FETCHED_LOGS=""
	FETCH_OUTCOME="empty"

	for ((attempt = 1; attempt <= LOG_FETCH_ATTEMPTS; attempt++)); do
		status=0
		logs="$(fetch_failed_logs)" || status=$?

		if ((status != 0)); then
			FETCH_OUTCOME="error"
			log_warn "Fetching failed-job logs for run ${RUN_ID} exited ${status} (attempt ${attempt}/${LOG_FETCH_ATTEMPTS})"
		elif [[ -n "${logs//[[:space:]]/}" ]]; then
			FETCHED_LOGS="$logs"
			FETCH_OUTCOME="ok"
			return 0
		else
			FETCH_OUTCOME="empty"
			log_warn "Failed-job logs for run ${RUN_ID} are still empty (attempt ${attempt}/${LOG_FETCH_ATTEMPTS}); GitHub may not have ingested them yet"
		fi

		if ((attempt < LOG_FETCH_ATTEMPTS && LOG_FETCH_DELAY > 0)); then
			sleep "$LOG_FETCH_DELAY"
		fi
	done

	return 1
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

	if ! fetch_failed_logs_with_retry; then
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		# FETCH_OUTCOME records the last attempt's classification only, so the
		# wording speaks to the final attempt rather than claiming every one of
		# them errored (earlier attempts may have returned empty payloads).
		if [[ "$FETCH_OUTCOME" == "error" ]]; then
			add_github_summary "Could not read the failed-job logs of run ${RUN_ID}: the last of ${LOG_FETCH_ATTEMPTS} fetch attempt(s) failed. No signature check was possible, so this says nothing about whether the failure is genuine."
			die "Failed to fetch failed-job logs for run ${RUN_ID} after ${LOG_FETCH_ATTEMPTS} attempt(s)"
		fi
		# GitHub never made the log tail available. Inconclusive is not the same
		# as "no signature matched": say so explicitly and do not fail the
		# safety-net job over GitHub's ingestion lag.
		log_warn "Failed-job logs of run ${RUN_ID} stayed empty after ${LOG_FETCH_ATTEMPTS} attempt(s); inconclusive, not re-running"
		echo "::warning::Inconclusive: failed-job logs of run ${RUN_ID} were unavailable after ${LOG_FETCH_ATTEMPTS} attempt(s); no infra-signature check was possible"
		add_github_summary "Inconclusive: logs unavailable. The failed-job logs of run ${RUN_ID} were still empty after ${LOG_FETCH_ATTEMPTS} fetch attempt(s), so no infra signature could be checked and the failed jobs were not re-run. This does **not** mean the failure is genuine — re-check the run manually."
		return 0
	fi

	local matched
	if ! matched="$(match_signature "$FETCHED_LOGS")"; then
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
