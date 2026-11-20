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

@test "comment-fields: '#hashtag' and a heading inside the text are not the first heading" {
	COMMENT_FIELDS="Region: eu-west-1" _post $'#nospace\n## Later'

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s\n\n%s\n%s' "$MARKER_LINE" \
		"> **Region:** eu-west-1" "#nospace" "## Later")"
}

# =============================================================================
# Unset input is byte-identical; identity and delete-on-empty
# =============================================================================

@test "comment-fields: unset, empty, blank or comment-only input changes nothing" {
	local expected value history
	for history in false true; do
		export GH_LIST_JSON='[]'
		_post "$REPORT" "$history"
		assert_success
		expected="$(cat "$GH_BODY")"
		for value in "" "   " $'\n\n\t\n' $'# only a comment\n'; do
			rm -f "$GH_BODY"
			COMMENT_FIELDS="$value" _post "$REPORT" "$history"
			assert_success
			assert_equal "$(cat "$GH_BODY")" "$expected"
			refute_output --partial "comment-fields"
		done
	done
	refute_output --partial "fields="
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
