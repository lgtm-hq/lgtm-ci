#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Runner expressions are literal; BATS tests intentionally isolate environment changes.
# shellcheck disable=SC2016,SC2030,SC2031
# Purpose: Unit tests for scripts/ci/canary/runs.sh with an offline gh stub.

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export RUNS_SCRIPT="$PROJECT_ROOT/scripts/ci/canary/runs.sh"
	export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
	export CANARY_STATE_DIR="$BATS_TEST_TMPDIR/state"
	export FIXTURE_REPO=owner/fixture CANARY_DISPATCH=false CANARY_KEEP_BRANCH=false
	export CANARY_MAX_IN_FLIGHT=2 CANARY_QUEUE_TIMEOUT_SECONDS=10 CANARY_TIMEOUT_SECONDS=20
	export CANARY_POLL_SECONDS=0 CANARY_CLEANUP_POLL_SECONDS=0
	export STALE_SHA=1111111111111111111111111111111111111111
	export OWNED_BRANCH="canary/${STALE_SHA}-12345-2"
	# The sweep (#1652) runs for another candidate, so STALE_SHA refs are foreign to it.
	export SWEEP_SHA=9999999999999999999999999999999999999999
	export SWEEP_OWNED="canary/${SWEEP_SHA}-500-1"
	export CANARY_NEVER_STARTED_PRUNE_HOURS=24 CANARY_SWEEP_MAX_REFS=20
	export CANARY_SWEEP_BUDGET_SECONDS=120 CANARY_SWEEP_CALL_TIMEOUT_SECONDS=30 CANARY_JOB_TIMEOUT_MINUTES=55
	unset GITHUB_RUN_NUMBER
	mkdir -p "$MOCK_DIR/bin" "$CANARY_STATE_DIR" "$MOCK_DIR/stale-runs/canary" "$MOCK_DIR/owners" \
		"$MOCK_DIR/run-info" "$MOCK_DIR/job-count"
	printf '100\n' >"$MOCK_DIR/clock"
	printf '0\n' >"$MOCK_DIR/poll"
	: >"$MOCK_DIR/calls"
	: >"$MOCK_DIR/runs.1"
	: >"$MOCK_DIR/jobs"
	: >"$MOCK_DIR/refs"
	cat >"$MOCK_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_DIR/calls"
args="$*"
# A slow API (#1656): every call advances the mock clock.
if [[ -n "${MOCK_SLOW_SECONDS:-}" ]]; then
	printf '%s\n' "$(($(cat "$MOCK_DIR/clock") + MOCK_SLOW_SECONDS))" >"$MOCK_DIR/clock"
fi
# A hung call with a child process; optionally both ignore SIGTERM.
if [[ -n "${MOCK_HANG:-}" && "$*" == *"$MOCK_HANG"* ]]; then
	[[ "${MOCK_HANG_IGNORE_TERM:-false}" != true ]] || trap '' TERM
	if [[ "${MOCK_HANG_ESCAPE:-false}" == true ]]; then
		# A child that leaves the call's process group (as setsid would) and
		# keeps the inherited stdout and stderr open; no timeout reaches it.
		perl -e 'setpgrp(0, 0); exec "sleep", "30" or die' &
		printf '%s\n' "$!" >"$MOCK_DIR/escaped-child"
	else
		sleep 30 &
		printf '%s\n' "$!" >"$MOCK_DIR/hung-child"
	fi
	wait
	exit 1
fi
case "$*" in
*'/git/matching-refs/heads/canary/ '*)
	# The sweep's listing of every canary ref (#1652).
	[[ "${MOCK_SWEEP_REFS_FAIL:-false}" != true ]] || exit 1
	cat "$MOCK_DIR/refs"
	;;
*'/git/matching-refs/'*)
	[[ "${MOCK_REFS_FAIL:-false}" != true ]] || exit 1
	cat "$MOCK_DIR/refs"
	;;
*'-X GET repos/owner/fixture/actions/runs/'*' --jq [.status, .head_branch,'*)
	# never_started_run_age (#1605): the stub prints the TSV the --jq would.
	id="${args##*/runs/}"
	id="${id%% *}"
	[[ -f "$MOCK_DIR/run-info/$id" ]] || exit 1
	cat "$MOCK_DIR/run-info/$id"
	;;
*'/jobs?per_page=1 --jq .total_count')
	id="${args##*/runs/}"
	id="${id%%/*}"
	[[ -f "$MOCK_DIR/job-count/$id" ]] || exit 1
	cat "$MOCK_DIR/job-count/$id"
	;;
*'-X DELETE repos/owner/fixture/actions/runs/'*)
	id="${args##*/runs/}"
	# A row that appears on owner 100's ref by the fresh listing.
	if [[ -n "${MOCK_RUN_DELETE_APPEND:-}" ]]; then
		printf '%s\n' "$MOCK_RUN_DELETE_APPEND" >>"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	fi
	# What changes by the fresh listing and reads: a replacement listing for
	# owner 100's ref, and a run's new fresh-read TSV or job count.
	if [[ -f "$MOCK_DIR/after-delete/listing" ]]; then
		mv "$MOCK_DIR/after-delete/listing" "$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	fi
	for kind in run-info job-count; do
		if [[ -f "$MOCK_DIR/after-delete/$kind.$id" ]]; then mv "$MOCK_DIR/after-delete/$kind.$id" "$MOCK_DIR/$kind/$id"; fi
	done
	if [[ "${MOCK_RUN_DELETE_FAIL:-false}" == true ]]; then
		# What GitHub answered the owner for a never-started run (#1605).
		echo 'HTTP 403: Could not delete the workflow run' >&2
		exit 1
	fi
	# A deleted run disappears from its branch listing.
	for listing in "$MOCK_DIR"/stale-runs/canary/*; do
		{ grep -vF "/runs/${id}"$'\t' "$listing" || true; } >"$listing.tmp"
		mv "$listing.tmp" "$listing"
	done
	;;
*'/attempts/'*' --jq [.status, (try (.updated_at '*)
	id="${args##*/runs/}"
	id="${id%% *}"
	id="${id//\/attempts\//-}"
	cat "$MOCK_DIR/owners/$id"
	;;
*'/actions/workflows/'*'/runs?branch='*)
	n=$(cat "$MOCK_DIR/poll")
	if [[ -n "${MOCK_FETCH_CLOCK:-}" ]]; then printf '%s\n' "$MOCK_FETCH_CLOCK" >"$MOCK_DIR/clock"; fi
	if [[ "${MOCK_OBSERVED_FAIL_AT:-}" == "$n" ]] || [[ -n "${MOCK_OBSERVED_FAIL_FROM:-}" && "$n" -ge "$MOCK_OBSERVED_FAIL_FROM" ]]; then
		if [[ -f "$MOCK_DIR/read-error-output" ]]; then cat "$MOCK_DIR/read-error-output"; fi
		exit 1
	fi
	if [[ -f "$MOCK_DIR/observed.$n.json" ]]; then cat "$MOCK_DIR/observed.$n.json"; exit 0; fi
	if [[ -f "$MOCK_DIR/observed.json" ]]; then cat "$MOCK_DIR/observed.json"; exit 0; fi
	status=queued; conclusion=null
	if ((n >= 2)); then status=completed; conclusion='"failure"'; fi
	printf '{"total_count":1,"workflow_runs":[{"id":11,"path":".github/workflows/one.yml","head_branch":"canary/test","head_sha":"1111111111111111111111111111111111111111","event":"workflow_dispatch","created_at":"1970-01-01T00:01:40Z","status":"%s","conclusion":%s,"html_url":"https://github.com/owner/fixture/actions/runs/11","name":"one.yml","repository":{"full_name":"owner/fixture"},"head_repository":{"full_name":"owner/fixture"}}]}' "$status" "$conclusion"
	;;
