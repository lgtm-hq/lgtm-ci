#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for the oversized comment backstop (#1705) in
# scripts/ci/actions/post-pr-comment.sh and the character budget
# (HISTORY_MAX_CHARS) of scripts/ci/actions/post-pr-comment-history.sh

load "../../../helpers/common"

POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
HELPER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment-history.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'
RUN_URL_200='https://github.com/lgtm-hq/consumer/actions/runs/200'
LIMIT=65536

setup() {
	setup_temp_dir
	export GH_TOKEN="test-token"
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export PR_NUMBER="42"
	export MARKER="test-marker"
	export MODE="upsert"
	export DELETE_ON_EMPTY="false"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	export GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_NUMBER=2
	export GITHUB_SHA=0000000000000000000000000000000000000000
	export EVENT_PULL_REQUEST_HEAD_SHA=abcdef1234567890abcdef1234567890abcdef12
	export GITHUB_SERVER_URL="https://github.com"
	export HISTORY_NOW="2026-11-20T12:00:00Z"
	unset COMMENT_FIELDS HISTORY HISTORY_SUMMARY HISTORY_FIELDS HISTORY_MAX_BYTES HISTORY_MAX_CHARS

	# gh stub: viewer is github-actions[bot]; the listing prints
	# $GH_LIST_JSON; POST/PATCH write body= to $GH_BODY and keep every body
	# sent in $GH_SENT (one file each).
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export GH_BODY="${BATS_TEST_TMPDIR}/gh_body"
	export GH_SENT="${BATS_TEST_TMPDIR}/sent"
	mkdir -p "$GH_SENT"
	: >"$GH_CALLS"
	rm -f "$GH_BODY"
	export GH_LIST_JSON='[]'
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-} ${2:-} ${3:-} ${4:-}" >>"$GH_CALLS"
if [[ "$1 $2" == "api graphql" ]]; then
	printf '{"data":{"viewer":{"login":"github-actions[bot]","databaseId":41898282}}}\n'
	exit 0
