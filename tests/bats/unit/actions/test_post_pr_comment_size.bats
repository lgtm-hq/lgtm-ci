#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for the comment size limit (#1705) and the body file the post
# step reads itself (#1716) in scripts/ci/actions/post-pr-comment.sh, and for
# the byte ceiling of scripts/ci/actions/post-pr-comment-history.sh

load "../../../helpers/common"

POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
HELPER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment-history.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'
RUN_URL_200='https://github.com/lgtm-hq/consumer/actions/runs/200'
# GitHub's limit on a comment body, in bytes.
LIMIT=262144

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
	unset COMMENT_FIELDS HISTORY HISTORY_SUMMARY HISTORY_FIELDS HISTORY_MAX_BYTES BODY_FILE

	# gh stub. The viewer is github-actions[bot]; the listing prints
	# $GH_LIST_JSON; DELETE succeeds. POST/PATCH write the body they were
	# given to $GH_BODY and keep a copy of each in $GH_SENT: from `-f body=`
	# (logged as "field") or from the JSON file of `--input` (logged as
	# "json"). With $GH_WRITE_FAIL set a write answers HTTP 422.
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
if [[ "$1 $2" == "api graphql" ]]; then
	printf 'graphql\n' >>"$GH_CALLS"
	printf '{"data":{"viewer":{"login":"github-actions[bot]","databaseId":41898282}}}\n'
	exit 0
