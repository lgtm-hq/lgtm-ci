#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: History under GitHub's limit (#1705): archive entries first,
# then the archive, then the result, in scripts/ci/actions/post-pr-comment.sh
# and scripts/ci/actions/post-pr-comment-history.sh

load "../../../helpers/common"
load "../../../helpers/post_pr_comment_size"

setup() {
	post_pr_comment_size_setup
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# History: archive first, then the archive as a whole, then the result
# =============================================================================

@test "notice: comment-fields over a report the history stamp pushes past the limit log one thing" {
	# 262,100 bytes fit without history; the stamp pushes them over.
	_write "${BATS_TEST_TMPDIR}/body.md" 262100
	COMMENT_FIELDS="Env: staging" _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post"
	_refute_fields_messages
	_assert_all_sent_fit
}

@test "history: an oversized report with no earlier comment gets marker, stamp and notice" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000 r "### ✅ PASSED "
	HISTORY_SUMMARY="all 42 passed" _post_file "${BATS_TEST_TMPDIR}/body.md" true

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run cat "$GH_BODY"
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "### ⚠️ Summary too long to post"
	refute_output --partial "summary="
	refute_output --partial "Previous runs"
}

@test "history: a large archive and an oversized report: notice on top, archive kept, step fails" {
	_set_listing 7 "$(_passed_history_comment 50000)"
	_write "${BATS_TEST_TMPDIR}/body.md" 600000 r "### ✅ PASSED (run 200) "
	HISTORY_SUMMARY="all 42 passed" COMMENT_FIELDS="Status: PASSED" \
		_post_file "${BATS_TEST_TMPDIR}/body.md" true

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "### ⚠️ Summary too long to post"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
}

@test "history: the next normal run updates the notice comment and archives it" {
	_set_listing 7 "$(_passed_history_comment)"
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	_post_file "${BATS_TEST_TMPDIR}/body.md" true
	assert_failure

	_set_listing 7 "$(cat "$GH_BODY")"
	: >"$GH_CALLS"
	GITHUB_RUN_ID=300 GITHUB_RUN_NUMBER=3 _post "### ❌ FAILED (run 300)" true
	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_line --index 2 "### ❌ FAILED (run 300)"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=${EVENT_PULL_REQUEST_HEAD_SHA} run=200 "
	assert_output --partial "Summary too long to post"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
}

@test "history: a raised HISTORY_MAX_BYTES never replaces a fitting report for its archive" {
	# Review case: a large PASSED archive and a small FAILED report with the
	# budget raised far past GitHub's limit. The archive is trimmed to the
	# limit; the report is posted.
	_set_listing 7 "$(_passed_history_comment 200000)"
	_write "${BATS_TEST_TMPDIR}/body.md" 100000 f "### ❌ FAILED "
	HISTORY_MAX_BYTES=1000000 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_line --index 2 --partial "### ❌ FAILED fff"
	refute_output --partial "lgtm-ci:history:entry"
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
	_assert_all_sent_fit
}

@test "history: with a raised budget the archive is kept up to the limit" {
	_set_listing 7 "$(_passed_history_comment 64000)"
	HISTORY_MAX_BYTES=1000000 _post "### ❌ FAILED $(_pad 2000 f)" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	refute_output --partial "Summary too long"
}

@test "history: entries are trimmed oldest first against the encoded size, keeping those that fit" {
	# Review case: 60,000 ASCII bytes and 60,000 stray continuation bytes
	# (240,000 bytes once encoded) over two earlier 15,000-byte results. The
	# newest earlier result fits; the oldest does not.
	_set_listing 7 "$(_two_run_comment 15000)"
	_write "${BATS_TEST_TMPDIR}/body.md" 60000 '\x80' "### ❌ FAILED $(_pad 60000 f)"
	HISTORY_MAX_BYTES=262144 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_line --index 2 --partial "### ❌ FAILED fff"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	refute_output --partial "run=50 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
	refute_output --partial "Summary too long"
	_assert_all_sent_fit
}

@test "history: when the measures disagree the result is posted alone, with no archive and no note" {
	# The composer is made to measure every candidate as fitting; the poster
	# measures what it sends, finds it over, and posts the result alone
	# before it would replace it (review thread on the zero-budget fallback).
	local bin="${BATS_TEST_TMPDIR}/stub" real_jq
	real_jq="$(command -v jq)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nif [[ " $* " == *"\\$body | utf8bytelength"* ]]; then printf 1; exit 0; fi\nexec "%s" "$@"\n' \
		"$real_jq" >"${bin}/jq"
	chmod +x "${bin}/jq"
	_set_listing 7 "$(_two_run_comment 15000)"
	_write "${BATS_TEST_TMPDIR}/body.md" 60000 '\x80' "### ❌ FAILED $(_pad 60000 f)"
	PATH="${bin}:${PATH}" HISTORY_MAX_BYTES=262144 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_line --index 2 --partial "### ❌ FAILED fff"
	refute_output --partial "Previous runs"
	refute_output --partial "older runs not listed"
	refute_output --partial "Summary too long"
	_assert_all_sent_fit
}