fi
args=("$@")
method=GET
for ((i = 0; i < ${#args[@]}; i++)); do
	[[ "${args[i]}" == "-X" ]] && method="${args[i + 1]}"
done
case "$method" in
DELETE) exit 0 ;;
POST | PATCH)
	for arg in "$@"; do
		[[ "$arg" == /repos/* ]] && printf '%s %s\n' "$method" "$arg" >>"$GH_CALLS"
	done
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "-f" && "${args[i + 1]}" == body=* ]]; then
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
			cp "$GH_BODY" "${GH_SENT}/$(ls "$GH_SENT" | wc -l | tr -d ' ')"
		fi
	done
	printf '{"id": 7, "html_url": "https://github.com/c/7"}\n'
	exit 0
	;;
esac
printf '%s\n' "$GH_LIST_JSON"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

teardown() {
	teardown_temp_dir
}

_post() { # body [HISTORY]
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="$1" \
		HISTORY="${2:-false}" \
		bash "$POSTER"
}

# _comment <id> <body>: one listing element written by github-actions[bot].
_comment() {
	jq -cn --argjson id "$1" --arg body "$2" \
		'{id: $id, user: {login: "github-actions[bot]", id: 41898282, type: "Bot"}, body: $body}'
}

# Characters of a file as the poster counts them (UTF-16 code units).
_units() {
	python3 -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); print(sum(2 if ord(c) > 0xFFFF else 1 for c in t))' "$1"
}

# Code points of a file.
_codepoints() {
	python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$1"
}

# _pad <count> [char]: <count> copies of char (default r).
_pad() {
	python3 -c 'import sys; sys.stdout.write(sys.argv[2] * int(sys.argv[1]))' "$1" "${2:-r}"
}

# Every body the API received is within GitHub's limit.
_assert_all_sent_fit() {
	local f
	for f in "$GH_SENT"/*; do
		[[ -e "$f" ]] || continue
		run _units "$f"
		assert [ "$output" -le "$LIMIT" ]
	done
}

_warnings() {
	grep -c '^::warning' <<<"$output" || true
}

# The stamp line the composer writes for run 200 in these tests.
_stamp_200() {
	printf '<!-- lgtm-ci:history:latest sha=%s run=200 attempt=1 number=2 at=%s -->' \
		"$EVENT_PULL_REQUEST_HEAD_SHA" "$HISTORY_NOW"
}

# =============================================================================
# Without history
# =============================================================================

@test "size: a body that brings the comment to exactly the limit is posted byte for byte" {
	local body
	# marker line + newline + body = 65,536 characters
	body="$(_pad $((LIMIT - ${#MARKER_LINE} - 1)))"
	_post "$body"

	assert_success
	assert_equal "$(_warnings)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
	run _units "$GH_BODY"
	assert_output "$LIMIT"
}

@test "size: one character over the limit posts the notice instead, with one warning" {
	local head body
	# An ASCII-only head, so its length is the same in bytes and characters.
	head="## Results"$'\n\n'"### Status: PASSED"$'\n\n'
	body="${head}$(_pad $((LIMIT - ${#MARKER_LINE} - 1 - ${#head} + 1)))"
	_post "$body"

	assert_success
	assert_equal "$(_warnings)" "1"
	assert_output --partial "::warning title=post-pr-comment::The comment body is over GitHub's limit of 65,536 characters (65,537 characters)"
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run head -n 1 "$GH_BODY"
	assert_output "$MARKER_LINE"
	run cat "$GH_BODY"
	assert_line --index 1 "### ⚠️ Summary too long to post"
	assert_output --partial "> The summary for this run (commit \`abcdef1\`) is 65,537 characters, over GitHub's limit of 65,536 for one comment, so it is not shown."
	assert_output --partial "> **No result is shown for this run**, and no earlier result applies to it: see the [workflow run](${RUN_URL_200}) for the outcome."
	refute_output --partial "PASSED"
	refute_output --partial "rrrr"
	_assert_all_sent_fit
}

@test "size: the notice overwrites the stale comment, and the next run updates the same one" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")")]"
	_post "### ✅ PASSED $(_pad 70000)"

	assert_success
	run grep -c '^PATCH .*/issues/comments/7$' "$GH_CALLS"
	assert_output "1"
	run grep -c '^POST ' "$GH_CALLS"
	assert_output "0"
	refute grep -q "PASSED" "$GH_BODY"

	export GH_LIST_JSON="[$(_comment 7 "$(cat "$GH_BODY")")]"
	: >"$GH_CALLS"
	_post "### ❌ FAILED"
	assert_success
	assert_equal "$(_warnings)" "0"
	run grep -c '^PATCH .*/issues/comments/7$' "$GH_CALLS"
	assert_output "1"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
	_assert_all_sent_fit
}

@test "size: characters are counted, not bytes: a multibyte body over the limit in bytes is posted unchanged" {
	local body
	# 40,000 characters, 80,000 bytes.
	body="$(_pad 40000 é)"
	_post "$body"

	assert_success
	assert_equal "$(_warnings)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
}

@test "size: multibyte characters at the limit: 65,536 posts, 65,537 is replaced" {
	local head body
	# ASCII padding with 600 two-byte characters at the end, across the
	# point where bytes pass the limit long before characters do.
	head="$(_pad $((LIMIT - ${#MARKER_LINE} - 1 - 600)))"
	body="${head}$(_pad 600 é)"
	_post "$body"
	assert_success
	assert_equal "$(_warnings)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
	run _codepoints "$GH_BODY"
	assert_output "$LIMIT"

	rm -f "$GH_BODY"
	_post "${body}€"
	assert_success
	assert_equal "$(_warnings)" "1"
	run cat "$GH_BODY"
	assert_line --index 1 "### ⚠️ Summary too long to post"
	assert_output --partial "is 65,537 characters"
	_assert_all_sent_fit
}

@test "size: a character outside the Basic Multilingual Plane counts as two" {
	local body
	# 65,000 code points, 66,000 UTF-16 code units, plus the marker line.
	body="$(_pad 64000)$(_pad 1000 😀)"
	_post "$body"

	assert_success
	assert_equal "$(_warnings)" "1"
	assert_output --partial "(66,029 characters)"
	_assert_all_sent_fit
}

@test "size: a body whose length cannot be counted is treated as over the limit" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin" real_jq
	real_jq="$(command -v jq)"
	cat >"${mock_bin}/jq" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *explode* ]] && exit 3
