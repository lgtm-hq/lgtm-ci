#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/all-checks-gate.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SHA="0123456789abcdef0123456789abcdef01234567"
RUN_URL="https://github.com/lgtm-hq/example/actions/runs"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/all-checks-gate.sh"
	export GITHUB_REPOSITORY="lgtm-hq/example"
	export GH_TOKEN="test-token"
	export HEAD_SHA="$SHA"
	export SELF_WORKFLOW_REF="lgtm-hq/example/.github/workflows/all-checks-gate.yml@refs/pull/7/merge"
	export SELF_RUN_ID="900"
	export SETTLE_SECONDS="60"
	export POLL_INTERVAL="30"
	export TIMEOUT_SECONDS="600"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	export FIXTURES="${BATS_TEST_TMPDIR}/fixtures"
	export CLOCK_FILE="${BATS_TEST_TMPDIR}/clock"
	export POLL_FILE="${BATS_TEST_TMPDIR}/polls"
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	unset IGNORE_PATTERN MAX_API_ERRORS GH_CMD_TIMEOUT TIMEOUT_MINUTES TIMEOUT_MARGIN_SECONDS
	unset ALLOW_EMPTY FAIL_ON_DRAFT PR_DRAFT
	: >"$GITHUB_OUTPUT"
	: >"$GH_CALLS"
	echo 1000 >"$CLOCK_FILE"
	echo 0 >"$POLL_FILE"
	mkdir -p "$FIXTURES"
	_mock_tools
}

teardown() {
	restore_path
	teardown_temp_dir
}

# gh answers from $FIXTURES/<poll>/{runs,checks,statuses}.ndjson (the already
# --jq-filtered lines real gh would print), falling back to the newest earlier
# poll, so a test describes only the polls where something changes. Each
# actions/runs call starts a new poll. A missing file for the poll means an
# empty list; a file named fail makes that poll's calls exit 1 with the file's
# content on stderr. `gh api
# rate_limit` prints $FIXTURES/rate_limit ("<remaining> <reset>") once when
# present. Every call is appended to $GH_CALLS. sleep advances a fake clock
# that date reads, so timeouts run instantly.
_mock_tools() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
url=""
for arg in "$@"; do
	case "$arg" in
	repos/* | rate_limit) url="$arg" ;;
	esac
done
case "$url" in
rate_limit)
	if [[ -f "$FIXTURES/rate_limit" ]]; then
		cat "$FIXTURES/rate_limit"
		rm -f "$FIXTURES/rate_limit"
	else
		echo "4999 0"
	fi
	exit 0
	;;
*/actions/runs\?*)
	kind=runs
	echo $(($(cat "$POLL_FILE") + 1)) >"$POLL_FILE"
	;;
*/check-runs\?*) kind=checks ;;
*/status\?*) kind=statuses ;;
*) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
poll="$(cat "$POLL_FILE")"
for ((p = poll; p >= 1; p--)); do
	if [[ -e "$FIXTURES/$p/fail" ]]; then
		if [[ "$p" == "$poll" ]]; then
			cat "$FIXTURES/$p/fail" >&2
			exit 1
		fi
		continue
	fi
	if [[ -d "$FIXTURES/$p" ]]; then
		[[ -f "$FIXTURES/$p/${kind}.ndjson" ]] && cat "$FIXTURES/$p/${kind}.ndjson"
		exit 0
	fi
done
exit 0
EOF
	cat >"${mock_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
echo $(($(cat "$CLOCK_FILE") + $1)) >"$CLOCK_FILE"
EOF
	cat >"${mock_bin}/date" <<'EOF'