*'/dispatches'*)
	[[ "$*" != *"/${MOCK_DISPATCH_FAIL:-none}/dispatches"* ]]
	;;
*'/jobs?'*)
	[[ "${MOCK_JOBS_FAIL:-false}" != true ]] || exit 1
	cat "$MOCK_DIR/jobs"
	;;
*'/cancel'*)
	[[ "${MOCK_CANCEL_FAIL:-false}" != true ]]
	;;
*'/actions/runs?branch='*)
	[[ "${MOCK_LIST_FAIL:-false}" != true ]] || exit 1
	branch="${args##*branch=}"
	branch="${branch%%&*}"
	# Stale refs of any SHA that has a listing file (the sweep, #1652).
	if [[ "$branch" == "canary/${STALE_SHA}-"* || -f "$MOCK_DIR/stale-runs/$branch" ]]; then
		[[ "$branch" != "${MOCK_LIST_FAIL_BRANCH:-none}" ]] || exit 1
		cat "$MOCK_DIR/stale-runs/$branch"
		exit 0
	fi
	n=$(cat "$MOCK_DIR/poll")
	n=$((n + 1))
	printf '%s\n' "$n" >"$MOCK_DIR/poll"
	[[ -z "${MOCK_LIST_FAIL_FROM:-}" || "$n" -lt "$MOCK_LIST_FAIL_FROM" ]] || exit 1
	while [[ ! -f "$MOCK_DIR/runs.$n" && "$n" -gt 1 ]]; do n=$((n - 1)); done
	cat "$MOCK_DIR/runs.$n"
	;;
*'-X DELETE '*) [[ "${MOCK_DELETE_FAIL:-false}" != true ]] ;;
*) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
EOF
	chmod +x "$MOCK_DIR/bin/gh"
	export PATH="$MOCK_DIR/bin:$PATH"
	# A runner file also works under kcov, where bash -c loses BASH_SOURCE.
	cat >"$MOCK_DIR/eval.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090 -- source the helper under test from the checkout.
source "$RUNS_SCRIPT"
fixture_api() { gh api "$@"; }
lgtm_ci_api() { gh api "$@"; }
GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
dispatch_workflow() { fixture_api -X POST "repos/$FIXTURE_REPO/actions/workflows/$1/dispatches" -f "ref=$2"; }
delete_canary_branch() { fixture_api -X DELETE "repos/$FIXTURE_REPO/git/refs/heads/$1"; }
# Host roles: no workflow is a gate here, so no failure is retry-eligible.
is_gate() { return 1; }
log_info() { :; }
log_warn() { echo "$*" >&2; }
_write_summary() { printf '%s\n' "$2"; }
date() { cat "$MOCK_DIR/clock"; }
sleep() {
	local now
	now=$(cat "$MOCK_DIR/clock")
	printf '%s\n' "$((now + 1))" >"$MOCK_DIR/clock"
}
eval "$1"
EOF
}

teardown() {
	# A mock child that left its process group is not ours to leave running.
	if [[ -f "$MOCK_DIR/escaped-child" ]]; then kill -KILL "$(cat "$MOCK_DIR/escaped-child")" 2>/dev/null || true; fi
	restore_path
	teardown_temp_dir
}

call_fn() {
	bash "$MOCK_DIR/eval.sh" "$*"
}

run_row() {
	printf '%s\t%s\t%s\thttps://example/runs/%s\t%s\n' "$1" "$2" "$3" "$4" "$1"
}

@test "runs: queued and invisible dispatches occupy slots until completion" {
	export CANARY_DISPATCH=true
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	# two.yml has been dispatched but is not yet visible in the API.
	run_row one.yml completed success 11 >"$MOCK_DIR/runs.2"
	run_row two.yml queued '' 12 >>"$MOCK_DIR/runs.2"
	{
		run_row one.yml completed success 11
		run_row two.yml completed success 12
		run_row three.yml completed success 13
	} >"$MOCK_DIR/runs.3"
	run call_fn 'poll_runs canary/test since one.yml two.yml three.yml'
	assert_success
	assert_line "$(printf 'three.yml\tsuccess\thttps://example/runs/13\tthree.yml')"
	run sed -E 's/ --jq .*//' "$MOCK_DIR/calls"
	assert_success
	assert_line --index 0 'api -X POST repos/owner/fixture/actions/workflows/one.yml/dispatches -f ref=canary/test'
	assert_line --index 1 'api -X POST repos/owner/fixture/actions/workflows/two.yml/dispatches -f ref=canary/test'
	assert_line --index 6 'api -X POST repos/owner/fixture/actions/workflows/three.yml/dispatches -f ref=canary/test'
	run cat "$CANARY_STATE_DIR/attempted"
	assert_output "$(printf 'one.yml\ntwo.yml\nthree.yml')"
}

@test "runs: ambiguous dispatch failure keeps its slot until observed terminal" {
	export CANARY_DISPATCH=true CANARY_MAX_IN_FLIGHT=1 MOCK_DISPATCH_FAIL=one.yml
	export CANARY_FIXTURE_HEAD="$STALE_SHA"
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run_row one.yml completed failure 11 >"$MOCK_DIR/runs.2"
	{
		run_row one.yml completed failure 11
		run_row two.yml completed success 12
	} >"$MOCK_DIR/runs.3"
	run call_fn 'poll_runs canary/test since one.yml two.yml'
	assert_success
	assert_line "$(printf 'one.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/11\tone.yml\tdispatch response failed')"
	assert_line "$(printf 'two.yml\tsuccess\thttps://example/runs/12\ttwo.yml')"
	run grep -n '/dispatches' "$MOCK_DIR/calls"
	assert_success
	assert_line --index 0 '1:api -X POST repos/owner/fixture/actions/workflows/one.yml/dispatches -f ref=canary/test'
	assert_line --index 1 '7:api -X POST repos/owner/fixture/actions/workflows/two.yml/dispatches -f ref=canary/test'
}

@test "runs: expired admission budget does not dispatch" {
	export CANARY_DISPATCH=true CANARY_QUEUE_TIMEOUT_SECONDS=0
	run call_fn 'poll_runs canary/test since one.yml two.yml'
	assert_success
	assert_line "$(printf 'one.yml\tqueued-timeout\t\t')"
	assert_line "$(printf 'two.yml\tqueued-timeout\t\t')"
	run grep '/dispatches' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: queued run exhausts queue budget and is cancelled" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=0
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tqueued-timeout\thttps://example/runs/11\tone.yml')"
	run grep '/11/cancel' "$MOCK_DIR/calls"
	assert_success
}

@test "runs: started job retains execution budget after queue deadline" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=0
	printf '95\n' >"$MOCK_DIR/jobs"
	run_row one.yml in_progress '' 11 >"$MOCK_DIR/runs.1"
	run_row one.yml completed success 11 >"$MOCK_DIR/runs.2"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tsuccess\thttps://example/runs/11\tone.yml')"
	run grep '/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: execution deadline uses earliest job start and cancels timed out run" {
	printf '90\n80\n' >"$MOCK_DIR/jobs"
	run_row one.yml in_progress '' 11 >"$MOCK_DIR/runs.1"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\ttimeout\thttps://example/runs/11\tone.yml')"
	run grep '/11/cancel' "$MOCK_DIR/calls"
	assert_success
}

@test "runs: failed job lookup is monitoring failure rather than queue timeout" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=0 MOCK_JOBS_FAIL=true
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tmonitoring_failed\thttps://example/runs/11\tone.yml')"
}

