#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Exercise the gate rerun handler at the gh API boundary.

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/all-checks-gate-rerun.sh"
	export GITHUB_REPOSITORY="lgtm-hq/example"
	export GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json"
	export FIXTURES="${BATS_TEST_TMPDIR}"
	export GH_CALLS="${BATS_TEST_TMPDIR}/calls"
	: >"$GH_CALLS"
	jq -n '{workflow_run: {id: 7, name: "CI", status: "completed", conclusion: "success", run_attempt: 2, head_sha: "0123456789abcdef0123456789abcdef01234567", updated_at: "2026-01-02T00:00:00Z"}}' >"$GITHUB_EVENT_PATH"
	jq '.workflow_run' "$GITHUB_EVENT_PATH" >"$FIXTURES/trigger"
	jq -n '{id: 9, name: "All Checks Gate", path: ".github/workflows/all-checks-gate.yml", status: "completed", conclusion: "failure", run_attempt: 1, head_sha: "0123456789abcdef0123456789abcdef01234567", updated_at: "2026-01-01T00:00:00Z"}' >"$FIXTURES/gate"
	mkdir -p "$FIXTURES/bin"
	cat >"$FIXTURES/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$*" >>"$GH_CALLS"
case "$*" in
*rerun-failed-jobs*)
 args="$*"; id="${args##*runs/}"; id="${id%%/*}"
 [[ "${FAIL_POST:-}" != true && "${FAIL_POST_ID:-}" != "$id" ]] || exit 1
 touch "$FIXTURES/reran" "$FIXTURES/reran-$id" ;;
*'actions/workflows/all-checks-gate.yml/runs?'*) [[ "${FAIL_LIST:-}" != true ]] || exit 1; cat "$FIXTURES/gate"; [[ ! -f "$FIXTURES/gate11" ]] || cat "$FIXTURES/gate11" ;;
*actions/runs/7*) cat "$FIXTURES/trigger" ;;
*actions/runs/9*)
 if [[ -f "$FIXTURES/reran-9" ]]; then jq -s '.[0] | .status="queued" | .conclusion=null | .run_attempt=2' "$FIXTURES/gate"; else jq -s '.[0]' "$FIXTURES/gate"; fi ;;
*actions/runs/11*)
 if [[ -f "$FIXTURES/reran-11" ]]; then jq '.status="queued" | .conclusion=null | .run_attempt=2' "$FIXTURES/gate11"; else cat "$FIXTURES/gate11"; fi ;;
*) exit 2 ;;
esac
EOF
	chmod +x "$FIXTURES/bin/gh"
	export PATH="$FIXTURES/bin:$PATH"
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "gate-rerun: successful later attempt reruns a failed same-SHA gate and verifies it" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Re-ran gate 9 attempt 1"
	run grep -c rerun-failed-jobs "$GH_CALLS"
	assert_output "1"
}

@test "gate-rerun: first attempts and unsuccessful completions do not call the API" {
	cp "$GITHUB_EVENT_PATH" "$FIXTURES/original-event"
	for change in '.workflow_run.run_attempt=1' '.workflow_run.conclusion="failure"' '.workflow_run.name="All Checks Gate"'; do
		jq "$change" "$FIXTURES/original-event" >"$FIXTURES/changed"
		cp "$FIXTURES/changed" "$GITHUB_EVENT_PATH"
		run bash "$SCRIPT"
		assert_success
		[[ ! -s "$GH_CALLS" ]]
	done
}

@test "gate-rerun: running successful unrelated and newer failed gates are not rerun" {
	cp "$FIXTURES/gate" "$FIXTURES/original"
	for change in '.status="in_progress"' '.status="queued"' '.conclusion="success"' '.head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' '.path=".github/workflows/other.yml"' '.updated_at="2026-01-03T00:00:00Z"'; do
		jq "$change" "$FIXTURES/original" >"$FIXTURES/gate"
		run bash "$SCRIPT"
		assert_success
		[[ ! -f "$FIXTURES/reran" ]]
	done
}

@test "gate-rerun: duplicate listing and event replay submit only once" {
	cp "$FIXTURES/gate" "$FIXTURES/copy"
	cat "$FIXTURES/copy" >>"$FIXTURES/gate"
	# The fresh-run endpoint must return a single object even with duplicate pages.
	run bash "$SCRIPT"
	assert_success
	run bash "$SCRIPT"
	assert_success
	run grep -c rerun-failed-jobs "$GH_CALLS"
	assert_output "1"
}

@test "gate-rerun: stale successful delivery cannot retry a gate" {
	jq '.run_attempt=3 | .conclusion="failure"' "$FIXTURES/trigger" >"$FIXTURES/changed"
	cp "$FIXTURES/changed" "$FIXTURES/trigger"
	run bash "$SCRIPT"
	assert_success
	[[ ! -f "$FIXTURES/reran" ]]
}

@test "gate-rerun: failed list reads never submit writes" {
	export FAIL_LIST=true
	run bash "$SCRIPT"
	assert_failure
	[[ ! -f "$FIXTURES/reran" ]]
}

@test "gate-rerun: ambiguous POST failure is not retried" {
	export FAIL_POST=true
	run bash "$SCRIPT"
	assert_failure
	run grep -c rerun-failed-jobs "$GH_CALLS"
	assert_output "1"
}

@test "gate-rerun: a failed POST for one gate still refreshes the next gate" {
	jq '.id=11' "$FIXTURES/gate" >"$FIXTURES/gate11"
	export FAIL_POST_ID=9
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Rerun request for gate 9 failed; not retrying"
	assert_output --partial "Re-ran gate 11 attempt 1"
	assert_output --partial "Failed to refresh gate(s): 9"
	[[ ! -f "$FIXTURES/reran-9" ]]
	[[ -f "$FIXTURES/reran-11" ]]
	run grep -c 'runs/9/rerun-failed-jobs' "$GH_CALLS"
	assert_output "1"
}
