#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for the run history of post-pr-comment (#1346):
# scripts/ci/actions/post-pr-comment-history.sh (pure composer) and the
# HISTORY=true path of scripts/ci/actions/post-pr-comment.sh

load "../../../helpers/common"

HELPER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment-history.sh"
POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'

setup() {
	setup_temp_dir
	export MARKER_TAG="$MARKER_LINE"
	export RUN_URL="https://github.com/lgtm-hq/consumer/actions/runs/200"
	export HISTORY_LIMIT=3
	export HISTORY_NOW="2026-11-05T12:00:00Z"
	unset HISTORY_SUMMARY HISTORY_MAX_BYTES
	export EXISTING="${BATS_TEST_TMPDIR}/existing.md"
	: >"$EXISTING"
	export NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md"
}

teardown() {
	teardown_temp_dir
}

# _compose <run-id> <attempt> <sha> <body> [stdin-file]: compose the next body
# for run <run-id> (run number = run id / 100) over the existing comment.
_compose() {
	printf '%s\n' "$4" >"$NEW_BODY_FILE"
	run env RUN_ID="$1" RUN_ATTEMPT="$2" RUN_NUMBER="$(($1 / 100))" HEAD_SHA="$3" \
		RUN_URL="https://github.com/lgtm-hq/consumer/actions/runs/$1" \
		bash "$HELPER" <"${5:-$EXISTING}"
}

# _advance <run-id> <attempt> <sha> <body>: compose and keep the result as the
# existing comment for the next call.
_advance() {
	_compose "$@"
	assert_success
	printf '%s\n' "$output" >"$EXISTING"
}

_entry_runs() {
	grep -oE '^<!-- lgtm-ci:history:entry sha=[^ ]+ run=[0-9]+' <<<"$1" | sed 's/.*run=//' | paste -sd, -
}

# =============================================================================
# Composer
# =============================================================================

@test "post-pr-comment-history: first run is stamped with no archive" {
	_compose 100 1 aaaaaaaaaaaa "## Test Results"

	assert_success
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 1 "<!-- lgtm-ci:history:latest sha=aaaaaaaaaaaa run=100 attempt=1 number=1 at=2026-11-05T12:00:00Z -->"
	assert_line --index 2 "## Test Results"
	refute_output --partial "Previous runs"
	refute_output --partial "lgtm-ci:history:start"
}

@test "post-pr-comment-history: second run archives the first under its stamp" {
	HISTORY_SUMMARY="1 passed, 0 failed" HISTORY_NOW="2026-11-05T10:00:00Z" \
		_advance 100 1 aaaaaaaaaaaa "first body"

	_compose 200 1 bbbbbbbbbbbb "second body"

	assert_success
	assert_line --index 1 --partial "lgtm-ci:history:latest sha=bbbbbbbbbbbb run=200"
	assert_line --index 2 "second body"
	assert_output --partial "<details><summary>🕘 Previous runs (1)</summary>"
	assert_output --partial "<!-- lgtm-ci:history:entry sha=aaaaaaaaaaaa run=100 attempt=1 number=1 at=2026-11-05T10:00:00Z -->"
	assert_output --partial '<details><summary>Run #1 · aaaaaaa · 2026-11-05T10:00:00Z · <a href="https://github.com/lgtm-hq/consumer/actions/runs/100/attempts/1">workflow run</a> · 1 passed, 0 failed</summary>'
	assert_output --partial "first body"
	# The latest section holds only the new body: the old one sits after start.
	run awk '/lgtm-ci:history:start/{exit} {print}' <<<"$output"
	refute_output --partial "first body"
}

@test "post-pr-comment-history: unstamped pre-history comment is archived as run=0" {
	printf '%s\n%s\n' "$MARKER_LINE" "legacy body" >"$EXISTING"
	_advance 200 1 bbbbbbbbbbbb "new body"
	_compose 300 1 cccccccccccc "newest body"

	assert_success
	assert_output --partial "<!-- lgtm-ci:history:entry sha=unknown run=0 attempt=0 number=0 at=unknown -->"
	assert_output --partial "<details><summary>earlier run (unstamped)</summary>"
	assert_output --partial "legacy body"
	# run=0 sorts last, after the stamped run 200.
	assert_equal "$(_entry_runs "$output")" "200,0"
}

