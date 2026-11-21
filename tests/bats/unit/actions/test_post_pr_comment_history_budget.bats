#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: History under GitHub's limit (#1705): archive entries first,
# then the archive, then the result, in scripts/ci/actions/post-pr-comment.sh
# and scripts/ci/actions/post-pr-comment-history.sh
#
# Bodies near the limit are built with python straight into files and read
# back with grep, awk and cmp: under coverage every traced shell line that
# expands a large string is expensive.

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

	_assert_notice "summary file" "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	_line_starts "$GH_BODY" 2 "$(_stamp_200)"
	_line_starts "$GH_BODY" 3 "### ⚠️ Summary too long to post"
	_lacks "$GH_BODY" "summary="
	_lacks "$GH_BODY" "Previous runs"
}

@test "history: a large archive and an oversized report: notice on top, archive kept, step fails" {
	_history_file "${BATS_TEST_TMPDIR}/existing.md" passed 50000
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write "${BATS_TEST_TMPDIR}/body.md" 600000 r "### ✅ PASSED (run 200) "
	HISTORY_SUMMARY="all 42 passed" COMMENT_FIELDS="Status: PASSED" \
		_post_file "${BATS_TEST_TMPDIR}/body.md" true

	_assert_notice "summary file" "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
	_line_starts "$GH_BODY" 2 "$(_stamp_200)"
	_line_starts "$GH_BODY" 3 "### ⚠️ Summary too long to post"
	_has "$GH_BODY" "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
}

@test "history: the next normal run updates the notice comment and archives it" {
	_history_file "${BATS_TEST_TMPDIR}/existing.md" passed 0
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	_post_file "${BATS_TEST_TMPDIR}/body.md" true
	assert_failure

	_set_listing_file 7 "$GH_BODY"
	: >"$GH_CALLS"
	GITHUB_RUN_ID=300 GITHUB_RUN_NUMBER=3 _post "### ❌ FAILED (run 300)" true
	assert_success
	assert_equal "$(_commands)" "0"
	_line_starts "$GH_BODY" 3 "### ❌ FAILED (run 300)"
	_has "$GH_BODY" "<!-- lgtm-ci:history:entry sha=${EVENT_PULL_REQUEST_HEAD_SHA} run=200 "
	_has "$GH_BODY" "Summary too long to post"
	_has "$GH_BODY" "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
}

@test "history: a raised HISTORY_MAX_BYTES never replaces a fitting report for its archive" {
	# Review case, at the smallest size that shows it: a PASSED archive and a
	# FAILED report that pass GitHub's limit only together, with the budget
	# raised far past it. The archive is trimmed to the limit; the report is
	# posted.
	_history_file "${BATS_TEST_TMPDIR}/existing.md" passed 170000
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write "${BATS_TEST_TMPDIR}/body.md" 100000 f "### ❌ FAILED "
	HISTORY_MAX_BYTES=1000000 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	_line_starts "$GH_BODY" 3 "### ❌ FAILED fff"
	_lacks "$GH_BODY" "lgtm-ci:history:entry"
	_has "$GH_BODY" "> ✂️ 1 older runs not listed (size limit)"
	_assert_all_sent_fit
}

@test "history: with a raised budget the archive is kept up to the limit" {
	_history_file "${BATS_TEST_TMPDIR}/existing.md" passed 64000
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	HISTORY_MAX_BYTES=1000000 _post "### ❌ FAILED (run 200)" true

	assert_success
	assert_equal "$(_commands)" "0"
	_has "$GH_BODY" "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	_lacks "$GH_BODY" "Summary too long"
}

