#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for comment-fields (#1677) in scripts/ci/actions/post-pr-comment.sh,
# its history line in scripts/ci/actions/post-pr-comment-history.sh and the
# bash entry scripts/ci/lib/github/comment_fields.sh

load "../../../helpers/common"

POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
HELPER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment-history.sh"
ENTRY="${PROJECT_ROOT}/scripts/ci/lib/github/comment_fields.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'
RUN_LINK='([job log](https://github.com/lgtm-hq/consumer/actions/runs/200))'
EXAMPLE=$'Environment: staging\nEnvironment URL: https://staging.example.com\nRegion: eu-west-1\n'
BLOCK=$'> **Environment:** staging\n> **Environment URL:** [staging.example.com](https://staging.example.com)\n> **Region:** eu-west-1'
REPORT=$'## 🧪 Playwright E2E Report\n\nThis PR has been analyzed.\n\n### 📊 Status: ✅ PASSED'

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
	export GITHUB_SHA=mergesha00000 EVENT_PULL_REQUEST_HEAD_SHA=headsha111111
	export GITHUB_SERVER_URL="https://github.com"
	export HISTORY_NOW="2026-11-20T12:00:00Z"
	unset COMMENT_FIELDS HISTORY HISTORY_SUMMARY HISTORY_FIELDS

	# gh stub: viewer is github-actions[bot]; the listing prints
	# $GH_LIST_JSON; DELETE succeeds; POST/PATCH write body= to $GH_BODY.
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
	printf '{"data":{"viewer":{"login":"github-actions[bot]","databaseId":41898282}}}\n'
	exit 0
fi
args=("$@")
method=GET
# case, not [[ ]]: a trace prints [[ ]] operands unquoted, and a coverage
# run copies a body's lines into its log (#1726).
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	-X) method="${args[i + 1]}" ;;
	esac
