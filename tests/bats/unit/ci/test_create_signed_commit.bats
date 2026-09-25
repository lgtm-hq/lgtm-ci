#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for create-signed-commit.sh (GraphQL createCommitOnBranch)

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/git/create-signed-commit.sh"
BASE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
HEAD_SHA="c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff"

# Recording gh mock:
#   - logs every invocation (one line of args) to MOCK_GH_LOG
#   - graphql: saves stdin to MOCK_GH_GRAPHQL_PAYLOAD and prints
#     MOCK_GRAPHQL_RESPONSE (default: a successful commit)
#   - branches/<name>: prints MOCK_BRANCH_SHA, or 404s when
#     MOCK_BRANCH_EXISTS=false
#   - git/refs create: fails when MOCK_REF_EXISTS=true
_mock_gh() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$MOCK_GH_LOG"
args=" $* "
if [[ "$args" == *" graphql "* ]]; then
	cat >"$MOCK_GH_GRAPHQL_PAYLOAD"
	printf '%s\n' "${MOCK_GRAPHQL_RESPONSE:-{\"data\":{\"createCommitOnBranch\":{\"commit\":{\"oid\":\"abc123abc123abc123abc123abc123abc123abc1\",\"url\":\"https://github.com/o/r/commit/abc123\"}}}}}"
	exit "${MOCK_GRAPHQL_EXIT:-0}"
fi
if [[ "$args" == *"/branches/"* ]]; then
	if [[ "${MOCK_BRANCH_EXISTS:-true}" != "true" ]]; then
		echo "gh: Branch not found (HTTP 404)" >&2
		exit 1
	fi
	echo "${MOCK_BRANCH_SHA}"
	exit 0
fi
if [[ "$args" == *" -X PATCH "* ]]; then
	echo '{}'
	exit 0
fi
if [[ "$args" == *"/git/refs "* ]]; then
	if [[ "${MOCK_REF_EXISTS:-false}" == "true" ]]; then
		echo "gh: Reference already exists (HTTP 422)" >&2
		exit 1
	fi
	echo '{}'
	exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
MOCK
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

setup() {
	setup_temp_dir
	setup_github_env
	_mock_gh
	export MOCK_GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
	export MOCK_GH_GRAPHQL_PAYLOAD="${BATS_TEST_TMPDIR}/graphql-payload.json"
	export MOCK_BRANCH_SHA="$HEAD_SHA"
	: >"$MOCK_GH_LOG"
	export GITHUB_REPOSITORY="lgtm-hq/example"
	export GH_TOKEN="test-token"

	WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK/Formula"
	printf 'class Lintro < Formula\n  version "1.2.3"\nend\n' >"$WORK/Formula/lintro.rb"
	cd "$WORK"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_input() {
	jq -c '.variables.input' "$MOCK_GH_GRAPHQL_PAYLOAD"
}

# =============================================================================
# append mode
# =============================================================================

@test "create-signed-commit: append sets expectedHeadOid and never touches git/refs" {
	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "chore(deps): pin digest" \
		--file "Formula/lintro.rb"

	assert_success
	assert_output --partial "commit-sha=abc123abc123abc123abc123abc123abc123abc1"
	assert_output --partial "commit-url=https://github.com/o/r/commit/abc123"

	[ "$(_input | jq -r '.expectedHeadOid')" = "$HEAD_SHA" ]
	[ "$(_input | jq -r '.branch.branchName')" = "renovate/foo" ]
	[ "$(_input | jq -r '.branch.repositoryNameWithOwner')" = "lgtm-hq/example" ]
	[ "$(_input | jq -r '.message.headline')" = "chore(deps): pin digest" ]
	[ "$(_input | jq -r '.message | has("body")')" = "false" ]

	run grep -F "git/refs" "$MOCK_GH_LOG"
	assert_failure
	run grep -F -- "-X PATCH" "$MOCK_GH_LOG"
	assert_failure
}

@test "create-signed-commit: append is the default mode" {
	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb"

	assert_success
	run grep -F "repos/lgtm-hq/example/branches/renovate/foo" "$MOCK_GH_LOG"
	assert_success
}

@test "create-signed-commit: append fails clearly when branch is missing" {
	export MOCK_BRANCH_EXISTS="false"

	run bash "$SCRIPT" \
		--branch "renovate/gone" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "Branch renovate/gone does not exist in lgtm-hq/example"
	[ ! -f "$MOCK_GH_GRAPHQL_PAYLOAD" ]
}

@test "create-signed-commit: append fails when branch head moved" {
	export MOCK_BRANCH_SHA="1111111111111111111111111111111111111111"

	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "head moved: expected ${HEAD_SHA}, found 1111111111111111111111111111111111111111"
	[ ! -f "$MOCK_GH_GRAPHQL_PAYLOAD" ]
}

@test "create-signed-commit: append requires --expected-head" {
	run bash "$SCRIPT" --branch "b" --message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "append mode requires --expected-head"
}

@test "create-signed-commit: append rejects --base" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --base "$BASE_SHA" \
		--message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "--base is only valid with --mode reset"
}

