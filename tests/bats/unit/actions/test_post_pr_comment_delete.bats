#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for delete-on-empty in scripts/ci/actions/post-pr-comment.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GH_TOKEN="test-token"
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export PR_NUMBER="42"
	export MARKER="test-marker"
	export MODE="upsert"
	export DELETE_ON_EMPTY="true"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"

	# gh stub: listing returns one marker comment; DELETE prints
	# $GH_DELETE_STDERR to stderr and exits $GH_DELETE_EXIT.
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" -X DELETE "* ]]; then
	[[ -n "${GH_DELETE_STDERR:-}" ]] && printf '%s\n' "$GH_DELETE_STDERR" >&2
	exit "${GH_DELETE_EXIT:-0}"
fi
printf '[{"id": 7, "body": "<!-- lgtm-ci:test-marker -->\\nold failure"}]\n'
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

teardown() {
	teardown_temp_dir
}

_run_clear() {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
}

@test "post-pr-comment: deletes the marker comment on empty body" {
	_run_clear

	assert_success
	assert_output --partial "Deleted comment 7"
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
}

@test "post-pr-comment: treats a 404 on delete as already deleted" {
	# An overlapping run deleted the comment between our list and DELETE.
	export GH_DELETE_STDERR="gh: Not Found (HTTP 404)"
	export GH_DELETE_EXIT=1

	_run_clear

	assert_success
	assert_output --partial "Comment 7 was already deleted"
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
}

@test "post-pr-comment: fails when delete hits any other API error" {
	export GH_DELETE_STDERR="gh: Resource not accessible by integration (HTTP 403)"
	export GH_DELETE_EXIT=1

	_run_clear

	assert_failure
	assert_output --partial "HTTP 403"
	run grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
	assert_failure
}