fi
args=("$@")
method=GET path="" transport=""
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	-X) method="${args[i + 1]}" ;;
	/repos/*) path="${args[i]}" ;;
	--input)
		transport=json
		jq -j '.body' "${args[i + 1]}" >"$GH_BODY"
		;;
	-f)
		if [[ "${args[i + 1]}" == body=* ]]; then
			transport=field
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
		fi
		;;
	esac
done
printf '%s %s %s\n' "$method" "$path" "$transport" >>"$GH_CALLS"
case "$method" in
DELETE) exit 0 ;;
POST | PATCH)
	n=0
	while [[ -e "${GH_SENT}/${n}" ]]; do n=$((n + 1)); done
	cp "$GH_BODY" "${GH_SENT}/${n}"
	if [[ -n "${GH_WRITE_FAIL:-}" ]]; then
		echo "gh: Validation Failed (HTTP 422)" >&2
		exit 1
	fi
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

# _post BODY [HISTORY]: post BODY given as the body input.
_post() {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="$1" \
		HISTORY="${2:-false}" \
		bash "$POSTER"
}

# _post_file PATH [HISTORY]: post the file at PATH, read by the script.
_post_file() {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FILE="$1" \
		HISTORY="${2:-false}" \
		bash "$POSTER"
}

# _comment <id> <body>: one listing element written by github-actions[bot].
_comment() {
	jq -cn --argjson id "$1" --arg body "$2" \
		'{id: $id, user: {login: "github-actions[bot]", id: 41898282, type: "Bot"}, body: $body}'
}

# _write FILE COUNT [TEXT] [HEAD]: write HEAD, then COUNT copies of TEXT
# (default r) to FILE, with no trailing newline. TEXT may hold \x escapes.
_write() {
	python3 -c '
import sys
text = sys.argv[3].encode("utf-8").decode("unicode_escape").encode("latin-1") if "\\x" in sys.argv[3] else sys.argv[3].encode("utf-8")
with open(sys.argv[1], "wb") as out:
    out.write(sys.argv[4].encode("utf-8"))
    out.write(text * int(sys.argv[2]))
' "$1" "$2" "${3:-r}" "${4:-}"
}

# _pad COUNT [TEXT]: COUNT copies of TEXT (default r) on stdout.
_pad() {
	python3 -c 'import sys; sys.stdout.write(sys.argv[2] * int(sys.argv[1]))' "$1" "${2:-r}"
}

# _fmt N: N with thousands separators.
_fmt() {
	python3 -c 'import sys; print(f"{int(sys.argv[1]):,}")' "$1"
}

_bytes() {
	wc -c <"$1" | tr -d '[:space:]'
}

# Every body the API received is within GitHub's limit.
_assert_all_sent_fit() {
	local f
	for f in "$GH_SENT"/*; do
		[[ -e "$f" ]] || continue
		assert [ "$(_bytes "$f")" -le "$LIMIT" ]
	done
}

# Workflow command lines (::warning and ::error) in $output.
_commands() {
	grep -cE '^::(warning|error)' <<<"$output" || true
}

# The stamp line the composer writes for run 200 in these tests.
_stamp_200() {
	printf '<!-- lgtm-ci:history:latest sha=%s run=200 attempt=1 number=2 at=%s -->' \
		"$EVENT_PULL_REQUEST_HEAD_SHA" "$HISTORY_NOW"
}

# Assert that $GH_BODY is the notice for run 200 and that the step failed
# with one ::error after posting it. Usage: _assert_notice SIZE_TEXT
_assert_notice() {
	local out="$output"
	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary for this run $1. A notice with no result was posted in its place (comment 7)"
	run head -n 1 "$GH_BODY"
	assert_output "$MARKER_LINE"
	run cat "$GH_BODY"
	assert_output --partial "### ⚠️ Summary too long to post"
	assert_output --partial "> GitHub accepts at most 262,144 bytes in one comment."
	assert_output --partial "> The summary for this run (commit \`abcdef1\`) $1, so it is not shown."
	assert_output --partial "> **No result is shown for this run**, and no earlier result applies to it: see the [workflow run](${RUN_URL_200}) for the outcome."
	# Above the archive (if any) no result shows.
	run sed -n '1,/^---$/p' "$GH_BODY"
	refute_output --partial "PASSED"
	refute_output --partial "passed"
	output="$out"
	_assert_all_sent_fit
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
# The body file is read by the script (#1716)
# =============================================================================

@test "file: 300 KiB overwrites the stale comment with the notice and fails the step" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 307200 r "### ✅ PASSED "
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 field$' "$GH_CALLS"
	assert_output "1"
	grep -q 'action-taken=updated' "$GITHUB_OUTPUT"
	grep -q 'comment-id=7' "$GITHUB_OUTPUT"
}

@test "file: several MiB are never read in full and take the notice" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")")]"
	_write "${BATS_TEST_TMPDIR}/body.md" $((6 * 1024 * 1024))
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 6,291,456 bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
}

@test "file: a file just under the limit is posted unchanged" {
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - 2))
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(_bytes "$GH_BODY")" "$((LIMIT - 1))"
}

@test "file: the body is the file less one trailing newline, as the read-file step delivered it" {
	printf '## Report

line

' >"${BATS_TEST_TMPDIR}/body.md"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(od -c "$GH_BODY")" "$(printf '%s
%s' "$MARKER_LINE" $'## Report

line
' | od -c)"
}

@test "file: the file takes precedence over the body input" {
	printf 'from the file\n' >"${BATS_TEST_TMPDIR}/body.md"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=lgtm-hq/consumer \
		BODY_FILE="${BATS_TEST_TMPDIR}/body.md" BODY_FROM_INPUT="from the input" bash "$POSTER"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "from the file")"
}

@test "file: a missing file or a directory warns and skips, as before" {
	local path
	for path in "${BATS_TEST_TMPDIR}/missing.md" "$BATS_TEST_TMPDIR"; do
		: >"$GITHUB_OUTPUT"
		_post_file "$path"
		assert_success
		assert_output --partial "::warning::Comment file not found: ${path}"
		assert_output --partial "Skipped: empty body"
		grep -q 'action-taken=skipped' "$GITHUB_OUTPUT"
	done
	assert [ ! -e "$GH_BODY" ]
}

@test "file: a missing file with delete-on-empty deletes the comment, as before" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")")]"
	DELETE_ON_EMPTY=true _post_file "${BATS_TEST_TMPDIR}/missing.md"

	assert_success
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
	run grep -c '^DELETE /repos/lgtm-hq/consumer/issues/comments/7 $' "$GH_CALLS"
	assert_output "1"
}

@test "file: an oversized file never counts as empty, even with delete-on-empty" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	DELETE_ON_EMPTY=true _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 300,000 bytes"
	run grep -c '^DELETE ' "$GH_CALLS"
	assert_output "0"
}

@test "file: a symlink to a regular file is followed, as the read-file step did" {
	printf 'linked\n' >"${BATS_TEST_TMPDIR}/target.md"
	ln -s "${BATS_TEST_TMPDIR}/target.md" "${BATS_TEST_TMPDIR}/link.md"
	_post_file "${BATS_TEST_TMPDIR}/link.md"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "linked")"
}

@test "file: a read that fails fails the step and posts nothing" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\necho "head: read error" >&2\nexit 1\n' >"${bin}/head"
	chmod +x "${bin}/head"
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	PATH="${bin}:${PATH}" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_output --partial "::error::Cannot read comment file: ${BATS_TEST_TMPDIR}/body.md"
	assert [ ! -e "$GH_BODY" ]
}

# =============================================================================
# After the notice the step fails; paths that write nothing skip (#1705)
# =============================================================================

@test "fail: when posting the notice fails, the error says so and no notice is claimed" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	GH_WRITE_FAIL=1 _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary for this run is 300,000 bytes. Posting the notice that replaces it failed too (the API call failed); the previous comment is unchanged."
	refute_output --partial "was posted in its place"
	_assert_all_sent_fit
}

@test "fail: when not even the notice can be measured, nothing is posted" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${bin}/wc"
	chmod +x "${bin}/wc"
	PATH="${bin}:${PATH}" _post "### ✅ PASSED"

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary for this run could not be measured. The notice that would replace it cannot be measured within the limit either, so nothing was posted and the previous comment is unchanged."
	run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
	assert_output "0"
}

@test "fail: a body that cannot be measured is replaced, not sent" {
	local bin="${BATS_TEST_TMPDIR}/stub" real_jq
	real_jq="$(command -v jq)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\n[[ " $* " == *utf8bytelength* ]] && exit 3\nexec "%s" "$@"\n' "$real_jq" >"${bin}/jq"
	chmod +x "${bin}/jq"
	PATH="${bin}:${PATH}" _post "### ✅ PASSED $(_pad 70000)"

	_assert_notice "could not be measured"
}

@test "skip: update mode without a comment, an unknown mode and a fork post nothing and do not fail" {
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	MODE=update _post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_output --partial "Skipped: no existing comment to update"
	assert_equal "$(_commands)" "0"

	MODE=sideways _post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_equal "$(_commands)" "0"

	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=fork/consumer \
		BODY_FILE="${BATS_TEST_TMPDIR}/body.md" bash "$POSTER"
	assert_success
	assert_output --partial "Skipped: fork PR cannot receive workflow comments"
	assert [ ! -e "$GH_BODY" ]
}

@test "notice: the next normal run updates the same comment" {
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_failure

	export GH_LIST_JSON="[$(_comment 7 "$(cat "$GH_BODY")")]"
	: >"$GH_CALLS"
	_post "### ❌ FAILED"
	assert_success
	assert_equal "$(_commands)" "0"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 field$' "$GH_CALLS"
	assert_output "1"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
}

@test "notice: the reserved namespace and comment-fields of an oversized body never reach it" {
	_write "${BATS_TEST_TMPDIR}/body.md" 300000 r $'<!-- lgtm-ci:other -->\n<!-- lgtm-ci:history:latest sha=x run=999 attempt=1 number=9 at=y -->\n'
	COMMENT_FIELDS="Status: PASSED" _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c 'lgtm-ci:' "$GH_BODY"
	assert_output "1"
	refute_output --partial "comment-fields"
}

@test "notice: comment-fields with a report over the limit log one thing once" {
	# The report alone is one byte over: the fields are not rendered, so
	# neither their note nor their warning appears; one ::error in all.
	local head="## Report "
	_write "${BATS_TEST_TMPDIR}/body.md" $((LIMIT - ${#MARKER_LINE} - ${#head})) r "$head"
	COMMENT_FIELDS="Env: staging" _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 262,145 bytes"
	refute_output --partial "comment-fields"
}

@test "notice: without a run id or a commit id it points at the pull request's checks" {
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	GITHUB_RUN_ID="" EVENT_PULL_REQUEST_HEAD_SHA="not-a-sha" GITHUB_SHA="" \
		_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	run cat "$GH_BODY"
	assert_output --partial "> The summary for this run is 300,000 bytes, so it is not shown."
	assert_output --partial "see this pull request's checks for the outcome."
	refute_output --partial "](http"
}

# =============================================================================
# History: archive first, then the result (#1705)
# =============================================================================

# An existing history comment for run 100 that said PASSED, with a summary,
# and a body of BYTES (default: a short line).
_passed_history_comment() {
	local summary
	summary="$(printf '%s' 'all 42 passed' | base64)"
	printf '%s\n%s\n%s%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=1111111111111111111111111111111111111111 run=100 attempt=1 number=1 at=2026-11-19T12:00:00Z summary=${summary} -->" \
		"### ✅ PASSED (run 100)" "$(_pad "${1:-0}" p)"
}

@test "history: an oversized report with no earlier comment gets marker, stamp and notice" {
	_write "${BATS_TEST_TMPDIR}/body.md" 300000 r "### ✅ PASSED "
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
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment 50000)")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 300000 r "### ✅ PASSED (run 200) "
	HISTORY_SUMMARY="all 42 passed" COMMENT_FIELDS="Status: PASSED" \
		_post_file "${BATS_TEST_TMPDIR}/body.md" true

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_line --index 1 "$(_stamp_200)"
	assert_line --index 2 "### ⚠️ Summary too long to post"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	local latest
	latest="$(sed -n '1,/^---$/p' "$GH_BODY")"
	[[ "$latest" != *PASSED* && "$latest" != *passed* ]]
}

@test "history: the next normal run updates the notice comment and archives it" {
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment)")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	_post_file "${BATS_TEST_TMPDIR}/body.md" true
	assert_failure

	export GH_LIST_JSON="[$(_comment 7 "$(cat "$GH_BODY")")]"
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
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment 200000)")]"
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
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment 64000)")]"
	HISTORY_MAX_BYTES=1000000 _post "### ❌ FAILED $(_pad 2000 f)" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=1111111111111111111111111111111111111111 run=100 "
	refute_output --partial "Summary too long"
}

@test "history: invalid UTF-8 that only fits without the archive drops the archive, not the result" {
	# The composer counts 100,000 + 120,000 bytes and keeps the archive; jq
	# encodes the 40,000 stray bytes as 120,000, so the whole is over the
	# limit. The poster drops the archive and posts the report.
	export GH_LIST_JSON="[$(_comment 7 "$(_passed_history_comment 120000)")]"
	_write "${BATS_TEST_TMPDIR}/body.md" 40000 '\x80' "### ❌ FAILED $(_pad 60000 f)"
	HISTORY_MAX_BYTES=262144 _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_success
	assert_equal "$(_commands)" "0"
	run cat "$GH_BODY"
	assert_line --index 2 --partial "### ❌ FAILED fff"
	refute_output --partial "lgtm-ci:history:entry"
	refute_output --partial "Summary too long"
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
# Composer: GitHub's limit is a ceiling on the byte budget
# =============================================================================

# _compose EXISTING_FILE NEW_BODY [ENV...]: run the composer for run 200.
_compose() {
	local existing="$1" body="$2"
	shift 2
	printf '%s\n' "$body" >"${BATS_TEST_TMPDIR}/new.md"
	run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		HEAD_SHA=abcdef1 RUN_ID=200 RUN_ATTEMPT=1 RUN_NUMBER=2 RUN_URL="$RUN_URL_200" \
		"$@" bash "$HELPER" <"$existing"
}

# _archive FILE N BYTES: an existing comment whose archive holds runs 1..N
# (newest last) and whose latest is run N+1, each body BYTES long.
_archive() {
	local file="$1" n="$2" bytes="$3" i blocks=""
	for ((i = n; i >= 1; i--)); do
		blocks+="<!-- lgtm-ci:history:entry sha=s${i} run=${i} attempt=1 number=${i} at=t -->"$'\n'
		blocks+="<details><summary>Run #${i}</summary>"$'\n\n'"run ${i} $(_pad "$bytes" a)"$'\n\n'"</details>"$'\n'
	done
	printf '%s\n%s\n%s\n\n---\n\n%s\n\n%s\n%s%s\n' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=s$((n + 1)) run=$((n + 1)) attempt=1 number=$((n + 1)) at=t -->" \
		"latest $((n + 1))" "<details><summary>🕘 Previous runs (${n})</summary>" \
		"<!-- lgtm-ci:history:start -->" "$blocks" "<!-- lgtm-ci:history:end -->" >"$file"
	printf '\n</details>\n' >>"$file"
}

@test "post-pr-comment-history: entries are trimmed oldest first at GitHub's limit, whatever the budget" {
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=1000000 HISTORY_LIMIT=0

	assert_success
	assert [ "$(printf '%s' "$output" | wc -c)" -le "$LIMIT" ]
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s2 run=2 "
	refute_output --partial "run=1 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: the archive goes entirely when only its note would pass the limit" {
	local body
	_archive "${BATS_TEST_TMPDIR}/existing.md" 1 100
	# marker + stamp + body = 262,100 bytes: fits; the note would not.
	body="$(_pad 262000)"
	_compose "${BATS_TEST_TMPDIR}/existing.md" "$body" HISTORY_MAX_BYTES=1000000

	assert_success
	assert [ "$(printf '%s' "$output" | wc -c)" -le "$LIMIT" ]
	refute_output --partial "Previous runs"
	refute_output --partial "older runs not listed"
	assert_line --index 2 "$body"
}

@test "post-pr-comment-history: an overflowing HISTORY_MAX_BYTES is held to the limit" {
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 100000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200" HISTORY_MAX_BYTES=99999999999999999999999 HISTORY_LIMIT=0

	assert_success
	assert [ "$(printf '%s' "$output" | wc -c)" -le "$LIMIT" ]
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}

@test "post-pr-comment-history: the default budget is unchanged" {
	# history-limit 3 keeps runs 4, 3 and 2; run 2 does not fit 60,000 bytes.
	_archive "${BATS_TEST_TMPDIR}/existing.md" 3 30000
	_compose "${BATS_TEST_TMPDIR}/existing.md" "body 200"

	assert_success
	assert [ "$(printf '%s' "$output" | wc -c)" -le 60000 ]
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s4 run=4 "
	assert_output --partial "<!-- lgtm-ci:history:entry sha=s3 run=3 "
	refute_output --partial "run=2 "
	assert_output --partial "> ✂️ 1 older runs not listed (size limit)"
}