exec "${real_jq}" "\$@"
EOF
	chmod +x "${mock_bin}/jq"
	_post "### ✅ PASSED $(_pad 66000)"

	assert_success
	assert_equal "$(_warnings)" "1"
	assert_output --partial "(its size could not be measured)"
	run cat "$GH_BODY"
	assert_output --partial "could not be measured and may be over GitHub's limit of 65,536 characters for one comment, so it is not shown."
	refute_output --partial "PASSED"
	_assert_all_sent_fit
}

@test "size: the reserved namespace in an oversized body never reaches the notice" {
	_post "<!-- lgtm-ci:other -->"$'\n'"<!-- lgtm-ci:history:latest sha=x run=999 attempt=1 number=9 at=y -->"$'\n'"$(_pad 70000)"

	assert_success
	run grep -c 'lgtm-ci:' "$GH_BODY"
	assert_output "1"
	run head -n 1 "$GH_BODY"
	assert_output "$MARKER_LINE"
}

@test "size: comment-fields are not carried onto the notice" {
	COMMENT_FIELDS="Status: PASSED" _post "## Report"$'\n\n'"$(_pad 70000)"

	assert_success
	refute grep -q "PASSED" "$GH_BODY"
	run grep -c '^::warning title=post-pr-comment::' <<<"$output"
	assert_output "1"
	_assert_all_sent_fit
}

@test "size: update mode without a comment skips an oversized body without a warning" {
	MODE=update _post "$(_pad 70000)"

	assert_success
	assert_output --partial "Skipped: no existing comment to update"
	assert_equal "$(_warnings)" "0"
	assert [ ! -e "$GH_BODY" ]
}

@test "size: without a run id the notice points at the pull request's checks" {
	GITHUB_RUN_ID="" EVENT_PULL_REQUEST_HEAD_SHA="not-a-sha" GITHUB_SHA="" _post "$(_pad 70000)"

	assert_success
	run cat "$GH_BODY"
	assert_output --partial "> The summary for this run is 70,029 characters"
	assert_output --partial "see this pull request's checks for the outcome."
	refute_output --partial "](http"
}

# =============================================================================
# With history
# =============================================================================

# An existing history comment for run 100 that said PASSED, with summary.
_passed_history_comment() {
	local summary
	summary="$(printf '%s' 'all 42 passed' | base64)"
	printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=1111111111111111111111111111111111111111 run=100 attempt=1 number=1 at=2026-11-19T12:00:00Z summary=${summary} -->" \
		"### ✅ PASSED (run 100)"
}

@test "size: history, oversized with no earlier comment: marker, stamp and notice, no archive" {
	HISTORY_SUMMARY="all 42 passed" _post "### ✅ PASSED $(_pad 70000)" true

	assert_success
	assert_equal "$(_warnings)" "1"
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run cat "$GH_BODY"
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "### ⚠️ Summary too long to post"
	refute_output --partial "PASSED"
	refute_output --partial "summary="
	refute_output --partial "Previous runs"
	_assert_all_sent_fit
}

@test "size: history, oversized over a PASSED comment: the notice is on top, the old result only in the archive" {
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment)")]"
	HISTORY_SUMMARY="all 42 passed" COMMENT_FIELDS="Status: PASSED" \
		_post "### ✅ PASSED (run 200) $(_pad 70000)" true

	assert_success
	run grep -c '^::warning title=post-pr-comment::' <<<"$output"
	assert_output "1"
	run grep -c '^PATCH .*/issues/comments/7$' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "### ⚠️ Summary too long to post"
	refute_output --partial "run 200"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	# Above the archive no result shows; the PASSED of run 100 is only below.
	local latest
	latest="$(sed -n '1,/^---$/p' "$GH_BODY")"
	[[ "$latest" != *PASSED* && "$latest" != *passed* ]]
	_assert_all_sent_fit
}

