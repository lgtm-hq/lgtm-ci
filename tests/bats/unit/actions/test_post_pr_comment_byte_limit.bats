#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: GitHub's 262,144-byte limit on a comment (#1705) in
# scripts/ci/actions/post-pr-comment.sh: bodies at and just over it in
# ASCII, two-byte and four-byte text, invalid UTF-8 measured as sent, and
# the comment-fields log when the body is replaced

load "../../../helpers/common"
load "../../../helpers/post_pr_comment_size"

setup() {
	post_pr_comment_size_setup
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# The limit is 262,144 bytes (#1705)
# =============================================================================

@test "size: ASCII, a comment of exactly 262,144 bytes is posted byte for byte" {
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - 1))
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(_commands)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$(cat "${BATS_TEST_TMPDIR}/body.md")")"
	assert_equal "$(_bytes "$GH_BODY")" "$LIMIT"
	run grep -c '^POST /repos/lgtm-hq/consumer/issues/42/comments json$' "$GH_CALLS"
	assert_output "1"
}

@test "size: ASCII, a comment of 262,145 bytes is replaced by the notice and the step fails" {
	local head="### Status: PASSED "
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - ${#head})) r "$head"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 262,145 bytes"
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	refute grep -q "rrrr" "$GH_BODY"
}

@test "size: two-byte characters, 262,144 bytes are posted and 262,146 are replaced" {
	# 1 ASCII byte + 131,057 two-byte characters = 262,115 bytes, plus the
	# marker line: 262,144 bytes.
	_write "${BATS_TEST_TMPDIR}/body.md" 131057 é x
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_equal "$(_bytes "$GH_BODY")" "$LIMIT"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$(cat "${BATS_TEST_TMPDIR}/body.md")")"

	rm -f "$GH_BODY"
	_write "${BATS_TEST_TMPDIR}/body.md" 131058 é x
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	_assert_notice "is 262,146 bytes"
}

@test "size: four-byte characters, 262,144 bytes are posted and 262,148 are replaced" {
	# 3 ASCII bytes + 65,528 four-byte characters = 262,115 bytes.
	_write "${BATS_TEST_TMPDIR}/body.md" 65528 😀 xyz
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_equal "$(_bytes "$GH_BODY")" "$LIMIT"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$(cat "${BATS_TEST_TMPDIR}/body.md")")"

	rm -f "$GH_BODY"
	_write "${BATS_TEST_TMPDIR}/body.md" 65529 😀 xyz
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	_assert_notice "is 262,148 bytes"
}

@test "size: 65,537 ASCII characters, over the old character threshold, are posted unchanged" {
	local body
	body="### ❌ FAILED $(_pad 65537)"
	_post "$body"

	assert_success
	assert_equal "$(_commands)" "0"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
}

@test "size: a body up to 65,536 bytes goes as a -f field exactly as before; a larger one as JSON" {
	_post "$(_pad $((65536 - ${#MARKER_LINE} - 1)))"
	assert_success
	run grep -c '^POST .* field$' "$GH_CALLS"
	assert_output "1"

	: >"$GH_CALLS"
	_post "$(_pad $((65536 - ${#MARKER_LINE})))"
	assert_success
	run grep -c '^POST .* json$' "$GH_CALLS"
	assert_output "1"
	assert_equal "$(_bytes "$GH_BODY")" "65537"
}

@test "size: invalid UTF-8 that jq encodes longer than its bytes is measured as sent and replaced" {
	# 100,000 stray continuation bytes: 100,000 bytes on disk, each one
	# U+FFFD (3 bytes) once encoded. Sent as it is, GitHub would get 300,000.
	_write "${BATS_TEST_TMPDIR}/body.md" 100000 '\x80'
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 300,029 bytes"
}

@test "size: invalid UTF-8 within the limit once encoded is posted as encoded" {
	# 30,000 truncated four-byte sequences (F0 9F 98), 90,000 bytes: jq
	# replaces the invalid sequences with U+FFFD; what it encodes is what is
	# measured and sent, within the limit.
	_write "${BATS_TEST_TMPDIR}/body.md" 30000 '\xf0\x9f\x98'
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(_commands)" "0"
	run grep -c '^POST .* json$' "$GH_CALLS"
	assert_output "1"
	run jq -nj --rawfile b "${BATS_TEST_TMPDIR}/body.md" '$b | utf8bytelength'
	assert_equal "$(_bytes "$GH_BODY")" "$((output + ${#MARKER_LINE} + 1))"
	_assert_all_sent_fit
}

@test "size: a small invalid UTF-8 body still goes to gh as a field, as on main" {
	local body
	body="$(printf 'abc\x80\xf0\x80\x80\x80def')"
	_post "$body"

	assert_success
	run grep -c '^POST .* field$' "$GH_CALLS"
	assert_output "1"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
}

# =============================================================================
# Files near the limit (#1716)
# =============================================================================

@test "file: a CRLF file over the limit that normalises under it is posted, as before" {
	# 270,000 bytes of CRLF lines become 225,000 bytes of LF lines. As on
	# main, the one trailing LF is stripped first, so the last CR becomes
	# the final LF.
	_write "${BATS_TEST_TMPDIR}/body.md" 45000 $'line\r\n'
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(_commands)" "0"
	{
		printf '%s\n' "$MARKER_LINE"
		python3 -c 'import sys; sys.stdout.write("line\n" * 45000)'
	} >"${BATS_TEST_TMPDIR}/expected-body"
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected-body"
	assert_success
}

@test "file: 300 KiB overwrites the stale comment with the notice and fails the step" {
	_stale_passed
	_write "${BATS_TEST_TMPDIR}/body.md" 307200 r "### ✅ PASSED "
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is $(_fmt "$(($(_bytes "${BATS_TEST_TMPDIR}/body.md") + ${#MARKER_LINE} + 1))") bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 field$' "$GH_CALLS"
	assert_output "1"
	grep -q 'action-taken=updated' "$GITHUB_OUTPUT"
	grep -q 'comment-id=7' "$GITHUB_OUTPUT"
}

# =============================================================================
# One message when the body is replaced
# =============================================================================

@test "notice: comment-fields with a report over the limit log one thing once" {
	# The report alone is one byte over: the fields are not rendered, so
	# neither their note nor their warning appears; one ::error in all.
	local head="## Report "
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - ${#head})) r "$head"
	COMMENT_FIELDS="Env: staging" _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 262,145 bytes"
	_refute_fields_messages
}

@test "notice: comment-fields over a body that only grows past the limit when encoded log one thing" {
	# 100,000 stray continuation bytes fit as bytes, so the fields are
	# rendered; jq's encoding then passes the limit. Their messages are held
	# and dropped with the body.
	_write "${BATS_TEST_TMPDIR}/body.md" 100000 '\x80'
	COMMENT_FIELDS="Env: staging" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post"
	_refute_fields_messages
	_assert_all_sent_fit
}