@test "post-pr-comment-history: history-limit keeps the newest runs" {
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 200 1 bbbbbbbbbbbb "body 200"
	_advance 300 1 cccccccccccc "body 300"
	HISTORY_LIMIT=2 _compose 400 1 dddddddddddd "body 400"

	assert_success
	assert_equal "$(_entry_runs "$output")" "300,200"
	assert_output --partial "Previous runs (2)"
	refute_output --partial "body 100"
	# Limit trimming is silent: no size note.
	refute_output --partial "older runs not listed"
}

@test "post-pr-comment-history: history-limit 0 keeps every run" {
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 200 1 bbbbbbbbbbbb "body 200"
	_advance 300 1 cccccccccccc "body 300"
	_advance 400 1 dddddddddddd "body 400"
	HISTORY_LIMIT=0 _compose 500 1 eeeeeeeeeeee "body 500"

	assert_success
	assert_equal "$(_entry_runs "$output")" "400,300,200,100"
}

@test "post-pr-comment-history: size cap drops the oldest runs and notes the count" {
	local filler
	filler="$(printf 'x%.0s' {1..300})"
	_advance 100 1 aaaaaaaaaaaa "body 100 ${filler}"
	_advance 200 1 bbbbbbbbbbbb "body 200 ${filler}"
	_advance 300 1 cccccccccccc "body 300 ${filler}"
	_advance 400 1 dddddddddddd "body 400 ${filler}"
	# Room for the latest section and about two archived entries.
	HISTORY_MAX_BYTES=2000 HISTORY_LIMIT=0 _compose 500 1 eeeeeeeeeeee "body 500 ${filler}"

	assert_success
	# Newest-first prefix kept; the oldest tail (200, 100) is dropped and counted.
	assert_equal "$(_entry_runs "$output")" "400,300"
	refute_output --partial "body 200"
	refute_output --partial "body 100"
	assert_output --partial "> ✂️ 2 older runs not listed (size limit)"
	assert_output --partial "Previous runs (2)"
	run env LC_ALL=C bash -c 'printf "%s" "$1" | wc -c' _ "$output"
	assert [ "${output// /}" -le 2000 ]
}

@test "post-pr-comment-history: size note counts only size-cap drops, not limit trims" {
	local filler
	filler="$(printf 'x%.0s' {1..300})"
	_advance 100 1 aaaaaaaaaaaa "body 100 ${filler}"
	_advance 200 1 bbbbbbbbbbbb "body 200 ${filler}"
	_advance 300 1 cccccccccccc "body 300 ${filler}"
	_advance 400 1 dddddddddddd "body 400 ${filler}"
	# The limit trims run 100; the cap then drops 300 and 200 (k=2, not 3).
	HISTORY_MAX_BYTES=1500 HISTORY_LIMIT=3 _compose 500 1 eeeeeeeeeeee "body 500 ${filler}"

	assert_success
	assert_equal "$(_entry_runs "$output")" "400"
	assert_output --partial "> ✂️ 2 older runs not listed (size limit)"
}

@test "post-pr-comment-history: an entry larger than the budget drops it and every older run" {
	local big
	big="$(printf 'y%.0s' {1..5000})"
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 200 1 bbbbbbbbbbbb "body 200 ${big}"
	_advance 300 1 cccccccccccc "body 300"
	HISTORY_MAX_BYTES=3000 _compose 400 1 dddddddddddd "body 400"

	assert_success
	# The archive stays a contiguous newest-first prefix: run 100 would fit,
	# but it is older than the oversize run 200, so both are dropped.
	assert_equal "$(_entry_runs "$output")" "300"
	refute_output --partial "$big"
	refute_output --partial "body 100"
	assert_output --partial "Previous runs (1)"
	assert_output --partial "> ✂️ 2 older runs not listed (size limit)"
}

