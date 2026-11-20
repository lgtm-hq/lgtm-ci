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
#   PROTECTED_WORKFLOWS - Newline- or comma-separated workflow files (basename
#                       or .github/workflows path) or workflow names whose runs
#                       are never re-run automatically, because their jobs have
#                       irreversible steps (publishing, promoting). Empty by
#                       default (#967)
#   PROTECTED_JOB_PATTERN - Case-insensitive ERE; a failed job whose name matches
#                       is never re-run automatically, and since `gh run rerun
#                       --failed` cannot exclude jobs, the whole run is left
#                       alone (default: publish|promote|release|upload). Empty
#                       disables the job-name guard
#   ACQUISITION_MAX_JOBS - Max failed jobs whose check-run annotations are read
#                       for the runner-acquisition signature (a job that never
#                       started leaves no log); 0 disables (default: 10)
#   AGENT_CHECK_MAX_JOBS - Max failed jobs with an agent-failure shape whose
#                       annotations and raw log are read (#1616); 0 disables
#                       (default: 3). The rule re-runs attempt 1 only
#                       (independent of MAX_RERUNS)
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
#   LOG_PROBE_MAX_JOBS - Max raw per-job log probes per empty `--log-failed`
#                       attempt; 0 disables the #794 probe (default: 5)
#   LOG_PROBE_MAX_CALLS - Max probe `gh api` calls for the whole invocation; a
#                       `--paginate`d listing counts as one call however many
#                       pages it walks. 0 disables the probe (default: 12)
#   LOG_PROBE_CMD_TIMEOUT - Wall-clock bound in seconds on each probe `gh` call,
#                       at least 1 (default: 15). Deliberately far below
#                       GH_CMD_TIMEOUT: the probe is instrumentation and must
#                       never eat the log-fetch loop's own time budget
#   LOG_PROBE_TIME_BUDGET - Total wall clock in seconds the probe may spend
#                       across the whole invocation, at least 1 (default: 60).
#                       Bounds how far probing can push the script out past
#                       LOG_FETCH_DEADLINE and keeps the WATCHDOG_DEADLINE
#                       margin intact
#   HEAD_CMD_TIMEOUT  - Wall-clock bound in seconds on each `gh` read of the
#                       #1706 head check (the run; for a push or
#                       workflow_dispatch run its branches and tags; the
#                       branch or tag commit), at least 1
#                       (default: 15)
#   GITHUB_REPOSITORY - owner/repo (provided by GitHub Actions)
#   GH_TOKEN          - Token with actions: write (re-run, logs), checks: read
#                       (annotations) and contents: read (the current tip of
#                       the run's ref: a superseded commit is never re-run, #1706)

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
: "${PROTECTED_WORKFLOWS:=}"
# `=` rather than `:=`: an explicitly empty pattern disables the job guard,
# only an unset one takes the default.
: "${PROTECTED_JOB_PATTERN=publish|promote|release|upload}"
: "${ACQUISITION_MAX_JOBS:=10}"
: "${AGENT_CHECK_MAX_JOBS:=3}"
: "${LOG_FETCH_ATTEMPTS:=5}"
: "${LOG_FETCH_DELAY:=5}"
: "${LOG_FETCH_DEADLINE:=180}"
: "${GH_CMD_TIMEOUT:=60}"
: "${WATCHDOG_DEADLINE:=420}"
: "${LOG_PROBE_MAX_JOBS:=5}"
: "${LOG_PROBE_MAX_CALLS:=12}"
: "${LOG_PROBE_CMD_TIMEOUT:=15}"
: "${LOG_PROBE_TIME_BUDGET:=60}"
: "${HEAD_CMD_TIMEOUT:=15}"

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
# Both probe bounds are non-negative: zero is the documented off switch for the
# #794 instrumentation, which is observational and must always be droppable.
if [[ ! "$LOG_PROBE_MAX_JOBS" =~ ^[0-9]+$ ]]; then
	echo "::error::LOG_PROBE_MAX_JOBS must be a non-negative integer (got '${LOG_PROBE_MAX_JOBS}')"
	exit 1
fi
if [[ ! "$LOG_PROBE_MAX_CALLS" =~ ^[0-9]+$ ]]; then
	echo "::error::LOG_PROBE_MAX_CALLS must be a non-negative integer (got '${LOG_PROBE_MAX_CALLS}')"
	exit 1