@test "history: entries are trimmed oldest first against the encoded size, keeping those that fit" {
	# Review case: 60,000 ASCII bytes and 60,000 stray continuation bytes
	# (240,000 bytes once encoded) over two earlier 15,000-byte results. The
	# newest earlier result fits; the oldest does not.
	_history_file "${BATS_TEST_TMPDIR}/existing.md" two 15000
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write_runs "${BATS_TEST_TMPDIR}/body.md" 1 "### ❌ FAILED " 60000 f
	_write "${BATS_TEST_TMPDIR}/tail.md" 60000 '\x80'
	cat "${BATS_TEST_TMPDIR}/tail.md" >>"${BATS_TEST_TMPDIR}/body.md"
	HISTORY_MAX_BYTES=262144 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	_line_starts "$GH_BODY" 3 "### ❌ FAILED fff"
	_has "$GH_BODY" "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	_lacks "$GH_BODY" "run=50 "
	_has "$GH_BODY" "> ✂️ 1 older runs not listed (size limit)"
	_lacks "$GH_BODY" "Summary too long"
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
	_history_file "${BATS_TEST_TMPDIR}/existing.md" two 15000
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write_runs "${BATS_TEST_TMPDIR}/body.md" 1 "### ❌ FAILED " 60000 f
	_write "${BATS_TEST_TMPDIR}/tail.md" 60000 '\x80'
	cat "${BATS_TEST_TMPDIR}/tail.md" >>"${BATS_TEST_TMPDIR}/body.md"
	PATH="${bin}:${PATH}" HISTORY_MAX_BYTES=262144 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	_line_starts "$GH_BODY" 3 "### ❌ FAILED fff"
	_lacks "$GH_BODY" "Previous runs"
	_lacks "$GH_BODY" "older runs not listed"
	_lacks "$GH_BODY" "Summary too long"
	_assert_all_sent_fit
}