@test "post-pr-comment-history: an oversize newest entry leaves only the note" {
	local big
	big="$(printf 'y%.0s' {1..5000})"
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 200 1 bbbbbbbbbbbb "body 200 ${big}"
	HISTORY_MAX_BYTES=3000 _compose 300 1 cccccccccccc "body 300"

	assert_success
	assert_equal "$(_entry_runs "$output")" ""
	refute_output --partial "body 100"
	assert_output --partial "Previous runs (0)"
	assert_output --partial "> ✂️ 2 older runs not listed (size limit)"
}

@test "post-pr-comment-history: the latest section is never cut when it alone exceeds the budget" {
	local big
	big="$(printf 'z%.0s' {1..3000})"
	_advance 100 1 aaaaaaaaaaaa "body 100"
	HISTORY_MAX_BYTES=1000 _compose 200 1 bbbbbbbbbbbb "body 200 ${big}"

	assert_success
	assert_output --partial "body 200 ${big}"
	refute_output --partial "lgtm-ci:history:entry"
}

@test "post-pr-comment-history: a re-run replaces its earlier entry by run id" {
	_advance 100 1 aaaaaaaaaaaa "body 100 attempt 1"
	_advance 200 1 bbbbbbbbbbbb "body 200"
	# Run 100 is re-run after 200 posted: attempt 2 replaces attempt 1.
	_compose 100 2 aaaaaaaaaaaa "body 100 attempt 2"

	assert_success
	assert_line --index 1 --partial "run=200 attempt=1"
	assert_equal "$(_entry_runs "$output")" "100"
	assert_output --partial "run=100 attempt=2"
	assert_output --partial "body 100 attempt 2"
	refute_output --partial "body 100 attempt 1"
}

@test "post-pr-comment-history: a re-run of the latest run replaces it without archiving" {
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 200 1 bbbbbbbbbbbb "body 200 attempt 1"
	_compose 200 2 bbbbbbbbbbbb "body 200 attempt 2"

	assert_success
	assert_line --index 1 --partial "run=200 attempt=2"
	assert_equal "$(_entry_runs "$output")" "100"
	refute_output --partial "body 200 attempt 1"
}

@test "post-pr-comment-history: an older run finishing last is archived, not promoted" {
	_advance 100 1 aaaaaaaaaaaa "body 100"
	_advance 300 1 cccccccccccc "body 300"
	_compose 200 1 bbbbbbbbbbbb "body 200"

	assert_success
	assert_line --index 1 --partial "run=300 attempt=1"
	assert_line --index 2 "body 300"
	assert_equal "$(_entry_runs "$output")" "200,100"
	assert_output --partial "body 200"
}

@test "post-pr-comment-history: neutralises only the history sentinels in the body" {
	local hostile
	hostile="$(
		printf '%s\n' \
			"<!-- lgtm-ci:history:latest sha=evil run=999999 attempt=1 number=1 at=x -->" \
			"<!-- lgtm-ci:history:start -->" \
			"<!-- lgtm-ci:history:entry sha=evil run=999998 attempt=1 number=1 at=x -->" \
			"<!-- lgtm-ci:history:end -->" \
			"<!-- lgtm-ci:validation -->" \
			"<!-- lgtm-ci:other-marker -->"
	)"
	_advance 100 1 aaaaaaaaaaaa "$hostile"

	assert_line --index 1 --partial "run=100 attempt=1"
	run grep -c '^<!-- lgtm-ci:history:' "$EXISTING"
	assert_output "1"
	run cat "$EXISTING"
	assert_output --partial "< !-- lgtm-ci:history:entry sha=evil"
	assert_output --partial "<!-- lgtm-ci:validation -->"
	assert_output --partial "<!-- lgtm-ci:other-marker -->"

	# Archived next run: still exactly one real entry, the forged ones inert.
	_compose 200 1 bbbbbbbbbbbb "body 200"
	assert_success
	assert_equal "$(_entry_runs "$output")" "100"
	assert_output --partial "<!-- lgtm-ci:validation -->"
}

@test "post-pr-comment-history: history-summary is escaped and carried into the archive" {
	HISTORY_SUMMARY=$'2 passed <b>&\n1 failed' _advance 100 1 aaaaaaaaaaaa "body 100"
	_compose 200 1 bbbbbbbbbbbb "body 200"

	assert_success
	assert_output --partial "· 2 passed &lt;b&gt;&amp; 1 failed</summary>"
}