@test "history: a report that fits only without the archive's note is posted alone" {
	# Marker, stamp and report come to 20 bytes under the limit; the
	# archive's wrapper and note would pass it.
	local stamp
	stamp="$(_stamp_200)"
	_set_listing 7 "$(_two_run_comment 100)"
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - 1 - ${#stamp} - 1 - 20))
	_post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	refute_output --partial "Previous runs"
	refute_output --partial "older runs not listed"
	assert_line --index 1 "$(_stamp_200)"
	_assert_all_sent_fit
}

@test "history: a multibyte report under the limit is posted exactly as the composer writes it" {
	local body expected
	body="$(_pad 30000 €)"
	printf '%s\n' "$body" >"${BATS_TEST_TMPDIR}/new.md"
	expected="$(env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		HEAD_SHA="$EVENT_PULL_REQUEST_HEAD_SHA" RUN_ID=200 RUN_ATTEMPT=1 RUN_NUMBER=2 \
		RUN_URL="$RUN_URL_200" bash "$HELPER" </dev/null)"
	_post "$body" true

	assert_success
	assert_equal "$(_commands)" "0"
	assert_equal "$(cat "$GH_BODY")" "$expected"
}

# =============================================================================
# Composer: bytes as sent, GitHub's limit a ceiling on the budget
# =============================================================================

@test "post-pr-comment-history: entries are trimmed oldest first at GitHub's limit, whatever the budget" {
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=1000000 HISTORY_LIMIT=0

	assert_success
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	refute_output --partial "run=1 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: entries are trimmed against the encoded size of invalid UTF-8" {
	local body
	_archive "${BATS_TEST_TMPDIR}/existing.md" 2 15000
	body="$(printf 'body 200 %s' "$(_pad 60000 f)")$(printf '\x80%.0s' $(seq 1 60000))"
	_compose "${BATS_TEST_TMPDIR}/existing.md" "$body" HISTORY_MAX_BYTES=262144 HISTORY_LIMIT=0

	assert_success
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	refute_output --partial "run=1 "
	printf '%s' "$output" >"${BATS_TEST_TMPDIR}/composed"
	run jq -nj --rawfile b "${BATS_TEST_TMPDIR}/composed" '$b | utf8bytelength'
	assert [ "$output" -le "$LIMIT" ]
}

@test "post-pr-comment-history: the archive goes entirely when only its note would pass the limit" {
	local body
	_archive "${BATS_TEST_TMPDIR}/existing.md" 1 100
	# marker + stamp + body = 262,100 bytes: fits; the note would not.
	body="$(_pad 262000)"
	_compose "${BATS_TEST_TMPDIR}/existing.md" "$body" HISTORY_MAX_BYTES=1000000

	assert_success
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	refute_output --partial "Previous runs"
	refute_output --partial "older runs not listed"
	assert_line --index 2 "$body"
}

@test "post-pr-comment-history: HISTORY_LATEST_ONLY writes the latest result alone" {
	_archive "${BATS_TEST_TMPDIR}/existing.md" 2 100
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_LATEST_ONLY=true

	assert_success
	assert_equal "$output" "$(printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=abcdef1 run=200 attempt=1 number=2 at=${HISTORY_NOW} -->" "body 200")"

	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_LATEST_ONLY=maybe
	assert_failure
	assert_output --partial "HISTORY_LATEST_ONLY must be true or false, got 'maybe'"
}

@test "post-pr-comment-history: an overflowing HISTORY_MAX_BYTES is held to the limit" {
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=99999999999999999999999 HISTORY_LIMIT=0

	assert_success
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: the default budget is unchanged" {
	# history-limit 3 keeps runs 4, 3 and 2; run 2 does not fit 60,000 bytes.
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 30000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200"

	assert_success
	assert [ "$(_composed_bytes)" -le 60000 ]
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	refute_output --partial "run=2 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: sizes are bytes under a UTF-8 locale too" {
	# Two archived runs of 20,000 two-byte characters: 40,000 characters
	# would fit the 60,000 budget together; 80,000 bytes do not.
	local utf8
	utf8="$(locale -a 2>/dev/null | grep -iE '^(C\.UTF-?8|en_US\.UTF-?8)$' | head -n 1)"
	[[ -n "$utf8" ]] || skip "no UTF-8 locale on this system"
	_archive "${BATS_TEST_TMPDIR}/existing.md" 2 20000 é
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" LC_ALL="$utf8" LANG="$utf8"

	assert_success
	assert [ "$(_composed_bytes)" -le 60000 ]
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	refute_output --partial "run=1 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}