done
case "$method" in
DELETE) exit 0 ;;
POST | PATCH)
	for ((i = 0; i < ${#args[@]}; i++)); do
		case "${args[i]}" in
		-f)
			case "${args[i + 1]}" in
			body=*) printf '%s' "${args[i + 1]#body=}" >"$GH_BODY" ;;
			esac
			;;
		esac
	done
	printf '{"id": 99, "html_url": "https://github.com/c/99"}\n'
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

# _run <run-id> <fields>: post REPORT for run <run-id> with HISTORY=true over
# the comment in $GH_BODY (if any) and keep the result as the next listing.
_run() {
	if [[ -f "$GH_BODY" ]]; then
		export GH_LIST_JSON="[$(_comment 7 "$(cat "$GH_BODY")")]"
	fi
	export GITHUB_RUN_ID="$1" GITHUB_RUN_NUMBER="$(($1 / 100))"
	export EVENT_PULL_REQUEST_HEAD_SHA="sha${1}aaaaaaa"
	COMMENT_FIELDS="$2" _post "$REPORT" true
	assert_success
}

# =============================================================================
# Placement
# =============================================================================

@test "comment-fields: the block sits under the first heading" {
	COMMENT_FIELDS="$EXAMPLE" _post "$REPORT"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s\n\n%s\n\n%s' "$MARKER_LINE" \
		"## 🧪 Playwright E2E Report" "$BLOCK" "This PR has been analyzed." \
		"### 📊 Status: ✅ PASSED")"
	assert_output --partial "comment-fields: 3 fields shown."
	refute_output --partial "::warning"
}

@test "comment-fields: hidden lines and blank lines before the heading stay above it" {
	COMMENT_FIELDS="Region: eu-west-1" _post $'\n<!-- note -->\n\n# Title\nbody'

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n\n%s\n\n%s\n\n%s\n\n%s' "$MARKER_LINE" \
		"<!-- note -->" "# Title" "> **Region:** eu-west-1" "body")"
}

@test "comment-fields: a body that is only a heading ends with the block" {
	COMMENT_FIELDS="Region: eu-west-1" _post "## Title"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s' "$MARKER_LINE" "## Title" "> **Region:** eu-west-1")"
}

@test "comment-fields: a body without a heading gets the block at the top" {
	COMMENT_FIELDS="Region: eu-west-1" _post $'**Bold headline** · passed\n\nDetails'

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s\n\n%s' "$MARKER_LINE" \
		"> **Region:** eu-west-1" "**Bold headline** · passed" "Details")"
}

@test "comment-fields: a heading followed by a long run of blank lines takes the block, the run dropped" {
	# #1726: the blank lines after the heading go in one cut, found by
	# halving, where they were dropped one at a time.
	local blank
	printf -v blank '%*s' 5000 ''
	COMMENT_FIELDS="Region: eu-west-1" _post "## Title${blank// /$'\n'}rest"$'\n\n'"end"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s\n\n%s\n\n%s' "$MARKER_LINE" \
		"## Title" "> **Region:** eu-west-1" "rest" "end")"
}

# _leading_lines <file> <count>: <count> rounds of a blank line, a
# whitespace-only line and two one-line comments, as the lines before a
# heading. Written to a file so the expected comment can be built from it
# and compared with cmp: no test reads the sent body back into the shell
# (#1726).
_leading_lines() {
	local i
	for ((i = 0; i < $2; i++)); do
		printf '\n \t\n<!-- note %d -->\n  <!-- é ✅ -->  \n' "$i"
	done >"$1"
}

@test "comment-fields: a long run of blank and comment lines before the heading stays above it, unchanged" {
	# #1733: the run is counted in one pass and cut once, where each line
	# was dropped by copying the rest of the body.
	local lead="${BATS_TEST_TMPDIR}/lead"
	_leading_lines "$lead" 800
	{
		printf '%s\n' "$MARKER_LINE"
		cat "$lead"
		printf '## Title\n\n> **Region:** eu-west-1\n\nrest\n\nend'
	} >"${BATS_TEST_TMPDIR}/expected"
	COMMENT_FIELDS="Region: eu-west-1" _post "$(cat "$lead")"$'\n## Title\n\n\nrest\n\nend'

	assert_success
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

@test "comment-fields: a long body of only blank and comment lines gets the block at the top" {
	local lead="${BATS_TEST_TMPDIR}/lead"
	_leading_lines "$lead" 800
	{
		printf '%s\n> **Region:** eu-west-1\n\n' "$MARKER_LINE"
		cat "$lead"
		printf '<!-- end -->'
	} >"${BATS_TEST_TMPDIR}/expected"
	COMMENT_FIELDS="Region: eu-west-1" _post "$(cat "$lead")"$'\n<!-- end -->'

	assert_success
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

@test "comment-fields: a long run before a line that is not a heading gets the block at the top" {
	local lead="${BATS_TEST_TMPDIR}/lead"
	_leading_lines "$lead" 800
	{
		printf '%s\n> **Region:** eu-west-1\n\n' "$MARKER_LINE"
		cat "$lead"
		printf 'plain text\n## Later'
	} >"${BATS_TEST_TMPDIR}/expected"
	COMMENT_FIELDS="Region: eu-west-1" _post "$(cat "$lead")"$'\nplain text\n## Later'

	assert_success
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

@test "comment-fields: sixty thousand blank lines before the heading are placed within seconds" {
	# The case measured in #1733: about a minute before, under a second now.
	# The bound is loose so a slow runner or a coverage run does not trip it.
	# The newlines are written with tr: replacing them inside the shell takes
	# minutes on bash 3.2.
	local lead="${BATS_TEST_TMPDIR}/lead"
	printf '%*s' 60000 '' | tr ' ' '\n' >"$lead"
	{
		printf '%s\n' "$MARKER_LINE"
		cat "$lead"
		printf '## Title\n\n> **Region:** eu-west-1\n\nrest'
	} >"${BATS_TEST_TMPDIR}/expected"
	{
		cat "$lead"
		printf '## Title\nrest'
	} >"${BATS_TEST_TMPDIR}/body"
	SECONDS=0
	COMMENT_FIELDS="Region: eu-west-1" _post "$(cat "${BATS_TEST_TMPDIR}/body")"

	assert_success
	assert [ "$SECONDS" -lt 30 ]
	run cmp "$GH_BODY" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

# _fields_function <file>: the poster's insert_fields_block alone, for the
# tests that need to run it in a shell of their own.
_fields_function() {
	awk '/^insert_fields_block\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$POSTER" >"$1"
}

@test "comment-fields: a comment line that is not valid UTF-8 is counted as the bytes it has" {
	# Review case for #1733. In a UTF-8 locale bash 5.2 and 5.3 drop bytes
	# from this line when `read` stores it. A count taken from the stored
	# line is short, and a cut by that count lands inside the line, at
	# "# -->", which reads as a heading. The stored line is not the start of
	# the body, so nothing is taken from the pass. The line as it is does not
	# match the comment pattern in a UTF-8 locale (its bytes are not valid
	# UTF-8), so it is ordinary text and the block goes at the top, as on
	# main.
	local utf8=""
	utf8="$(locale -a 2>/dev/null | grep -i -m 1 -E '^(C|en_US)\.utf-?8$')" || skip "no UTF-8 locale here"
	printf '<!-- \001\342\001\234\205\001\342\001\234\205 # -->\n## Title\nrest' >"${BATS_TEST_TMPDIR}/body"
	{
		printf '> **Region:** eu-west-1\n\n'
		cat "${BATS_TEST_TMPDIR}/body"
	} >"${BATS_TEST_TMPDIR}/expected"
	_fields_function "${BATS_TEST_TMPDIR}/fn.sh"
	cat >"${BATS_TEST_TMPDIR}/runner.sh" <<'EOF'
source "$1"
body="$(
	cat "$2"
	printf x
)"
insert_fields_block "${body%x}" "> **Region:** eu-west-1" >"$3"
EOF
	run env LC_ALL="$utf8" bash "${BATS_TEST_TMPDIR}/runner.sh" "${BATS_TEST_TMPDIR}/fn.sh" \
		"${BATS_TEST_TMPDIR}/body" "${BATS_TEST_TMPDIR}/actual"

	assert_success
	run cmp "${BATS_TEST_TMPDIR}/actual" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

@test "comment-fields: when the one-pass count cannot run, the block still goes under the heading" {
	# Review cases for #1733. A body too large for a pipe (200,000 bytes,
	# well over the 64 KiB a pipe holds) makes the shell write the
	# here-string to a temporary file; with a file-size limit of one block
	# that write fails and the pass takes nothing. The lines are then
	# handled one at a time and the result is the same. The function runs as
	# the poster runs it, in a command substitution, and with errexit
	# inherited by it where the shell can do that: the failed redirection
	# must not end the function.
	local filler="${BATS_TEST_TMPDIR}/filler"
	printf '%*s' 200000 '' | tr ' ' 'c' >"$filler"
	{
		printf '\n<!-- note -->\n\n## Title\n\n\n'
		cat "$filler"
	} >"${BATS_TEST_TMPDIR}/body"
	{
		printf '\n<!-- note -->\n\n## Title\n\n> **Region:** eu-west-1\n\n'
		cat "$filler"
	} >"${BATS_TEST_TMPDIR}/expected"
	_fields_function "${BATS_TEST_TMPDIR}/fn.sh"
	cat >"${BATS_TEST_TMPDIR}/runner.sh" <<'EOF'
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || :
source "$1"
body="$(
	cat "$2"
	printf x
)"
trap '' XFSZ
ulimit -Sf 1
result="$(insert_fields_block "${body%x}" "> **Region:** eu-west-1")"
printf '%s' "$result"
EOF
	# Output through a pipe: the limit stops the shell writing files.
	run bash -c 'bash "$1" "$2" "$3" 2>"$5" | cat >"$4"; echo "status ${PIPESTATUS[0]}"' _ \
		"${BATS_TEST_TMPDIR}/runner.sh" "${BATS_TEST_TMPDIR}/fn.sh" "${BATS_TEST_TMPDIR}/body" \
		"${BATS_TEST_TMPDIR}/actual" "${BATS_TEST_TMPDIR}/stderr"

	assert_output "status 0"
	# The fault did fire: the shell said it could not write the here-string.
	run grep -c -i 'here.document' "${BATS_TEST_TMPDIR}/stderr"
	assert_output "1"
	run cmp "${BATS_TEST_TMPDIR}/actual" "${BATS_TEST_TMPDIR}/expected"
	assert_success
}

@test "comment-fields: '#hashtag' and a heading inside the text are not the first heading" {
	COMMENT_FIELDS="Region: eu-west-1" _post $'#nospace\n## Later'

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s\n%s' "$MARKER_LINE" \
		"> **Region:** eu-west-1" "#nospace" "## Later")"
}

# =============================================================================
# Unset input is byte-identical; identity and delete-on-empty
# =============================================================================

@test "comment-fields: unset, empty, blank or comment-only input changes nothing, byte for byte" {
	local value history baseline="${BATS_TEST_TMPDIR}/baseline"
	# Without history the posted body is exactly the marker line and the report.
	printf '%s\n%s' "$MARKER_LINE" "$REPORT" >"${BATS_TEST_TMPDIR}/contract"
	for history in false true; do
		export GH_LIST_JSON='[]'
		rm -f "$GH_BODY"
		_post "$REPORT" "$history"
		assert_success
		cp "$GH_BODY" "$baseline"
		if [[ "$history" == "false" ]]; then
			run cmp "$baseline" "${BATS_TEST_TMPDIR}/contract"
			assert_success
		fi
		for value in "" "   " $'\n\n\t\n' $'# only a comment\n'; do
			rm -f "$GH_BODY"
			COMMENT_FIELDS="$value" _post "$REPORT" "$history"
			assert_success
			refute_output --partial "comment-fields"
			run grep -c 'fields=' "$GH_BODY"
			assert_output "0"
			run cmp "$GH_BODY" "$baseline"
			assert_success
		done
	done
}

@test "comment-fields: delete-on-empty decides on the report alone" {
	export DELETE_ON_EMPTY="true"
	export GH_LIST_JSON="[$(_comment 7 "$(printf '%s\nold' "$MARKER_LINE")")]"

	COMMENT_FIELDS="$EXAMPLE" _post ""

	assert_success
	assert_output --partial "Deleted comment 7"
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
	run grep -cE -- '-X (POST|PATCH)' "$GH_CALLS"
	assert_output "0"
}

@test "comment-fields: an empty report with fields is skipped, not posted" {
	COMMENT_FIELDS="$EXAMPLE" _post ""

	assert_success
	assert_output --partial "Skipped: empty body"
	run grep -cE -- '-X (POST|PATCH)' "$GH_CALLS"
	assert_output "0"
}

@test "comment-fields: fields never change which comment is updated" {
	local other
	other="$(printf '%s\n%s' '<!-- lgtm-ci:other -->' "> **Environment:** staging")"
	export GH_LIST_JSON="[$(_comment 5 "$other"),$(_comment 7 "$(printf '%s\nold' "$MARKER_LINE")")]"

	COMMENT_FIELDS=$'Environment: staging\nMarker: <!-- lgtm-ci:other -->' _post "$REPORT"

	assert_success
	run grep -c -- '-X PATCH .*/issues/comments/7' "$GH_CALLS"
	assert_output "1"
	run grep -c -- 'comments/5' "$GH_CALLS"
	assert_output "0"
}

# =============================================================================
# Bad lines and hostile values
# =============================================================================

@test "comment-fields: a bad line is a note with the run link; the step succeeds" {
	COMMENT_FIELDS=$'Environment: staging\nno colon here\nURL: http://x.example\nRegion: eu-west-1' \
		_post "$REPORT"

	assert_success
	run cat "$GH_BODY"
	# Blank lines are not in bats' lines array: marker, heading, block.
	assert_line --index 2 "> **Environment:** staging"
	assert_line --index 3 "> ⚠️ \`comment-fields\` line 2: no colon found ${RUN_LINK}"
	assert_line --index 4 "> ⚠️ \`comment-fields\` line 3: links must start with https&#8203;:// ${RUN_LINK}"
	assert_line --index 5 "> **Region:** eu-west-1"
	refute_output --partial "no colon here"
	refute_output --partial "x.example"
}

@test "comment-fields: the job log names each line and raises one warning" {
	COMMENT_FIELDS=$'::error::forged\nURL: http://x.example' _post "$REPORT"

	assert_success
	assert_output --partial 'comment-fields: line 1: nothing before the colon. A correct line looks like "Environment: staging".'
	assert_output --partial 'comment-fields: line 2: links must start with https://.'
	run grep -c '^::warning' <<<"$output"
	assert_output "1"
	refute_output --partial "::error::forged"
}

@test "comment-fields: an input over the size limit posts the report with one note" {
	COMMENT_FIELDS="A: $(printf 'x%.0s' {1..9000})" _post "$REPORT"

	assert_success
	run cat "$GH_BODY"
	assert_line --index 1 "## 🧪 Playwright E2E Report"
	assert_line --index 2 "> ⚠️ \`comment-fields\` could not be read: the input is larger than 8192 bytes ${RUN_LINK}"
	assert_output --partial "This PR has been analyzed."
}

@test "comment-fields: hostile labels and values are inert in the posted body" {
	COMMENT_FIELDS=$'@org/team: #1\n<img src=x>: [x](javascript:y)\nH: <!-- lgtm-ci:history:start -->\nB: \\[a](https://ok.example)@other.example\nC: a\rD: ok' \
		_post "$REPORT" true

	assert_success
	run cat "$GH_BODY"
	assert_line --index 3 "> **@&#8203;org/team:** \\#&#8203;1"
	assert_line --index 4 "> **&lt;img src=x&gt;:** \\[x\\](javascript:y)"
	refute_output --partial "<img"
	refute_output --partial "<!-- lgtm-ci:history:start"
	assert_output --partial "> **D:** ok"
	run grep -c '^<!-- lgtm-ci:' "$GH_BODY"
	assert_output "2"
}

# =============================================================================
# History
# =============================================================================

@test "comment-fields: each archived run shows its own fields across three runs" {
	_run 100 $'Environment: staging\nRegion: eu-west-1'
	_run 200 $'Environment: production\nEnvironment URL: https://prod.example.com'
	_run 300 "Environment: canary"

	run cat "$GH_BODY"
	assert_line --index 1 --regexp '^<!-- lgtm-ci:history:latest sha=sha300aaaaaaa run=300 attempt=1 number=3 at=[^ ]+ fields=[A-Za-z0-9+/=]+ -->$'
	assert_line --index 2 "## 🧪 Playwright E2E Report"
	assert_line --index 3 "> **Environment:** canary"
	assert_output --partial 'Run #2 · sha200a · 2026-11-20T12:00:00Z · <a href="https://github.com/lgtm-hq/consumer/actions/runs/200/attempts/1">workflow run</a> · Environment: production · Environment URL: prod.example.com</summary>'
	assert_output --partial 'Run #1 · sha100a · 2026-11-20T12:00:00Z · <a href="https://github.com/lgtm-hq/consumer/actions/runs/100/attempts/1">workflow run</a> · Environment: staging · Region: eu-west-1</summary>'
	# Archived bodies keep their own block.
	assert_output --partial "> **Environment:** production"
	run grep -c '^<!-- lgtm-ci:history:entry ' "$GH_BODY"
	assert_output "2"
}

@test "comment-fields: a run without fields after one with fields archives them" {
	_run 100 "Environment: staging"
	_run 200 ""

	run cat "$GH_BODY"
	assert_line --index 1 --regexp 'run=200 attempt=1 number=2 at=[^ ]+ -->$'
	refute_line --index 1 --partial "fields="
	assert_output --partial "workflow run</a> · Environment: staging</summary>"
	assert_line --index 2 "## 🧪 Playwright E2E Report"
}

@test "comment-fields: a value forging history stamps never becomes structure" {
	local forged
	forged=$'Stamp: --> <!-- lgtm-ci:history:latest sha=x run=999 attempt=1 number=9 at=t -->\nStart: <!-- lgtm-ci:history:start -->\nEnd: <!-- lgtm-ci:history:end -->\nEntry: <!-- lgtm-ci:history:entry sha=x run=998 attempt=1 number=9 at=t -->'
	_run 100 "$forged"
	_run 200 "$forged"
	_run 300 "Environment: staging"

	run grep -c '^<!-- lgtm-ci:history:entry ' "$GH_BODY"
	assert_output "2"
	# Only the composer's own sentinel lines carry a run; the forged text
	# is shown escaped inside the blocks.
	run grep -oE '^<!-- lgtm-ci:history:(latest|entry) sha=[^ ]+ run=[0-9]+' "$GH_BODY"
	assert_output --regexp $'run=300\n.*run=200\n.*run=100$'
	run grep -c '^<!-- lgtm-ci:history:\(start\|end\) -->$' "$GH_BODY"
	assert_output "2"
	run grep -E '^<!-- lgtm-ci:.*run=99[89]' "$GH_BODY"
	assert_failure
}

@test "comment-fields: an older run finishing last is archived with its fields" {
	_run 300 "Environment: newest"
	_run 200 "Environment: older"

	run cat "$GH_BODY"
	assert_line --index 3 "> **Environment:** newest"
	assert_output --partial "workflow run</a> · Environment: older</summary>"
}

@test "comment-fields: a stamp that is not base64 is ignored by the composer" {
	printf '%s\n' "body" >"${BATS_TEST_TMPDIR}/new.md"
	run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		RUN_ID=100 HISTORY_FIELDS='--> <!-- x' bash "$HELPER" </dev/null

	assert_success
	assert_line --index 1 --regexp 'run=100 attempt=1 number=0 at=[^ ]+ -->$'
}

# =============================================================================
# Bash entry
# =============================================================================

@test "comment_fields.sh: without python3 a fixed note is written and the call succeeds" {
	run bash -c '
		source "$1"
		_COMMENT_SANITIZE_PYTHON=""
		COMMENT_FIELDS="Region: eu-west-1" comment_fields render --env COMMENT_FIELDS \
			--style block --out "$2/block" --stamp "$2/stamp"
		echo "rc=$?"
		cat "$2/block"; echo; wc -c <"$2/stamp"
		comment_fields history --env X; echo "history rc=$?"
	' _ "$ENTRY" "$BATS_TEST_TMPDIR"

	assert_success
	assert_output --partial "::warning title=comment-fields::comment-fields could not be read: this runner has no python3"
	assert_line "rc=0"
	assert_line "> ⚠️ \`comment-fields\` could not be read: this runner has no python3"
	assert_line --regexp '^ *0$'
	assert_line "history rc=0"
}


# =============================================================================
# Size budget (#1703 review)
# =============================================================================

# Opus's worst case: 20 fields whose escaping is 4-5 times the input.
_opus_fields() {
	local i
	for ((i = 0; i < 20; i++)); do
		printf 'L%02d%s: %s\n' "$i" "$(printf '<%.0s' {1..57})" "$(printf '#1%.0s' {1..170})"
	done
}

# _chars FILE: the file's length in characters (UTF-8).
_chars() {
	LC_ALL=C.UTF-8 python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$1"
}

@test "comment-fields: a body at the publisher's 60,000-byte limit still posts under 65,536 characters" {
	local report history
	report="## Report"$'\n\n'"$(printf 'r%.0s' $(seq 1 59980))"
	for history in false true; do
		rm -f "$GH_BODY"
		export GH_LIST_JSON='[]'
		COMMENT_FIELDS="$(_opus_fields)" _post "$report" "$history"
		assert_success
		run _chars "$GH_BODY"
		assert [ "$output" -lt 65536 ]
		run grep -c 'more fields not shown (size limit)' "$GH_BODY"
		assert_output "1"
		run grep -c "$(printf 'r%.0s' $(seq 1 200))" "$GH_BODY"
		assert_output "1"
	done
}

@test "comment-fields: Sol's 15 fields of 512 '<' over a 40,000-character report post under the limit" {
	local report fields="" i
	report="## Report"$'\n\n'"$(printf 'r%.0s' $(seq 1 40000))"
	for ((i = 0; i < 15; i++)); do
		fields+="F${i}: $(printf '<%.0s' $(seq 1 512))"$'\n'
	done
	_run 100 "$fields"
	_run 200 "$fields"
	COMMENT_FIELDS="$fields" _post "$report" true
	assert_success
	run _chars "$GH_BODY"
	assert [ "$output" -lt 65536 ]
	run grep -c "$(printf 'r%.0s' $(seq 1 200))" "$GH_BODY"
	assert_output "1"
}

@test "comment-fields: a body too large for the block gets a short note instead" {
	local report
	report="## Report"$'\n\n'"$(printf 'r%.0s' $(seq 1 64000))"

	COMMENT_FIELDS="$EXAMPLE" _post "$report"

	assert_success
	run grep -c '^::warning title=comment-fields::' <<<"$output"
	assert_output "1"
	run _chars "$GH_BODY"
	assert [ "$output" -lt 65536 ]
	run grep -c "could not be read: the comment is at GitHub's size limit" "$GH_BODY"
	assert_output "1"
}

@test "comment-fields: a report within a note's length of the limit is posted unchanged, with a warning" {
	# The report fits GitHub's limit on its own; neither the block nor the
	# size-limit note may push it over (the note used to be added unchecked).
	local report plain history
	report="## Report"$'\n\n'"$(printf 'r%.0s' $(seq 1 65300))"
	for history in false true; do
		rm -f "$GH_BODY"
		_post "$report" "$history"
		assert_success
		plain="$(_chars "$GH_BODY")"
		assert [ "$plain" -le 65536 ]

		rm -f "$GH_BODY"
		COMMENT_FIELDS="Env: staging" _post "$report" "$history"
		assert_success
		run grep -c '^::warning title=comment-fields::' <<<"$output"
		assert_output "1"
		run _chars "$GH_BODY"
		assert_output "$plain"
		run grep -c "comment-fields" "$GH_BODY"
		assert_output "0"
	done
}

# =============================================================================
# Failures never fail the step or drop the fields silently (#1703 review)
# =============================================================================

# _stub NAME SCRIPT: put a stand-in for NAME first on PATH.
_stub() {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\n%s\n' "$2" >"${bin}/$1"
	chmod +x "${bin}/$1"
	export PATH="${bin}:$PATH"
}

_assert_internal_note() {
	assert_success
	run cat "$GH_BODY"
	assert_line --index 2 "> ⚠️ \`comment-fields\` could not be read: internal error, see the job log ${RUN_LINK}"
	assert_output --partial "This PR has been analyzed."
}

@test "comment-fields: a failing mktemp gives the internal-error note and one warning" {
	_stub mktemp 'if [[ "${1:-}" == "-d" ]]; then echo "No space left on device" >&2; exit 1; fi; exec /usr/bin/mktemp "$@"'
	export MODE=create

	COMMENT_FIELDS="$EXAMPLE" _post "$REPORT"

	assert_success
	run grep -c '^::warning title=comment-fields::comment-fields could not be read: internal error' <<<"$output"
	assert_output "1"
	_assert_internal_note
}

@test "comment-fields: a renderer that exits non-zero gives the internal-error note" {
	_stub python3 'exit 1'
	export MODE=create

	COMMENT_FIELDS="$EXAMPLE" _post "$REPORT"

	assert_success
	assert_output --partial "::warning title=comment-fields::comment-fields could not be read: internal error"
	_assert_internal_note
}

@test "comment-fields: a renderer that writes nothing gives the internal-error note" {
	_stub python3 'exit 0'
	export MODE=create

	COMMENT_FIELDS="$EXAMPLE" _post "$REPORT"

	assert_success
	assert_output --partial "::warning title=comment-fields::comment-fields could not be read: internal error"
	_assert_internal_note
}

# =============================================================================
# A malformed fields= token costs only the fields (#1703 review)
# =============================================================================

@test "comment-fields: a malformed, empty or oversized fields= keeps the run's identity" {
	local token existing
	for token in 'fields=!' 'fields=' 'fields=-' "fields=$(printf 'A%.0s' $(seq 1 5000))"; do
		existing="${BATS_TEST_TMPDIR}/existing.md"
		printf '%s\n' "$MARKER_LINE" \
			"<!-- lgtm-ci:history:latest sha=old run=3 attempt=1 number=3 at=t ${token} -->" \
			"## Old report" "" "---" "" \
			"<details><summary>🕘 Previous runs (1)</summary>" "" \
			"<!-- lgtm-ci:history:start -->" \
			"<!-- lgtm-ci:history:entry sha=one run=1 attempt=1 number=1 at=t -->" \
			"<details><summary>Run #1</summary>" "" "run one" "" "</details>" \
			"<!-- lgtm-ci:history:end -->" "" "</details>" >"$existing"
		printf '%s\n' "## New report" >"${BATS_TEST_TMPDIR}/new.md"
		run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
			RUN_ID=2 RUN_NUMBER=2 HISTORY_NOW=t2 RUN_URL="https://github.com/o/r/actions/runs/2" \
			bash "$HELPER" <"$existing"
		assert_success
		# Run 3 is newer: it stays latest, without fields; run 2 is archived.
		assert_line --index 1 "<!-- lgtm-ci:history:latest sha=old run=3 attempt=1 number=3 at=t -->"
		assert_line --index 2 "## Old report"
		refute_output --partial "earlier run (unstamped)"
		run grep -oE '^<!-- lgtm-ci:history:entry sha=[^ ]+ run=[0-9]+' <<<"$output"
		assert_output $'<!-- lgtm-ci:history:entry sha=unknown run=2\n<!-- lgtm-ci:history:entry sha=one run=1'
	done
}

@test "comment-fields: a valid summary= survives beside a malformed fields=" {
	local summary
	summary="$(printf '%s' '3 passed' | base64)"
	printf '%s\n' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=old run=3 attempt=1 number=3 at=t summary=${summary} fields=! -->" \
		"## Old report" >"${BATS_TEST_TMPDIR}/existing.md"
	printf '%s\n' "## New report" >"${BATS_TEST_TMPDIR}/new.md"

	run env NEW_BODY_FILE="${BATS_TEST_TMPDIR}/new.md" MARKER_TAG="$MARKER_LINE" \
		RUN_ID=4 RUN_NUMBER=4 HISTORY_NOW=t4 bash "$HELPER" <"${BATS_TEST_TMPDIR}/existing.md"

	assert_success
	assert_output --partial "<details><summary>Run #3 · old · t · 3 passed</summary>"
}
