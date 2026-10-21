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
#   - Workflow runs for HEAD_SHA (any event) gate completion only: a run that
#     is not completed (queued, in_progress, waiting, pending, requested) keeps
#     the gate waiting, which covers jobs whose check run does not exist yet
#     because they wait on `needs:`. A run that concluded startup_failure or
#     action_required never produced check runs, so it fails the gate. The
#     gate's own workflow file (SELF_WORKFLOW_REF) and run (SELF_RUN_ID) are
#     excluded, so concurrent gate runs on the same commit cannot deadlock.
#   - Check runs for HEAD_SHA, from every app. Re-runs and superseded runs
#     leave several check runs with the same app and name; only the newest
#     (highest id) counts, so a cancelled run replaced by a green re-run
#     passes. Conclusions success, skipped and neutral pass; everything else
#     (failure, cancelled, timed_out, action_required, stale, startup_failure)
#     fails. Check runs named SELF_CHECK_NAME or "<caller job> / SELF_CHECK_NAME"
#     are this gate (any attempt) and are excluded.
#   - Commit statuses (latest per context): pending keeps the gate waiting,
#     failure and error fail it, success passes.
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
#   TIMEOUT_MARGIN_SECONDS - Room left for setup steps inside the job timeout
#                           (default: 180, floor of 60s for the wait)
#   SETTLE_SECONDS        - Quiet period with no pending check and no change
#                           before the verdict (default: 60)
#   POLL_INTERVAL         - Seconds between polls (default: 30)
#   MAX_API_ERRORS        - Consecutive failed API polls tolerated before the
#                           gate fails (default: 5)
#   GH_CMD_TIMEOUT        - Wall-clock bound in seconds on each gh call
#                           (default: 60)
#   GITHUB_OUTPUT         - Receives status=passed|failed and exit-code
#   GITHUB_STEP_SUMMARY   - Receives the verdict table (optional)

set -euo pipefail
exec </dev/null

: "${HEAD_SHA:?HEAD_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${SELF_CHECK_NAME:=✅ All Checks Passed}"
: "${SELF_WORKFLOW_REF:=}"
: "${SELF_RUN_ID:=}"
: "${IGNORE_PATTERN:=}"
: "${TIMEOUT_MINUTES:=}"
: "${TIMEOUT_MARGIN_SECONDS:=180}"
if [[ ! "$TIMEOUT_MARGIN_SECONDS" =~ ^[0-9]+$ ]]; then
	echo "::error title=all-checks-gate::TIMEOUT_MARGIN_SECONDS must be a non-negative integer (got '${TIMEOUT_MARGIN_SECONDS}')"
	exit 1
fi
if [[ -z "${TIMEOUT_SECONDS:-}" && -n "$TIMEOUT_MINUTES" ]]; then
	if [[ ! "$TIMEOUT_MINUTES" =~ ^[0-9]+$ ]]; then
		echo "::error title=all-checks-gate::TIMEOUT_MINUTES must be a non-negative integer (got '${TIMEOUT_MINUTES}')"
		exit 1
	fi
	# Leave the job's setup steps and the verdict room inside the job timeout,
	# so the gate reports what it was waiting on instead of being killed.
	TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60 - TIMEOUT_MARGIN_SECONDS))
	((TIMEOUT_SECONDS >= 60)) || TIMEOUT_SECONDS=60
fi
: "${TIMEOUT_SECONDS:=3300}"
: "${SETTLE_SECONDS:=60}"
: "${POLL_INTERVAL:=30}"
: "${MAX_API_ERRORS:=5}"
: "${GH_CMD_TIMEOUT:=60}"

for var in TIMEOUT_SECONDS SETTLE_SECONDS POLL_INTERVAL MAX_API_ERRORS GH_CMD_TIMEOUT; do
	if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
		echo "::error title=all-checks-gate::${var} must be a non-negative integer (got '${!var}')"
		exit 1
	fi