@test "history: a report that fits only without the archive's note is posted alone" {
	# Marker, stamp and report come to 20 bytes under the limit; the
	# archive's wrapper and note would pass it.
	local stamp
	stamp="$(_stamp_200)"
	_history_file "${BATS_TEST_TMPDIR}/existing.md" two 100
	_set_listing_file 7 "${BATS_TEST_TMPDIR}/existing.md"
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - 1 - ${#stamp} - 1 - 20))
	_post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	_lacks "$GH_BODY" "Previous runs"
	_lacks "$GH_BODY" "older runs not listed"
	_line_starts "$GH_BODY" 2 "$stamp"
	assert_equal "$(_bytes "$GH_BODY")" "$((LIMIT - 20))"
	_assert_all_sent_fit
}

@test "history: a multibyte report under the limit is posted exactly as the composer writes it" {
	_write "${BATS_TEST_TMPDIR}/new.md" 30000 €
	printf '\n' >>"${BATS_TEST_TMPDIR}/new.md"
	env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		HEAD_SHA="$EVENT_PULL_REQUEST_HEAD_SHA" RUN_ID=200 RUN_ATTEMPT=1 RUN_NUMBER=2 \
		RUN_URL="$RUN_URL_200" bash "$HELPER" </dev/null >"${BATS_TEST_TMPDIR}/expected.raw"
	# The poster posts the composer's output without its final newline.
	head -c "$(($(_bytes "${BATS_TEST_TMPDIR}/expected.raw") - 1))" "${BATS_TEST_TMPDIR}/expected.raw" \
		>"${BATS_TEST_TMPDIR}/expected"
	_write "${BATS_TEST_TMPDIR}/body.md" 30000 €
	_post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

# =============================================================================
# Composer: bytes as sent, GitHub's limit a ceiling on the budget
# =============================================================================

@test "post-pr-comment-history: entries are trimmed oldest first at GitHub's limit, whatever the budget" {
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=1000000 HISTORY_LIMIT=0

	assert_success
	local composed="${BATS_TEST_TMPDIR}/composed"
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	_lacks "$composed" "run=1 "
	_has "$composed" "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: entries are trimmed against the encoded size of invalid UTF-8" {
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 2 15000
	_write_runs "${BATS_TEST_TMPDIR}/new.md" 1 "body 200 " 60000 f
	_write "${BATS_TEST_TMPDIR}/tail.md" 60000 '\x80'
	cat "${BATS_TEST_TMPDIR}/tail.md" >>"${BATS_TEST_TMPDIR}/new.md"
	printf '\n' >>"${BATS_TEST_TMPDIR}/new.md"
	_compose_file "${BATS_TEST_TMPDIR}/existing.md" "${BATS_TEST_TMPDIR}/new.md" \
		HISTORY_MAX_BYTES=262144 HISTORY_LIMIT=0

	assert_success
	local composed="${BATS_TEST_TMPDIR}/composed"
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	_lacks "$composed" "run=1 "
	run jq -nj --rawfile b "$composed" '$b | utf8bytelength'
	assert [ "$output" -le "$((LIMIT + 1))" ]
}

@test "post-pr-comment-history: the archive goes entirely when only its note would pass the limit" {
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 1 100
	# marker + stamp + body = 262,100 bytes: fits; the note would not.
	_write "${BATS_TEST_TMPDIR}/new.md" 262000
	printf '\n' >>"${BATS_TEST_TMPDIR}/new.md"
	_compose_file "${BATS_TEST_TMPDIR}/existing.md" "${BATS_TEST_TMPDIR}/new.md" HISTORY_MAX_BYTES=1000000

	assert_success
	local composed="${BATS_TEST_TMPDIR}/composed"
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	_lacks "$composed" "Previous runs"
	_lacks "$composed" "older runs not listed"
	# The third line is the body, all of it.
	run awk 'NR == 3 { print length($0) }' "$composed"
	assert_output "262000"
}

@test "post-pr-comment-history: HISTORY_LATEST_ONLY writes the latest result alone" {
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 2 100
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_LATEST_ONLY=true

	assert_success
	assert_equal "$(cat "${BATS_TEST_TMPDIR}/composed")" "$(printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=abcdef1 run=200 attempt=1 number=2 at=${HISTORY_NOW} -->" "body 200")"

	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_LATEST_ONLY=maybe
	assert_failure
	assert_output --partial "HISTORY_LATEST_ONLY must be true or false, got 'maybe'"
}

@test "post-pr-comment-history: an overflowing HISTORY_MAX_BYTES is held to the limit" {
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=99999999999999999999999 HISTORY_LIMIT=0

	assert_success
	assert [ "$(_composed_bytes)" -le "$LIMIT" ]
	_has "${BATS_TEST_TMPDIR}/composed" "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: the default budget is unchanged" {
	# history-limit 3 keeps runs 4, 3 and 2; run 2 does not fit 60,000 bytes.
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 3 30000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200"

	assert_success
	local composed="${BATS_TEST_TMPDIR}/composed"
	assert [ "$(_composed_bytes)" -le 60000 ]
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	_lacks "$composed" "run=2 "
	_has "$composed" "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: sizes are bytes under a UTF-8 locale too" {
	# Two archived runs of 20,000 two-byte characters: 40,000 characters
	# would fit the 60,000 budget together; 80,000 bytes do not.
	local utf8
	utf8="$(locale -a 2>/dev/null | grep -iE '^(C\.UTF-?8|en_US\.UTF-?8)$' | head -n 1)"
	[[ -n "$utf8" ]] || skip "no UTF-8 locale on this system"
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 2 20000 é
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" LC_ALL="$utf8" LANG="$utf8"

	assert_success
	local composed="${BATS_TEST_TMPDIR}/composed"
	assert [ "$(_composed_bytes)" -le 60000 ]
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	_has "$composed" "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	_lacks "$composed" "run=1 "
	_has "$composed" "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: archive candidates are sized as composed" {
	# The composer sizes candidates from their parts; the body it composes is
	# measured whole. With the budget exactly at a candidate's composed size
	# the candidate is kept, one byte under it is not.
	_archive_file "${BATS_TEST_TMPDIR}/existing.md" 1 5000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=1000000
	assert_success
	local size
	size="$(_composed_bytes)"
	_has "${BATS_TEST_TMPDIR}/composed" "<!-- lgtm-ci:history:entry sha=s1 run=1 "

	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES="$size"
	_has "${BATS_TEST_TMPDIR}/composed" "<!-- lgtm-ci:history:entry sha=s1 run=1 "
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES="$((size - 1))"
	_lacks "${BATS_TEST_TMPDIR}/composed" "<!-- lgtm-ci:history:entry sha=s1 run=1 "
}