@test "runs: failed run listing cannot establish queue pressure" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=0 MOCK_LIST_FAIL=true
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_line "$(printf 'one.yml\tmonitoring_failed\t\t')"
}

@test "runs: successful empty fetch followed by outage is monitoring failure" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=2 MOCK_LIST_FAIL_FROM=2
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_line "$(printf 'one.yml\tmonitoring_failed\t\t')"
	refute_output --partial queued-timeout
}

@test "runs: repeated successful empty fetches establish queue timeout" {
	export CANARY_QUEUE_TIMEOUT_SECONDS=2
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tqueued-timeout\t\t')"
	run cat "$MOCK_DIR/poll"
	assert_output 3
}

@test "runs: cleanup cancels queued and running children but retains unfinished branch" {
	printf 'canary/test\n' >"$CANARY_STATE_DIR/branch"
	printf 'one.yml\n' >"$CANARY_STATE_DIR/attempted"
	{
		run_row one.yml queued '' 11
		run_row child.yml in_progress '' 12
		run_row done.yml completed success 13
	} >"$MOCK_DIR/runs.1"
	run call_fn cleanup_fixture_runs
	assert_success
	assert_output --partial 'Retained `owner/fixture@canary/test`'
	[[ -f "$CANARY_STATE_DIR/branch" ]]
	run grep -c '/11/cancel' "$MOCK_DIR/calls"
	assert_output 3
	run grep -c '/12/cancel' "$MOCK_DIR/calls"
	assert_output 3
	run grep -E '/13/cancel|-X DELETE' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: cleanup deletes branch only after cancellation is observed complete" {
	printf 'canary/test\n' >"$CANARY_STATE_DIR/branch"
	printf 'one.yml\n' >"$CANARY_STATE_DIR/attempted"
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run_row one.yml completed cancelled 11 >"$MOCK_DIR/runs.2"
	run call_fn cleanup_fixture_runs
	assert_success
	[[ ! -f "$CANARY_STATE_DIR/branch" ]]
	run grep -E '/cancel|-X DELETE' "$MOCK_DIR/calls"
	assert_output "$(printf '%s\n' 'api -X POST repos/owner/fixture/actions/runs/11/cancel' 'api -X DELETE repos/owner/fixture/git/refs/heads/canary/test')"
}

@test "runs: cleanup without ownership journal makes no API calls" {
	run call_fn cleanup_fixture_runs
	assert_success
	run cat "$MOCK_DIR/calls"
	assert_output ''
}

@test "runs: cancellation failure warns without aborting cleanup" {
	export MOCK_CANCEL_FAIL=true
	run call_fn 'cancel_canary_run 11'
	assert_success
	assert_output --partial 'could not cancel fixture run 11'
}

stale_ref() {
	local attempt="${4:-1}" branch
	branch="canary/${STALE_SHA}-${1}-${attempt}"
	printf 'refs/heads/%s\n' "$branch" >>"$MOCK_DIR/refs"
	printf '%s\n' "${3:-completed}" >"$MOCK_DIR/owners/$1-$attempt"
	if [[ -n "$2" ]]; then
		run_row one.yml "$2" success 11 >"$MOCK_DIR/stale-runs/$branch"
	else
		: >"$MOCK_DIR/stale-runs/$branch"
	fi
}

@test "runs: stale cleanup prunes completed prior attempts including terminal probe children" {
	stale_ref 12345 completed
	# The latest attempt is still running; this ref belongs to completed attempt 1.
	printf 'in_progress\n' >"$MOCK_DIR/owners/12345"
	run_row child.yml completed failure 12 >>"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-12345-1"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run grep '/actions/runs/12345' "$MOCK_DIR/calls"
	assert_output 'api -X GET repos/lgtm-hq/lgtm-ci/actions/runs/12345/attempts/1 --jq [.status, (try (.updated_at | fromdateiso8601 | floor) catch "")] | @tsv'
	run grep -E '/cancel|-X DELETE' "$MOCK_DIR/calls"
	assert_output "api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-12345-1"
	run grep 'git/matching-refs' "$MOCK_DIR/calls"
	assert_output --partial "matching-refs/heads/canary/${STALE_SHA}- --paginate"
	run grep '/actions/runs?branch=' "$MOCK_DIR/calls"
	assert_output --partial '--paginate'
	refute_output --partial 'created='
}

@test "runs: stale cleanup retains unfinished probe children and empty listings" {
	stale_ref 100 completed
	run_row child.yml queued '' 12 >>"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	stale_ref 101 ''
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run grep -E '/cancel|-X DELETE' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup retains ref while its owning attempt is running" {
	stale_ref 100 completed in_progress 2
	# A run-level response cannot establish that the owning attempt completed.
	printf 'completed\n' >"$MOCK_DIR/owners/100"
	printf 'completed\n' >"$MOCK_DIR/owners/100-1"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run grep '/actions/runs/100' "$MOCK_DIR/calls"
	assert_output 'api -X GET repos/lgtm-hq/lgtm-ci/actions/runs/100/attempts/2 --jq [.status, (try (.updated_at | fromdateiso8601 | floor) catch "")] | @tsv'
	run grep -E '/actions/runs\?|-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup retains ref when its owning attempt lookup fails" {
	stale_ref 101 completed
	printf 'completed\n' >"$MOCK_DIR/owners/101"
	rm "$MOCK_DIR/owners/101-1"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'cannot verify owner'
	run grep -E '/actions/runs\?|-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup does not touch owned refs or other SHAs" {
	printf '%s\n' "refs/heads/$OWNED_BRANCH" \
		'refs/heads/canary/2222222222222222222222222222222222222222-100-1' >"$MOCK_DIR/refs"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run wc -l <"$MOCK_DIR/calls"
	assert_output --regexp '^[[:space:]]*1$'
}

@test "runs: stale cleanup retains refs whose owner cannot be parsed" {
	printf '%s\n' "refs/heads/canary/${STALE_SHA}-unknown-1" \
		"refs/heads/canary/${STALE_SHA}-100-unknown" \
		"refs/heads/canary/${STALE_SHA}-100-1/child" \
		"refs/heads/canary/${STALE_SHA}" >"$MOCK_DIR/refs"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run wc -l <"$MOCK_DIR/calls"
	assert_output --regexp '^[[:space:]]*1$'
}

@test "runs: stale cleanup leaves refs on failed ref or run listings" {
	stale_ref 100 completed
	run env MOCK_REFS_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'cannot list stale canary refs'
	run env MOCK_LIST_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'cannot verify fixture runs'
	run grep -E '/cancel|-X DELETE' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup tolerates deletion failures and honors keep branch" {
	stale_ref 100 completed
	run env MOCK_DELETE_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	: >"$MOCK_DIR/calls"
	run env CANARY_KEEP_BRANCH=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run cat "$MOCK_DIR/calls"
	assert_output ''
}

# Fresh-read TSV of a queued run on the stale ref of owner run $1 (attempt 1):
# status, head branch $5 (default the ref), run_attempt $7 (default 1), created
# epoch $3, run_started_at epoch $6 (default $3; "-" for a missing one).
run_info() {
	local started="${6:-$3}"
	[[ "$started" != - ]] || started=""
	printf 'queued\t%s\t%s\t%s\t%s\n' "${5:-canary/${STALE_SHA}-${1}-1}" "${7:-1}" "$3" "$started"
}