done
if ((POLL_INTERVAL < 1 || MAX_API_ERRORS < 1 || GH_CMD_TIMEOUT < 1)); then
	echo "::error title=all-checks-gate::POLL_INTERVAL, MAX_API_ERRORS and GH_CMD_TIMEOUT must be at least 1"
	exit 1
fi
if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
	echo "::error title=all-checks-gate::HEAD_SHA must be a 40-character commit SHA (got '${HEAD_SHA}')"
	exit 1
fi
if [[ -n "$IGNORE_PATTERN" ]] && ! jq -n --arg p "$IGNORE_PATTERN" '"" | test($p)' >/dev/null 2>&1; then
	echo "::error title=all-checks-gate::IGNORE_PATTERN is not a valid regex: ${IGNORE_PATTERN}"
	exit 1
fi

# owner/repo/.github/workflows/gate.yml@refs/pull/1/merge -> .github/workflows/gate.yml
SELF_WORKFLOW_PATH="${SELF_WORKFLOW_REF%%@*}"
SELF_WORKFLOW_PATH="${SELF_WORKFLOW_PATH#"${GITHUB_REPOSITORY}/"}"
if [[ "$SELF_WORKFLOW_PATH" == "$SELF_WORKFLOW_REF" && "$SELF_WORKFLOW_REF" != .github/* ]]; then
	SELF_WORKFLOW_PATH=""
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/all-checks-gate.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

now() { date +%s; }

gh_bounded() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$GH_CMD_TIMEOUT" gh "$@"
	else
		gh "$@"
	fi
}

# Fetch one snapshot into WORK_DIR/{runs,checks,statuses}.json. Returns non-zero
# when any call failed so the caller can retry instead of judging a partial view.
fetch_snapshot() {
	local repo="$GITHUB_REPOSITORY" sha="$HEAD_SHA"
	gh_bounded api --paginate \
		"repos/${repo}/actions/runs?head_sha=${sha}&per_page=100" \
		--jq '.workflow_runs[] | {id, name, path, event, status, conclusion}' \
		>"$WORK_DIR/runs.ndjson" || return 1
	gh_bounded api --paginate \
		"repos/${repo}/commits/${sha}/check-runs?filter=all&per_page=100" \
		--jq '.check_runs[] | {id, name, status, conclusion, app: (.app.slug // ""), url: (.html_url // "")}' \
		>"$WORK_DIR/checks.ndjson" || return 1
	gh_bounded api --paginate \
		"repos/${repo}/commits/${sha}/status?per_page=100" \
		--jq '.statuses[] | {context, state, url: (.target_url // "")}' \
		>"$WORK_DIR/statuses.ndjson" || return 1
	jq -s . "$WORK_DIR/runs.ndjson" >"$WORK_DIR/runs.json" || return 1
	jq -s . "$WORK_DIR/checks.ndjson" >"$WORK_DIR/checks.json" || return 1
	jq -s . "$WORK_DIR/statuses.ndjson" >"$WORK_DIR/statuses.json" || return 1
}

# Reduce a snapshot to {pending, failed, passed, fingerprint}.
evaluate_snapshot() {
	jq -n \
		--slurpfile runs "$WORK_DIR/runs.json" \
		--slurpfile checks "$WORK_DIR/checks.json" \
		--slurpfile statuses "$WORK_DIR/statuses.json" \
		--arg self "$SELF_CHECK_NAME" \
		--arg self_path "$SELF_WORKFLOW_PATH" \
		--arg self_run "$SELF_RUN_ID" \
		--arg pat "$IGNORE_PATTERN" '
		def ignored: ($pat != "") and test($pat);
		def is_self: . == $self or endswith(" / " + $self);
		def ok: . == "success" or . == "skipped" or . == "neutral";
		($runs[0]
			| map(select((.id | tostring) != $self_run)
				| select($self_path == "" or .path != $self_path)
				| select((.name // "") | ignored | not))) as $r
		| ($checks[0]
			| map(select(.name | is_self | not) | select(.name | ignored | not))
			| group_by([.app, .name]) | map(max_by(.id))) as $c
		| ($statuses[0] | map(select(.context | ignored | not))) as $s
		| {
			pending: (
				[$r[] | select(.status != "completed")
					| "workflow run \(.name) (\(.status))"]
				+ [$c[] | select(.status != "completed")
					| "check \(.name) (\(.status))"]
				+ [$s[] | select(.state == "pending")
					| "status \(.context) (pending)"]),
			failed: (
				[$r[] | select(.status == "completed")
					| select(.conclusion == "startup_failure" or .conclusion == "action_required")
					| "workflow run \(.name): \(.conclusion)"]
				+ [$c[] | select(.status == "completed")
					| select((.conclusion // "none") | ok | not)
					| "check \(.name): \(.conclusion // "none")"]
				+ [$s[] | select(.state == "failure" or .state == "error")
					| "status \(.context): \(.state)"]),
			passed: (
				[$c[] | select(.status == "completed" and ((.conclusion // "none") | ok))
					| "check \(.name): \(.conclusion)"]
				+ [$s[] | select(.state == "success") | "status \(.context): success"]),
			fingerprint: (
				[$r[] | "r:\(.id):\(.status):\(.conclusion)"]
				+ [$c[] | "c:\(.id):\(.status):\(.conclusion)"]
				+ [$s[] | "s:\(.context):\(.state)"]
				| sort | join(","))
		}'
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
			(.failed[] | "| ❌ failed | \(.) |"),
			(.pending[] | "| ⏳ pending | \(.) |"),
			(.passed[] | "| ✅ passed | \(.) |")' <<<"$eval_json"
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
[[ -n "$IGNORE_PATTERN" ]] && echo "ignoring checks matching: ${IGNORE_PATTERN}"
[[ -n "$SELF_WORKFLOW_PATH" ]] && echo "excluding own workflow: ${SELF_WORKFLOW_PATH}"

start="$(now)"
deadline=$((start + TIMEOUT_SECONDS))
api_errors=0
quiet_since=""
quiet_fp=""
last_eval='{"pending":[],"failed":[],"passed":[],"fingerprint":""}'
last_report=""

while :; do
	if fetch_snapshot && eval_json="$(evaluate_snapshot)"; then
		api_errors=0
		last_eval="$eval_json"
		fp="$(jq -r .fingerprint <<<"$eval_json")"
		pending_count="$(jq '.pending | length' <<<"$eval_json")"
		t="$(now)"
		if ((pending_count > 0)); then
			quiet_since=""
			report="$(jq -r '.pending | join("; ")' <<<"$eval_json")"
			if [[ "$report" != "$last_report" ]]; then
				echo "[$((t - start))s] waiting on ${pending_count}: ${report}"
				last_report="$report"
			fi
		elif [[ -z "$quiet_since" || "$fp" != "$quiet_fp" ]]; then
			quiet_since="$t"
			quiet_fp="$fp"
			last_report=""
			echo "[$((t - start))s] nothing pending; settling for ${SETTLE_SECONDS}s"
		elif ((t - quiet_since >= SETTLE_SECONDS)); then
			break
		fi
	else
		api_errors=$((api_errors + 1))
		echo "::warning title=all-checks-gate::API poll failed (${api_errors}/${MAX_API_ERRORS})"
		if ((api_errors >= MAX_API_ERRORS)); then
			echo "::error title=all-checks-gate::${MAX_API_ERRORS} consecutive API polls failed; cannot verify checks"
			write_outputs failed 1
			exit 1
		fi
	fi
	if (($(now) + POLL_INTERVAL > deadline)); then
		print_list "Still pending" pending "$last_eval"
		print_list "Failed" failed "$last_eval"
		write_summary "timed out" "$last_eval"
		echo "::error title=all-checks-gate::Timed out after ${TIMEOUT_SECONDS}s waiting for checks to finish"
		write_outputs failed 1
		exit 1
	fi
	sleep "$POLL_INTERVAL"
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
	echo "::warning title=all-checks-gate::No other checks found on ${HEAD_SHA}; nothing to gate"
fi
write_summary "passed" "$last_eval"
echo "All ${passed_count} other check(s) passed"
write_outputs passed 0