#!/usr/bin/env bash
cat "$CLOCK_FILE"
EOF
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
	chmod +x "${mock_bin}"/*
	export PATH="${mock_bin}:$PATH"
}

# poll <n> <kind> <ndjson lines...>
poll() {
	local n="$1" kind="$2"
	shift 2
	mkdir -p "$FIXTURES/$n"
	printf '%s\n' "$@" >>"$FIXTURES/$n/${kind}.ndjson"
}

check() { # id name status conclusion [app] [run-id] [suite]
	local conclusion="null" url=""
	[[ "$4" != "null" ]] && conclusion="\"$4\""
	[[ -n "${6:-}" && "${6:-}" != "0" ]] && url="${RUN_URL}/$6/job/$1"
	jq -cn --argjson id "$1" --arg name "$2" --arg status "$3" \
		--argjson conclusion "$conclusion" --arg app "${5:-github-actions}" \
		--arg url "$url" --argjson suite "${7:-0}" \
		'{id: $id, name: $name, status: $status, conclusion: $conclusion, app: $app, suite: $suite, url: $url}'
}

run_() { # id name path status conclusion [event]
	local conclusion="null"
	[[ "$5" != "null" ]] && conclusion="\"$5\""
	printf '{"id":%s,"name":"%s","path":"%s","event":"%s","status":"%s","conclusion":%s}' \
		"$1" "$2" "$3" "${6:-pull_request}" "$4" "$conclusion"
}

status_() { # context state
	printf '{"context":"%s","state":"%s"}' "$1" "$2"
}

@test "all-checks-gate: passes when every other check succeeded, skipped or was neutral" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'quality / Lint' completed success github-actions 1)" \
		"$(check 12 'notify-failure' completed skipped github-actions 1)" \
		"$(check 13 'ai-review / AI Review' completed neutral github-actions 1)"
	poll 1 statuses "$(status_ CodeRabbit success)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All 4 other check(s) passed"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "status=passed"
	assert_output --partial "exit-code=0"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "✅ All Checks Passed: passed"
}

@test "all-checks-gate: queries every page of runs, all check runs and statuses for the commit" {
	export ALLOW_EMPTY=true
	run bash "$SCRIPT"
	assert_success
	run cat "$GH_CALLS"
	assert_output --partial "api --paginate repos/lgtm-hq/example/actions/runs?head_sha=${SHA}&per_page=100"
	assert_output --partial "api --paginate repos/lgtm-hq/example/commits/${SHA}/check-runs?filter=all&per_page=100"
	assert_output --partial "api --paginate repos/lgtm-hq/example/commits/${SHA}/status?per_page=100"
}

@test "all-checks-gate: waits for running workflows, then passes after the settle period" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 1 checks "$(check 11 'quality / Lint' in_progress null github-actions 1)"
	poll 3 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 3 checks "$(check 11 'quality / Lint' completed success github-actions 1)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "waiting on 1: workflow run CI (in_progress)"
	assert_output --partial "nothing pending; settling for 60s"
	# polls 1-2 pending, 3 quiet, 4 still within settle, 5 settled
	run cat "$POLL_FILE"
	assert_output "5"
}

@test "all-checks-gate: only lists workflow runs while one is still running" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 2 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 2 checks "$(check 11 'lint' completed success github-actions 1)"

	run bash "$SCRIPT"
	assert_success
	# poll 1 is one request; polls 2-4 fetch runs, check runs and statuses
	run grep -c "check-runs" "$GH_CALLS"
	assert_output "3"
	run grep -c "actions/runs" "$GH_CALLS"
	assert_output "4"
}

@test "all-checks-gate: backs off while the same runs stay pending, up to 4x the interval" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 7 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 7 checks "$(check 11 'lint' completed success github-actions 1)"
	export TIMEOUT_SECONDS=3000

	run bash "$SCRIPT"
	assert_success
	# polls 1-6 pending: sleeps 30, 45, 67, 100, 120 (capped), 120
	run cat "$CLOCK_FILE"
	# 1000 + 30 + 45 + 67 + 100 + 120 + 120, then settle: 30 + 30
	assert_output "1542"
}

@test "all-checks-gate: waits for a workflow run whose jobs have no check run yet" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 1 checks "$(check 11 'build / Build' completed success github-actions 1)"
	poll 2 runs "$(run_ 1 CI .github/workflows/ci.yml completed failure)"
	poll 2 checks "$(check 11 'build / Build' completed success github-actions 1)" \
		"$(check 12 'deploy / Deploy' completed failure github-actions 1)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "waiting on 1: workflow run CI (in_progress)"
	assert_output --partial "check deploy / Deploy: failure"
}

@test "all-checks-gate: fails on failure, cancelled, timed_out, action_required, stale and no conclusion" {
	poll 1 checks "$(check 11 'a' completed failure)" \
		"$(check 12 'b' completed cancelled)" \
		"$(check 13 'c' completed timed_out)" \
		"$(check 14 'd' completed action_required)" \
		"$(check 15 'e' completed stale)" \
		"$(check 16 'f' completed success)" \
		"$(check 17 'g' completed null)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "6 check(s) did not pass"
	for line in "a: failure" "b: cancelled" "c: timed_out" "d: action_required" "e: stale" "g: none"; do
		assert_output --partial "check ${line}"
	done
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "status=failed"
	assert_output --partial "exit-code=1"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "❌ failed"
}

@test "all-checks-gate: a re-run or superseded run of the same workflow replaces the old result" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed cancelled)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'test / Tests' completed cancelled github-actions 1)" \
		"$(check 19 'test / Tests' completed success github-actions 2)" \
		"$(check 12 'lint' completed failure github-actions 2)" \
		"$(check 18 'lint' completed success github-actions 2)"

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "cancelled"
	assert_output --partial "All 2 other check(s) passed"
}

@test "all-checks-gate: a superseded run's jobs do not count, even when the new run has other job names" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed cancelled)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'test (3.11)' completed cancelled github-actions 1)" \
		"$(check 12 'test (3.12)' completed success github-actions 2)"

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "3.11"
}

@test "all-checks-gate: a later run whose jobs skip cannot hide an earlier failure" {
	# e.g. synchronize failed, then a `labeled` run of the same workflow skipped
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed failure)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'test' completed failure github-actions 1)" \
		"$(check 12 'test' completed skipped github-actions 2)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check test: failure"
	assert_output --partial "workflow run CI: failure"
}

@test "all-checks-gate: a cancelled run is not superseded by a newer run whose jobs all skip" {
	# e.g. a `labeled` run cancels the real `synchronize` run and skips its jobs
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed cancelled)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'test' completed cancelled github-actions 1)" \
		"$(check 12 'test' completed skipped github-actions 2)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "workflow run CI: cancelled"
	assert_output --partial "check test: cancelled"
}

@test "all-checks-gate: a run cancelled by a newer run on another event is superseded" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed cancelled push)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success pull_request)"
	poll 1 checks "$(check 11 'test' completed cancelled github-actions 1)" \
		"$(check 12 'test' completed success github-actions 2)"

	run bash "$SCRIPT"
	assert_success
}

@test "all-checks-gate: same job name in two workflows is judged separately" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed failure)" \
		"$(run_ 2 Docker .github/workflows/docker.yml completed success)"
	poll 1 checks "$(check 11 'build' completed failure github-actions 1)" \
		"$(check 12 'build' completed success github-actions 2)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check build: failure"
	assert_output --partial "check build: success"
}

@test "all-checks-gate: same workflow on push and pull_request is judged separately" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed failure push)" \
		"$(run_ 2 CI .github/workflows/ci.yml completed success pull_request)"
	poll 1 checks "$(check 11 'test' completed failure github-actions 1)" \
		"$(check 12 'test' completed success github-actions 2)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check test: failure"
	assert_output --partial "workflow run CI: failure"
}

@test "all-checks-gate: same check name from two apps is judged separately" {
	poll 1 checks "$(check 11 'Security' completed failure socket-security 0 101)" \
		"$(check 12 'Security' completed success other-app 0 102)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check Security: failure"
}

@test "all-checks-gate: a cancelled workflow run without check runs fails the gate" {
	poll 1 runs "$(run_ 3 Nightly .github/workflows/nightly.yml completed cancelled)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "workflow run Nightly: cancelled"
}

@test "all-checks-gate: a workflow run that failed to start or awaits approval fails the gate" {
	poll 1 runs "$(run_ 3 Broken .github/workflows/broken.yml completed startup_failure)" \
		"$(run_ 4 Fork .github/workflows/fork.yml completed action_required)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "workflow run Broken: startup_failure"
	assert_output --partial "workflow run Fork: action_required"
}

@test "all-checks-gate: excludes its own check runs and workflow runs" {
	poll 1 runs "$(run_ 900 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 800 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 21 'gate / ✅ All Checks Passed' in_progress null github-actions 900)" \
		"$(check 20 'gate / ✅ All Checks Passed' completed failure github-actions 800)" \
		"$(check 23 'job of an older gate run' completed failure github-actions 800)" \
		"$(check 22 '✅ All Checks Passed' completed failure)" \
		"$(check 11 'quality / Lint' completed success github-actions 1)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "excluding own workflow: .github/workflows/all-checks-gate.yml"
	assert_output --partial "All 1 other check(s) passed"
}

@test "all-checks-gate: fails when the gate shares its workflow run with other jobs" {
	poll 1 runs "$(run_ 900 CI .github/workflows/all-checks-gate.yml in_progress null)"
	poll 1 checks "$(check 21 'gate / ✅ All Checks Passed' in_progress null github-actions 900)" \
		"$(check 22 'test / Tests' completed failure github-actions 900)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "shares its workflow run with other jobs (test / Tests)"
}

@test "all-checks-gate: keeps check runs of unknown runs and third-party checks named like the gate" {
	poll 1 checks "$(check 11 'orphan' completed failure github-actions 777)" \
		"$(check 12 'x / ✅ All Checks Passed' completed failure other-app 0 55)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check orphan: failure"
	assert_output --partial "check x / ✅ All Checks Passed: failure"
}

@test "all-checks-gate: a workflow ref from another repository excludes only the own run id" {
	export SELF_WORKFLOW_REF="other/repo/.github/workflows/all-checks-gate.yml@refs/heads/main"
	poll 1 runs "$(run_ 900 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 2 'Other' .github/workflows/all-checks-gate.yml in_progress null)"
	poll 2 runs "$(run_ 900 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 2 'Other' .github/workflows/all-checks-gate.yml completed failure)"

	run bash "$SCRIPT"
	assert_failure
	refute_output --partial "excluding own workflow"
	assert_output --partial "waiting on 1: workflow run Other (in_progress)"
	assert_output --partial "workflow run Other: failure"
}

@test "all-checks-gate: an ignored workflow's check runs are dropped with it" {
	poll 1 runs "$(run_ 5 Nightly .github/workflows/nightly.yml completed failure)" \
		"$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'build' completed failure github-actions 5)" \
		"$(check 12 'lint' completed success github-actions 1)"
	export IGNORE_PATTERN='^Nightly$'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All 1 other check(s) passed"
}

@test "all-checks-gate: a pending commit status keeps the gate waiting until it resolves" {
	poll 1 statuses "$(status_ renovate/stability-days pending)" "$(status_ CodeRabbit pending)"
	poll 2 statuses "$(status_ renovate/stability-days success)" "$(status_ CodeRabbit success)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "status renovate/stability-days (pending); status CodeRabbit (pending)"
}

@test "all-checks-gate: failure and error commit statuses fail the gate" {
	poll 1 statuses "$(status_ ci/legacy failure)" "$(status_ ci/other error)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "status ci/legacy: failure"
	assert_output --partial "status ci/other: error"
}

@test "all-checks-gate: a timeout while a run is pending still lists runs that already failed" {
	poll 1 runs "$(run_ 1 Slow .github/workflows/slow.yml in_progress null)" \
		"$(run_ 2 Lint .github/workflows/lint.yml completed failure)"
	export TIMEOUT_SECONDS=60

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Timed out after 60s"
	assert_output --partial "workflow run Slow (in_progress)"
	assert_output --partial "workflow run Lint: failure"
}

@test "all-checks-gate: times out and names what is still pending" {
	poll 1 statuses "$(status_ CodeRabbit pending)"
	export TIMEOUT_SECONDS=120

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Timed out after 120s"
	assert_output --partial "status CodeRabbit (pending)"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "timed out"
}

@test "all-checks-gate: ignore pattern drops matching checks, statuses and workflows" {
	poll 1 runs "$(run_ 2 'Stuck Bot' .github/workflows/bot.yml queued null)"
	poll 1 checks "$(check 11 'flaky / Probe' completed failure)" "$(check 12 'lint' completed success)"
	poll 1 statuses "$(status_ 'SlowBot' pending)"
	export IGNORE_PATTERN='^(flaky / |SlowBot$|Stuck Bot$)'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All 1 other check(s) passed"
}

@test "all-checks-gate: ignore pattern alone releases a status that never finishes" {
	poll 1 statuses "$(status_ 'renovate/stability-days' pending)" "$(status_ CodeRabbit success)"
	export IGNORE_PATTERN='^renovate/stability-days$'

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "stability-days (pending)"
}

@test "all-checks-gate: a check that appears during the settle period restarts it" {
	poll 1 checks "$(check 11 'lint' completed success)"
	poll 2 checks "$(check 11 'lint' completed success)" "$(check 12 'late / Report' completed failure)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check late / Report: failure"
}

@test "all-checks-gate: check names cannot inject workflow commands or break the summary" {
	poll 1 checks "$(check 11 $'evil\n::error::injected' completed failure)" \
		"$(check 12 'a | b' completed success)"

	run bash "$SCRIPT"
	assert_failure
	refute_line "::error::injected"
	assert_output --partial "check evil ::error::injected: failure"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial 'check a \| b: success'
}

@test "all-checks-gate: fails when nothing else ran" {
	export GITHUB_EVENT_NAME=merge_group
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "No other checks found"
	assert_output --partial "trigger on merge_group"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "status=failed"
}

@test "all-checks-gate: allow-empty passes with a warning when nothing else ran" {
	export ALLOW_EMPTY=true
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "nothing to gate (allow-empty)"
}

@test "all-checks-gate: fail-on-draft fails a draft PR at once" {
	export FAIL_ON_DRAFT=true PR_DRAFT=true
	poll 1 checks "$(check 11 'lint' completed success)"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Draft PR: not gated"
	run cat "$GH_CALLS"
	assert_output ""
}

@test "all-checks-gate: drafts are gated normally without fail-on-draft" {
	export PR_DRAFT=true
	poll 1 checks "$(check 11 'lint' completed skipped)"
	run bash "$SCRIPT"
	assert_success
}

@test "all-checks-gate: retries failed API polls, then fails after MAX_API_ERRORS" {
	mkdir -p "$FIXTURES/1" "$FIXTURES/2" "$FIXTURES/3"
	touch "$FIXTURES/1/fail" "$FIXTURES/2/fail" "$FIXTURES/3/fail"
	export MAX_API_ERRORS=3

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "API poll failed (1/3)"
	assert_output --partial "3 consecutive API polls failed"
}

@test "all-checks-gate: recovers from a transient API failure" {
	mkdir -p "$FIXTURES/1" && touch "$FIXTURES/1/fail"
	poll 2 checks "$(check 11 'lint' completed success)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "API poll failed (1/5)"
}

@test "all-checks-gate: waits out an exhausted rate limit instead of counting an error" {
	mkdir -p "$FIXTURES/1" && touch "$FIXTURES/1/fail"
	poll 2 checks "$(check 11 'lint' completed success)"
	echo "0 1300" >"$FIXTURES/rate_limit"
	export MAX_API_ERRORS=1

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "API rate limit hit; waiting 301s"
	refute_output --partial "API poll failed"
}

@test "all-checks-gate: a rate-limit reset in the past waits at least a second" {
	mkdir -p "$FIXTURES/1" && touch "$FIXTURES/1/fail"
	poll 2 checks "$(check 11 'lint' completed success)"
	echo "0 900" >"$FIXTURES/rate_limit"
	export MAX_API_ERRORS=1

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "API rate limit hit; waiting 1s"
}

@test "all-checks-gate: a secondary rate limit waits instead of counting an error" {
	mkdir -p "$FIXTURES/1"
	echo "gh: You have exceeded a secondary rate limit (HTTP 403)" >"$FIXTURES/1/fail"
	poll 2 checks "$(check 11 'lint' completed success)"
	export MAX_API_ERRORS=1

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "API rate limit hit; waiting 60s"
	refute_output --partial "API poll failed"
}

@test "all-checks-gate: derives the wait budget from TIMEOUT_MINUTES" {
	poll 1 statuses "$(status_ CodeRabbit pending)"
	unset TIMEOUT_SECONDS
	export TIMEOUT_MINUTES=5

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "timeout 120s"
	assert_output --partial "Timed out after 120s"
}

@test "all-checks-gate: the wait budget derived from TIMEOUT_MINUTES has a 60s floor" {
	poll 1 statuses "$(status_ CodeRabbit pending)"
	unset TIMEOUT_SECONDS
	export TIMEOUT_MINUTES=2

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "timeout 60s"
}

@test "all-checks-gate: rejects an invalid ignore regex" {
	export IGNORE_PATTERN='('
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IGNORE_PATTERN is not a valid regex"
}

@test "all-checks-gate: caller-supplied values cannot inject workflow commands" {
	export IGNORE_PATTERN=$'^skip\n::error::injected'
	poll 1 checks "$(check 11 'lint' completed success)"
	run bash "$SCRIPT"
	assert_success
	refute_line "::error::injected"
	assert_output --partial "ignoring checks matching: ^skip ::error::injected"
}

@test "all-checks-gate: rejects a malformed HEAD_SHA" {
	export HEAD_SHA="main"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "HEAD_SHA must be a 40-character commit SHA"
}

@test "all-checks-gate: rejects non-integer timing inputs" {
	export SETTLE_SECONDS="soon"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "SETTLE_SECONDS must be a non-negative integer"
}