# A queued run on the stale ref of owner run $1 (attempt 1), with id $2, created
# at epoch $3, $4 jobs (default 0), then run_info's head branch, run_started_at
# and run_attempt (#1605).
queued_run() {
	local branch="canary/${STALE_SHA}-${1}-1"
	run_info "$1" "$2" "$3" "${4:-0}" "${5:-}" "${6:-}" "${7:-}" >"$MOCK_DIR/run-info/$2"
	printf '%s\n' "${4:-0}" >"$MOCK_DIR/job-count/$2"
	run_row stuck.yml queued '' "$2" >>"$MOCK_DIR/stale-runs/$branch"
}

# Mock clock: 100,000s (about 27.8h) after a run created at 100,000.
NEVER_STARTED_NOW=200000

@test "runs: stale cleanup deletes an old never-started run of a completed attempt, then its ref" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Kept'
	refute_output --partial 'Removed'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_output "$(printf '%s\n' 'api -X DELETE repos/owner/fixture/actions/runs/12' \
		"api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1")"
	# The ref goes only on a fresh listing taken after the run delete.
	run grep -c "actions/runs?branch=canary/${STALE_SHA}-100-1" "$MOCK_DIR/calls"
	assert_output 2
}

@test "runs: stale cleanup deletes the ref when the fresh listing is empty after the run delete" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 ""
	queued_run 100 12 100000
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run cat "$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	assert_output ''
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_output "$(printf '%s\n' 'api -X DELETE repos/owner/fixture/actions/runs/12' \
		"api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1")"
}

@test "runs: stale cleanup keeps and counts a ref whose never-started run is younger than the threshold" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	# 23 hours old: one hour short of CANARY_NEVER_STARTED_PRUNE_HOURS=24.
	queued_run 100 12 $((NEVER_STARTED_NOW - 23 * 3600))
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial "kept 1 stale canary ref(s) for ${STALE_SHA} because their never-started fixture runs are younger than 24h"
	assert_output --partial "Kept 1 stale canary ref(s) for \`${STALE_SHA}\`"
	refute_output --partial 'Removed'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup ages a re-run from its latest attempt, not from created_at" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	# Created 27.8h ago, re-run 10 seconds ago (attempt 2): the attempt is young.
	queued_run 100 12 100000 0 '' $((NEVER_STARTED_NOW - 10)) 2
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'Kept 1 stale canary ref(s)'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup keeps the ref when run_started_at is missing" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000 0 '' -
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Kept'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup never removes a ref whose queued run waits for a runner" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	# Old, but GitHub created a job for it: it waits for a runner.
	queued_run 100 12 100000 1
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Kept'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup never removes the ref or runs of an active attempt" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed in_progress
	queued_run 100 12 100000
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run grep -E -- '-X DELETE|/cancel|actions/runs/12' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup keeps a ref with any other unfinished run beside a never-started one" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	run_row other.yml in_progress '' 13 >>"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	# A fresh read that places the run on another branch is no evidence.
	stale_ref 101 completed
	queued_run 101 14 100000 0 "canary/${STALE_SHA}-999-1"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Kept'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup keeps the ref on any failed or unparseable never-started evidence" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	rm "$MOCK_DIR/run-info/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run_info 100 12 'not-a-time' >"$MOCK_DIR/run-info/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run_info 100 12 100000 0 '' 'not-a-time' >"$MOCK_DIR/run-info/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run_info 100 12 100000 0 '' '' 'x' >"$MOCK_DIR/run-info/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run_info 100 12 100000 >"$MOCK_DIR/run-info/12"
	rm "$MOCK_DIR/job-count/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	printf 'unknown\n' >"$MOCK_DIR/job-count/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	printf '0\n' >"$MOCK_DIR/job-count/12"
	printf 'in_progress\t%s\t1\t100000\t100000\n' "canary/${STALE_SHA}-100-1" >"$MOCK_DIR/run-info/12"
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Kept'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup keeps every ref on a threshold unset, malformed or below 24 hours, uncounted" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	local bad
	for bad in '' 0 1 23 024 -1 1.5 100000; do
		run env CANARY_NEVER_STARTED_PRUNE_HOURS="$bad" bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
		assert_success
		assert_output --partial "threshold unset, malformed or below 24h ('${bad}')"
		refute_output --partial 'Kept'
	done
	run grep -E -- '-X DELETE|/cancel|actions/runs/12' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup removes the ref when GitHub refuses the never-started run delete, and reports the run" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	run env MOCK_RUN_DELETE_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial "removed owner/fixture@canary/${STALE_SHA}-100-1; GitHub refused to delete its never-started run(s) 12, which stay queued"
	assert_output --partial "removed 1 stale canary ref(s) for ${STALE_SHA} despite a refused run delete; 1 never-started fixture run(s) stay queued without a ref"
	assert_output --partial "Removed 1 stale canary ref(s) for \`${STALE_SHA}\`"
	refute_output --partial 'Kept'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_output "$(printf '%s\n' 'api -X DELETE repos/owner/fixture/actions/runs/12' \
		"api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1")"
	# The ref goes on a fresh listing and a fresh read of the refused run.
	run grep -c "actions/runs?branch=canary/${STALE_SHA}-100-1" "$MOCK_DIR/calls"
	assert_output 2
	run grep -c -- '-X GET repos/owner/fixture/actions/runs/12 --jq' "$MOCK_DIR/calls"
	assert_output 2
	run grep -c 'actions/runs/12/jobs?per_page=1' "$MOCK_DIR/calls"
	assert_output 2
}

@test "runs: stale cleanup counts no queued leftover for a refused run that completed by the fresh listing" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	mkdir -p "$MOCK_DIR/after-delete"
	{
		run_row one.yml completed success 11
		run_row stuck.yml completed cancelled 12
	} >"$MOCK_DIR/after-delete/listing"
	run env MOCK_RUN_DELETE_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	refute_output --partial 'Removed'
	refute_output --partial 'stay queued'
	run grep -F -- '-X DELETE repos/owner/fixture/git/refs' "$MOCK_DIR/calls"
	assert_output "api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1"
}

@test "runs: stale cleanup keeps the ref when the fresh listing shows a new or started run" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	local row
	for row in "$(run_row other.yml queued '' 13)" "$(run_row stuck.yml in_progress '' 12)"; do
		run env MOCK_RUN_DELETE_FAIL=true MOCK_RUN_DELETE_APPEND="$row" \
			bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
		assert_success
		assert_output --partial 'cannot confirm that only its never-started fixture runs are unfinished'
		refute_output --partial 'Removed'
		refute_output --partial 'Kept'
		run_row one.yml completed success 11 >"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
		run_row stuck.yml queued '' 12 >>"$MOCK_DIR/stale-runs/canary/${STALE_SHA}-100-1"
	done
	run grep -F -- '-X DELETE repos/owner/fixture/git/refs' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: stale cleanup keeps the ref when a still-queued run gains a job or a new attempt between checks" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	mkdir -p "$MOCK_DIR/after-delete"
	# The run picks up a job (waiting for a runner) while still `queued`.
	printf '1\n' >"$MOCK_DIR/after-delete/job-count.12"
	run env MOCK_RUN_DELETE_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'cannot confirm that only its never-started fixture runs are unfinished'
	refute_output --partial 'Removed'
	# Someone re-runs it: same id, still queued with no job, attempt 2.
	printf '0\n' >"$MOCK_DIR/job-count/12"
	run_info 100 12 100000 0 '' 100000 2 >"$MOCK_DIR/after-delete/run-info.12"
	run env MOCK_RUN_DELETE_FAIL=true bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial 'cannot confirm that only its never-started fixture runs are unfinished'
	run grep -F -- '-X DELETE repos/owner/fixture/git/refs' "$MOCK_DIR/calls"
	assert_failure
}

# --- cross-SHA sweep (#1652) ----------------------------------------------