# =============================================================================
# reset mode
# =============================================================================

@test "create-signed-commit: reset creates branch ref at base" {
	run bash "$SCRIPT" \
		--mode reset \
		--branch "homebrew/lintro-1.2.3" \
		--base "$BASE_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb"

	assert_success
	assert_output --partial "Created branch homebrew/lintro-1.2.3 at ${BASE_SHA}"
	run grep -qF \
		"api repos/lgtm-hq/example/git/refs -f ref=refs/heads/homebrew/lintro-1.2.3 -f sha=${BASE_SHA}" \
		"$MOCK_GH_LOG"
	assert_success
	run grep -F -- "-X PATCH" "$MOCK_GH_LOG"
	assert_failure
	[ "$(_input | jq -r '.expectedHeadOid')" = "$BASE_SHA" ]
}

@test "create-signed-commit: reset force-patches when ref already exists" {
	export MOCK_REF_EXISTS="true"

	run bash "$SCRIPT" \
		--mode reset \
		--branch "homebrew/lintro-1.2.3" \
		--base "$BASE_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb"

	assert_success
	assert_output --partial "Reset existing branch homebrew/lintro-1.2.3 to ${BASE_SHA}"
	run grep -qF \
		"api -X PATCH repos/lgtm-hq/example/git/refs/heads/homebrew/lintro-1.2.3 -f sha=${BASE_SHA} -F force=true" \
		"$MOCK_GH_LOG"
	assert_success
	[ "$(_input | jq -r '.expectedHeadOid')" = "$BASE_SHA" ]
}

@test "create-signed-commit: reset requires --base" {
	run bash "$SCRIPT" --mode reset --branch "b" --message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "reset mode requires --base"
}

@test "create-signed-commit: rejects invalid mode" {
	run bash "$SCRIPT" --mode rebase --branch "b" --message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "Invalid --mode: rebase"
}

@test "create-signed-commit: rejects abbreviated SHAs" {
	run bash "$SCRIPT" --branch "b" --expected-head "deadbee" --message "msg" \
		--file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "must be a full lowercase commit SHA"
}

# =============================================================================
# File changes and message
# =============================================================================

@test "create-signed-commit: additions base64-encode working-tree contents" {
	printf '\x00\x01binary\xff\n' >"$WORK/blob.bin"
	head -c 200000 /dev/zero | tr '\0' 'x' >"$WORK/large.txt"

	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb" \
		--file "blob.bin" \
		--file "large.txt"

	assert_success
	[ "$(_input | jq -r '.fileChanges.additions | length')" = "3" ]
	[ "$(_input | jq -r '.fileChanges.additions[0].path')" = "Formula/lintro.rb" ]
	_input | jq -r '.fileChanges.additions[0].contents' | base64 -d >"${BATS_TEST_TMPDIR}/decoded0"
	cmp "${BATS_TEST_TMPDIR}/decoded0" "$WORK/Formula/lintro.rb"
	_input | jq -r '.fileChanges.additions[1].contents' | base64 -d >"${BATS_TEST_TMPDIR}/decoded1"
	cmp "${BATS_TEST_TMPDIR}/decoded1" "$WORK/blob.bin"
	_input | jq -r '.fileChanges.additions[2].contents' | base64 -d >"${BATS_TEST_TMPDIR}/decoded2"
	cmp "${BATS_TEST_TMPDIR}/decoded2" "$WORK/large.txt"
	[ "$(_input | jq -r '.fileChanges | has("deletions")')" = "false" ]
}

@test "create-signed-commit: deletions are included" {
	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--file "Formula/lintro.rb" \
		--delete "old/one.txt" \
		--delete "old/two.txt"

	assert_success
	[ "$(_input | jq -c '.fileChanges.deletions')" = '[{"path":"old/one.txt"},{"path":"old/two.txt"}]' ]
}

@test "create-signed-commit: deletions alone are enough to commit" {
	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "msg" \
		--delete "old/one.txt"

	assert_success
	[ "$(_input | jq -r '.fileChanges | has("additions")')" = "false" ]
}

@test "create-signed-commit: body is sent with the headline" {
	run bash "$SCRIPT" \
		--branch "renovate/foo" \
		--expected-head "$HEAD_SHA" \
		--message "chore: headline" \
		--body $'Line one\n\nLine "two" with $dollar' \
		--file "Formula/lintro.rb"

	assert_success
	[ "$(_input | jq -r '.message.body')" = $'Line one\n\nLine "two" with $dollar' ]
}