@test "post-pr-comment-history: archived bodies keep their own <details> blocks" {
	_advance 100 1 aaaaaaaaaaaa "$(printf '%s\n' '## Coverage' '<details><summary>Files</summary>' '' '| a | b |' '' '</details>')"
	_advance 200 1 bbbbbbbbbbbb "body 200"
	_compose 300 1 cccccccccccc "body 300"

	assert_success
	assert_equal "$(_entry_runs "$output")" "200,100"
	assert_output --partial "<details><summary>Files</summary>"
}

@test "post-pr-comment-history: rejects a non-numeric history-limit" {
	HISTORY_LIMIT=three _compose 100 1 aaaaaaaaaaaa "body"

	assert_failure
	assert_output --partial "HISTORY_LIMIT must be a non-negative integer"
}

# =============================================================================
# post-pr-comment.sh with HISTORY=true (gh stubbed)
# =============================================================================

_setup_gh_stub() {
	export GH_TOKEN="test-token"
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export PR_NUMBER="42"
	export MARKER="test-marker"
	export MODE="upsert"
	export DELETE_ON_EMPTY="false"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	export GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_NUMBER=2
	export GITHUB_SHA=mergesha00000 EVENT_PULL_REQUEST_HEAD_SHA=headsha111111
	export GITHUB_SERVER_URL="https://github.com"

	# gh stub. Every call's argv goes to $GH_CALLS, one line per call.
	#   listing (--paginate): prints each line of $GH_PAGES_FILE (one JSON
	#     array per page), or $GH_LIST_JSON; exits $GH_LIST_EXIT
	#   listing (no --paginate): prints $GH_LIST_JSON
	#   -X DELETE: comment ids in $GH_DELETE_403 answer HTTP 403
	#   -X POST / -X PATCH: writes the body= field to $GH_BODY and prints
	#     {"id": 99, "html_url": ...}
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export GH_BODY="${BATS_TEST_TMPDIR}/gh_body"
	: >"$GH_CALLS"
	rm -f "$GH_BODY"
	export GH_LIST_JSON='[]'
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
args=("$@")
method=GET
for ((i = 0; i < ${#args[@]}; i++)); do
	[[ "${args[i]}" == "-X" ]] && method="${args[i + 1]}"
done
case "$method" in
DELETE)
	id="${!#}"
	id="${id##*/}"
	if [[ " ${GH_DELETE_403:-} " == *" $id "* ]]; then
		echo "gh: Resource not accessible by integration (HTTP 403)" >&2
		exit 1
	fi
	exit 0
	;;
POST | PATCH)
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "-f" && "${args[i + 1]}" == body=* ]]; then
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
		fi
	done
	printf '{"id": 99, "html_url": "https://github.com/c/99"}\n'
	exit 0
	;;
esac
if [[ " $* " == *" --paginate "* && -n "${GH_PAGES_FILE:-}" ]]; then
	cat "$GH_PAGES_FILE"
else
	printf '%s\n' "$GH_LIST_JSON"
fi
exit "${GH_LIST_EXIT:-0}"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

_post() { # body [HISTORY]
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="$1" \
		HISTORY="${2:-true}" \
		bash "$POSTER"
}

# _comment <id> <body>: one listing element as JSON.
_comment() {
	jq -cn --argjson id "$1" --arg body "$2" '{id: $id, body: $body}'
}

@test "post-pr-comment: history POST stamps the new comment" {
	_setup_gh_stub

	_post "first result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run cat "$GH_BODY"
	assert_line --index 0 "$MARKER_LINE"
	assert_line --index 1 --regexp '^<!-- lgtm-ci:history:latest sha=headsha111111 run=200 attempt=1 number=2 at=[0-9T:Z-]+ -->$'
	assert_line --index 2 "first result"
}