# Branch of candidate SHA "$1" x 40 (one hex digit), owner run $2, attempt $3.
sweep_branch() {
	printf 'canary/%s-%s-%s' "$(printf '%040d' 0 | tr 0 "$1")" "$2" "$3"
}

# A ref for the sweep: candidate digit $1, run $2, attempt $3, owning attempt
# status $4 and completion epoch $6 (default none), one fixture run of status
# $5 ("" for an empty listing).
sweep_ref() {
	local branch
	branch="$(sweep_branch "$1" "$2" "$3")"
	printf 'refs/heads/%s\n' "$branch" >>"$MOCK_DIR/refs"
	printf '%s\t%s\n' "$4" "${6:-}" >"$MOCK_DIR/owners/$2-$3"
	if [[ -n "$5" ]]; then
		run_row one.yml "$5" success 11 >"$MOCK_DIR/stale-runs/$branch"
	else
		: >"$MOCK_DIR/stale-runs/$branch"
	fi
}

# Fail unless process $1 is gone within two seconds (a killed child is
# reaped by init a moment later; until then kill -0 still finds it).
assert_dead() {
	local i
	for i in {1..20}; do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.1
	done
	echo "process $1 is still alive" >&2
	return 1
}

# Run the sweep for $SWEEP_OWNED with extra environment "$@" (VAR=value). The
# canary started at the current mock clock unless the test wrote another start.
sweep() {
	[[ -f "$CANARY_STATE_DIR/started" ]] || cat "$MOCK_DIR/clock" >"$CANARY_STATE_DIR/started"
	env "$@" bash "$MOCK_DIR/eval.sh" 'sweep_stale_canary_refs "$SWEEP_OWNED"'
}

@test "runs: sweep removes settled refs of every other candidate SHA and leaves its own SHA to the per-SHA cleanup" {
	sweep_ref a 200 1 completed completed
	sweep_ref b 150 1 completed completed
	sweep_ref c 300 2 completed completed
	printf 'refs/heads/%s\n' "$SWEEP_OWNED" "canary/${SWEEP_SHA}-400-1" >>"$MOCK_DIR/refs"
	run sweep
	assert_success
	assert_output --partial 'checked 3 of 3 `canary/` ref(s) of other candidates'
	assert_output --partial '0 left for the next run'
	assert_output --partial "- Removed 3: \`$(sweep_branch b 150 1)\`, \`$(sweep_branch a 200 1)\`, \`$(sweep_branch c 300 2)\`"
	refute_output --partial 'Kept'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "$(printf 'api -X DELETE repos/owner/fixture/git/refs/heads/%s\n' \
		"$(sweep_branch b 150 1)" "$(sweep_branch a 200 1)" "$(sweep_branch c 300 2)")"
	run grep -F "$SWEEP_SHA" "$MOCK_DIR/calls"
	assert_failure
	run grep -c 'matching-refs/heads/canary/ --paginate' "$MOCK_DIR/calls"
	assert_output 1
}

@test "runs: sweep checks at most CANARY_SWEEP_MAX_REFS refs, oldest run id first" {
	# Numeric order 9, 10, 100; a text sort would put 10 and 100 before 9.
	sweep_ref a 100 1 completed completed
	sweep_ref b 9 1 completed completed
	sweep_ref c 10 1 completed completed
	run sweep CANARY_SWEEP_MAX_REFS=2
	assert_success
	assert_output --partial 'checked 2 of 3'
	assert_output --partial 'oldest first (CANARY_SWEEP_MAX_REFS=2); 1 left for the next run'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "$(printf 'api -X DELETE repos/owner/fixture/git/refs/heads/%s\n' \
		"$(sweep_branch b 9 1)" "$(sweep_branch c 10 1)")"
	run grep -F 'actions/runs/100/' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: sweep rotates the last quarter of its cap by run number, so refs kept for good cannot stall it" {
	# Runs 1-3 belong to attempts that stay active: the head of the queue never moves.
	sweep_ref a 1 1 in_progress completed
	sweep_ref a 2 1 in_progress completed
	sweep_ref a 3 1 in_progress completed
	local id
	for id in 4 5 6 7; do sweep_ref b "$id" 1 completed completed; done
	# Cap 4: the 3 oldest, then 1 of the 4 younger refs from offset run number x 1 mod 4.
	run sweep CANARY_SWEEP_MAX_REFS=4 GITHUB_RUN_NUMBER=2
	assert_success
	assert_output --partial 'checked 4 of 7'
	assert_output --partial '1 from offset 2 of the 4 younger first, then oldest first (CANARY_SWEEP_MAX_REFS=4); 3 left for the next run'
	assert_output --partial "- Kept 3, owning lgtm-ci attempt still active"
	assert_output --partial "- Removed 1: \`$(sweep_branch b 6 1)\`"
	run sweep CANARY_SWEEP_MAX_REFS=4 GITHUB_RUN_NUMBER=3
	assert_output --partial "- Removed 1: \`$(sweep_branch b 7 1)\`"
	# No or a malformed run number: offset 0.
	run sweep CANARY_SWEEP_MAX_REFS=4 GITHUB_RUN_NUMBER=x
	assert_output --partial "- Removed 1: \`$(sweep_branch b 4 1)\`"
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "$(printf 'api -X DELETE repos/owner/fixture/git/refs/heads/%s\n' \
		"$(sweep_branch b 6 1)" "$(sweep_branch b 7 1)" "$(sweep_branch b 4 1)")"
}

@test "runs: sweep keeps the ref of an active owning attempt without reading its fixture runs" {
	sweep_ref a 200 1 in_progress completed
	run sweep
	assert_success
	assert_output --partial "- Kept 1, owning lgtm-ci attempt still active: \`$(sweep_branch a 200 1)\`"
	run grep -E -- '-X DELETE|/cancel|actions/runs\?' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: sweep keeps a ref with an unfinished run, or a young never-started run, and reports both" {
	sweep_ref a 200 1 completed in_progress
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 $((NEVER_STARTED_NOW - 23 * 3600))
	run sweep
	assert_success
	assert_output --partial "- Kept 1, unfinished fixture run that is not a proven never-started run: \`$(sweep_branch a 200 1)\`"
	assert_output --partial "- Kept 1, never-started fixture run younger than 24h: \`canary/${STALE_SHA}-100-1\`"
	refute_output --partial 'Removed'
	run grep -E -- '-X DELETE|/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: sweep removes a ref whose never-started run GitHub refuses to delete, and reports the run left queued" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 completed
	queued_run 100 12 100000
	run sweep MOCK_RUN_DELETE_FAIL=true
	assert_success
	assert_output --partial "- Removed 1: \`canary/${STALE_SHA}-100-1\`"
	assert_output --partial '- 1 never-started fixture run(s) stay queued without a ref (GitHub refused the run delete): 12'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "$(printf '%s\n' 'api -X DELETE repos/owner/fixture/actions/runs/12' \
		"api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1")"
}

@test "runs: an empty listing goes only once its owning attempt completed CANARY_NEVER_STARTED_PRUNE_HOURS ago" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	sweep_ref a 200 1 completed '' $((NEVER_STARTED_NOW - 23 * 3600))
	sweep_ref b 201 1 completed '' $((NEVER_STARTED_NOW - 24 * 3600))
	# No readable completion time: unverifiable, kept.
	sweep_ref c 202 1 completed ''
	# Completed in the future of this clock: unverifiable, kept.
	sweep_ref d 203 1 completed '' $((NEVER_STARTED_NOW + 60))
	run sweep
	assert_success
	assert_output --partial "- Removed 1: \`$(sweep_branch b 201 1)\`"
	assert_output --partial "- Kept 1, no fixture run and owning attempt completed less than 24h ago: \`$(sweep_branch a 200 1)\`"
	assert_output --partial "- Kept 2, unverifiable (owning attempt's completion time unreadable or in the future, or threshold invalid): \`$(sweep_branch c 202 1)\`, \`$(sweep_branch d 203 1)\`"
	refute_output --partial 'API error'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "api -X DELETE repos/owner/fixture/git/refs/heads/$(sweep_branch b 201 1)"
}

