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
#   LOG_FETCH_DEADLINE - Wall-clock budget in seconds for the whole log-fetch
#                       loop, at least 1 (default: 180)
#   GH_CMD_TIMEOUT    - Wall-clock bound in seconds on each `gh` call, at least
#                       1 (default: 60)
#   TIMEOUT_BIN       - Name/path of the coreutils timeout binary (default:
#                       timeout; set to gtimeout on hosts that name it that way)
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
: "${LOG_FETCH_DEADLINE:=180}"
: "${GH_CMD_TIMEOUT:=60}"
: "${TIMEOUT_BIN:=timeout}"

# `timeout` exits 124 when it kills the command it wrapped. That is the one
# non-zero status this script must not treat as a generic `gh` error.
readonly TIMEOUT_EXIT_STATUS=124

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
# Both wall-clock bounds are positive: zero would either forbid the first fetch
# outright or hand `timeout` a "no limit" argument, reinstating the unbounded
# hang this script exists to prevent (#743).
if [[ ! "$LOG_FETCH_DEADLINE" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::LOG_FETCH_DEADLINE must be a positive integer (got '${LOG_FETCH_DEADLINE}')"
	exit 1
fi
if [[ ! "$GH_CMD_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::GH_CMD_TIMEOUT must be a positive integer (got '${GH_CMD_TIMEOUT}')"
	exit 1
fi

# Every `gh` call runs under `timeout`, so a missing binary would silently
# restore unbounded calls. Fail loudly instead: an absent bound is exactly the
# outage this guard prevents.
if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
	echo "::error::TIMEOUT_BIN '${TIMEOUT_BIN}' not found on PATH; coreutils timeout is required to bound gh calls"
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/github/summary.sh
source "$SCRIPT_DIR/../lib/github/summary.sh"
# Sourced in this shell for COSIGN_OIDC_TRANSIENT_MARKERS, the single source of
# the transient ambient-OIDC marker strings (#719). This script is not a signing
# path, but the markers are cosign-emitted strings, so cosign.sh stays their
# home; sourcing it here is side-effect-free (a load guard, function
# definitions, and two numeric defaults).
# shellcheck source=../lib/cosign.sh
source "$SCRIPT_DIR/../lib/cosign.sh"

# Known transient infra failure signatures (fixed strings, one per line).
#
# The trailing cosign markers are the ambient-OIDC flake class that
# scripts/ci/lib/cosign.sh already retries in-step. The in-step retry is the
# fast path; this matcher is the slow path for when that retry is exhausted and
# the publish fails outright. Without them a persistent OIDC flake burned its
# retries and then matched nothing here, leaving a human to press re-run (#719).
DEFAULT_SIGNATURES="Failed to resolve action download info
The runner has received a shutdown signal
Error resolving allowed domain
lost communication with the server
${COSIGN_OIDC_TRANSIENT_MARKERS}"

# Build the effective signature list: defaults plus optional SIGNATURES
# extensions, blank lines dropped.
build_signatures() {
	printf '%s\n' "$DEFAULT_SIGNATURES"
	if [[ -n "$SIGNATURES" ]]; then
		printf '%s\n' "$SIGNATURES"
	fi
}

# Run `gh` under a hard wall-clock bound. `gh run view --log-failed` downloads
# the failed-job log archive, which stalled twice on 2026-07-25 and burned the
# whole job budget, so the safety net never fired (#743). SIGTERM first, then
# SIGKILL for a `gh` that ignores it, so a wedged download can never outlive
# the bound.
gh_bounded() {
	"$TIMEOUT_BIN" --kill-after=10s "$GH_CMD_TIMEOUT" gh "$@"
}

fetch_failed_logs() {
	gh_bounded run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log-failed
}

# Outputs of fetch_failed_logs_with_retry: the log payload and why the loop
# ended ("ok", "empty", "error" or "timeout"). Set as globals because the
# payload can be large and command substitution would strip the outcome.
FETCHED_LOGS=""
FETCH_OUTCOME="empty"
# For the "timeout" outcome, which bound tripped: "command" (a single fetch
# exceeded GH_CMD_TIMEOUT) or "deadline" (the loop ran out of wall clock).
FETCH_TIMEOUT_REASON="command"
# Seconds the fetch loop spent, for the triage breadcrumb in the summary.
FETCH_ELAPSED=0

# Fetch the failed-job logs, retrying while GitHub has not made them available
# yet. The workflow_run:completed event fires before log ingestion is
# guaranteed complete, so an empty payload, an outright `gh` error, or a fetch
# killed at GH_CMD_TIMEOUT is retryable rather than terminal.
#
# Retries stop at the first non-empty payload: signature matching runs against
# it immediately, which keeps the happy path free of any sleeping.
#
# LOG_FETCH_ATTEMPTS x LOG_FETCH_DELAY bounds attempts but not time, so slow
# fetches would still let the loop run to the job timeout. LOG_FETCH_DEADLINE
# bounds it in wall clock as well, checked before each attempt from the shell's
# own SECONDS rather than by shelling out per iteration. Sets FETCHED_LOGS,
# FETCH_OUTCOME, FETCH_TIMEOUT_REASON and FETCH_ELAPSED; returns 0 when a
# non-empty payload was obtained.
fetch_failed_logs_with_retry() {
	local attempt logs status start=$SECONDS

	FETCHED_LOGS=""
	FETCH_OUTCOME="empty"
	FETCH_TIMEOUT_REASON="command"
	FETCH_ELAPSED=0

	for ((attempt = 1; attempt <= LOG_FETCH_ATTEMPTS; attempt++)); do
		FETCH_ELAPSED=$((SECONDS - start))
		# Attempt 1 always runs: LOG_FETCH_DEADLINE is positive and elapsed is 0.
		if ((FETCH_ELAPSED >= LOG_FETCH_DEADLINE)); then
			FETCH_OUTCOME="timeout"
			FETCH_TIMEOUT_REASON="deadline"
			log_warn "Log-fetch deadline of ${LOG_FETCH_DEADLINE}s reached after ${FETCH_ELAPSED}s for run ${RUN_ID}; abandoning the remaining attempt(s) of ${LOG_FETCH_ATTEMPTS}"
			return 1
		fi

		status=0
		logs="$(fetch_failed_logs)" || status=$?
		FETCH_ELAPSED=$((SECONDS - start))

		if ((status == TIMEOUT_EXIT_STATUS)); then
			# A killed fetch may have written a partial archive; discard it
			# rather than matching signatures against a truncated payload.
			FETCH_OUTCOME="timeout"
			FETCH_TIMEOUT_REASON="command"
			log_warn "Fetching failed-job logs for run ${RUN_ID} exceeded GH_CMD_TIMEOUT=${GH_CMD_TIMEOUT}s and was killed (attempt ${attempt}/${LOG_FETCH_ATTEMPTS})"
		elif ((status != 0)); then
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

	FETCH_ELAPSED=$((SECONDS - start))
	return 1
}

# Print the first signature found in the logs on stdin; return 1 when none
# match.
#
# Matching stays case-sensitive (#719). Every signature is stored in the exact
# case its source emits — including the cosign markers — so case-insensitive
# matching would buy no extra true positives, while widening what auto-rerun
# fires on across ALL signatures, not just the OIDC ones. The cost of a false
# positive here is re-running a workflow that may have failed for real; the cost
# of a miss is the pre-#719 status quo of a human pressing re-run. Strict is the
# safe default for the safety net.
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
		if [[ "$FETCH_OUTCOME" == "timeout" ]]; then
			# Distinct from both "logs unavailable" (GitHub answered, with
			# nothing) and "looks real" (logs were read): here the fetch itself
			# never came back. Reported, not fatal — the safety net declining to
			# act must not add a second red job to a run that already failed.
			log_warn "Log fetch for run ${RUN_ID} hit its wall-clock bound after ${FETCH_ELAPSED}s; not re-running"
			echo "::warning::Timed out reading the failed-job logs of run ${RUN_ID} after ${FETCH_ELAPSED}s (${FETCH_TIMEOUT_REASON} bound); no infra-signature check was possible and the failed jobs were not re-run"
			add_github_summary "Timed out reading logs. The failed-job log fetch for run ${RUN_ID} hit its **${FETCH_TIMEOUT_REASON}** wall-clock bound after ${FETCH_ELAPSED}s (\`GH_CMD_TIMEOUT=${GH_CMD_TIMEOUT}\`s per call, \`LOG_FETCH_DEADLINE=${LOG_FETCH_DEADLINE}\`s for the loop, \`LOG_FETCH_ATTEMPTS=${LOG_FETCH_ATTEMPTS}\`), so no infra signature could be checked and the failed jobs were not re-run."
			add_github_summary ""
			# Triage breadcrumb (#743): both real occurrences surfaced at RUN
			# level as `cancelled` and were misread twice as a GitHub-side
			# cancellation before job-step evidence showed a timeout. Saying so
			# here means the next reader does not have to rediscover it.
			add_github_summary "This is a **timeout in the safety net itself**, not a verdict on run ${RUN_ID}. \`gh run view --log-failed\` stalled; the script bounded itself and exited rather than burning the job budget. Re-check run ${RUN_ID} manually and re-run its failed jobs if the failure was transient."
			return 0
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
	local rerun_status=0
	gh_bounded run rerun "$RUN_ID" --repo "$GITHUB_REPOSITORY" --failed || rerun_status=$?
	if ((rerun_status != 0)); then
		# A matched signature the script could not act on is the worst outcome:
		# a human must press re-run. Fail loudly rather than let a killed or
		# errored `gh run rerun` read as a successful safety-net run.
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		if ((rerun_status == TIMEOUT_EXIT_STATUS)); then
			add_github_summary "Matched transient infra signature \`${matched}\` in the failed-job logs of run ${RUN_ID}, but \`gh run rerun\` exceeded \`GH_CMD_TIMEOUT=${GH_CMD_TIMEOUT}\`s and was killed. The failed jobs were **not** re-run — press re-run manually."
			die "Timed out re-running failed jobs of run ${RUN_ID} after ${GH_CMD_TIMEOUT}s"
		fi
		add_github_summary "Matched transient infra signature \`${matched}\` in the failed-job logs of run ${RUN_ID}, but \`gh run rerun\` exited ${rerun_status}. The failed jobs were **not** re-run — press re-run manually."
		die "Failed to re-run failed jobs of run ${RUN_ID}: gh run rerun exited ${rerun_status}"
	fi
	echo "::notice::Re-ran failed jobs of run ${RUN_ID} (attempt ${RUN_ATTEMPT}): matched infra signature '${matched}'"
	add_github_summary "## Auto re-run on infra failure"
	add_github_summary ""
	add_github_summary "Matched transient infra signature \`${matched}\` in the failed-job logs of run ${RUN_ID} (attempt ${RUN_ATTEMPT}); re-ran the failed jobs."
	log_success "Re-ran failed jobs of run ${RUN_ID}"
}

main "$@"
