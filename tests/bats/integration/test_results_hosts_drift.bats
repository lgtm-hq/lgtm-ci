#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/maintenance/results-hosts-drift.sh (#1498)
#
# gh is the stub in tests/helpers/gh_issue_stub.bash, which behaves like the
# real CLI where the script depends on it and logs every call.

load "../../helpers/common"
load "../../helpers/gh_issue_stub"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/results-hosts-drift.sh"
FIXTURE="${PROJECT_ROOT}/tests/fixtures/results-hosts-drift/meta.json"
MARKER="<!-- lgtm-ci:results-hosts-drift -->"
BOT="github-actions[bot]"

setup() {
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GITHUB_RUN_ID=12345
	export FIXTURE
	install_gh_issue_stub
}

# Write a /meta copy with one added shard and return its path.
drifted_meta() {
	local out="${BATS_TEST_TMPDIR}/drifted.json"
	jq '.domains.actions += ["productionresultssa200.blob.core.windows.net"]' "$FIXTURE" >"$out"
	printf '%s' "$out"
}

@test "results-hosts-drift.sh: match with no open issue changes nothing" {
	add_filler 3
	add_issue 7 "$BOT" Bot null
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "no tracking issue to close"
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
	run grep -F 'api meta' "$GH_CALLS"
	assert_success
}

@test "results-hosts-drift.sh: match closes the lowest-numbered tracking issue" {
	add_issue 50 "$BOT" Bot "$MARKER newer"
	add_issue 42 "$BOT" Bot "$MARKER older"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Closed tracking issue #42"
	run grep -E '^issue close 42 .*--reason completed' "$GH_CALLS"
	assert_success
}

@test "results-hosts-drift.sh: finds the tracker beyond the first pages" {
	add_filler 250
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Closed tracking issue #42"
	run grep -F -- '--paginate repos/lgtm-hq/lgtm-ci/issues?state=open&per_page=100' "$GH_CALLS"
	assert_success
}

@test "results-hosts-drift.sh: a marked issue from another author is ignored" {
	add_issue 42 mallory User "$MARKER planted"
	add_issue 43 "$BOT" Bot "no marker here"
	META_FILE="$(drifted_meta)"
	export META_FILE
	run bash "$SCRIPT"
	assert_failure 1
	run grep -c '^issue create' "$GH_CALLS"
	assert_output "1"
	run grep -E '^issue (edit|comment|close|view)' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: a marked issue from a User named github-actions is ignored" {
	# Both spellings: `github-actions` alone is already refused by the login
	# check, so only the `[bot]` spelling with type User proves the type check.
	add_issue 42 github-actions User "$MARKER planted"
	add_issue 41 "$BOT" User "$MARKER planted"
	META_FILE="$(drifted_meta)"
	export META_FILE
	run bash "$SCRIPT"
	assert_failure 1
	assert_new_issue_only
}

@test "results-hosts-drift.sh: a marked issue from another bot is ignored" {
	add_issue 42 'evil[bot]' Bot "$MARKER planted"
	META_FILE="$(drifted_meta)"
	export META_FILE
	run bash "$SCRIPT"
	assert_failure 1
	assert_new_issue_only
}

@test "results-hosts-drift.sh: a difference opens one issue and fails the run" {
	META_FILE="$(drifted_meta)"
	export META_FILE
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "productionresultssa200.blob.core.windows.net"
	run grep -c '^issue create' "$GH_CALLS"
	assert_output "1"
	run grep -F 'fix(egress): GitHub results storage hosts differ from /meta' "$GH_CALLS"
	assert_success
	run grep -E '^api meta' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: a changed difference updates the existing issue" {
	add_issue 42 "$BOT" Bot "$MARKER older difference"
	META_FILE="$(drifted_meta)"
	export META_FILE
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Updated tracking issue #42"
	run grep -E '^issue edit 42 ' "$GH_CALLS"
	assert_success
	run grep -E '^issue comment 42 ' "$GH_CALLS"
	assert_success
	run grep -E '^issue create' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: an unchanged difference leaves the issue alone" {
	META_FILE="$(drifted_meta)"
	export META_FILE
	python3 "${PROJECT_ROOT}/scripts/ci/maintenance/check-results-hosts-drift.py" \
		--meta "$META_FILE" --issue-body "${BATS_TEST_TMPDIR}/body.md" >/dev/null 2>&1 || true
	add_issue 42 "$BOT" Bot "$(cat "${BATS_TEST_TMPDIR}/body.md")"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "already lists this difference"
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: an unrecognised /meta fails closed without issue writes" {
	add_issue 42 "$BOT" Bot "$MARKER"
	echo '{"domains": {}}' >"${BATS_TEST_TMPDIR}/bad.json"
	export META_FILE="${BATS_TEST_TMPDIR}/bad.json"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "failed closed"
	run grep -E '^issue' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: a drift exit without an issue body writes nothing" {
	printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/fake-python"
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "wrote no issue body"
	run grep -E '^(issue|api --paginate)' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: a drift exit with an empty issue body writes nothing" {
	# The fake interpreter creates the body file but leaves it empty, so only
	# a non-empty (-s) check, not an exists (-e) check, refuses it.
	printf '#!/usr/bin/env bash\n: >"$5"\nexit 1\n' >"${BATS_TEST_TMPDIR}/fake-python"
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "wrote no issue body"
	run grep -E '^(issue|api --paginate)' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: a failed issue listing never opens a duplicate" {
	META_FILE="$(drifted_meta)"
	export META_FILE STUB_LIST_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not list every open issue"
	run grep -E '^issue create' "$GH_CALLS"
	assert_failure
}

@test "results-hosts-drift.sh: requires GH_TOKEN" {
	unset GH_TOKEN
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "GH_TOKEN is required"
}
