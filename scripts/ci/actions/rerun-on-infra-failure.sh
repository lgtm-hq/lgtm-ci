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
#                       whichever of timeout / gtimeout is on PATH)
#   WATCHDOG_DEADLINE - Wall-clock budget in seconds for the whole script, at
#                       least 1 (default: 420). On expiry the script prints
#                       diagnostics and exits 0 (#776)
#   GITHUB_REPOSITORY - owner/repo (provided by GitHub Actions)
#   GH_TOKEN          - Token with actions:write scope

set -euo pipefail

# Nothing this script or its children run has any business reading stdin, and an
# inherited stdin is a classic source of a silent forever-block (#776). Close
# the door once, here, so every descendant inherits /dev/null.
exec </dev/null

# First write of the run, before any validation, sourcing or work. Ten minutes
# of total silence was a reachable state before #776 and made the hang
# unlocalisable from the log alone; this line makes "the script never started"
# distinguishable from "the script started and stopped somewhere". Written with
# a raw printf because log.sh is not sourced yet, and to stderr because bash
# writes builtin output straight through without buffering it.
printf '[INFO] rerun-on-infra-failure: starting (run=%s attempt=%s)\n' \
	"${RUN_ID:-<unset>}" "${RUN_ATTEMPT:-<unset>}" >&2

: "${RUN_ID:?RUN_ID is required}"
: "${RUN_ATTEMPT:?RUN_ATTEMPT is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${MAX_RERUNS:=1}"
: "${SIGNATURES:=}"
: "${LOG_FETCH_ATTEMPTS:=5}"
: "${LOG_FETCH_DELAY:=5}"
: "${LOG_FETCH_DEADLINE:=180}"
: "${GH_CMD_TIMEOUT:=60}"
: "${WATCHDOG_DEADLINE:=420}"