@test "runs: a malformed threshold makes empty and unfinished refs unverifiable, not API errors" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	sweep_ref a 200 1 completed '' $((NEVER_STARTED_NOW - 48 * 3600))
	stale_ref 100 completed
	queued_run 100 12 100000
	run sweep CANARY_NEVER_STARTED_PRUNE_HOURS=1.5
	assert_success
	assert_output --partial "threshold unset, malformed or below 24h ('1.5')"
	assert_output --partial "- Kept 2, unverifiable (owning attempt's completion time unreadable or in the future, or threshold invalid): \`canary/${STALE_SHA}-100-1\`, \`$(sweep_branch a 200 1)\`"
	run grep -E -- '-X DELETE|actions/runs/12' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: per-SHA cleanup shares the empty-listing rule" {
	printf '%s\n' "$NEVER_STARTED_NOW" >"$MOCK_DIR/clock"
	stale_ref 100 ''
	printf 'completed\t%s\n' $((NEVER_STARTED_NOW - 25 * 3600)) >"$MOCK_DIR/owners/100-1"
	stale_ref 101 ''
	printf 'completed\t%s\n' $((NEVER_STARTED_NOW - 3600)) >"$MOCK_DIR/owners/101-1"
	run env CANARY_NEVER_STARTED_PRUNE_HOURS=1.5 bash "$MOCK_DIR/eval.sh" 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	assert_output --partial "threshold unset, malformed or below 24h ('1.5')"
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_failure
	run call_fn 'cleanup_stale_canary_branches "$OWNED_BRANCH"'
	assert_success
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "api -X DELETE repos/owner/fixture/git/refs/heads/canary/${STALE_SHA}-100-1"
}

