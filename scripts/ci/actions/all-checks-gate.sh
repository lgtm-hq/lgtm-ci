#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pass only when every other check on a commit has finished green.
#
# GitHub native auto-merge and the merge queue wait for REQUIRED checks only,
# so a PR can merge while non-required checks are still running or after one
# failed. This script backs a single required job that turns "all checks
# passed" into one required context: it polls the commit's workflow runs,
# check runs and commit statuses until nothing is queued or in progress and
# the set of checks has been stable for SETTLE_SECONDS, then fails on any
# conclusion other than success, skipped or neutral.
#
# What counts:
#   - Workflow runs for HEAD_SHA (any event). A run that is not completed
#     (queued, in_progress, waiting, pending, requested) keeps the gate
#     waiting, which covers jobs whose check run does not exist yet because
#     they wait on `needs:`. An older run of a workflow file that concluded
#     cancelled is superseded (concurrency) and dropped with its check runs
#     only when newer runs of the same file did its work: every job name it
#     left unfinished (not success, skipped or neutral) has a check run that
#     is not skipped in a newer run, and the newer runs have at least one such
#     check run at all. Every other run counts, so a later run (say on
#     `labeled`) that skips the real jobs can hide neither an earlier failure
#     nor an earlier cancellation. Known gap: jobs the cancelled run never
#     started (skipped or absent) are not compared. A run that concluded failure, cancelled, timed_out,
#     startup_failure or action_required fails the gate even when it left no
#     failed check run. Runs of the gate's own workflow file
#     (SELF_WORKFLOW_REF), its own run (SELF_RUN_ID) and workflows matching
#     IGNORE_PATTERN are dropped with their check runs, so concurrent gate runs
#     on one commit cannot deadlock.
#   - Check runs for HEAD_SHA, from every app. Actions check runs belong to
#     the run in their URL and are judged per run and name; re-run attempts
#     keep the run id, so the newest attempt (highest id) counts. Other apps
#     are judged per check suite and name. Conclusions success, skipped and
#     neutral pass; everything else (failure, cancelled, timed_out,
#     action_required, stale, startup_failure, none) fails. A check run whose
#     run is unknown is kept unless it is an Actions check run named
#     SELF_CHECK_NAME or "<caller job> / SELF_CHECK_NAME". Any other job in the
#     gate's own run fails the gate: the gate must live in its own workflow
#     file, or the jobs it shares a file with would go ungated.
#   - Commit statuses (latest per context): pending keeps the gate waiting,
#     failure and error fail it, success passes.
#   - Nothing else on the commit after the settle period fails the gate unless
#     ALLOW_EMPTY is true: in a merge queue whose other workflows do not
#     trigger on merge_group, a vacuous pass would merge unchecked.
#
# Request budget: while a workflow run is still in progress only the runs
# list is fetched (one request per poll, more past 100 runs), and while that
# pending set stays unchanged the interval grows by half up to 4x
# POLL_INTERVAL; check runs and statuses are fetched once no run is pending.
# A rate-limited poll (primary or secondary limit) waits instead of counting
# as an API error, so a persistent rate limit runs into the timeout rather
# than MAX_API_ERRORS.
#
# Known limit: two jobs with the same display name in one workflow run are
# indistinguishable from re-run attempts of one job, so only the newest
# counts; the run's own conclusion still fails the gate when either failed.
#
# Environment variables:
#   HEAD_SHA              - Commit to gate (required): the PR head SHA on
#                           pull_request, merge_group.head_sha on merge_group
#   GITHUB_REPOSITORY     - owner/repo (provided by GitHub Actions)
#   GH_TOKEN              - Token with checks: read, statuses: read, actions: read
#   SELF_CHECK_NAME       - This gate's job display name (default:
#                           "✅ All Checks Passed")
#   SELF_WORKFLOW_REF     - github.workflow_ref of the calling workflow; its
#                           runs on HEAD_SHA are excluded (optional)
#   SELF_RUN_ID           - github.run_id; excluded (optional)
#   IGNORE_PATTERN        - Regex (jq/Oniguruma) matched against check-run
#                           names, status contexts and workflow-run names;
#                           matches are not gated (optional)
#   TIMEOUT_SECONDS       - Wall-clock budget for the wait (default: 3300, or
#                           TIMEOUT_MINUTES*60 - TIMEOUT_MARGIN_SECONDS)
#   TIMEOUT_MINUTES       - The job's timeout-minutes; used to derive
#                           TIMEOUT_SECONDS when that is unset (optional)
#   TIMEOUT_MARGIN_SECONDS - Room left for setup steps and one last slow poll
#                           inside the job timeout (default: 180, floor of 60s
#                           for the wait)
#   SETTLE_SECONDS        - Quiet period with no pending check and no change
#                           before the verdict (default: 60)
#   POLL_INTERVAL         - Seconds between polls (default: 60)
#   MAX_API_ERRORS        - Consecutive failed API polls tolerated before the
#                           gate fails (default: 5)
#   GH_CMD_TIMEOUT        - Wall-clock bound in seconds on each gh call
#                           (default: 20)
#   ALLOW_EMPTY           - true: pass when no other check exists (default:
#                           false)
#   FAIL_ON_DRAFT         - true: fail at once when PR_DRAFT is true, so a
#                           draft's result can never be read as a pass after
#                           ready_for_review (default: false)
#   PR_DRAFT              - github.event.pull_request.draft (optional)
#   GITHUB_OUTPUT         - Receives status=passed|failed and exit-code
#   GITHUB_STEP_SUMMARY   - Receives the verdict table (optional)