# `timeout` exits 124 when it kills the command it wrapped. That is the one
# non-zero status this script must not treat as a generic `gh` error.
readonly TIMEOUT_EXIT_STATUS=124
# Status bash reports for a child killed by SIGKILL (128 + 9), which is how the
# watchdog ends a hung run.
readonly WATCHDOG_KILL_STATUS=137

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
# The watchdog is the outermost bound and covers work `timeout` cannot see —
# the shell's own string handling, which is what actually hung in #776. Zero
# would mean "expired before starting", so this bound is positive too.
if [[ ! "$WATCHDOG_DEADLINE" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::WATCHDOG_DEADLINE must be a positive integer (got '${WATCHDOG_DEADLINE}')"
	exit 1
fi

# Every `gh` call runs under `timeout`, so a missing binary would silently
# restore unbounded calls. Fail loudly instead: an absent bound is exactly the
# outage this guard prevents.
#
# The binary is auto-resolved rather than hardcoded because `runner-image` is a
# caller input: ubuntu images ship coreutils as `timeout`, while macOS ships
# none by default and names the Homebrew coreutils build `gtimeout`. An explicit
# TIMEOUT_BIN always wins, so an unusual host can still name its own.
if [[ -n "${TIMEOUT_BIN:-}" ]]; then
	if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
		echo "::error::TIMEOUT_BIN '${TIMEOUT_BIN}' not found on PATH; coreutils timeout is required to bound gh calls"
		exit 1
	fi
else
	for candidate in timeout gtimeout; do
		if command -v "$candidate" >/dev/null 2>&1; then
			TIMEOUT_BIN="$candidate"
			break
		fi
	done
	if [[ -z "${TIMEOUT_BIN:-}" ]]; then
		echo "::error::Neither 'timeout' nor 'gtimeout' is on PATH; coreutils timeout is required to bound gh calls (install coreutils or set TIMEOUT_BIN)"
		exit 1
	fi
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

# Scratch state shared between the work child and the watchdog parent (#776).
# Removed on exit by whichever shell created it, so the background child cannot
# delete the directory out from under the watchdog.
WATCHDOG_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rerun-on-infra-failure.XXXXXX")"
WATCHDOG_OWNER_PID=$BASHPID
WATCHDOG_PHASE_FILE="${WATCHDOG_STATE_DIR}/phase"
WATCHDOG_TRIPPED_FILE="${WATCHDOG_STATE_DIR}/tripped"
printf 'startup\n' >"$WATCHDOG_PHASE_FILE"

_cleanup_watchdog_state() {
	[[ "$BASHPID" == "$WATCHDOG_OWNER_PID" ]] || return 0
	rm -rf "$WATCHDOG_STATE_DIR"
}
trap _cleanup_watchdog_state EXIT

# Record and announce the phase of work about to start. The announcement makes
# progress visible in the job log; the file lets the watchdog name where a hang
# happened, since the work runs in a child whose variables the parent cannot
# see.
log_phase() {
	local phase="$1"
	printf '%s\n' "$phase" >"$WATCHDOG_PHASE_FILE"
	log_info "$phase"
}

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
	"$TIMEOUT_BIN" --kill-after=10s "$GH_CMD_TIMEOUT" gh "$@" </dev/null
}

fetch_failed_logs() {
	gh_bounded run view "$RUN_ID" --repo "$GITHUB_REPOSITORY" --log-failed
}

# True when the payload contains at least one non-whitespace character.
#
# This replaces `[[ -n "${logs//[[:space:]]/}" ]]`, which is what actually hung
# in #776. Bash's `${var//pat/}` rebuilds the string once per match, so its cost
# is O(length x matches) — quadratic in payload size for a log, where roughly
# one character in six is whitespace. Measured on the real thing: 1 MB of
# failed-job log took 21s, 4 MB took 147s, and a multi-megabyte log therefore
# burned the entire 10-minute job timeout inside a single parameter expansion.
# No `gh` bound could see it (#743/#749 bound `gh`, not the shell), and it sits
# on the success path where nothing is logged, which is why the job produced
# zero output for ten minutes.
#
# The glob form scans left to right and stops at the first non-whitespace
# character, so it is linear and, on any real payload, effectively instant:
# 64 MB measures at 0.5s, and 0.9s for the pathological all-whitespace case.
payload_has_content() {
	[[ "$1" == *[![:space:]]* ]]
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

		log_phase "Fetching failed-job logs of run ${RUN_ID} (attempt ${attempt}/${LOG_FETCH_ATTEMPTS}, ${FETCH_ELAPSED}s elapsed)"
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
		elif payload_has_content "$logs"; then
			FETCHED_LOGS="$logs"
			FETCH_OUTCOME="ok"
			# Payload size is the first thing to look at when this step is slow:
			# every remaining cost in the script scales with it (#776).
			log_info "Fetched ${#logs} bytes of failed-job logs for run ${RUN_ID} in ${FETCH_ELAPSED}s (attempt ${attempt}/${LOG_FETCH_ATTEMPTS})"
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
	log_phase "Checking re-run eligibility for run ${RUN_ID} (attempt ${RUN_ATTEMPT}, max ${MAX_RERUNS})"
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
			# Same class as "empty" and "timeout": the safety net could not
			# reach a verdict. It used to `die` here, which reddened a job whose
			# whole purpose is to react to someone else's red job (#763). The
			# common cause is benign — a superseded run's log archive is gone,
			# so `gh` errors with `log not found`, and there is nothing to
			# re-run anyway. Kept distinct from "empty" in the wording: an
			# errored fetch is a different triage story from GitHub answering
			# with nothing yet.
			log_warn "Failed-job log fetch for run ${RUN_ID} errored on all ${LOG_FETCH_ATTEMPTS} attempt(s); inconclusive, not re-running"
			echo "::warning::Inconclusive: fetching the failed-job logs of run ${RUN_ID} errored on all ${LOG_FETCH_ATTEMPTS} attempt(s); no infra-signature check was possible"
			add_github_summary "Inconclusive: log fetch errored. Reading the failed-job logs of run ${RUN_ID} failed on all ${LOG_FETCH_ATTEMPTS} attempt(s) — \`gh\` returned an error rather than an empty payload. The usual cause is a run that was cancelled or superseded, whose log archive GitHub has already discarded (\`log not found\`); there is nothing to re-run in that case. No infra signature could be checked, so this says **nothing** about whether the failure is genuine — re-check the run manually."
			return 0
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
	log_phase "Matching infra signatures against ${#FETCHED_LOGS} bytes of failed-job logs for run ${RUN_ID}"
	if ! matched="$(match_signature "$FETCHED_LOGS")"; then
		log_info "No infra signature matched in failed-job logs of run ${RUN_ID}; not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "No infra signature matched in the failed-job logs of run ${RUN_ID}; not re-running. The failure looks real — investigate it."
		return 0
	fi

	log_info "Infra signature matched for run ${RUN_ID}: ${matched}"
	log_phase "Re-running the failed jobs of run ${RUN_ID}"
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

# =============================================================================
# Script-level watchdog (#776)
# =============================================================================
#
# `timeout` bounds `gh`; it cannot bound the shell itself. The #776 hang was a
# quadratic parameter expansion inside bash, so every `gh` bound was irrelevant
# and the only backstop left was the job's own `timeout-minutes` — ten minutes
# of burnt runner time that ends in a red job and no diagnostics at all.
#
# So main() runs in a child, this shell holds the clock, and on expiry it
# reports the last phase the child reached and exits 0. A safety net that
# declines to act must never be the thing that fails (#763), and a hang that
# names itself is a readable non-event rather than a mystery.
#
# The alarm is a background child rather than a signal trap on purpose: bash
# only runs traps between commands, and the #776 hang was *inside* a single
# command, so a trap would not have fired until the hang finished. Only an
# outside process can end it.

# Report where the watchdog found the run stuck. Non-fatal by construction.
watchdog_report() {
	local phase="unknown"
	if [[ -s "$WATCHDOG_PHASE_FILE" ]]; then
		phase="$(<"$WATCHDOG_PHASE_FILE")"
	fi
	log_warn "Watchdog: the safety net exceeded WATCHDOG_DEADLINE=${WATCHDOG_DEADLINE}s and was stopped while: ${phase}"
	echo "::warning::Auto re-run for run ${RUN_ID} exceeded its own ${WATCHDOG_DEADLINE}s budget and was stopped while: ${phase}. The failed jobs were not re-run."
	add_github_summary "## Auto re-run on infra failure"
	add_github_summary ""
	add_github_summary "Watchdog stopped the safety net. It exceeded its own wall-clock budget of \`WATCHDOG_DEADLINE=${WATCHDOG_DEADLINE}\`s while: **${phase}**. The failed jobs of run ${RUN_ID} were **not** re-run — re-check the run and press re-run manually."
	add_github_summary ""
	add_github_summary "This is a timeout in the safety net itself, not a verdict on run ${RUN_ID}. It exits green on purpose so the safety net never adds a second red job to a run that already failed."
}

# Bounded wait, then kill. Uses `read -t` on a fifo rather than `sleep` so that
# the alarm keeps working where `sleep` is absent, stubbed or itself wedged.
watchdog_timer() {
	local target="$1"
	read -r -t "$WATCHDOG_DEADLINE" -u "$WATCHDOG_WAIT_FD" _ || true
	: >"$WATCHDOG_TRIPPED_FILE"
	# The whole process group, not just the child. A surviving `gh` still holds
	# the step's stdout, and the runner does not consider a step finished while
	# anything holds that pipe open — killing only the shell would swap one
	# silent hang for another. The single-pid kill is the fallback for a shell
	# that did not give the job its own process group.
	#
	# SIGKILL because the point is to end something that is, by definition,
	# no longer responding to anything gentler.
	kill -KILL -"$target" 2>/dev/null || kill -KILL "$target" 2>/dev/null || true
}

run_with_watchdog() {
	local main_pid dog_pid status=0 fifo

	# Opened read-write so the timer's `read` blocks for its full timeout
	# instead of seeing EOF; unlinked immediately, the fd keeps it alive.
	fifo="${WATCHDOG_STATE_DIR}/watchdog.fifo"
	mkfifo "$fifo"
	exec {WATCHDOG_WAIT_FD}<>"$fifo"
	rm -f "$fifo"

	# Job control just for this launch, so main() and everything it spawns land
	# in their own process group and the watchdog can kill the tree in one go.
	# Turned straight back off, which keeps the timer below in this group.
	set -m
	main &
	main_pid=$!
	set +m

	watchdog_timer "$main_pid" &
	dog_pid=$!

	# stderr is muted for the `wait` alone: when the watchdog kills the child,
	# bash reports the job as "Killed" with a raw pid, which reads as a crash
	# next to the watchdog's own explanation of what happened and why. main()
	# has already written its own output straight to fd 2 by this point, so
	# nothing else is lost.
	{ wait "$main_pid" || status=$?; } 2>/dev/null

	kill "$dog_pid" 2>/dev/null || true
	wait "$dog_pid" 2>/dev/null || true
	exec {WATCHDOG_WAIT_FD}>&-

	# Both conditions, so a timer that trips in the same instant main() finishes
	# cannot rewrite a completed run as a hang: the watchdog only speaks when it
	# armed *and* the child died by the signal it sent.
	if [[ -e "$WATCHDOG_TRIPPED_FILE" ]] && ((status == WATCHDOG_KILL_STATUS)); then
		watchdog_report
		return 0
	fi
	return "$status"
}

# No "$@": this script is driven entirely by environment variables and takes no
# positional arguments, and forwarding them here would only look like main()
# receives them when it does not.
run_with_watchdog