@test "size: history, the next normal run updates the notice comment and archives it" {
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment)")]"
	_post "### ✅ PASSED $(_pad 70000)" true
	assert_success

	export GH_LIST_JSON="[$(_comment 7 "$(cat "$GH_BODY")")]"
	: >"$GH_CALLS"
	GITHUB_RUN_ID=300 GITHUB_RUN_NUMBER=3 _post "### ❌ FAILED (run 300)" true
	assert_success
	assert_equal "$(_warnings)" "0"
	run grep -c '^PATCH .*/issues/comments/7$' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 2 "### ❌ FAILED (run 300)"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=${EVENT_PULL_REQUEST_HEAD_SHA} run=200 "
	assert_output --partial "Summary too long to post"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	_assert_all_sent_fit
}

@test "size: history is trimmed before the notice is used: a large body that fits alone is posted" {
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment)")]"
	local body
	body="### ❌ FAILED $(_pad 61000)"
	_post "$body" true

	assert_success
	assert_equal "$(_warnings)" "0"
	run cat "$GH_BODY"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "$body"
	refute_output --partial "lgtm-ci:history:entry"
	refute_output --partial "Summary too long"
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
	_assert_all_sent_fit
}

@test "size: history, the size note is left out when only the note would push the body over" {
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment)")]"
	local stamp body
	stamp="$(_stamp_200)"
	# marker + stamp + body = 65,500 characters: fits; with the note it would not.
	body="$(_pad $((65500 - ${#MARKER_LINE} - 1 - ${#stamp} - 1)))"
	_post "$body" true

	assert_success
	assert_equal "$(_warnings)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n%s' "$MARKER_LINE" "$stamp" "$body")"
	_assert_all_sent_fit
}

@test "size: history, a multibyte body under the limit is posted exactly as the composer writes it" {
	local body expected
	body="$(_pad 30000 €)"
	printf '%s\n' "$body" >"${BATS_TEST_TMPDIR}/new.md"
	expected="$(env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		HEAD_SHA="$EVENT_PULL_REQUEST_HEAD_SHA" RUN_ID=200 RUN_ATTEMPT=1 RUN_NUMBER=2 \
		RUN_URL="$RUN_URL_200" bash "$HELPER" </dev/null)"
	_post "$body" true

	assert_success
	assert_equal "$(_warnings)" "0"
	assert_equal "$(cat "$GH_BODY")" "$expected"
}

# =============================================================================
# Composer: HISTORY_MAX_CHARS
# =============================================================================

@test "post-pr-comment-history: HISTORY_MAX_CHARS must be a non-negative integer" {
	printf 'x\n' >"${BATS_TEST_TMPDIR}/new.md"
	run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		HISTORY_MAX_CHARS="65k" bash "$HELPER" </dev/null

	assert_failure
	assert_output --partial "HISTORY_MAX_CHARS must be a non-negative integer, got '65k'"
}

@test "post-pr-comment-history: HISTORY_MAX_CHARS leaves a body within the byte budget untouched" {
	local existing new
	existing="$(_passed_history_comment)"
	printf '%s\n' "body 200" >"${BATS_TEST_TMPDIR}/new.md"
	new="$(printf '%s' "$existing" | env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" \
		MARKER_TAG="$MARKER_LINE" RUN_ID=200 RUN_NUMBER=2 bash "$HELPER")"
	run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		RUN_ID=200 RUN_NUMBER=2 HISTORY_MAX_CHARS=65536 bash "$HELPER" <<<"$existing"

	assert_success
	assert_equal "$output" "$new"
	assert_output --partial "lgtm-ci:history:entry"
}