fi
# Positive like the other per-call bounds: zero would hand `timeout` "no limit".
if [[ ! "$HEAD_CMD_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::HEAD_CMD_TIMEOUT must be a positive integer (got '${HEAD_CMD_TIMEOUT}')"
	exit 1
fi
# Positive, like the other per-call bound: zero would hand `timeout` a "no
# limit" argument and let one probe call run unbounded inside the fetch loop.
if [[ ! "$LOG_PROBE_CMD_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::LOG_PROBE_CMD_TIMEOUT must be a positive integer (got '${LOG_PROBE_CMD_TIMEOUT}')"
	exit 1
fi
# Positive: the off switches are LOG_PROBE_MAX_JOBS=0 and LOG_PROBE_MAX_CALLS=0,
# and a zero time budget would be a third, silently different one.
if [[ ! "$LOG_PROBE_TIME_BUDGET" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::LOG_PROBE_TIME_BUDGET must be a positive integer (got '${LOG_PROBE_TIME_BUDGET}')"
	exit 1
fi

if [[ ! "$ACQUISITION_MAX_JOBS" =~ ^[0-9]+$ ]]; then
	echo "::error::ACQUISITION_MAX_JOBS must be a non-negative integer (got '${ACQUISITION_MAX_JOBS}')"
	exit 1
fi
if [[ ! "$AGENT_CHECK_MAX_JOBS" =~ ^[0-9]+$ ]]; then
	echo "::error::AGENT_CHECK_MAX_JOBS must be a non-negative integer (got '${AGENT_CHECK_MAX_JOBS}')"
	exit 1
fi
# A malformed pattern would make grep exit 2 on every job name, which reads
# like "no protected job" — the one misreading this guard exists to prevent.
if [[ -n "$PROTECTED_JOB_PATTERN" ]]; then
	pattern_status=0
	grep -Eiq -- "$PROTECTED_JOB_PATTERN" <<<"" || pattern_status=$?
	if ((pattern_status == 2)); then
		echo "::error::PROTECTED_JOB_PATTERN is not a valid extended regular expression (got '${PROTECTED_JOB_PATTERN}')"
		exit 1
	fi
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
# Sourced in this shell for the transient-infrastructure signatures, whose
# single source is ../lib/infra-signatures.sh. The lib in turn sources
# cosign.sh for COSIGN_OIDC_TRANSIENT_MARKERS, the single source of the
# transient ambient-OIDC marker strings (#719); this script is not a signing
# path, but the markers are cosign-emitted strings, so cosign.sh stays their
# home. Sourcing here is side-effect-free (a load guard, function
# definitions, and two numeric defaults).
# shellcheck source=../lib/infra-signatures.sh
source "$SCRIPT_DIR/../lib/infra-signatures.sh"

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

# The transient-infra failure signatures and their matcher live in
# ../lib/infra-signatures.sh so the release-mode failure notifier
# (report-release-failure.sh) can reuse the exact same classification when it
# decides whether an automatic re-run may still be in flight. The SIGNATURES
# environment variable still extends the built-in list: it is mapped onto the
# lib's INFRA_SIGNATURES input, which infra_match_signature reads, so this
# script's documented SIGNATURES input keeps working unchanged.
INFRA_SIGNATURES="$SIGNATURES"

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

# =============================================================================
# Ingestion probe instrumentation (#794) — observational only
# =============================================================================
#
# #794 proposes reading the raw per-job log endpoint instead of
# `gh run view --log-failed`, on the theory that the run archive lags behind it
# and the safety net therefore matches against an empty payload. That theory is
# unproven: the two endpoints have only ever been compared *after* ingestion
# finished. Nothing here changes the verdict — it records, for each empty
# `--log-failed` attempt, what the raw endpoint returned at the same instant,
# so a handful of natural runner-loss failures settle the question with
# evidence instead of argument.
#
# Every failure mode of the probe (HTTP error, BlobNotFound, empty body,
# missing jq output, a killed `gh`) is recorded and swallowed: the safety net
# already exists to keep a red run from needing a human, and instrumentation
# that can redden it would be worse than no instrumentation at all.

# Markdown rows accumulated by the probe, flushed once by emit_probe_evidence.
PROBE_EVIDENCE=()
# `gh api` calls the probe has spent, against the LOG_PROBE_MAX_CALLS budget. A
# `--paginate`d listing debits one call however many pages it walks.
PROBE_CALLS=0
# The attempt-jobs listing, cached after the first successful non-empty fetch.
# The run is complete and the attempt is pinned, so its job conclusions cannot
# change under us; per-row age is computed at probe time, so nothing is lost by
# not asking again. An errored or empty listing is not cached — those are the
# two cases where asking again can legitimately give a different answer.
PROBE_LISTING_CACHE=""

# True while the probe still has budget for one more `gh api` call.
probe_has_budget() {
	((PROBE_CALLS < LOG_PROBE_MAX_CALLS))
}

# Wall clock left in the log-fetch loop's LOG_FETCH_DEADLINE, from the loop's
# own start. Set by fetch_failed_logs_with_retry; before the loop runs, the
# whole deadline is nominally left.
PROBE_LOOP_START=$SECONDS
# Seconds spent inside probe `gh` calls. Credited back to the fetch loop, whose
# deadline check subtracts it, so probing can never cost the loop an attempt:
# with the credit, "elapsed" means "elapsed doing the loop's own work".
PROBE_TIME_SPENT=0

# Bill the wall clock since $1 to the probe. Called after the call rather than
# around it: probe calls read their output through a command substitution, and
# a subshell's increment of PROBE_TIME_SPENT would be discarded on return.
probe_bill_since() {
	PROBE_TIME_SPENT=$((PROBE_TIME_SPENT + SECONDS - $1))
}

probe_time_remaining() {
	printf '%s\n' "$((LOG_FETCH_DEADLINE - (SECONDS - PROBE_LOOP_START - PROBE_TIME_SPENT)))"
}

# Seconds of total probe spend still allowed by LOG_PROBE_TIME_BUDGET.
probe_spend_remaining() {
	printf '%s\n' "$((LOG_PROBE_TIME_BUDGET - PROBE_TIME_SPENT))"
}

# True while one more worst-case probe call fits in the total spend budget.
#
# Crediting probe time back to the fetch loop protects the loop's attempts, but
# on its own it lets probing push the whole script out by an unbounded amount —
# straight into WATCHDOG_DEADLINE, whose SIGKILL lands before the evidence is
# flushed. This is the second bound: LOG_FETCH_DEADLINE (180) plus this budget
# (60) plus startup stays comfortably inside WATCHDOG_DEADLINE (420).
probe_has_spend_budget() {
	(($(probe_spend_remaining) >= LOG_PROBE_CMD_TIMEOUT + PROBE_KILL_GRACE))
}

# True while one more probe call fits in the loop's remaining wall clock with a
# full real fetch still left over.
#
# This is the invariant that keeps the instrumentation observational (#794
# review). The probe runs *between* two LOG_FETCH_DEADLINE checks, which happen
# only at the top of the loop, so unbudgeted probe calls could push the next
# check past the deadline: attempts 2-5 would never run, a payload that would
# have arrived on attempt 3 would never be matched, and a genuine infra failure
# would go un-re-run *because* of the instrumentation. Worst case it would also
# blow WATCHDOG_DEADLINE, whose SIGKILL lands before emit_probe_evidence and
# would take the evidence with it.
#
# Reserved: this call's own bound plus the kill grace, and GH_CMD_TIMEOUT for
# the next real fetch, so the probe can only ever spend slack the fetch loop
# was never going to use.
probe_has_time_budget() {
	local needed=$((LOG_PROBE_CMD_TIMEOUT + PROBE_KILL_GRACE + GH_CMD_TIMEOUT))
	(($(probe_time_remaining) >= needed))
}

# Seconds `timeout` waits after SIGTERM before SIGKILL on a probe call.
readonly PROBE_KILL_GRACE=5

# `gh` under the probe's own, much shorter bound. Never gh_bounded: a probe is
# allowed to give up, and GH_CMD_TIMEOUT is sized for a log-archive download
# the probe is not doing.
gh_probe_bounded() {
	"$TIMEOUT_BIN" --kill-after="${PROBE_KILL_GRACE}s" "$LOG_PROBE_CMD_TIMEOUT" gh "$@" </dev/null
}

# Seconds between an ISO-8601 timestamp and now, or "unknown" when the stamp is
# absent or unparseable. GNU `date -d` first, BSD `date -j -f` second, so this
# reads the same on a runner and on a developer's mac.
seconds_since() {
	local ts="$1" epoch="" now
	if [[ -z "$ts" || "$ts" == "null" ]]; then
		printf 'unknown\n'
		return 0
	fi
	epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || epoch=""
	if [[ -z "$epoch" ]]; then
		epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)" || epoch=""
	fi
	if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
		printf 'unknown\n'
		return 0
	fi
	now="$(date -u +%s)"
	printf '%s\n' "$((now - epoch))"
}

# First line of a probe `gh` call's stderr, squeezed onto one line and cut to
# 120 characters. Enough to tell an egress block ("dial tcp … i/o timeout")
# from a genuine 404/BlobNotFound, which is the difference between "the raw
# endpoint has nothing" and "this runner could not reach the raw endpoint" —
# and therefore between valid and invalid evidence for #794.
probe_stderr_tail() {
	local file="$1" line=""
	[[ -s "$file" ]] || return 0
	IFS= read -r line <"$file" || true
	line="${line//[[:cntrl:]]/ }"
	printf '%s' "${line:0:120}"
}

# Outputs of probe_one_job_log. Globals rather than a printed result because
# a command substitution would run the probe in a subshell, where the
# PROBE_CALLS budget it spends would be discarded on return — an unbounded
# probe wearing the appearance of a bounded one.
PROBE_JOB_STATE=""
PROBE_JOB_BYTES=0
PROBE_JOB_DETAIL=""

# Fetch the raw log of one job and describe what came back. Never fails.
probe_one_job_log() {
	local job_id="$1" body status=0 started=$SECONDS
	local err_file="${WATCHDOG_STATE_DIR}/probe.err"
	PROBE_CALLS=$((PROBE_CALLS + 1))
	PROBE_JOB_STATE=""
	PROBE_JOB_BYTES=0
	PROBE_JOB_DETAIL=""
	: >"$err_file"
	body="$(gh_probe_bounded api "repos/${GITHUB_REPOSITORY}/actions/jobs/${job_id}/logs" 2>"$err_file")" || status=$?
	probe_bill_since "$started"
	if ((status == TIMEOUT_EXIT_STATUS)); then
		PROBE_JOB_STATE="timed out"
		PROBE_JOB_DETAIL="$(probe_stderr_tail "$err_file")"
	elif ((status != 0)); then
		PROBE_JOB_STATE="unavailable (gh exit ${status})"
		PROBE_JOB_DETAIL="$(probe_stderr_tail "$err_file")"
	elif payload_has_content "$body"; then
		PROBE_JOB_STATE="available"
		# Bytes, not characters: ${#body} counts characters in the ambient
		# locale, and a raw job log is arbitrary bytes. LC_ALL=C makes the
		# expansion byte-wise. Note the count is of the payload as bash holds
		# it, so trailing newlines stripped by the command substitution are not
		# included — the figure is a floor, which is all the evidence needs.
		local LC_ALL=C
		PROBE_JOB_BYTES=${#body}
	else
		PROBE_JOB_STATE="empty"
	fi
}

# Record, for one empty `--log-failed` attempt, what the raw per-job log
# endpoint returns for the failed jobs of the current attempt.
#
# Job selection mirrors what #794 proposes for the real switch — conclusion
# `failure`, `cancelled` or `timed_out` — and is done by `gh`'s built-in jq so
# the probe adds no dependency of its own. `timed_out` is in the set because a
# `timeout-minutes` kill is squarely the evidence class #794 is about: the job
# died mid-step, which is exactly when the run archive and the raw endpoint are
# most likely to disagree. Pagination is explicit (`--paginate`): a matrix run
# can exceed the endpoint's 100-jobs-per-page limit, and a relevant job on page
# two would otherwise silently drop out of the evidence.
probe_raw_job_logs() {
	local attempt="$1" listing status=0 probed=0 job_id conclusion completed_at age
	local started err_file="${WATCHDOG_STATE_DIR}/probe.err" detail listing_state age_phrase

	# The two off switches, before any recording: with the probe disabled there
	# must be no rows, no evidence section and no log lines at all, or "off"
	# would still be visible in every run's summary.
	((LOG_PROBE_MAX_JOBS > 0)) || return 0
	((LOG_PROBE_MAX_CALLS > 0)) || return 0
	# An exhausted budget, by contrast, is recorded rather than silent: a table
	# that simply stops has no way to say whether the later attempts found logs
	# or went unprobed, and an unexplained gap is not evidence.
	if ! probe_has_budget; then
		log_info "#794 probe: call budget of ${LOG_PROBE_MAX_CALLS} spent; attempt ${attempt} went unprobed"
		PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | not probed: call budget of ${LOG_PROBE_MAX_CALLS} spent | 0 |")
		return 0
	fi
	if ! probe_has_spend_budget; then
		log_info "#794 probe: probe time budget of ${LOG_PROBE_TIME_BUDGET}s spent (${PROBE_TIME_SPENT}s used); attempt ${attempt} went unprobed"
		PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | not probed: probe time budget spent (${PROBE_TIME_SPENT}s of ${LOG_PROBE_TIME_BUDGET}s) | 0 |")
		return 0
	fi
	if ! probe_has_time_budget; then
		log_info "#794 probe: only $(probe_time_remaining)s of the log-fetch deadline left; attempt ${attempt} went unprobed"
		PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | not probed: $(probe_time_remaining)s of log-fetch deadline left | 0 |")
		return 0
	fi

	if payload_has_content "$PROBE_LISTING_CACHE"; then
		listing="$PROBE_LISTING_CACHE"
	else
		PROBE_CALLS=$((PROBE_CALLS + 1))
		started=$SECONDS
		: >"$err_file"
		listing="$(gh_probe_bounded api \
			"repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" \
			--paginate \
			--jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") | [(.id|tostring), .conclusion, (.completed_at // "")] | @tsv' \
			2>"$err_file")" || status=$?
		probe_bill_since "$started"
		if ((status != 0)); then
			detail="$(probe_stderr_tail "$err_file")"
			# Same wording as a killed per-job probe: a listing the probe's own
			# bound cut short is a timeout, not an API error.
			if ((status == TIMEOUT_EXIT_STATUS)); then
				listing_state="job listing timed out"
			else
				listing_state="job listing failed (gh exit ${status})"
			fi
			log_warn "#794 probe: listing the failed jobs of run ${RUN_ID} attempt ${RUN_ATTEMPT} exited ${status} (attempt ${attempt})${detail:+: ${detail}}"
			PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | ${listing_state}${detail:+ — ${detail}} | 0 |")
			return 0
		fi
		if ! payload_has_content "$listing"; then
			PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | no failed/cancelled/timed_out job in the listing | 0 |")
			return 0
		fi
		PROBE_LISTING_CACHE="$listing"
	fi

	while IFS=$'\t' read -r job_id conclusion completed_at; do
		[[ -n "$job_id" ]] || continue
		if ((probed >= LOG_PROBE_MAX_JOBS)) || ! probe_has_budget; then
			PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | probe ceiling reached (${probed} job(s) probed, ${PROBE_CALLS} call(s) spent) | 0 |")
			break
		fi
		if ! probe_has_spend_budget; then
			PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | probe stopped: probe time budget spent (${PROBE_TIME_SPENT}s of ${LOG_PROBE_TIME_BUDGET}s) | 0 |")
			break
		fi
		if ! probe_has_time_budget; then
			PROBE_EVIDENCE+=("| ${attempt} | unknown | 0 | — | probe stopped: $(probe_time_remaining)s of log-fetch deadline left | 0 |")
			break
		fi
		probed=$((probed + 1))
		age="$(seconds_since "$completed_at")"
		# "completed unknown" rather than "completed unknowns ago" when the
		# timestamp was missing or unparseable.
		if [[ "$age" == "unknown" ]]; then
			age_phrase="completed unknown"
		else
			age_phrase="completed ${age}s ago"
		fi
		probe_one_job_log "$job_id"
		log_info "#794 probe: attempt ${attempt}, job ${job_id} (${conclusion}, ${age_phrase}) raw log ${PROBE_JOB_STATE}, ${PROBE_JOB_BYTES} bytes${PROBE_JOB_DETAIL:+ (${PROBE_JOB_DETAIL})}"
		PROBE_EVIDENCE+=("| ${attempt} | ${age} | 0 | \`${job_id}\` (${conclusion}) | ${PROBE_JOB_STATE}${PROBE_JOB_DETAIL:+ — ${PROBE_JOB_DETAIL}} | ${PROBE_JOB_BYTES} |")
	done <<<"$listing"
}

# Flush the probe rows into the step summary, clearly labelled as evidence for
# #794 rather than as part of the verdict above it. No rows, no section.
emit_probe_evidence() {
	local row
	((${#PROBE_EVIDENCE[@]} > 0)) || return 0
	add_github_summary ""
	add_github_summary "### Log-ingestion probe evidence (#794)"
	add_github_summary ""
	add_github_summary "Temporary instrumentation, **observational only** — it does not affect the verdict above. Each row is one \`gh run view --log-failed\` attempt that came back empty, alongside what the raw per-job log endpoint (\`/actions/jobs/{job_id}/logs\`) returned at that same moment. #794 is implemented only if the raw endpoint is shown to have content while \`--log-failed\` is still empty."
	add_github_summary ""
	add_github_summary "| attempt | job completed (s ago) | \`--log-failed\` bytes | job | raw log | raw bytes |"
	add_github_summary "| --- | --- | --- | --- | --- | --- |"
	for row in "${PROBE_EVIDENCE[@]}"; do
		add_github_summary "$row"
	done
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

	# Same clock the deadline is measured from, so the probe can tell how much
	# of it is left before spending any of it (#794 review).
	PROBE_LOOP_START=$start
	FETCHED_LOGS=""
	FETCH_OUTCOME="empty"
	FETCH_TIMEOUT_REASON="command"
	FETCH_ELAPSED=0

	for ((attempt = 1; attempt <= LOG_FETCH_ATTEMPTS; attempt++)); do
		FETCH_ELAPSED=$((SECONDS - start))
		# The deadline measures the loop's own work, so time spent inside #794
		# probe calls is credited back. Without the credit, stalled probes eat
		# attempts the loop would otherwise have made — an attempt due at t=170
		# no longer fits — and the instrumentation changes the verdict, which is
		# exactly what it must never do. LOG_PROBE_TIME_BUDGET is what stops the
		# credit from pushing the script into WATCHDOG_DEADLINE.
		# Attempt 1 always runs: LOG_FETCH_DEADLINE is positive and elapsed is 0.
		if (((FETCH_ELAPSED - PROBE_TIME_SPENT) >= LOG_FETCH_DEADLINE)); then
			FETCH_OUTCOME="timeout"
			FETCH_TIMEOUT_REASON="deadline"
			log_warn "Log-fetch deadline of ${LOG_FETCH_DEADLINE}s reached after ${FETCH_ELAPSED}s for run ${RUN_ID} (${PROBE_TIME_SPENT}s of it spent probing, not counted); abandoning the remaining attempt(s) of ${LOG_FETCH_ATTEMPTS}"
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
			# The one moment worth measuring for #794: the run archive has
			# nothing, so ask the raw per-job endpoint what it has right now.
			# Best-effort and verdict-neutral by construction.
			probe_raw_job_logs "$attempt" || true
		fi

		if ((attempt < LOG_FETCH_ATTEMPTS && LOG_FETCH_DELAY > 0)); then
			sleep "$LOG_FETCH_DELAY"
		fi
	done

	FETCH_ELAPSED=$((SECONDS - start))
	return 1
}

# Print the first signature found in the logs on stdin; return 1 when none
# match. Delegates to the shared lib; see infra_match_signature for why
# matching stays case-sensitive (#719).
match_signature() {
	local logs="$1"
	infra_match_signature "$logs"
}

# =============================================================================
# Irreversible-step protection (#967)
# =============================================================================
#
# `gh run rerun --failed` re-runs every failed job of the run, and a job that
# publishes or promotes cannot be undone by a second attempt: the v0.160.3rc1
# publish run was re-run into the npm approval gate after a deterministic
# egress refusal matched a signature. Two guards, both checked before any log
# is fetched: the triggering workflow may be protected outright, and a failed
# job whose name looks irreversible protects the whole run, because there is
# no way to re-run only the other failed jobs.

# Failed/cancelled/timed-out jobs of this attempt as TSV rows of
# "<id>\t<name>\t<steps that ran>", fetched once and cached; the acquisition
# check below reads the same listing.
ATTEMPT_JOBS=""
ATTEMPT_JOBS_STATE=""

fetch_attempt_jobs() {
	local status=0
	if [[ -n "$ATTEMPT_JOBS_STATE" ]]; then
		[[ "$ATTEMPT_JOBS_STATE" == "ok" ]]
		return
	fi
	ATTEMPT_JOBS="$(gh_bounded api \
		"repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" \
		--paginate \
		--jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") | [(.id|tostring), .name, ([.steps[]? | select(.conclusion != null and .conclusion != "skipped")] | length | tostring)] | @tsv')" || status=$?
	if ((status != 0)); then
		ATTEMPT_JOBS=""
		ATTEMPT_JOBS_STATE="error"
		log_warn "Listing the failed jobs of run ${RUN_ID} attempt ${RUN_ATTEMPT} exited ${status}"
		return 1
	fi
	ATTEMPT_JOBS_STATE="ok"
	return 0
}

# Print the PROTECTED_WORKFLOWS entry naming the run's workflow (by file
# basename, .github/workflows path or display name); return 1 when none does.
protected_workflow_entry() {
	local wf_path="$1" wf_name="$2" wf_base entry
	wf_base="${wf_path##*/}"
	while IFS= read -r entry; do
		# Trim surrounding whitespace: a list is easiest to write one entry per
		# line with indentation, or comma-separated on one line.
		entry="${entry#"${entry%%[![:space:]]*}"}"
		entry="${entry%"${entry##*[![:space:]]}"}"
		[[ -z "$entry" ]] && continue
		if [[ "$entry" == "$wf_base" || "$entry" == "$wf_path" || "$entry" == "$wf_name" ]]; then
			printf '%s\n' "$entry"
			return 0
		fi
	done < <(tr ',' '\n' <<<"$PROTECTED_WORKFLOWS")
	return 1
}

# Split the failed jobs by PROTECTED_JOB_PATTERN. Globals rather than printed
# output because the caller needs both lists.
PROTECTED_JOBS=()
UNPROTECTED_JOBS=()

classify_failed_jobs() {
	local job_id name steps
	PROTECTED_JOBS=()
	UNPROTECTED_JOBS=()
	while IFS=$'\t' read -r job_id name steps; do
		[[ -n "$job_id" ]] || continue
		if grep -Eiq -- "$PROTECTED_JOB_PATTERN" <<<"$name"; then
			PROTECTED_JOBS+=("$name")
		else
			UNPROTECTED_JOBS+=("$name")
		fi
	done <<<"$ATTEMPT_JOBS"
}

# Join "$@" with ", ".
join_names() {
	local joined
	joined="$(printf '%s, ' "$@")"
	printf '%s\n' "${joined%, }"
}

# Return 0 when the run may be re-run; return 1, having written the summary,
# when a protection rule (or the inability to evaluate one) forbids it.
check_protection() {
	local status=0 meta wf_path wf_name entry names others

	if [[ -n "$PROTECTED_WORKFLOWS" ]]; then
		log_phase "Checking whether the workflow of run ${RUN_ID} is protected"
		meta="$(gh_bounded api "repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}" --jq '[.path, .name] | @tsv')" || status=$?
		if ((status != 0)); then
			# Fail closed: protection is the property that keeps a publish
			# from being repeated, so "could not check" must mean "do not act".
			log_warn "Reading the workflow of run ${RUN_ID} exited ${status}; protection cannot be verified, not re-running"
			echo "::warning::Could not read the workflow of run ${RUN_ID} (gh exit ${status}); the protected-workflow check was inconclusive and the failed jobs were not re-run"
			add_github_summary "## Auto re-run on infra failure"
			add_github_summary ""
			add_github_summary "Inconclusive: could not read the workflow of run ${RUN_ID} (\`gh api\` exited ${status}), so the protected-workflow check could not run. The failed jobs were **not** re-run — re-check the run manually."
			return 1
		fi
		IFS=$'\t' read -r wf_path wf_name <<<"$meta"
		if entry="$(protected_workflow_entry "$wf_path" "$wf_name")"; then
			log_info "Run ${RUN_ID} belongs to protected workflow ${wf_path} (${wf_name}), matched by '${entry}'; not re-running"
			echo "::notice::Run ${RUN_ID} belongs to protected workflow ${wf_path}; its jobs have irreversible steps and are never re-run automatically"
			add_github_summary "## Auto re-run on infra failure"
			add_github_summary ""
			add_github_summary "Protected workflow: run ${RUN_ID} belongs to \`${wf_path}\` (\`${wf_name}\`), listed in \`protected-workflows\` as \`${entry}\`. Its jobs have irreversible steps (publish, promote), so the failed jobs were **not** re-run regardless of the failure logs. Re-run by hand only after confirming nothing was published."
			return 1
		fi
	fi

	if [[ -n "$PROTECTED_JOB_PATTERN" ]]; then
		log_phase "Checking the failed jobs of run ${RUN_ID} against the protected-job pattern"
		if ! fetch_attempt_jobs; then
			echo "::warning::Could not list the failed jobs of run ${RUN_ID}; the protected-job check was inconclusive and the failed jobs were not re-run"
			add_github_summary "## Auto re-run on infra failure"
			add_github_summary ""
			add_github_summary "Inconclusive: could not list the failed jobs of run ${RUN_ID} attempt ${RUN_ATTEMPT}, so the protected-job check could not run. The failed jobs were **not** re-run — re-check the run manually."
			return 1
		fi
		classify_failed_jobs
		# The run failed, so a listing with no failed job is a partial answer
		# (an incomplete page, a workflow-level failure), not proof that nothing
		# irreversible failed. Fail closed rather than read absence as consent.
		if ((${#PROTECTED_JOBS[@]} == 0 && ${#UNPROTECTED_JOBS[@]} == 0)); then
			log_warn "The failed-jobs listing of run ${RUN_ID} attempt ${RUN_ATTEMPT} is empty; protection cannot be verified, not re-running"
			echo "::warning::The failed-jobs listing of run ${RUN_ID} came back empty; the protected-job check was inconclusive and the failed jobs were not re-run"
			add_github_summary "## Auto re-run on infra failure"
			add_github_summary ""
			add_github_summary "Inconclusive: the failed-jobs listing of run ${RUN_ID} attempt ${RUN_ATTEMPT} came back empty although the run failed, so the protected-job check could not tell whether an irreversible job is among them. The failed jobs were **not** re-run — re-check the run manually."
			return 1
		fi
		if ((${#PROTECTED_JOBS[@]} > 0)); then
			names="$(join_names "${PROTECTED_JOBS[@]}")"
			log_info "Run ${RUN_ID} has protected failed job(s) matching '${PROTECTED_JOB_PATTERN}': ${names}; not re-running"
			echo "::notice::Run ${RUN_ID} has failed job(s) with irreversible steps (${names}); not re-running automatically"
			add_github_summary "## Auto re-run on infra failure"
			add_github_summary ""
			if ((${#UNPROTECTED_JOBS[@]} > 0)); then
				others="$(join_names "${UNPROTECTED_JOBS[@]}")"
				add_github_summary "Protected job(s): ${names} (matched \`protected-job-pattern\` \`${PROTECTED_JOB_PATTERN}\`). Other failed job(s) — ${others} — would have been eligible, but \`gh run rerun --failed\` cannot exclude jobs, so **nothing** was re-run. Re-run the eligible jobs by hand from the run page."
			else
				add_github_summary "Protected job(s): ${names} (matched \`protected-job-pattern\` \`${PROTECTED_JOB_PATTERN}\`). Their steps are irreversible, so the failed jobs were **not** re-run regardless of the failure logs."
			fi
			return 1
		fi
	fi
	return 0
}

# =============================================================================
# Runner-acquisition failures (#967)
# =============================================================================
#
# "The job repeatedly failed to be acquired" ends a job before its first step,
# so the failed-job log has nothing to match and the fixed-string signatures
# never fire. GitHub records the reason as a check-run annotation on the job;
# this reads those annotations for failed jobs that ran zero steps. Print a
# description of the match; return 1 when no such job exists.
check_runner_acquisition() {
	local job_id name steps probed=0 annotations matched status
	((ACQUISITION_MAX_JOBS > 0)) || return 1
	fetch_attempt_jobs || return 1
	while IFS=$'\t' read -r job_id name steps; do
		[[ -n "$job_id" ]] || continue
		[[ "$steps" == "0" ]] || continue
		((probed < ACQUISITION_MAX_JOBS)) || break
		probed=$((probed + 1))
		status=0
		annotations="$(gh_bounded api "repos/${GITHUB_REPOSITORY}/check-runs/${job_id}/annotations" --paginate --jq '.[].message')" || status=$?
		if ((status != 0)); then
			log_warn "Reading the annotations of job ${job_id} (${name}) exited ${status}"
			continue
		fi
		if matched="$(infra_match_acquisition_annotation "$annotations")"; then
			printf 'runner acquisition failure on job %s (%s): %s\n' "$job_id" "$name" "$matched"
			return 0
		fi
	done <<<"$ATTEMPT_JOBS"
	return 1
}

# =============================================================================
# harden-runner agent did not start, or was the eBPF fallback (#1616, #1668)
# =============================================================================
#
# The verify step fails closed when the agent did not start, or when
# harden-runner installed its eBPF fallback agent, and that stays. A DNS
# SERVFAIL or REFUSED while the agent resolves its allowed hosts at start, and
# a failed TLS-status call that made harden-runner install the eBPF agent,
# are transient (infra-signatures.sh). The failure text alone does not prove
# it, because any step can print it: a job counts only when its shape, its
# failure annotations (which name the cause) and output in its raw log that no
# job step can have printed all agree (infra_harden_runner_shape,
# infra_harden_runner_cause, infra_harden_runner_log_evidence).
#
# Only attempt 1 is ever re-run on this rule, whatever MAX_RERUNS allows: a
# failure that comes back on the re-run is not treated as transient again. A
# failed end-of-job recheck (the agent stopped enforcing mid-job) is never
# re-run here.
#
# AGENT_CHECK_MAX_JOBS bounds the expensive reads: a job is counted when its
# annotations are read, after the shape and id checks that need no API call.
# When the budget runs out with shape-matching jobs left unread, a warning
# names how many, so a skipped re-run is visible (#1667 review).
#
# Print a description naming the job, the step and the rule; return 1 when no
# job qualifies.
check_harden_runner_agent() {
	local jobs job shape after matrix id name messages cause log evidence
	local examined=0 unexamined=0 status=0
	((AGENT_CHECK_MAX_JOBS > 0)) || return 1
	if [[ "$RUN_ATTEMPT" != 1 ]]; then
		log_info "Run ${RUN_ID} is on attempt ${RUN_ATTEMPT}; the harden-runner agent start-up rule re-runs attempt 1 only"
		return 1
	fi
	jobs="$(gh_bounded api \
		"repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" \
		--paginate --jq '.jobs[] | select(.conclusion == "failure") | tojson')" || status=$?
	if ((status != 0)); then
		log_warn "Listing the failed jobs of run ${RUN_ID} for the harden-runner agent check exited ${status}"
		return 1
	fi
	while IFS= read -r job; do
		[[ -n "$job" ]] || continue
		shape="$(infra_harden_runner_shape <<<"$job")" || continue
		IFS=$'\t' read -r _ after matrix <<<"$shape"
		id="$(jq -r '.id | numbers' <<<"$job" 2>/dev/null)" || continue
		[[ "$id" =~ ^[0-9]+$ ]] || continue
		if ((examined >= AGENT_CHECK_MAX_JOBS)); then
			unexamined=$((unexamined + 1))
			continue
		fi
		examined=$((examined + 1))
		name="$(jq -r '.name // ""' <<<"$job" 2>/dev/null)" || name=""
		status=0
		messages="$(gh_bounded api "repos/${GITHUB_REPOSITORY}/check-runs/${id}/annotations" \
			--paginate --jq '.[] | select(.annotation_level == "failure") | .message')" || status=$?
		if ((status != 0)); then
			log_warn "Reading the annotations of job ${id} (${name}) exited ${status}"
			continue
		fi
		cause="$(infra_harden_runner_cause "$after" "$matrix" <<<"$messages")" || continue
		status=0
		log="$(gh_bounded api "repos/${GITHUB_REPOSITORY}/actions/jobs/${id}/logs")" || status=$?
		if ((status != 0)); then
			log_warn "Reading the log of job ${id} (${name}) exited ${status}"
			continue
		fi
		infra_harden_runner_log_evidence "$cause" <<<"$log" || continue
		if [[ "$cause" == agent-ebpf ]]; then
			evidence="harden-runner's own pre-step output in the job log shows its TLS-status fallback (\"${INFRA_HR_TLS_FALLBACK_LINE}\")"
			printf 'harden-runner eBPF fallback agent refused on job %s (%s): step "%s" failed with "%s", and %s; re-run on attempt 1 only\n' \
				"$id" "$name" "$INFRA_HR_VERIFY_STEP" "$INFRA_HR_EBPF_MESSAGE" "$evidence"
		else
			evidence="the agent's own output in the job log (printed by harden-runner or by the verify step, before any job step) shows a DNS SERVFAIL or REFUSED (status 2 or 5) for an allowed host"
			printf 'harden-runner agent start-up DNS failure on job %s (%s): step "%s" failed with "%s", and %s; re-run on attempt 1 only\n' \
				"$id" "$name" "$INFRA_HR_VERIFY_STEP" "$INFRA_HR_STARTUP_MESSAGE" "$evidence"
		fi
		return 0
	done <<<"$jobs"
	if ((unexamined > 0)); then
		log_warn "The harden-runner agent check of run ${RUN_ID} read ${examined} job(s) (AGENT_CHECK_MAX_JOBS=${AGENT_CHECK_MAX_JOBS}) and left ${unexamined} more failed job(s) with the agent-failure shape unexamined; none of those was re-run"
		echo "::warning::harden-runner agent check: ${unexamined} failed job(s) with the agent-failure shape were not examined (AGENT_CHECK_MAX_JOBS=${AGENT_CHECK_MAX_JOBS}); a transient agent failure among them was not re-run" >&2
	fi
	return 1
}

# =============================================================================
# Superseded commits (#1706)
# =============================================================================
#
# A re-run of a superseded commit's run joins the concurrency group of the
# current commit's run, and with cancel-in-progress it cancels that run: on
# 2026-11-20 run 44749053360 (commit 6a57bf0e) was re-run two minutes after
# commit 22b64afd was pushed, and the current commit's run 44752165523 was
# cancelled. So, immediately before re-running, the run's head SHA is compared
# with the current tip of the branch it ran on, in the run's head repository:
#
#   - pull_request, pull_request_target: the head branch, which is the pull
#     request's head;
#   - merge_group: the queue branch (gh-readonly-queue/...), deleted once the
#     entry leaves the queue, so a finished entry is not re-run;
#   - schedule: the branch the schedule ran on;
#   - push, workflow_dispatch: these run on a branch or a tag, and the run
#     payload does not say which (`head_branch` holds either name and there
#     is no `ref` field). Both namespaces are listed: a branch alone is
#     compared by its tip; a tag alone by the commit it names (an annotated
#     tag peeled), so a tag run is re-run while its tag still names the run's
#     commit; both, or neither, is not re-run. A deleted branch whose name a
#     tag also has reads as a tag run, re-run only when the tag names the
#     run's own commit: with no branch there is no newer run in that branch's
#     group to cancel, and the commit is the one the tag names.
#
# Every other event, and a run payload without a valid head SHA, event, branch
# name and head repository, is not re-run. Refs are always read fully
# qualified (refs/heads/<name>, refs/tags/<name>), so one namespace never
# stands in for the other and a hex name never resolves to a commit.
#
# Reads: GET /repos/{head repository}/commits/refs%2F{heads|tags}%2F<name> with
# the `application/vnd.github.sha` media type, and for push and
# workflow_dispatch GET /repos/{head repository}/git/matching-refs/{heads,tags}/
# <name>, filtered to the exact name. All need contents: read, already granted;
# reading the pull request itself would need pull-requests: read, which the job
# does not have.
# A pull request from a fork reads the fork, which works for a public fork.
# Each read is bounded by HEAD_CMD_TIMEOUT, not GH_CMD_TIMEOUT: they are small
# metadata calls and must not eat the watchdog's budget.
#
# This narrows the race, it does not close it: the tip read and `gh run
# rerun` are two requests, so a push between them, or a force-push back to
# the run's SHA, still lets the re-run join a shared cancelling group. Only
# the caller's concurrency group can rule that out (a re-run attempt in a
# group of its own; docs/reusable-workflows.md).

# The head check's projection of the run, as one line. A payload of any other
# shape (not an object, a non-string head field, a head repository that is
# not an object) fails the read, so the check declines (#1710).
HEAD_RUN_JQ='if type == "object" and ((.head_repository | type) | IN("object", "null"))'
HEAD_RUN_JQ+=' and all(.head_sha, .event, .head_branch; type | IN("string", "null"))'
HEAD_RUN_JQ+=' then [.head_sha // "", .event // "", .head_branch // "",'
HEAD_RUN_JQ+=' (.head_branch // "" | tostring | @uri), .head_repository.full_name // ""]'
HEAD_RUN_JQ+=' | map(tostring) | join("\u001f") else error("malformed run") end'
readonly HEAD_RUN_JQ

# Bounded `gh` for the head check's metadata reads.
gh_head_bounded() {
	"$TIMEOUT_BIN" --kill-after="${PROBE_KILL_GRACE}s" "$HEAD_CMD_TIMEOUT" gh "$@" </dev/null
}

# True when $1 is a full commit SHA (SHA-1 or SHA-256).
is_commit_sha() {
	[[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]
}

# Return 0 when the run is for the current tip of its branch; return 1, having
# written the summary, when it is superseded or that cannot be established.
check_current_head() {
	local matched="$1" meta status=0 head_sha event branch ref head_repo tip heads tags kind namespace
	log_phase "Comparing the head of run ${RUN_ID} with the current head of its ref"
	meta="$(gh_head_bounded api "repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}" \
		--jq "$HEAD_RUN_JQ")" || status=$?
	if ((status != 0)); then
		head_unknown "$matched" "reading run ${RUN_ID} exited ${status}"
		return 1
	fi
	# Unit separator, not a tab: a tab is IFS whitespace, so `read` would
	# collapse an empty field and shift the rest into the wrong names.
	IFS=$'\x1f' read -r head_sha event branch ref head_repo <<<"$meta"
	# The whole payload first, so no event decides anything on an empty or
	# partial response.
	if ! is_commit_sha "$head_sha" || [[ ! "$event" =~ ^[a-z_]+$ || -z "$branch" || -z "$ref" ||
		! "$head_repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ||
		"${head_repo#*/}" == . || "${head_repo#*/}" == .. ]]; then
		head_unknown "$matched" "run ${RUN_ID} does not name a commit, event, branch and repository"
		return 1
	fi
	kind=branch
	case "$event" in
	pull_request | pull_request_target | merge_group | schedule) ;;
	push | workflow_dispatch)
		# A branch or a tag, and the payload does not say which: list both.
		heads="$(ref_named "$head_repo" heads "$ref" "$branch")" || {
			head_unknown "$matched" "could not tell whether ${event} run ${RUN_ID} ran on a branch or a tag (reading the branches of ${head_repo} failed)"
			return 1
		}
		tags="$(ref_named "$head_repo" tags "$ref" "$branch")" || {
			head_unknown "$matched" "could not tell whether ${event} run ${RUN_ID} ran on a branch or a tag (reading the tags of ${head_repo} failed)"
			return 1
		}
		case "${heads}${tags}" in
		10) ;;
		01) kind=tag ;;
		11)
			head_unknown "$matched" "a branch and a tag are both named $(md_code "$branch") in ${head_repo}; ${event} run ${RUN_ID} could have run on either"
			return 1
			;;
		*)
			head_unknown "$matched" "no branch or tag is named $(md_code "$branch") in ${head_repo} any more"
			return 1
			;;
		esac
		;;
	*)
		head_unknown "$matched" "run ${RUN_ID} was triggered by '${event}', whose head the safety net does not compare"
		return 1
		;;
	esac
	# Fully qualified, so neither namespace stands in for the other and a hex
	# name never resolves to a commit; refs/tags/<name> peels an annotated tag.
	namespace=heads
	[[ "$kind" == branch ]] || namespace=tags
	status=0
	tip="$(gh_head_bounded api -H 'Accept: application/vnd.github.sha' \
		"repos/${head_repo}/commits/refs%2F${namespace}%2F${ref}")" || status=$?
	if ((status != 0)); then
		head_unknown "$matched" "reading ${kind} $(md_code "$branch") in ${head_repo} exited ${status} (deleted, unreadable or not a ${kind})"
		return 1
	fi
	if ! is_commit_sha "$tip"; then
		head_unknown "$matched" "${kind} $(md_code "$branch") in ${head_repo} does not resolve to a commit SHA"
		return 1
	fi
	if [[ "$tip" != "$head_sha" ]]; then
		log_info "Run ${RUN_ID} ran for ${head_sha}, but ${kind} ${branch} in ${head_repo} is now at ${tip}; not re-running a superseded commit"
		echo "::notice::Run ${RUN_ID} is for superseded commit ${head_sha:0:12} (its ${kind} is now at ${tip:0:12}); not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "Superseded: matched transient infra signature \`${matched}\` in run ${RUN_ID}, but the run is for commit \`${head_sha}\` and ${kind} $(md_code "$branch") (${head_repo}) is now at \`${tip}\`. A re-run would test a commit that is no longer the head and could cancel the current commit's run in the same concurrency group, so the failed jobs were **not** re-run."
		return 1
	fi
	log_info "Run ${RUN_ID} is for the current commit of ${kind} ${branch} in ${head_repo} (${head_sha})"
	return 0
}

# Print 1 when the ref refs/<namespace>/<name> exists in <repository>, 0 when it
# does not; return 1 when the read fails. matching-refs is a prefix match
# (tags/v1 lists v1.0 too) and answers an empty list for no match, so absence
# is told apart from a failed read, which the commits endpoint cannot do.
# Only a well-formed answer establishes absence: every page must be an array of
# objects, each with a string `ref` in the namespace asked for. Anything else
# ({}, [{}], [null], a non-string ref, a malformed page after a valid one)
# fails the read, so the check declines; `[]` stays a legitimate "none" (#1710).
# Arguments: repository, namespace (heads or tags), URI-encoded name, name.
ref_named() {
	local listing status=0 jq_expr
	[[ "$2" == heads || "$2" == tags ]] || return 1
	# One line (built up here), so a call reads as one line in a log.
	jq_expr='if type == "array" and all(.[]; type == "object" and (.ref | type) == "string"'
	jq_expr+=" and (.ref | startswith(\"refs/${2}/\"))) then .[].ref"
	jq_expr+=' else error("malformed matching-refs page") end'
	listing="$(gh_head_bounded api --paginate "repos/${1}/git/matching-refs/${2}/${3}" \
		--jq "$jq_expr")" || status=$?
	((status == 0)) || return 1
	if grep -qxF -- "refs/${2}/${4}" <<<"$listing"; then
		printf '1'
	else
		printf '0'
	fi
}

# Print $1 as a Markdown code span that the value cannot close: the fence is
# one backtick longer than the longest backtick run in it, padded with spaces
# when the value starts or ends with a backtick.
md_code() {
	local value="$1" fence='`' run
	while [[ "$value" == *"$fence"* ]]; do
		fence+='`'
	done
	run=""
	[[ "$value" != \`* && "$value" != *\` ]] || run=" "
	printf '%s%s%s%s%s' "$fence" "$run" "$value" "$run" "$fence"
}

# Report that the head comparison could not run; nothing is re-run.
head_unknown() {
	local matched="$1" reason="$2"
	log_warn "Cannot compare the head of run ${RUN_ID} with its ref: ${reason}; not re-running"
	echo "::warning::Could not tell whether run ${RUN_ID} is for the current head (${reason}); the failed jobs were not re-run"
	add_github_summary "## Auto re-run on infra failure"
	add_github_summary ""
	add_github_summary "Inconclusive: matched transient infra signature \`${matched}\` in run ${RUN_ID}, but could not tell whether the run is for the current head of its ref (${reason}). The failed jobs were **not** re-run — re-check the run and re-run it by hand if it is still the head."
}

# Re-run the failed jobs for a matched signature and report. Fails loudly when
# `gh run rerun` is killed or errors: a matched signature the script could not
# act on is the worst outcome, and a human must press re-run.
perform_rerun() {
	local matched="$1" rerun_status=0
	log_info "Infra signature matched for run ${RUN_ID}: ${matched}"
	# Last check before acting, so the window for a new push is as short as
	# the API allows (#1706).
	check_current_head "$matched" || return 0
	log_phase "Re-running the failed jobs of run ${RUN_ID}"
	gh_bounded run rerun "$RUN_ID" --repo "$GITHUB_REPOSITORY" --failed || rerun_status=$?
	if ((rerun_status != 0)); then
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

evaluate_and_rerun() {
	log_phase "Checking re-run eligibility for run ${RUN_ID} (attempt ${RUN_ATTEMPT}, max ${MAX_RERUNS})"
	if [[ "$RUN_ATTEMPT" -gt "$MAX_RERUNS" ]]; then
		log_info "Run ${RUN_ID} attempt ${RUN_ATTEMPT} exceeds MAX_RERUNS=${MAX_RERUNS}; not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "Attempt ${RUN_ATTEMPT} exceeds the max of ${MAX_RERUNS} automatic re-run(s); leaving run ${RUN_ID} failed for a human."
		return 0
	fi

	# Before any log is read: a protected run is never re-run, whatever the
	# logs say, so there is no point downloading them (#967).
	check_protection || return 0

	local matched
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
		# A job that was never acquired by a runner has no log at all, so an
		# empty payload is exactly where the acquisition signature lives
		# (#967). Checked here, before declaring the fetch inconclusive.
		if matched="$(check_runner_acquisition)"; then
			perform_rerun "$matched"
			return 0
		fi
		if matched="$(check_harden_runner_agent)"; then
			perform_rerun "$matched"
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

	log_phase "Matching infra signatures against ${#FETCHED_LOGS} bytes of failed-job logs for run ${RUN_ID}"
	if ! matched="$(match_signature "$FETCHED_LOGS")"; then
		# The log may belong to a different failed job than the one that was
		# never acquired: a matrix can lose one runner while another job fails
		# for real. The acquisition check reads annotations, not logs, so it
		# still applies here (#967).
		if matched="$(check_runner_acquisition)"; then
			perform_rerun "$matched"
			return 0
		fi
		if matched="$(check_harden_runner_agent)"; then
			perform_rerun "$matched"
			return 0
		fi
		log_info "No infra signature matched in failed-job logs of run ${RUN_ID}; not re-running"
		add_github_summary "## Auto re-run on infra failure"
		add_github_summary ""
		add_github_summary "No infra signature matched in the failed-job logs of run ${RUN_ID}; not re-running. The failure looks real — investigate it."
		return 0
	fi

	perform_rerun "$matched"
}

# The verdict first, then the #794 evidence appended beneath it, so the summary
# still opens with what the safety net decided. The probe never contributes to
# the exit status: it is instrumentation, and instrumentation that can change
# an outcome is not measuring the outcome any more.
main() {
	local status=0
	evaluate_and_rerun || status=$?
	# `|| true` because the flush runs under `set -e`: a failed summary write —
	# a full disk, a GITHUB_STEP_SUMMARY that vanished — must not turn a green
	# verdict red. Losing the evidence is the acceptable half of that trade.
	emit_probe_evidence || true
	return "$status"
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