set -euo pipefail
exec </dev/null

# Caller-supplied values echoed into the log stay on one line, so none can
# start a workflow command.
one_line() { printf '%s' "${1//[$'\r\n']/ }"; }

: "${HEAD_SHA:?HEAD_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${SELF_CHECK_NAME:=✅ All Checks Passed}"
: "${SELF_WORKFLOW_REF:=}"
: "${SELF_RUN_ID:=}"
: "${IGNORE_PATTERN:=}"
: "${ALLOW_EMPTY:=false}"
: "${FAIL_ON_DRAFT:=false}"
: "${PR_DRAFT:=false}"
: "${TIMEOUT_MINUTES:=}"
: "${TIMEOUT_MARGIN_SECONDS:=180}"
if [[ ! "$TIMEOUT_MARGIN_SECONDS" =~ ^[0-9]+$ ]]; then
	echo "::error title=all-checks-gate::TIMEOUT_MARGIN_SECONDS must be a non-negative integer (got '$(one_line "$TIMEOUT_MARGIN_SECONDS")')"
	exit 1
fi
if [[ -z "${TIMEOUT_SECONDS:-}" && -n "$TIMEOUT_MINUTES" ]]; then
	if [[ ! "$TIMEOUT_MINUTES" =~ ^[0-9]+$ ]]; then
		echo "::error title=all-checks-gate::TIMEOUT_MINUTES must be a non-negative integer (got '$(one_line "$TIMEOUT_MINUTES")')"
		exit 1
	fi
	# Leave the job's setup steps and the verdict room inside the job timeout,
	# so the gate reports what it was waiting on instead of being killed.
	TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60 - TIMEOUT_MARGIN_SECONDS))
	((TIMEOUT_SECONDS >= 60)) || TIMEOUT_SECONDS=60
fi
: "${TIMEOUT_SECONDS:=3300}"
: "${SETTLE_SECONDS:=60}"
: "${POLL_INTERVAL:=60}"
: "${MAX_API_ERRORS:=5}"
: "${GH_CMD_TIMEOUT:=20}"

for var in TIMEOUT_SECONDS SETTLE_SECONDS POLL_INTERVAL MAX_API_ERRORS GH_CMD_TIMEOUT; do
	if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
		echo "::error title=all-checks-gate::${var} must be a non-negative integer (got '$(one_line "${!var}")')"
		exit 1
	fi
done
if ((POLL_INTERVAL < 1 || MAX_API_ERRORS < 1 || GH_CMD_TIMEOUT < 1)); then
	echo "::error title=all-checks-gate::POLL_INTERVAL, MAX_API_ERRORS and GH_CMD_TIMEOUT must be at least 1"
	exit 1
fi
if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
	echo "::error title=all-checks-gate::HEAD_SHA must be a 40-character commit SHA (got '$(one_line "$HEAD_SHA")')"
	exit 1