@test "create-signed-commit: rejects multi-line headline" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" \
		--message $'one\ntwo' --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "single-line headline"
}

@test "create-signed-commit: requires at least one file or deletion" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg"

	assert_failure
	assert_output --partial "Nothing to commit"
}

@test "create-signed-commit: rejects missing file" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg" \
		--file "Formula/missing.rb"

	assert_failure
	assert_output --partial "File not found: Formula/missing.rb"
	[ ! -s "$MOCK_GH_LOG" ]
}

@test "create-signed-commit: rejects directory" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg" \
		--file "Formula"

	assert_failure
	assert_output --partial "Refusing directory"
	[ ! -s "$MOCK_GH_LOG" ]
}

@test "create-signed-commit: rejects symlink" {
	ln -s "Formula/lintro.rb" "$WORK/link.rb"

	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg" \
		--file "link.rb"

	assert_failure
	assert_output --partial "Refusing symlink"
	[ ! -s "$MOCK_GH_LOG" ]
}

@test "create-signed-commit: rejects absolute and parent paths" {
	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg" \
		--file "$WORK/Formula/lintro.rb"
	assert_failure
	assert_output --partial "must be repo-relative"

	run bash "$SCRIPT" --branch "b" --expected-head "$HEAD_SHA" --message "msg" \
		--delete "../outside.txt"
	assert_failure
	assert_output --partial "must not contain '..'"
}

@test "create-signed-commit: rejects unknown argument" {
	run bash "$SCRIPT" --bogus

	assert_failure
	assert_output --partial "Unknown argument: --bogus"
}

# =============================================================================
# Mutation response handling
# =============================================================================

@test "create-signed-commit: GraphQL errors exit non-zero with the error text" {
	export MOCK_GRAPHQL_RESPONSE='{"data":{"createCommitOnBranch":null},"errors":[{"message":"Expected branch to point to \"c0ffee\" but it did not"}]}'
	export MOCK_GRAPHQL_EXIT=1

	run bash "$SCRIPT" --branch "renovate/foo" --expected-head "$HEAD_SHA" \
		--message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "createCommitOnBranch returned no commit"
	assert_output --partial 'Expected branch to point to "c0ffee" but it did not'
	[ ! -s "$GITHUB_OUTPUT" ]
}

@test "create-signed-commit: empty mutation response exits non-zero" {
	export MOCK_GRAPHQL_RESPONSE='{"data":{"createCommitOnBranch":{"commit":null}}}'

	run bash "$SCRIPT" --branch "renovate/foo" --expected-head "$HEAD_SHA" \
		--message "msg" --file "Formula/lintro.rb"

	assert_failure
	assert_output --partial "createCommitOnBranch returned no commit"
	[ ! -s "$GITHUB_OUTPUT" ]
}

@test "create-signed-commit: writes commit-sha and commit-url to GITHUB_OUTPUT" {
	run bash "$SCRIPT" --branch "renovate/foo" --expected-head "$HEAD_SHA" \
		--message "msg" --file "Formula/lintro.rb"

	assert_success
	assert_github_output "commit-sha" "abc123abc123abc123abc123abc123abc123abc1"
	assert_github_output "commit-url" "https://github.com/o/r/commit/abc123"
}

# =============================================================================
# Environment fallbacks (composite action wiring)
# =============================================================================

@test "create-signed-commit: reads inputs from COMMIT_* env with multiline lists" {
	printf 'second\n' >"$WORK/second.txt"

	run env \
		COMMIT_REPOSITORY="other-org/other-repo" \
		COMMIT_BRANCH="bot/branch" \
		COMMIT_MODE="reset" \
		COMMIT_BASE="$BASE_SHA" \
		COMMIT_MESSAGE="chore: from env" \
		COMMIT_BODY="env body" \
		COMMIT_FILES=$'Formula/lintro.rb\n\n  second.txt  \n' \
		COMMIT_DELETE=$'gone.txt\n' \
		bash "$SCRIPT"

	assert_success
	[ "$(_input | jq -r '.branch.repositoryNameWithOwner')" = "other-org/other-repo" ]
	[ "$(_input | jq -r '.branch.branchName')" = "bot/branch" ]
	[ "$(_input | jq -r '.expectedHeadOid')" = "$BASE_SHA" ]
	[ "$(_input | jq -r '.message.body')" = "env body" ]
	[ "$(_input | jq -c '[.fileChanges.additions[].path]')" = '["Formula/lintro.rb","second.txt"]' ]
	[ "$(_input | jq -c '.fileChanges.deletions')" = '[{"path":"gone.txt"}]' ]
	run grep -qF "repos/other-org/other-repo/git/refs" "$MOCK_GH_LOG"
	assert_success
}