@test "runs: sweep never touches a ref whose name does not parse, and lists it in a fenced block" {
	printf 'refs/heads/%s\n' "canary/${STALE_SHA}" "canary/${STALE_SHA}-x-1" "canary/${STALE_SHA}-100-1/child" \
		"$(sweep_branch A 100 1)" 'canary/abc-100-1' >"$MOCK_DIR/refs"
	run sweep
	assert_success
	assert_output --partial 'checked 0 of 0'
	assert_output --partial "$(printf '%s\n' \
		"- Left 5 alone, name is not \`canary/<40-hex>-<run>-<attempt>\` (a person decides):" '' '~~~text' \
		"canary/${STALE_SHA}" "canary/${STALE_SHA}-x-1" "canary/${STALE_SHA}-100-1/child" \
		"$(sweep_branch A 100 1)" 'canary/abc-100-1' '~~~')"
	run wc -l <"$MOCK_DIR/calls"
	assert_output --regexp '^[[:space:]]*1$'
}

@test "runs: a ref name with Markdown or HTML stays literal text in the summary" {
	# A valid Git ref name (git check-ref-format accepts it); a `~` cannot be in
	# one, but is replaced all the same, so the fence cannot close early.
	printf 'refs/heads/%s\n' 'canary/`<details><summary>Hidden</summary>`|x' 'canary/a~~~b' >"$MOCK_DIR/refs"
	run sweep
	assert_success
	assert_output --partial "$(printf '%s\n' '~~~text' 'canary/`<details><summary>Hidden</summary>`|x' 'canary/a???b' '~~~')"
	run grep -c '^~~~' <<<"$output"
	assert_output 2
	# Never inside a code span, where the backtick would close it.
	refute_output --partial '`canary/`<details>'
}

@test "runs: sweep keeps every ref on an API error and reports it" {
	run sweep MOCK_SWEEP_REFS_FAIL=true
	assert_success
	assert_output --partial 'cannot list canary refs for the stale ref sweep; leaving them untouched'
	sweep_ref a 200 1 completed completed
	rm "$MOCK_DIR/owners/200-1"
	sweep_ref b 201 1 completed completed
	sweep_ref c 202 1 completed completed
	run sweep MOCK_LIST_FAIL_BRANCH="$(sweep_branch b 201 1)" MOCK_DELETE_FAIL=true
	assert_success
	assert_output --partial 'cannot verify owner of'
	assert_output --partial 'cannot verify fixture runs on'
	assert_output --partial "- Kept 3, API error or timeout: \`$(sweep_branch a 200 1)\`, \`$(sweep_branch b 201 1)\`, \`$(sweep_branch c 202 1)\`"
	refute_output --partial 'Removed'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_output "api -X DELETE repos/owner/fixture/git/refs/heads/$(sweep_branch c 202 1)"
}

@test "runs: sweep is off on CANARY_SWEEP_MAX_REFS=0 or keep branch, and skipped with a warning on a malformed cap" {
	sweep_ref a 200 1 completed completed
	run sweep CANARY_SWEEP_MAX_REFS=0
	assert_success
	assert_output ''
	run sweep CANARY_KEEP_BRANCH=true
	assert_success
	assert_output ''
	local bad
	for bad in '' 01 -1 1000 x 1.5 ' 5'; do
		run sweep CANARY_SWEEP_MAX_REFS="$bad"
		assert_success
		assert_output "skipped the stale canary ref sweep: CANARY_SWEEP_MAX_REFS must be an integer from 0 to 999 without leading zeros ('${bad}')"
	done
	run cat "$MOCK_DIR/calls"
	assert_output ''
}

@test "runs: sweep is skipped on a malformed budget, call timeout or job limit, or without timeout" {
	sweep_ref a 200 1 completed completed
	local setting bad
	for setting in CANARY_SWEEP_BUDGET_SECONDS CANARY_SWEEP_CALL_TIMEOUT_SECONDS CANARY_JOB_TIMEOUT_MINUTES; do
		for bad in '' 0 01 -1 x 1.5 99999; do
			run sweep "${setting}=${bad}"
			assert_success
			assert_output --partial 'skipped the stale canary ref sweep: CANARY_SWEEP_BUDGET_SECONDS and CANARY_SWEEP_CALL_TIMEOUT_SECONDS must be integers from 1 to 999'
		done
	done
	run bash "$MOCK_DIR/eval.sh" 'command() { [[ "${2:-}" != timeout && "${2:-}" != gnutimeout ]] && builtin command "$@"; }; sweep_stale_canary_refs "$SWEEP_OWNED"'
	assert_success
	assert_output 'skipped the stale canary ref sweep: no GNU timeout (gnutimeout or timeout) to bound its API calls'
	run cat "$MOCK_DIR/calls"
	assert_output ''
}

@test "runs: sweep is skipped when the job is too close to its limit or the canary start is unknown" {
	sweep_ref a 200 1 completed completed
	printf '10000\n' >"$MOCK_DIR/clock"
	# 55 min - 600s margin = 2,700s; budget 120 + 5s kill grace must still fit.
	printf '%s\n' $((10000 - 2576)) >"$CANARY_STATE_DIR/started"
	run sweep
	assert_success
	assert_output 'skipped the stale canary ref sweep: 124s left before the job'"'"'s 55-minute limit less a 600s margin, under its 120s budget'
	run cat "$MOCK_DIR/calls"
	assert_output ''
	printf '%s\n' $((10000 - 2575)) >"$CANARY_STATE_DIR/started"
	run sweep
	assert_output --partial '- Removed 1'
	local started
	for started in '' x 20000; do
		printf '%s\n' "$started" >"$CANARY_STATE_DIR/started"
		run sweep
		assert_output 'skipped the stale canary ref sweep: cannot read when this canary started'
	done
	rm "$CANARY_STATE_DIR/started"
	run bash "$MOCK_DIR/eval.sh" 'sweep_stale_canary_refs "$SWEEP_OWNED"'
	assert_output 'skipped the stale canary ref sweep: cannot read when this canary started'
}

@test "runs: a slow API stops the sweep at its budget and the rest waits for the next run" {
	local id
	for id in 201 202 203 204; do sweep_ref a "$id" 1 completed completed; done
	# Every call takes 3 mock seconds against a 10s budget from clock 100:
	# listing ends at 103, the first ref at 112 (its delete began at 109).
	run sweep CANARY_SWEEP_BUDGET_SECONDS=10 MOCK_SLOW_SECONDS=3
	assert_success
	assert_output --partial "- Removed 1: \`$(sweep_branch a 201 1)\`"
	assert_output --partial 'Budget exhausted (CANARY_SWEEP_BUDGET_SECONDS=10), 3 ref(s) left for the next run.'
	assert_output --partial 'checked 1 of 4'
	# 4 seconds a call: the delete would start after the deadline and is not made.
	: >"$MOCK_DIR/calls"
	printf '100\n' >"$MOCK_DIR/clock"
	run sweep CANARY_SWEEP_BUDGET_SECONDS=10 MOCK_SLOW_SECONDS=4
	assert_success
	assert_output --partial 'stale canary ref sweep: budget spent, call not made'
	assert_output --partial "- Kept 1, API error or timeout: \`$(sweep_branch a 201 1)\`"
	assert_output --partial 'Budget exhausted (CANARY_SWEEP_BUDGET_SECONDS=10), 3 ref(s) left for the next run.'
	run grep -F -- '-X DELETE' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: a hung API call is killed with its children by the per-call timeout" {
	sweep_ref a 200 1 completed completed
	sweep_ref a 201 1 completed completed
	local start
	start=$SECONDS
	run sweep CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_HANG='/runs/200/attempts/'
	assert_success
	assert_output --partial "- Kept 1, API error or timeout: \`$(sweep_branch a 200 1)\`"
	assert_output --partial "- Removed 1: \`$(sweep_branch a 201 1)\`"
	((SECONDS - start < 10))
	assert_dead "$(cat "$MOCK_DIR/hung-child")"
	# A call that ignores SIGTERM (and so does its child) gets SIGKILL 5s later.
	rm "$MOCK_DIR/hung-child"
	start=$SECONDS
	run sweep CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_HANG='/runs/200/attempts/' MOCK_HANG_IGNORE_TERM=true
	assert_success
	assert_output --partial "- Kept 1, API error or timeout: \`$(sweep_branch a 200 1)\`"
	((SECONDS - start < 15))
	assert_dead "$(cat "$MOCK_DIR/hung-child")"
}

# Path of a GNU timeout on the PATH outside the mock bin (gnutimeout on
# ubuntu-26.04, timeout elsewhere), or fail.
real_gnu_timeout() {
	local candidate path
	for candidate in gnutimeout timeout; do
		path="$(PATH="${PATH#"$MOCK_DIR/bin:"}" command -v "$candidate")" || continue
		[[ "$(LC_ALL=C "$path" --version 2>/dev/null)" == 'timeout (GNU coreutils) '* ]] || continue
		printf '%s\n' "$path"
		return 0
	done
	return 1
}

# Shadow $1 with a timeout that behaves as ubuntu-26.04's uutils one did in
# CI (#1656): SIGTERM to the call's process group, but the SIGKILL after
# --kill-after to the direct child only.
fake_uutils_timeout() {
	cat >"$MOCK_DIR/bin/$1" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'timeout (uutils coreutils) 0.0.0-test'; exit 0; fi
ka="${1#--kill-after=}"; t="$2"; shift 2
perl -e 'setpgrp(0, 0); exec @ARGV or die' "$@" &
pid=$!
( sleep "$t"; kill -TERM -- "-$pid" 2>/dev/null; sleep "$ka"; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
watcher=$!
wait "$pid"; rc=$?
kill "$watcher" 2>/dev/null
exit "$rc"
FAKE
	chmod +x "$MOCK_DIR/bin/$1"
}

@test "runs: sweep is skipped when the only timeout is not GNU" {
	sweep_ref a 200 1 completed completed
	fake_uutils_timeout timeout
	fake_uutils_timeout gnutimeout
	run sweep
	assert_success
	assert_output 'skipped the stale canary ref sweep: no GNU timeout (gnutimeout or timeout) to bound its API calls'
	run cat "$MOCK_DIR/calls"
	assert_output ''
}

@test "runs: sweep prefers GNU gnutimeout over a non-GNU timeout, so SIGKILL reaches a child that ignores SIGTERM" {
	local gnu start
	gnu="$(real_gnu_timeout)" || skip 'no GNU timeout on this host'
	sweep_ref a 200 1 completed completed
	sweep_ref a 201 1 completed completed
	# ubuntu-26.04's layout: `timeout` is uutils, GNU is `gnutimeout`.
	fake_uutils_timeout timeout
	printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$gnu" >"$MOCK_DIR/bin/gnutimeout"
	chmod +x "$MOCK_DIR/bin/gnutimeout"
	start=$SECONDS
	run sweep CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_HANG='/runs/200/attempts/' MOCK_HANG_IGNORE_TERM=true
	assert_success
	assert_output --partial "- Kept 1, API error or timeout: \`$(sweep_branch a 200 1)\`"
	assert_output --partial "- Removed 1: \`$(sweep_branch a 201 1)\`"
	# 1s, then SIGKILL 5s later; the uutils one would wait out the 30s sleep.
	((SECONDS - start < 15))
	assert_dead "$(cat "$MOCK_DIR/hung-child")"
}

@test "runs: a child that leaves the call's process group cannot hold the sweep past the call's limit" {
	sweep_ref a 200 1 completed completed
	sweep_ref a 201 1 completed completed
	local start
	start=$SECONDS
	run sweep CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_HANG='/runs/200/attempts/' MOCK_HANG_ESCAPE=true
	assert_success
	assert_output --partial "- Kept 1, API error or timeout: \`$(sweep_branch a 200 1)\`"
	assert_output --partial "- Removed 1: \`$(sweep_branch a 201 1)\`"
	# The call's output goes to files, so the sweep does not wait for the
	# escaped child, which no timeout reaches and still holds them open.
	((SECONDS - start < 10))
	run kill -0 "$(cat "$MOCK_DIR/escaped-child")"
	assert_success
}

@test "runs: cleanup sweeps once after the own ref, and a failed sweep changes nothing" {
	sweep_ref a 200 1 completed completed
	printf '%s\n' "$SWEEP_OWNED" >"$CANARY_STATE_DIR/branch"
	cat "$MOCK_DIR/clock" >"$CANARY_STATE_DIR/started"
	# The own ref stays (an unfinished run), so a second cleanup runs again.
	run_row one.yml queued '' 31 >"$MOCK_DIR/runs.1"
	run call_fn 'cleanup_fixture_runs'
	assert_success
	assert_output --partial "retained owner/fixture@${SWEEP_OWNED}"
	assert_output --partial "- Removed 1: \`$(sweep_branch a 200 1)\`"
	run call_fn 'cleanup_fixture_runs'
	assert_success
	refute_output --partial 'Stale canary ref sweep'
	run grep -c 'matching-refs/heads/canary/ --paginate' "$MOCK_DIR/calls"
	assert_output 1
	# The sweep comes after the own ref's cancellation.
	run grep -nE '/31/cancel|matching-refs/heads/canary/ ' "$MOCK_DIR/calls"
	assert_line --index 0 --regexp '/31/cancel'
	rm "$CANARY_STATE_DIR/swept"
	run call_fn 'sweep_stale_canary_refs() { exit 3; }; cleanup_fixture_runs; echo "cleanup status $?"'
	assert_success
	assert_output --partial 'stale canary ref sweep failed (exit 3); ignored'
	assert_output --partial 'cleanup status 0'
}

@test "runs: a failed own-ref cleanup still runs the sweep and its status is returned" {
	sweep_ref a 200 1 completed completed
	printf '%s\n' "$SWEEP_OWNED" >"$CANARY_STATE_DIR/branch"
	cat "$MOCK_DIR/clock" >"$CANARY_STATE_DIR/started"
	run call_fn 'cleanup_owned_canary_branch() { return 4; }; cleanup_fixture_runs || echo "cleanup status $?"'
	assert_success
	assert_output --partial "- Removed 1: \`$(sweep_branch a 200 1)\`"
	assert_output --partial 'cleanup status 4'
}

@test "runs: API error text reaches the log as is, on one line" {
	# The host's log_info uses `echo -e`; a backslash in GitHub's answer must
	# not become an escape (#1605).
	run bash -c 'source "$1/scripts/ci/lib/log.sh"; source "$2"; log_info "x ($(api_text "$3"))" 2>&1' _ \
		"$PROJECT_ROOT" "$RUNS_SCRIPT" $'HTTP 403: a\\tb\\cc\nnext'
	assert_success
	assert_output --partial 'x (HTTP 403: a\tb\cc next)'
}

@test "runs: reconciled execution keeps its execution budget after queue expiry" {
	export CANARY_DISPATCH=true MOCK_DISPATCH_FAIL=one.yml CANARY_FIXTURE_HEAD="$STALE_SHA"
	export CANARY_QUEUE_TIMEOUT_SECONDS=1
	printf '95\n' >"$MOCK_DIR/jobs"
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run_row one.yml completed failure 11 >"$MOCK_DIR/runs.2"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/11\tone.yml\tdispatch response failed')"
	run grep '/cancel' "$MOCK_DIR/calls"
	assert_failure
}

# Real poll and ownership validator; only gh and the external clock are faked.
reconciliation_case() {
	export CANARY_DISPATCH=true MOCK_DISPATCH_FAIL=one.yml CANARY_FIXTURE_HEAD="$STALE_SHA"
	export CANARY_QUEUE_TIMEOUT_SECONDS=1 CANARY_TIMEOUT_SECONDS=3
	printf '100\n' >"$MOCK_DIR/jobs"
	# A loose terminal snapshot must never certify an ambiguous write.
	run_row one.yml completed success 11 >"$MOCK_DIR/runs.1"
	owned_evidence in_progress null >"$MOCK_DIR/observed.1.json"
}

owned_evidence() {
	jq -n --arg status "$1" --argjson conclusion "$2" '{total_count:1,workflow_runs:[{
		id:11,path:".github/workflows/one.yml",head_branch:"canary/test",
		head_sha:"1111111111111111111111111111111111111111",event:"workflow_dispatch",
		created_at:"1970-01-01T00:01:40Z",status:$status,conclusion:$conclusion,
		html_url:"https://github.com/owner/fixture/actions/runs/11",name:"one.yml",
		repository:{full_name:"owner/fixture"},head_repository:{full_name:"owner/fixture"}}]}'
}

@test "runs: transient reconciliation error after start preserves execution budget and fresh completion" {
	reconciliation_case
	export MOCK_OBSERVED_FAIL_AT=2
	owned_evidence completed '"success"' >"$MOCK_DIR/observed.3.json"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output "$(printf 'one.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tone.yml\tdispatch response failed')"
	run cat "$MOCK_DIR/poll"
	assert_output 3
	run grep -c '/one.yml/dispatches' "$MOCK_DIR/calls"
	assert_output 1
	run grep '/cancel' "$MOCK_DIR/calls"
	assert_failure
}

@test "runs: read error before identity can recover only from fresh ownership evidence" {
	reconciliation_case
	export MOCK_OBSERVED_FAIL_AT=1
	owned_evidence completed '"success"' >"$MOCK_DIR/observed.2.json"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output --partial "$(printf 'one.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11')"
}

@test "runs: read error before job start stays queue bounded and cancels established identity" {
	reconciliation_case
	: >"$MOCK_DIR/jobs"
	export MOCK_OBSERVED_FAIL_FROM=2
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output --partial "$(printf 'one.yml\tdispatch_failed\thttps://github.com/owner/fixture/actions/runs/11')"
	run grep -c '/11/cancel' "$MOCK_DIR/calls"
	assert_output 1
}

@test "runs: continued read errors exhaust execution budget without cached terminal certification" {
	reconciliation_case
	export MOCK_OBSERVED_FAIL_FROM=2
	owned_evidence completed '"success"' >"$MOCK_DIR/read-error-output"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output --partial "$(printf 'one.yml\tmonitoring_failed\thttps://github.com/owner/fixture/actions/runs/11')"
	assert_output --partial 'dispatch response failed'
	run cat "$MOCK_DIR/poll"
	assert_output 4
	run grep -c '/11/cancel' "$MOCK_DIR/calls"
	assert_output 1
}

@test "runs: continuing conflicting foreign malformed stale and future evidence cannot replace started identity" {
	local change
	for change in \
		'.workflow_runs[0] |= (.id=22 | .html_url="https://github.com/owner/fixture/actions/runs/22")' \
		'.workflow_runs[0].head_sha="2222222222222222222222222222222222222222"' \
		'.workflow_runs[0].conclusion=null' \
		'.workflow_runs[0].created_at="1970-01-01T00:01:39Z"' \
		'.workflow_runs[0].created_at="2099-01-01T00:00:00Z"'; do
		reconciliation_case
		printf '100\n' >"$MOCK_DIR/clock"
		printf '0\n' >"$MOCK_DIR/poll"
		: >"$MOCK_DIR/calls"
		owned_evidence completed '"success"' | jq "$change" >"$MOCK_DIR/observed.json"
		run call_fn 'poll_runs canary/test since one.yml'
		assert_success
		assert_output --partial "$(printf 'one.yml\tmonitoring_failed\thttps://github.com/owner/fixture/actions/runs/11')"
		run grep -c '/11/cancel' "$MOCK_DIR/calls"
		assert_output 1
		run grep '/22/cancel' "$MOCK_DIR/calls"
		assert_failure
	done
}

@test "runs: creation during GET is validated against postfetch time" {
	reconciliation_case
	export MOCK_FETCH_CLOCK=102
	owned_evidence completed '"success"' | jq '.workflow_runs[0].created_at="1970-01-01T00:01:42Z"' >"$MOCK_DIR/observed.1.json"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output --partial "$(printf 'one.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11')"
}

@test "runs: postfetch future timestamp remains untrusted and uses refreshed queue deadline" {
	reconciliation_case
	export MOCK_FETCH_CLOCK=102
	owned_evidence completed '"success"' | jq '.workflow_runs[0].created_at="1970-01-01T00:01:43Z"' >"$MOCK_DIR/observed.1.json"
	run call_fn 'poll_runs canary/test since one.yml'
	assert_success
	assert_output --partial "$(printf 'one.yml\tdispatch_failed')"
	run cat "$MOCK_DIR/poll"
	assert_output 1
}