@test "post-pr-comment: history lists every page with per_page=100" {
	_setup_gh_stub
	export GH_PAGES_FILE="${BATS_TEST_TMPDIR}/pages"
	{
		printf '[%s]\n' "$(_comment 1 'unrelated')"
		printf '[%s]\n' "$(_comment 7 "$(printf '%s\n%s' "$MARKER_LINE" 'old result on page two')")"
	} >"$GH_PAGES_FILE"

	_post "new result"

	assert_success
	grep -q 'action-taken=updated' "$GITHUB_OUTPUT"
	run grep -c -- '--paginate .*/repos/lgtm-hq/consumer/issues/42/comments?per_page=100' "$GH_CALLS"
	assert_output "1"
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_output --partial "earlier run (unstamped)"
	assert_output --partial "old result on page two"
}

@test "post-pr-comment: history fails closed when the listing fails" {
	_setup_gh_stub
	export GH_LIST_JSON=""
	export GH_LIST_EXIT=1

	_post "new result"

	assert_failure
	assert_output --partial "Could not list comments"
	run grep -cE -- '-X (POST|PATCH)' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: duplicate marker comments keep the stamped survivor" {
	_setup_gh_stub
	local stamped
	stamped="$(printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=oldsha run=100 attempt=1 number=1 at=2026-11-04T00:00:00Z -->" \
		"stamped result")"
	export GH_LIST_JSON="[$(_comment 5 "$(printf '%s\nunstamped dup' "$MARKER_LINE")"),$(_comment 6 "$stamped"),$(_comment 8 "$(printf '%s\nnewest unstamped dup' "$MARKER_LINE")")]"
	export GH_DELETE_403="8"

	_post "new result"

	assert_success
	assert_output --partial "Deleted duplicate comment 5"
	assert_output --partial "::warning::Could not delete duplicate comment 8"
	run grep -c -- '-X PATCH .*/issues/comments/6' "$GH_CALLS"
	assert_output "1"
	run cat "$GH_BODY"
	assert_output --partial "run=100 attempt=1 number=1 at=2026-11-04T00:00:00Z -->"
	assert_output --partial "stamped result"
	refute_output --partial "unstamped dup"
}

@test "post-pr-comment: duplicate marker comments without a stamp keep the newest" {
	_setup_gh_stub
	export GH_LIST_JSON="[$(_comment 5 "$(printf '%s\nolder' "$MARKER_LINE")"),$(_comment 9 "$(printf '%s\nnewer' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	assert_output --partial "Deleted duplicate comment 5"
	run grep -c -- '-X PATCH .*/issues/comments/9' "$GH_CALLS"
	assert_output "1"
}

@test "post-pr-comment: delete-on-empty removes the comment and its archive" {
	_setup_gh_stub
	export DELETE_ON_EMPTY="true"
	local archived
	archived="$(printf '%s\n%s\n%s\n\n---\n\n%s\n\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=s run=200 attempt=1 number=2 at=t -->" "latest" \
		"<details><summary>🕘 Previous runs (1)</summary>" \
		"<!-- lgtm-ci:history:start -->" "<!-- lgtm-ci:history:end -->")"
	export GH_LIST_JSON="[$(_comment 7 "$archived")]"

	_post ""

	assert_success
	assert_output --partial "Deleted comment 7"
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
	run grep -cE -- '-X (POST|PATCH)' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: update mode without a comment still skips under history" {
	_setup_gh_stub
	export MODE="update"

	_post "new result"

	assert_success
	assert_output --partial "Skipped: no existing comment to update"
	run grep -cE -- '-X (POST|PATCH)' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: HISTORY=false is unchanged byte for byte" {
	_setup_gh_stub
	local archived
	archived="$(printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=s run=100 attempt=1 number=1 at=t -->" "old")"
	export GH_LIST_JSON="[$(_comment 7 "$archived")]"

	_post "new result" false

	assert_success
	grep -q 'action-taken=updated' "$GITHUB_OUTPUT"
	# Same first-page listing as before history existed, then one PATCH.
	run cat "$GH_CALLS"
	assert_line --index 0 "api -H Accept: application/vnd.github+json /repos/lgtm-hq/consumer/issues/42/comments"
	assert_line --index 1 --partial "api -X PATCH -H Accept: application/vnd.github+json /repos/lgtm-hq/consumer/issues/comments/7 -f body="
	run grep -c '^api ' "$GH_CALLS"
	assert_output "2"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "new result")"
}
