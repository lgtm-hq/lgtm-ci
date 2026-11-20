#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for comment ownership, leading-marker matching, the reserved
# lgtm-ci namespace (#1674) and the read-file output delimiter (#1675) in
# scripts/ci/actions/post-pr-comment.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'
ME='github-actions[bot]'

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
	unset HISTORY GH_VIEWER_LOGIN GH_VIEWER_ID GH_VIEWER_FAIL GH_VIEWER_ERR GH_VIEWER_JSON \
		GH_PAGES_FILE GH_LIST_EXIT

	# gh stub. Every call's argv goes to $GH_CALLS, one line per call.
	#   api graphql: prints the viewer $GH_VIEWER_LOGIN / $GH_VIEWER_ID
	#     (default github-actions[bot] / 41898282), or $GH_VIEWER_JSON as is;
	#     $GH_VIEWER_FAIL makes it print $GH_VIEWER_ERR on stderr and exit 1
	#   listing: prints each line of $GH_PAGES_FILE (one JSON array per page)
	#     or $GH_LIST_JSON; exits $GH_LIST_EXIT
	#   -X DELETE: succeeds
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
if [[ "$1 $2" == "api graphql" ]]; then
	if [[ -n "${GH_VIEWER_FAIL:-}" ]]; then
		printf '%s\n' "${GH_VIEWER_ERR:-}" >&2
		exit 1
	fi
	if [[ -n "${GH_VIEWER_JSON:-}" ]]; then
		printf '%s\n' "$GH_VIEWER_JSON"
		exit 0
	fi
	printf '{"data":{"viewer":{"login":"%s","databaseId":%s}}}\n' "${GH_VIEWER_LOGIN:-github-actions[bot]}" "${GH_VIEWER_ID:-41898282}"
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
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "-f" && "${args[i + 1]}" == body=* ]]; then
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
		fi
	done
	printf '{"id": 99, "html_url": "https://github.com/c/99"}\n'
	exit 0
	;;
esac
if [[ -n "${GH_PAGES_FILE:-}" ]]; then
	cat "$GH_PAGES_FILE"
else
	printf '%s\n' "$GH_LIST_JSON"
fi
exit "${GH_LIST_EXIT:-0}"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

teardown() {
	teardown_temp_dir
}

_post() { # body
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="$1" \
		bash "$POSTER"
}

# REST user ids of the test accounts; github-actions[bot] is the real one.
ACCOUNT_IDS='{"github-actions[bot]": 41898282, "other-app[bot]": 2002, "my-app[bot]": 3003, "someone": 4004}'

# _comment <id> <login> <body>: one listing element as JSON.
_comment() {
	jq -cn --argjson id "$1" --arg login "$2" --arg body "$3" --argjson ids "$ACCOUNT_IDS" \
		'{id: $id, user: {login: $login, id: ($ids[$login] // 1000), type: (if ($login | endswith("[bot]")) then "Bot" else "User" end)}, body: $body}'
}

_writes() {
	grep -cE -- '-X (POST|PATCH|DELETE)' "$GH_CALLS" || true
}

# =============================================================================
# Ownership
# =============================================================================

