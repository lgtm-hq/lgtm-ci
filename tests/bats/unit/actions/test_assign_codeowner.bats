#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/assign-codeowner.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/assign-codeowner.sh"
	export GH_TOKEN="test-token"
	export PR_NUMBER="42"
	export PR_AUTHOR="some-bot[bot]"
	export CODEOWNERS_PATH="${BATS_TEST_TMPDIR}/CODEOWNERS"
}

teardown() {
	teardown_temp_dir
}

_create_codeowners() {
	cat >"$CODEOWNERS_PATH" <<'EOF'
# Team entries are ignored
* @lgtm-hq/maintainers

# Individual owners
* @alice
* @bob
EOF
}

_mock_gh() {
	local labels="${1:-}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_gh"
	: >"$calls_file"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${calls_file}'
case "\$*" in
	*pr\ view*labels*)
		echo '${labels}'
		;;
	*pr\ edit*)
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

@test "assign-codeowner: skips review request on release-bump PRs from pr-auto-assign" {
	require_bash4
	_create_codeowners
	_mock_gh "release-bump"

	run env PR_AUTHOR_TYPE=Bot "$MODERN_BASH" "$SCRIPT"

	assert_success
	assert_output --partial "Release-bump PR — review request handled by release workflow; skipping"
	local calls="${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_file_contains "${calls}" "pr edit 42 --add-assignee"
	refute_output --partial "requesting review from"
	! grep -q -- '--add-reviewer' "$calls"
}

@test "assign-codeowner: requests review on release-bump PRs when REQUEST_CODEOWNER_REVIEW=true" {
	require_bash4
	_create_codeowners
	_mock_gh "release-bump"

	run env PR_AUTHOR_TYPE=Bot REQUEST_CODEOWNER_REVIEW=true "$MODERN_BASH" "$SCRIPT"

	assert_success
	assert_output --partial "Bot-authored PR detected, requesting review from"
	local calls="${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_file_contains "${calls}" "pr edit 42 --add-assignee"
	assert_file_contains "${calls}" "pr edit 42 --add-reviewer"
}

@test "assign-codeowner: requests review for bot PRs without release-bump label" {
	require_bash4
	_create_codeowners
	_mock_gh ""

	run env PR_AUTHOR_TYPE=Bot "$MODERN_BASH" "$SCRIPT"

	assert_success
	assert_output --partial "Bot-authored PR detected, requesting review from"
	local calls="${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_file_contains "${calls}" "pr edit 42 --add-reviewer"
}

@test "assign-codeowner: assigns but does not request review for human-authored PRs" {
	require_bash4
	_create_codeowners
	_mock_gh ""

	run env PR_AUTHOR_TYPE=User "$MODERN_BASH" "$SCRIPT"

	assert_success
	assert_output --partial "Selected assignee:"
	local calls="${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_file_contains "${calls}" "pr edit 42 --add-assignee"
	! grep -q -- '--add-reviewer' "$calls"
}

@test "assign-codeowner: skips when CODEOWNERS has no individual owners" {
	require_bash4
	cat >"$CODEOWNERS_PATH" <<'EOF'
* @lgtm-hq/maintainers
EOF
	_mock_gh ""

	run env PR_AUTHOR_TYPE=Bot "$MODERN_BASH" "$SCRIPT"

	assert_success
	assert_output --partial "No valid individual CODEOWNERS found, skipping assignment"
	local calls="${BATS_TEST_TMPDIR}/mock_calls_gh"
	[[ ! -s "$calls" ]]
}