fi
if [[ -n "$IGNORE_PATTERN" ]] && ! jq -n --arg p "$IGNORE_PATTERN" '"" | test($p)' >/dev/null 2>&1; then
	echo "::error title=all-checks-gate::IGNORE_PATTERN is not a valid regex: $(one_line "$IGNORE_PATTERN")"
	exit 1
fi

# owner/repo/.github/workflows/gate.yml@refs/pull/1/merge -> .github/workflows/gate.yml
# Anything that does not reduce to a .github/ path is not this repository's
# workflow, so nothing is excluded by path (the run id still is).
SELF_WORKFLOW_PATH="${SELF_WORKFLOW_REF%%@*}"
SELF_WORKFLOW_PATH="${SELF_WORKFLOW_PATH#"${GITHUB_REPOSITORY}/"}"
if [[ "$SELF_WORKFLOW_PATH" != .github/* ]]; then
	SELF_WORKFLOW_PATH=""
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/all-checks-gate.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

now() { date +%s; }

# Each gh call's stderr lands in WORK_DIR/gh.err so a failed poll can tell a
# rate limit from other errors. GH_CMD_TIMEOUT bounds a whole --paginate call.
gh_bounded() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$GH_CMD_TIMEOUT" gh "$@" 2>>"$WORK_DIR/gh.err"
	else
		gh "$@" 2>>"$WORK_DIR/gh.err"
	fi
}

# Names come from workflow files, which a fork PR controls: keep them on one
# line so nothing printed can start a workflow command.
readonly JQ_CLEAN='def clean: tostring | gsub("[\\r\\n\\t]"; " ");'

fetch_runs() {
	gh_bounded api --paginate \
		"repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${HEAD_SHA}&per_page=100" \
		--jq '.workflow_runs[] | {id, name, path, event, status, conclusion}' \
		>"$WORK_DIR/runs.ndjson" || return 1
	jq -s . "$WORK_DIR/runs.ndjson" >"$WORK_DIR/runs.json" || return 1
}

fetch_checks_and_statuses() {
	gh_bounded api --paginate \
		"repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/check-runs?filter=all&per_page=100" \
		--jq '.check_runs[] | {id, name, status, conclusion, app: (.app.slug // ""), suite: (.check_suite.id // 0), url: (.html_url // "")}' \
		>"$WORK_DIR/checks.ndjson" || return 1
	gh_bounded api --paginate \
		"repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/status?per_page=100" \
		--jq '.statuses[] | {context, state}' \
		>"$WORK_DIR/statuses.ndjson" || return 1
	jq -s . "$WORK_DIR/checks.ndjson" >"$WORK_DIR/checks.json" || return 1
	jq -s . "$WORK_DIR/statuses.ndjson" >"$WORK_DIR/statuses.json" || return 1
}

# Shared jq prelude: exclusions of workflow runs and dropping of superseded
# runs (ids in $superseded). $names are jq variables, not shell.
# shellcheck disable=SC2016
readonly JQ_RUNS='
	def ignored: ($pat != "") and test($pat);
	def ok: . == "success" or . == "skipped" or . == "neutral";
	def in_set($set): . as $x | $set | index([$x]) != null;
	def candidate_runs: map(select((.id | tostring) != $self_run)
		| select($self_path == "" or .path != $self_path)
		| select((.name // "") | ignored | not));
	def gated_runs($superseded): candidate_runs
		| map(select((.id | tostring) | in_set($superseded) | not));
	# Ids of cancelled runs whose work newer runs of the same file did;
	# $byrun maps a run id to its check runs.
	def superseded_runs($byrun):
		[candidate_runs | group_by(.path)[] as $group
			| $group[] | select(.conclusion == "cancelled") as $old
			| [$group[] | select(.id > $old.id)] as $newer
			| ([$newer[] | ($byrun[.id | tostring] // [])[]
				| select(.conclusion != "skipped") | .name] | unique) as $done
			| select($done | length > 0)
			| ([($byrun[$old.id | tostring] // [])[]
				| select((.conclusion // "none") | ok | not) | .name] | unique) as $need
			| select(all($need[]; in_set($done)))
			| $old.id | tostring];
	def run_lists($runs):
		{pending: [$runs[] | select(.status != "completed")
			| "workflow run \(.name | clean) (\(.status))"],
		failed: [$runs[] | select(.status == "completed")
			| select((.conclusion // "none") | ok | not)
			| "workflow run \(.name | clean): \(.conclusion // "none")"]};'

# {pending, failed} from the workflow runs alone (after exclusions); used
# while a run is still in progress, when check runs are not fetched.
evaluate_runs() {
	jq -c \
		--arg self_path "$SELF_WORKFLOW_PATH" \
		--arg self_run "$SELF_RUN_ID" \
		--arg pat "$IGNORE_PATTERN" "${JQ_CLEAN}${JQ_RUNS}"'
		# Without check runs nothing is known to be superseded yet.
		run_lists(gated_runs([]))
		| .failed |= map(if endswith(": cancelled") then . + " (may be superseded)" else . end)
		| . + {passed: [], misplaced: [], fingerprint: ""}' "$WORK_DIR/runs.json"
}

# Reduce a full snapshot to {pending, failed, passed, fingerprint}.
evaluate_snapshot() {
	jq -n \
		--slurpfile runs "$WORK_DIR/runs.json" \
		--slurpfile checks "$WORK_DIR/checks.json" \
		--slurpfile statuses "$WORK_DIR/statuses.json" \
		--arg self "$SELF_CHECK_NAME" \
		--arg self_path "$SELF_WORKFLOW_PATH" \
		--arg self_run "$SELF_RUN_ID" \
		--arg pat "$IGNORE_PATTERN" "${JQ_CLEAN}${JQ_RUNS}"'
		def is_self: . == $self or endswith(" / " + $self);
		($checks[0]
			| map(. + {run: ((.url | capture("/actions/runs/(?<run>[0-9]+)/") | .run) // "")})) as $all
		| ($all | map(select(.run != "")) | group_by(.run)
			| map({key: .[0].run, value: .}) | from_entries) as $byrun
		| ($runs[0] | superseded_runs($byrun)) as $superseded
		| ($runs[0] | map(.id | tostring)) as $known
		| ($runs[0] | gated_runs($superseded)) as $r
		| ($r | map(.id | tostring)) as $kept
		| ([$all[] | select($self_run != "" and .run == $self_run)
			| select(.name | is_self | not) | .name | clean]) as $misplaced
		| ($all
			# A check run of a dropped run (own, ignored, superseded) goes with
			# it; one whose run is unknown is kept unless it is this gate.
			| map(select(if .run != "" and (.run | in_set($known))
				then (.run | in_set($kept))
				else ((.app == "github-actions" and (.name | is_self)) | not) end))
			| map(select(.name | ignored | not)
				| . + {key: (if .run != "" then ["run", .run, .name]
					else [.app, (.suite | tostring), .name] end)})
			| group_by(.key) | map(max_by(.id))) as $c
		| ($statuses[0] | map(select(.context | ignored | not))) as $s
		| run_lists($r) as $rl
		| {
			misplaced: $misplaced,
			pending: (
				$rl.pending
				+ [$c[] | select(.status != "completed")
					| "check \(.name | clean) (\(.status))"]
				+ [$s[] | select(.state == "pending")
					| "status \(.context | clean) (pending)"]),
			failed: (
				$rl.failed
				+ [$c[] | select(.status == "completed")
					| select((.conclusion // "none") | ok | not)
					| "check \(.name | clean): \(.conclusion // "none")"]
				+ [$s[] | select(.state == "failure" or .state == "error")
					| "status \(.context | clean): \(.state)"]),
			passed: (
				[$c[] | select(.status == "completed" and ((.conclusion // "none") | ok))
					| "check \(.name | clean): \(.conclusion)"]
				+ [$s[] | select(.state == "success")
					| "status \(.context | clean): success"]),
			fingerprint: (
				[$r[] | "r:\(.id):\(.status):\(.conclusion)"]
				+ [$c[] | "c:\(.id):\(.status):\(.conclusion)"]
				+ [$s[] | "s:\(.context):\(.state)"]
				| sort | join(","))
		}'
}

# Seconds until the core rate limit resets when it is exhausted, else empty.
# The rate_limit endpoint does not count against the limit.
rate_limit_wait() {
	local remaining="" reset=""
	read -r remaining reset < <(gh_bounded api rate_limit \
		--jq '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null) || return 0
	[[ "$remaining" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]] || return 0
	((remaining == 0)) || return 0
	local wait_s=$((reset - $(now) + 1))
	((wait_s >= 1)) || wait_s=1
	echo "$wait_s"
}

# Secondary rate limits answer 403/429 with a message rather than an
# exhausted counter; gh prints it to stderr. The pattern also matches primary
# limit messages, which only means a 60s wait instead of the exact reset.
secondary_rate_limited() {
	grep -qiE 'rate limit|retry-after|abuse' "$WORK_DIR/gh.err" 2>/dev/null
}

write_outputs() {
	local status="$1" code="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "status=${status}"
			echo "exit-code=${code}"
		} >>"$GITHUB_OUTPUT"
	fi
}

write_summary() {
	local verdict="$1" eval_json="$2"
	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	{
		echo "## ${SELF_CHECK_NAME}: ${verdict}"
		echo
		echo "Commit \`${HEAD_SHA}\`"
		echo
		echo "| Result | Check |"
		echo "| ------ | ----- |"
		jq -r '
			def cell: gsub("\\|"; "\\|");
			(.failed[] | "| ❌ failed | \(cell) |"),
			(.pending[] | "| ⏳ pending | \(cell) |"),
			(.passed[] | "| ✅ passed | \(cell) |")' <<<"$eval_json"
	} >>"$GITHUB_STEP_SUMMARY"
}

print_list() {
	local label="$1" key="$2" eval_json="$3"
	local items
	items="$(jq -r --arg k "$key" '.[$k][] | "  - " + .' <<<"$eval_json")"
	[[ -n "$items" ]] || return 0
	echo "${label}:"
	echo "$items"
}

echo "all-checks-gate: ${GITHUB_REPOSITORY}@${HEAD_SHA} (timeout ${TIMEOUT_SECONDS}s, settle ${SETTLE_SECONDS}s, poll ${POLL_INTERVAL}s)"
if [[ -n "$IGNORE_PATTERN" ]]; then
	echo "ignoring checks matching: $(one_line "$IGNORE_PATTERN")"
fi
if [[ -n "$SELF_WORKFLOW_PATH" ]]; then
	echo "excluding own workflow: $(one_line "$SELF_WORKFLOW_PATH")"
fi

if [[ "$FAIL_ON_DRAFT" == "true" && "$PR_DRAFT" == "true" ]]; then
	echo "::error title=all-checks-gate::Draft PR: not gated (fail-on-draft); marking the PR ready re-runs the gate"
	write_summary "failed (draft PR)" '{"pending":[],"failed":[],"passed":[]}'
	write_outputs failed 1
	exit 1
fi

start="$(now)"
deadline=$((start + TIMEOUT_SECONDS))
api_errors=0
quiet_since=""
quiet_fp=""
last_eval='{"pending":[],"failed":[],"passed":[],"fingerprint":""}'
last_report=""

# Poll interval while workflow runs are pending: back to POLL_INTERVAL when
# the pending set changes, else grows by half up to 4x POLL_INTERVAL.
pending_interval="$POLL_INTERVAL"

report_pending() {
	local count="$1" report="$2" t="$3"
	quiet_since=""
	if [[ "$report" != "$last_report" ]]; then
		echo "[$((t - start))s] waiting on ${count}: ${report}"
		last_report="$report"
		pending_interval="$POLL_INTERVAL"
	else
		pending_interval=$((pending_interval + pending_interval / 2))
		((pending_interval <= POLL_INTERVAL * 4)) || pending_interval=$((POLL_INTERVAL * 4))
	fi
}

while :; do
	sleep_for="$POLL_INTERVAL"
	poll_ok=0
	: >"$WORK_DIR/gh.err"
	if fetch_runs && runs_eval="$(evaluate_runs)"; then
		if (($(jq '.pending | length' <<<"$runs_eval") > 0)); then
			# Still running: skip the check-run and status requests this poll.
			poll_ok=1
			last_eval="$runs_eval"
			report_pending "$(jq '.pending | length' <<<"$last_eval")" \
				"$(jq -r '.pending | join("; ")' <<<"$last_eval")" "$(now)"
			sleep_for="$pending_interval"
		elif fetch_checks_and_statuses && eval_json="$(evaluate_snapshot)"; then
			poll_ok=1
			last_eval="$eval_json"
			if (($(jq '.misplaced | length' <<<"$eval_json") > 0)); then
				echo "::error title=all-checks-gate::The gate shares its workflow run with other jobs ($(jq -r '.misplaced | join(", ")' <<<"$eval_json")); call it from its own workflow file, or those jobs go ungated"
				write_summary "failed (shares its workflow run)" "$last_eval"
				write_outputs failed 1
				exit 1
			fi
			fp="$(jq -r .fingerprint <<<"$eval_json")"
			pending_count="$(jq '.pending | length' <<<"$eval_json")"
			t="$(now)"
			if ((pending_count > 0)); then
				report_pending "$pending_count" "$(jq -r '.pending | join("; ")' <<<"$eval_json")" "$t"
				sleep_for="$pending_interval"
			elif [[ -z "$quiet_since" || "$fp" != "$quiet_fp" ]]; then
				quiet_since="$t"
				quiet_fp="$fp"
				last_report=""
				echo "[$((t - start))s] nothing pending; settling for ${SETTLE_SECONDS}s"
			elif ((t - quiet_since >= SETTLE_SECONDS)); then
				break
			fi
		fi
	fi
	if ((poll_ok)); then
		api_errors=0
	else
		wait_s="$(rate_limit_wait)"
		if [[ -z "$wait_s" ]] && secondary_rate_limited; then
			wait_s=60
		fi
		if [[ -n "$wait_s" ]]; then
			echo "::warning title=all-checks-gate::API rate limit hit; waiting ${wait_s}s"
			if ((wait_s > POLL_INTERVAL)); then
				sleep_for="$wait_s"
			fi
		else
			api_errors=$((api_errors + 1))
			echo "::warning title=all-checks-gate::API poll failed (${api_errors}/${MAX_API_ERRORS})"
			if ((api_errors >= MAX_API_ERRORS)); then
				echo "::error title=all-checks-gate::${MAX_API_ERRORS} consecutive API polls failed; cannot verify checks"
				write_summary "failed (API errors)" "$last_eval"
				write_outputs failed 1
				exit 1
			fi
		fi
	fi
	# Poll once more right at the deadline rather than giving up a long
	# (backed-off) sleep early; time out only when no time is left.
	remaining=$((deadline - $(now)))
	if ((remaining <= 0)); then
		print_list "Still pending" pending "$last_eval"
		print_list "Failed" failed "$last_eval"
		write_summary "timed out" "$last_eval"
		if [[ -n "$quiet_since" ]]; then
			echo "::error title=all-checks-gate::Timed out after ${TIMEOUT_SECONDS}s while settling (nothing pending for under ${SETTLE_SECONDS}s); raise timeout-minutes or lower settle-seconds"
		else
			echo "::error title=all-checks-gate::Timed out after ${TIMEOUT_SECONDS}s waiting for checks to finish"
		fi
		write_outputs failed 1
		exit 1
	fi
	((sleep_for <= remaining)) || sleep_for="$remaining"
	sleep "$sleep_for"
done

failed_count="$(jq '.failed | length' <<<"$last_eval")"
passed_count="$(jq '.passed | length' <<<"$last_eval")"
print_list "Passed" passed "$last_eval"
if ((failed_count > 0)); then
	print_list "Failed" failed "$last_eval"
	write_summary "failed" "$last_eval"
	echo "::error title=all-checks-gate::${failed_count} check(s) did not pass"
	write_outputs failed 1
	exit 1
fi
if ((passed_count == 0)); then
	if [[ "$ALLOW_EMPTY" != "true" ]]; then
		write_summary "failed (no other checks)" "$last_eval"
		echo "::error title=all-checks-gate::No other checks found on ${HEAD_SHA}; check that the other workflows trigger on ${GITHUB_EVENT_NAME:-this event} (allow-empty: true accepts this)"
		write_outputs failed 1
		exit 1
	fi
	echo "::warning title=all-checks-gate::No other checks found on ${HEAD_SHA}; nothing to gate (allow-empty)"
fi
write_summary "passed" "$last_eval"
echo "All ${passed_count} other check(s) passed"
write_outputs passed 0
