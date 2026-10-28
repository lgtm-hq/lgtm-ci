#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
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
	mkdir -p "$MOCK_DIR/bin" "$CANARY_STATE_DIR" "$MOCK_DIR/stale-runs/canary" "$MOCK_DIR/owners"
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
case "$*" in
*'/git/matching-refs/'*)
	[[ "${MOCK_REFS_FAIL:-false}" != true ]] || exit 1
	cat "$MOCK_DIR/refs"
	;;
*'/actions/runs/'*' --jq .status')
	id="${args##*/runs/}"
	id="${id%% *}"
	id="${id//\/attempts\//-}"
	cat "$MOCK_DIR/owners/$id"
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
	if [[ "$branch" == "canary/${STALE_SHA}-"* ]]; then
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
	run_row one.yml queued '' 11 >"$MOCK_DIR/runs.1"
	run_row one.yml completed failure 11 >"$MOCK_DIR/runs.2"
	{
		run_row one.yml completed failure 11
		run_row two.yml completed success 12
	} >"$MOCK_DIR/runs.3"
	run call_fn 'poll_runs canary/test since one.yml two.yml'
	assert_success
	assert_line "$(printf 'one.yml\tdispatch_failed\t\t')"
	assert_line "$(printf 'two.yml\tsuccess\thttps://example/runs/12\ttwo.yml')"
	run grep -n '/dispatches' "$MOCK_DIR/calls"
	assert_success
	assert_line --index 0 '1:api -X POST repos/owner/fixture/actions/workflows/one.yml/dispatches -f ref=canary/test'
	assert_line --index 1 '4:api -X POST repos/owner/fixture/actions/workflows/two.yml/dispatches -f ref=canary/test'
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
	assert_output 'api -X GET repos/lgtm-hq/lgtm-ci/actions/runs/12345/attempts/1 --jq .status'
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
	assert_output 'api -X GET repos/lgtm-hq/lgtm-ci/actions/runs/100/attempts/2 --jq .status'
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