@test "post-pr-comment: another account's marker comment is never updated" {
	export GH_LIST_JSON="[$(_comment 5 'someone' "$(printf '%s\nforged' "$MARKER_LINE")"),$(_comment 6 'other-app[bot]' "$(printf '%s\nother bot' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run grep -c -- '-X PATCH' "$GH_CALLS"
	assert_output "0"
	run grep -c -- '-X POST .*/issues/42/comments' "$GH_CALLS"
	assert_output "1"
}

@test "post-pr-comment: own marker comment is updated, a foreign one beside it is not" {
	export GH_LIST_JSON="[$(_comment 5 'other-app[bot]' "$(printf '%s\nother bot' "$MARKER_LINE")"),$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
	run grep -c -- 'comments/5' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: delete-on-empty never deletes another account's comment" {
	export DELETE_ON_EMPTY="true"
	export GH_LIST_JSON="[$(_comment 5 'someone' "$(printf '%s\nforged' "$MARKER_LINE")"),$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post ""

	assert_success
	assert_output --partial "Deleted comment 7"
	run grep -c -- '-X DELETE' "$GH_CALLS"
	assert_output "1"
	run grep -c -- '-X DELETE .*/comments/5' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: an App installation token owns only its own bot's comments" {
	export GH_VIEWER_LOGIN='my-app[bot]' GH_VIEWER_ID=3003
	export GH_LIST_JSON="[$(_comment 5 "$ME" "$(printf '%s\nactions bot' "$MARKER_LINE")"),$(_comment 8 'my-app[bot]' "$(printf '%s\napp' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	run grep -c -- '-X PATCH .*/issues/comments/8' "$GH_CALLS"
	assert_output "1"
	run grep -c -- 'comments/5' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: history duplicate cleanup deletes only own comments" {
	export HISTORY=true GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_NUMBER=2
	local stamped
	stamped="$(printf '%s\n%s\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=oldsha run=100 attempt=1 number=1 at=2026-11-04T00:00:00Z -->" \
		"stamped result")"
	export GH_LIST_JSON="[$(_comment 5 "$ME" "$(printf '%s\nown dup' "$MARKER_LINE")"),$(_comment 6 "$ME" "$stamped"),$(_comment 7 'someone' "$stamped"),$(_comment 8 'other-app[bot]' "$(printf '%s\nforeign dup' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	run grep -c -- '-X PATCH .*/issues/comments/6' "$GH_CALLS"
	assert_output "1"
	run grep -c -- '-X DELETE' "$GH_CALLS"
	assert_output "1"
	run grep -c -- '-X DELETE .*/comments/5' "$GH_CALLS"
	assert_output "1"
}

# =============================================================================
# Leading marker
# =============================================================================

@test "post-pr-comment: a marker in the middle of a body does not match" {
	export GH_LIST_JSON="[$(_comment 5 "$ME" "$(printf 'intro\n%s\nbody' "$MARKER_LINE")"),$(_comment 6 "$ME" "see $MARKER_LINE inline")]"

	_post "new result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run grep -c -- '-X PATCH' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: a first line that only contains the marker does not match" {
	export GH_LIST_JSON="[$(_comment 5 "$ME" "x ${MARKER_LINE}"),$(_comment 6 "$ME" "${MARKER_LINE} trailing")]"

	_post "new result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
}

@test "post-pr-comment: a marker line ending in CR still matches" {
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\r\nold' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
}

# =============================================================================
# Reserved namespace
# =============================================================================

@test "post-pr-comment: a body cannot smuggle a second lgtm-ci marker" {
	_post "$(printf '%s\n' "## Results" "<!-- lgtm-ci:other-marker -->" \
		"<!-- lgtm-ci:history:latest sha=x run=9 attempt=1 number=1 at=x -->" \
		"test name <!-- lgtm-ci:test-marker -->")"

	assert_success
	run grep -c '<!-- lgtm-ci:' "$GH_BODY"
	assert_output "1"
	run head -1 "$GH_BODY"
	assert_output "$MARKER_LINE"
	run cat "$GH_BODY"
	assert_output --partial "< !-- lgtm-ci:other-marker -->"
	assert_output --partial "< !-- lgtm-ci:history:latest sha=x"
	assert_output --partial "test name < !-- lgtm-ci:test-marker -->"
}

@test "post-pr-comment: history mode also neutralises smuggled markers" {
	export HISTORY=true GITHUB_RUN_ID=200
	_post "$(printf '%s\n' "## Results" "<!-- lgtm-ci:other-marker -->")"

	assert_success
	run grep -c '^<!-- lgtm-ci:' "$GH_BODY"
	# Our marker line and our history stamp only.
	assert_output "2"
	run cat "$GH_BODY"
	assert_output --partial "< !-- lgtm-ci:other-marker -->"
}

@test "post-pr-comment: a body headed by our own marker line is not doubled" {
	_post "$(printf '%s\n%s' "$MARKER_LINE" "## Results")"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "## Results")"
}

@test "post-pr-comment: a body without the namespace is posted byte for byte" {
	local body
	body="$(printf '%s\n' "## Results" "" "| a | b |" "<!-- other-tool:marker -->" "trailing  ")"

	_post "$body"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "$body")"
}

# =============================================================================
# Listing
# =============================================================================

@test "post-pr-comment: reads every page without history and updates a page-two match" {
	export GH_PAGES_FILE="${BATS_TEST_TMPDIR}/pages"
	{
		printf '[%s]\n' "$(_comment 1 'someone' 'unrelated')"
		printf '[%s]\n' "$(_comment 7 "$ME" "$(printf '%s\nold result on page two' "$MARKER_LINE")")"
	} >"$GH_PAGES_FILE"

	_post "new result"

	assert_success
	grep -q 'action-taken=updated' "$GITHUB_OUTPUT"
	run grep -c -- '--paginate .*/repos/lgtm-hq/consumer/issues/42/comments?per_page=100' "$GH_CALLS"
	assert_output "1"
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
}

@test "post-pr-comment: fails closed without history when the listing fails" {
	export GH_LIST_JSON=""
	export GH_LIST_EXIT=1

	_post "new result"

	assert_failure
	assert_output --partial "Could not list comments"
	assert_equal "$(_writes)" "0"
}

@test "post-pr-comment: delete-on-empty fails closed when the listing fails" {
	export DELETE_ON_EMPTY="true" GH_LIST_JSON="" GH_LIST_EXIT=1

	_post ""

	assert_failure
	assert_equal "$(_writes)" "0"
}

@test "post-pr-comment: create mode with a body reads no identity and no listing" {
	export MODE="create"

	_post "new result"

	assert_success
	run grep -cE '^api (graphql|--paginate)' "$GH_CALLS"
	assert_output "0"
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
}

# =============================================================================
# Identity not determinable
# =============================================================================

@test "post-pr-comment: unknown identity posts a new comment and touches none" {
	export GH_VIEWER_FAIL=1
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	assert_output --partial "::warning::post-pr-comment: could not determine the account"
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run grep -cE -- '-X (PATCH|DELETE)' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: an implausible viewer login counts as unknown" {
	export GH_VIEWER_LOGIN='github-actions[bot] x'
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	assert_output --partial "could not determine the account"
	run grep -c -- '-X PATCH' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: unknown identity skips update mode and delete-on-empty" {
	export GH_VIEWER_FAIL=1
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	MODE="update" _post "new result"
	assert_success
	assert_output --partial "Skipped: no existing comment to update"

	DELETE_ON_EMPTY="true" _post ""
	assert_success
	assert_output --partial "Skipped: empty body"
	assert_equal "$(_writes)" "0"
}

@test "post-pr-comment: unknown identity in history mode starts a fresh comment" {
	export GH_VIEWER_FAIL=1 HISTORY=true GITHUB_RUN_ID=200
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run grep -cE -- '-X (PATCH|DELETE)' "$GH_CALLS"
	assert_output "0"
	run cat "$GH_BODY"
	refute_output --partial "Previous runs"
}

@test "post-pr-comment: the identity warning gives the reason on one sanitised line" {
	export GH_VIEWER_FAIL=1
	export GH_VIEWER_ERR=$'HTTP 401: Bad credentials (https://api.github.com/graphql)\n::error::forged'

	_post "new result"

	assert_success
	assert_output --partial "(GraphQL viewer: HTTP 401: Bad credentials (https://api.github.com/graphql) ::error::forged)"
	refute_line "::error::forged"
}

@test "post-pr-comment: a viewer answer without databaseId counts as unknown" {
	export GH_VIEWER_JSON='{"data":{"viewer":{"login":"github-actions[bot]"}}}'
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "new result"

	assert_success
	assert_output --partial "unexpected viewer answer"
	run grep -c -- '-X PATCH' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: same login with another account id is not ours" {
	export GH_LIST_JSON="[$(jq -cn --arg body "$(printf '%s\nlook-alike' "$MARKER_LINE")" \
		'{id: 7, user: {login: "github-actions[bot]", id: 5555}, body: $body}')]"

	_post "new result"

	assert_success
	grep -q 'action-taken=created' "$GITHUB_OUTPUT"
	run grep -c -- '-X PATCH' "$GH_CALLS"
	assert_output "0"
}

@test "post-pr-comment: an Enterprise Managed User login is accepted" {
	export GH_VIEWER_LOGIN='octo-cat_acme' GH_VIEWER_ID=7007
	export GH_LIST_JSON="[$(jq -cn --arg body "$(printf '%s\nours' "$MARKER_LINE")" \
		'{id: 7, user: {login: "octo-cat_acme", id: 7007}, body: $body}')]"

	_post "new result"

	assert_success
	refute_output --partial "could not determine the account"
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
}

@test "post-pr-comment: a body that is only our marker line counts as empty" {
	export DELETE_ON_EMPTY="true"
	export GH_LIST_JSON="[$(_comment 7 "$ME" "$(printf '%s\nours' "$MARKER_LINE")")]"

	_post "$MARKER_LINE"

	assert_success
	assert_output --partial "Deleted comment 7"
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
}

@test "post-pr-comment: carriage returns are dropped before the namespace is neutralised" {
	_post "$(printf '%s\r\n' "## Results" $'<!-\r- lgtm-ci:other -->' $'<\r!-- lgtm-ci:history:start -->')"

	assert_success
	run grep -c $'\r' "$GH_BODY"
	assert_output "0"
	run grep -c '<!-- lgtm-ci:' "$GH_BODY"
	assert_output "1"
	run cat "$GH_BODY"
	assert_output --partial "< !-- lgtm-ci:other -->"
	assert_output --partial "< !-- lgtm-ci:history:start -->"
}

@test "post-pr-comment: rejects a multi-line marker" {
	MARKER=$'a\nb' _post "new result"

	assert_failure
	assert_output --partial "MARKER must be a single line"
	assert_equal "$(_writes)" "0"
}

# =============================================================================
# read-file output (#1675)
# =============================================================================

_read_file() {
	run env STEP="read-file" COMMENT_FILE="$1" bash "$POSTER"
}

@test "post-pr-comment: read-file body holding guessed delimiters sets no extra output" {
	local file="${BATS_TEST_TMPDIR}/body.md"
	printf '%s\n' "## Results" "LGTM_EOF_$$_$(date +%s)" "EOF" \
		"ghadelimiter_00000000000000000000000000000000" "injected=true" >"$file"

	_read_file "$file"

	assert_success
	run github_file_keys "$GITHUB_OUTPUT"
	assert_output "$(printf '%s\n' file_provided body)"
	run get_github_output "body"
	assert_output "$(cat "$file")"
}

@test "post-pr-comment: read-file fails when the report cannot be read, and writes no body" {
	local file="${BATS_TEST_TMPDIR}/report.md" bin="${BATS_TEST_TMPDIR}/failing-cat"
	printf 'report\n' >"$file"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${bin}/cat"
	chmod +x "${bin}/cat"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/read-fail-output"
	: >"$GITHUB_OUTPUT"
	PATH="${bin}:${PATH}" run env STEP="read-file" COMMENT_FILE="$file" bash "$POSTER"
	assert_failure
	assert_output --partial "Cannot read comment file"
	run grep -c '^body' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "post-pr-comment: read-file keeps the body as the old framing delivered it" {
	local file="${BATS_TEST_TMPDIR}/body.md"
	printf '%s\n' "## Results" "" "trailing blank lines follow" "" "" >"$file"

	_read_file "$file"

	assert_success
	# Runner semantics: the value is every line between the delimiters.
	local delim expected
	delim="$(sed -n 's/^body<<//p' "$GITHUB_OUTPUT")"
	expected="$(printf '%s\n' "## Results" "" "trailing blank lines follow" "" "" "$delim")"
	assert_equal "$(sed -n '/^body<</,$p' "$GITHUB_OUTPUT" | sed 1d)" "$expected"
}
