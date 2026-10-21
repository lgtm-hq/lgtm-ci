#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/all-checks-gate.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SHA="0123456789abcdef0123456789abcdef01234567"

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
	unset IGNORE_PATTERN MAX_API_ERRORS GH_CMD_TIMEOUT TIMEOUT_MINUTES TIMEOUT_MARGIN_SECONDS
	: >"$GITHUB_OUTPUT"
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
# empty list; a file named fail makes that poll's call exit 1.
# sleep advances a fake clock that date reads, so timeouts run instantly.
_mock_tools() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
	case "$arg" in
	repos/*) url="$arg" ;;
	esac
done
case "$url" in
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
		exit 1
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

check() { # id name status conclusion [app]
	local conclusion="null"
	[[ "$4" != "null" ]] && conclusion="\"$4\""
	printf '{"id":%s,"name":"%s","status":"%s","conclusion":%s,"app":"%s","url":""}' \
		"$1" "$2" "$3" "$conclusion" "${5:-github-actions}"
}

run_() { # id name path status conclusion
	local conclusion="null"
	[[ "$5" != "null" ]] && conclusion="\"$5\""
	printf '{"id":%s,"name":"%s","path":"%s","event":"pull_request","status":"%s","conclusion":%s}' \
		"$1" "$2" "$3" "$4" "$conclusion"
}

status_() { # context state
	printf '{"context":"%s","state":"%s","url":""}' "$1" "$2"
}

@test "all-checks-gate: passes when every other check succeeded, skipped or was neutral" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 11 'quality / Lint' completed success)" \
		"$(check 12 'notify-failure' completed skipped)" \
		"$(check 13 'ai-review / AI Review' completed neutral)"
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

@test "all-checks-gate: waits for running checks, then passes after the settle period" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 1 checks "$(check 11 'quality / Lint' in_progress null)"
	poll 3 runs "$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 3 checks "$(check 11 'quality / Lint' completed success)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "waiting on 2: workflow run CI (in_progress); check quality / Lint (in_progress)"
	assert_output --partial "nothing pending; settling for 60s"
	# polls 1-2 pending, 3 quiet, 4 still within settle, 5 settled
	run cat "$POLL_FILE"
	assert_output "5"
}

@test "all-checks-gate: waits for a workflow run whose jobs have no check run yet" {
	poll 1 runs "$(run_ 1 CI .github/workflows/ci.yml in_progress null)"
	poll 1 checks "$(check 11 'build / Build' completed success)"
	poll 2 runs "$(run_ 1 CI .github/workflows/ci.yml completed failure)"
	poll 2 checks "$(check 11 'build / Build' completed success)" \
		"$(check 12 'deploy / Deploy' completed failure)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "waiting on 1: workflow run CI (in_progress)"
	assert_output --partial "check deploy / Deploy: failure"
}

@test "all-checks-gate: fails on failure, cancelled, timed_out, action_required and stale" {
	poll 1 checks "$(check 11 'a' completed failure)" \
		"$(check 12 'b' completed cancelled)" \
		"$(check 13 'c' completed timed_out)" \
		"$(check 14 'd' completed action_required)" \
		"$(check 15 'e' completed stale)" \
		"$(check 16 'f' completed success)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "5 check(s) did not pass"
	for line in "a: failure" "b: cancelled" "c: timed_out" "d: action_required" "e: stale"; do
		assert_output --partial "check ${line}"
	done
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "status=failed"
	assert_output --partial "exit-code=1"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "❌ failed"
}

@test "all-checks-gate: only the newest check run per app and name counts" {
	poll 1 checks "$(check 11 'test / Tests' completed cancelled)" \
		"$(check 19 'test / Tests' completed success)" \
		"$(check 12 'lint' completed success)" \
		"$(check 18 'lint' completed failure)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check lint: failure"
	refute_output --partial "test / Tests: cancelled"
}

@test "all-checks-gate: excludes its own check runs and workflow runs" {
	poll 1 runs "$(run_ 900 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 800 'All Checks Gate' .github/workflows/all-checks-gate.yml in_progress null)" \
		"$(run_ 1 CI .github/workflows/ci.yml completed success)"
	poll 1 checks "$(check 21 'gate / ✅ All Checks Passed' in_progress null)" \
		"$(check 20 'gate / ✅ All Checks Passed' completed failure)" \
		"$(check 11 'quality / Lint' completed success)"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "excluding own workflow: .github/workflows/all-checks-gate.yml"
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

@test "all-checks-gate: a check that appears during the settle period restarts it" {
	poll 1 checks "$(check 11 'lint' completed success)"
	poll 2 checks "$(check 11 'lint' completed success)" "$(check 12 'late / Report' completed failure)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "check late / Report: failure"
}

@test "all-checks-gate: a workflow run that failed to start fails the gate" {
	poll 1 runs "$(run_ 3 Broken .github/workflows/broken.yml completed startup_failure)"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "workflow run Broken: startup_failure"
}

@test "all-checks-gate: passes with a warning when nothing else ran" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No other checks found"
}

@test "all-checks-gate: retries failed API polls, then fails after MAX_API_ERRORS" {
	mkdir -p "$FIXTURES/1" && touch "$FIXTURES/1/fail"
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

@test "all-checks-gate: derives the wait budget from TIMEOUT_MINUTES" {
	poll 1 statuses "$(status_ CodeRabbit pending)"
	unset TIMEOUT_SECONDS
	export TIMEOUT_MINUTES=5

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "timeout 120s"
	assert_output --partial "Timed out after 120s"
}

@test "all-checks-gate: rejects an invalid ignore regex" {
	export IGNORE_PATTERN='('
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "IGNORE_PATTERN is not a valid regex"
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
