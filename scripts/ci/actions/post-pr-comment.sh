#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post or update a PR comment with marker-based identification
#
# Environment variables:
#   STEP - Which step to run: pr-number, read-file or post
#   GH_TOKEN - GitHub token for API access
#   GITHUB_REPOSITORY - Repository in owner/repo format
#   BODY_FILE - File holding the comment body (post step, #1716); the script
#     reads it itself, at most COMMENT_MAX_BYTES + 1 bytes
#   BODY_FROM_INPUT - Comment body (post step) when BODY_FILE is empty
#   COMMENT_FILE - File holding the comment body (read-file step, the earlier
#     way to pass a file: its body goes through an environment variable, which
#     Linux caps at 128 KiB)
#   FILE_PROVIDED, BODY_FROM_FILE - The read-file step's outputs (post step)
#   PR_NUMBER - Pull request number (for post step)
#   INPUT_PR_NUMBER - User-provided PR number override
#   EVENT_NAME - GitHub event name (for pr-number step)
#   EVENT_PR_NUMBER - PR number from event context
#   EVENT_ISSUE_NUMBER - Issue number from event context
#   MARKER - Unique marker for this comment
#   MODE - Comment mode: upsert, create, or update
#   DELETE_ON_EMPTY - Whether to delete comment if body is empty
#   HISTORY - "true" keeps earlier runs in a "Previous runs" archive (#1346)
#   HISTORY_LIMIT - Earlier runs kept with HISTORY=true (default 3; 0 = unlimited)
#   HISTORY_SUMMARY - Optional one-line text for this run's archived entry
#   GITHUB_SHA, EVENT_PULL_REQUEST_HEAD_SHA - Commit stamped on the result
#   GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_RUN_NUMBER, GITHUB_SERVER_URL -
#     Run metadata stamped on the result with HISTORY=true
#   COMMENT_FIELDS - Optional caller `Label: value` lines (#1677), shown as a
#     block under the body's first heading; rules in docs/comment-fields.md
#
# Ownership (#1674): a comment is this publisher's only when its first line is
# exactly the marker line and its author is the account GH_TOKEN posts as.
# No other comment is ever updated or deleted. The body may not carry the
# reserved <!-- lgtm-ci: namespace; any occurrence is neutralised.
#
# Size (#1705): GitHub's limit on a comment body is 262,144 bytes of UTF-8
# (measured; its error message says "65536 characters"). A body over it, or
# one that cannot be measured, is never sent: a short notice that states no
# result takes its place, keeping the marker line and, with HISTORY=true, the
# stamp and archive. Once the notice is posted the step fails with one
# ::error, so the oversized report still turns the job red.

set -euo pipefail

: "${STEP:=post}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"

# -----------------------------------------------------------------------------
# Step: read-file - Read comment body from file
# -----------------------------------------------------------------------------
if [[ "$STEP" == "read-file" ]]; then
	: "${COMMENT_FILE:?COMMENT_FILE is required}"
	: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
	echo "file_provided=true" >>"$GITHUB_OUTPUT"
	if [[ ! -f "$COMMENT_FILE" ]]; then
		echo "::warning::Comment file not found: $COMMENT_FILE"
		echo "body=" >>"$GITHUB_OUTPUT"
	else
		# The file as the earlier heredoc framing delivered it: every byte
		# less one trailing newline. The shared helper writes it under a
		# random delimiter the content does not contain (#1675).
		# A failed read must fail the step: an empty body here would let
		# delete-on-empty remove the previous comment and its history.
		if ! body="$(
			cat "$COMMENT_FILE" || exit 1
			printf x
		)"; then
			echo "::error::Cannot read comment file: $COMMENT_FILE"
			exit 1
		fi
		body="${body%x}"
		body="${body%$'\n'}"
		set_github_output_multiline "body" "$body"
	fi
	exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"

# -----------------------------------------------------------------------------
# Step: pr-number - Determine PR number from context
# -----------------------------------------------------------------------------
if [[ "$STEP" == "pr-number" ]]; then
	PR_NUMBER="${INPUT_PR_NUMBER:-}"

	if [[ -z "$PR_NUMBER" ]]; then
		case "${EVENT_NAME:-}" in
		pull_request | pull_request_target)
			PR_NUMBER="${EVENT_PR_NUMBER:-}"
			;;
		issue_comment)
			PR_NUMBER="${EVENT_ISSUE_NUMBER:-}"
			;;
		*)
			# Try to detect from current branch
			PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
			;;
		esac
	fi

	if [[ -z "$PR_NUMBER" ]]; then
		echo "::error::Could not determine PR number"
		exit 1
	fi

	echo "number=$PR_NUMBER" >>"$GITHUB_OUTPUT"
	exit 0
fi

# -----------------------------------------------------------------------------
# Step: post - Post or update comment
# -----------------------------------------------------------------------------
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${MARKER:?MARKER is required}"

if [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
	HEAD_REPO="${EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME:-}"
	if [[ -n "$HEAD_REPO" && "$HEAD_REPO" != "$GITHUB_REPOSITORY" ]]; then
		echo "action-taken=skipped" >>"$GITHUB_OUTPUT"
		echo "Skipped: fork PR cannot receive workflow comments ($HEAD_REPO)"
		exit 0
	fi
fi
: "${MODE:=upsert}"
: "${DELETE_ON_EMPTY:=false}"

if [[ "$MARKER" == *$'\n'* || "$MARKER" == *$'\r'* ]]; then
	echo "::error::MARKER must be a single line"
	exit 1
fi

# GitHub's limit on a comment body: 262,144 bytes of UTF-8, established by
# posting (#1705). The API's error message says "65536 characters", but a
# body of 65,537 characters is accepted and one of 262,145 bytes is not,
# whatever the characters.
COMMENT_MAX_BYTES=262144
# A body up to this size goes to gh as a `-f body=` field, exactly as before.
# gh replaces each invalid UTF-8 byte with U+FFFD (3 bytes), so even an
# invalid body of this size is at most 196,608 bytes on the wire. A larger
# body is encoded by jq into a JSON file, measured as encoded and sent with
# --input (a -f argument over 128 KiB would also exceed Linux's limit on one
# argument).
COMMENT_FIELD_MAX_BYTES=65536

# Temporary files, removed on exit.
TEMP_FILES=()
PAYLOAD_FILE=""
trap 'rm -f "${TEMP_FILES[@]}"' EXIT

# Set when the body is known to be over the limit before it is read in full.
BODY_OVERSIZED=false
BODY_FILE_BYTES=""

# Read BODY_FILE into COMMENT_BODY as the read-file step delivered it: every
# byte less one trailing newline (#1716). At most COMMENT_MAX_BYTES + 1 bytes
# are read, so a file of any size costs no more memory than the limit; a file
# over the limit sets BODY_OVERSIZED and is not read further. The path rule is
# the read-file step's: a regular file (after symlinks) or the "not found"
# warning and an empty body. A failed read fails the step: an empty body here
# would let delete-on-empty remove the previous comment and its history.
# Usage: read_body_file PATH
read_body_file() {
	local file="$1" part size
	COMMENT_BODY=""
	if [[ ! -f "$file" ]]; then
		echo "::warning::Comment file not found: $file"
		return 0
	fi
	if ! part="$(mktemp)"; then
		echo "::error::Cannot read comment file: $file (no temporary file)"
		exit 1
	fi
	TEMP_FILES+=("$part")
	if ! head -c "$((COMMENT_MAX_BYTES + 1))" -- "$file" >"$part"; then
		echo "::error::Cannot read comment file: $file"
		exit 1
	fi
	size="$(wc -c <"$part" | tr -d '[:space:]')" || size=""
	if [[ ! "$size" =~ ^[0-9]+$ ]]; then
		echo "::error::Cannot read comment file: $file (its size cannot be measured)"
		exit 1
	fi
	if ((size > COMMENT_MAX_BYTES)); then
		BODY_OVERSIZED=true
		BODY_FILE_BYTES="$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]')" || BODY_FILE_BYTES=""
		[[ "$BODY_FILE_BYTES" =~ ^[0-9]+$ ]] || BODY_FILE_BYTES=""
		rm -f "$part"
		return 0
	fi
	if ! COMMENT_BODY="$(
		cat "$part" || exit 1
		printf x
	)"; then
		echo "::error::Cannot read comment file: $file"
		exit 1
	fi
	rm -f "$part"
	COMMENT_BODY="${COMMENT_BODY%x}"
	COMMENT_BODY="${COMMENT_BODY%$'\n'}"
}

# Determine COMMENT_BODY: a file the script reads itself, then the read-file
# step's output when a file was given that way (even if empty), then the body.
if [[ -n "${BODY_FILE:-}" ]]; then
	read_body_file "$BODY_FILE"
elif [[ "${FILE_PROVIDED:-}" == "true" ]]; then
	COMMENT_BODY="${BODY_FROM_FILE:-}"
else
	COMMENT_BODY="${BODY_FROM_INPUT:-}"
fi

# Marker line (hidden in rendered markdown): always the first line we write.
MARKER_TAG="<!-- lgtm-ci:${MARKER} -->"
NAMESPACE="<!-- lgtm-ci:"

# Normalise line endings first: CRLF and a lone CR both become LF, which is
# how GitHub renders them, so no two lines are ever joined. The history parser
# does the same before it reads stamps and sentinels, so a CR can neither hide
# the namespace from the neutraliser nor turn into structure on a later run.
COMMENT_BODY="${COMMENT_BODY//$'\r\n'/$'\n'}"
COMMENT_BODY="${COMMENT_BODY//$'\r'/$'\n'}"

# Reserve the namespace (#1674). A copy of our own marker line heading the
# body is redundant (we write it) and is dropped, so a body that is only that
# line counts as empty. Every other <!-- lgtm-ci: becomes visible text
# (`< !--`), so it can neither match a publisher nor forge a history stamp.
case "$COMMENT_BODY" in
"$MARKER_TAG") COMMENT_BODY="" ;;
"$MARKER_TAG"$'\n'*) COMMENT_BODY="${COMMENT_BODY#"$MARKER_TAG"$'\n'}" ;;
esac
COMMENT_BODY="${COMMENT_BODY//"$NAMESPACE"/"< !-- lgtm-ci:"}"

HISTORY_ENABLED=false
DELETE_DUPLICATES=false
if [[ "${HISTORY:-false}" == "true" ]]; then
	HISTORY_ENABLED=true
fi

# The account GH_TOKEN posts as. GraphQL `viewer` answers for every token
# type with no extra permission: `github-actions[bot]` for GITHUB_TOKEN,
# `<app-slug>[bot]` for an App installation token, the user for a personal
# token. REST GET /user rejects installation tokens, and GET /app and
# GET /installation need the App's JWT. viewer.login and viewer.databaseId
# are the REST comment's user.login and user.id (for bots too: the bot's
# GraphQL databaseId is its REST user id). A comment counts as ours only when
# both match. Unknown identity fails closed: no comment counts as ours.
POSTER_LOGIN=""
POSTER_ID=""
OWN_COMMENTS_JSON="[]"

# One display line for a warning: control characters become spaces, so the
# text cannot start a workflow command on a line of its own; at most 200
# characters.
one_line() {
	local text="$1"
	text="$(printf '%s' "$text" | tr '\000-\037\177' ' ')"
	printf '%s' "${text:0:200}"
}

resolve_poster() {
	local viewer_json viewer_err reason=""
	viewer_err="$(mktemp)"
	if viewer_json=$(gh api graphql -f query='query { viewer { login databaseId } }' 2>"$viewer_err"); then
		POSTER_LOGIN=$(jq -r '.data.viewer.login // empty' <<<"$viewer_json" 2>/dev/null || true)
		POSTER_ID=$(jq -r '.data.viewer.databaseId // empty' <<<"$viewer_json" 2>/dev/null || true)
		reason="unexpected viewer answer: $(one_line "$viewer_json")"
	else
		reason="$(one_line "$(cat "$viewer_err")")"
		[[ -n "$reason" ]] || reason="gh api graphql failed with no message"
	fi
	rm -f "$viewer_err"
	# Logins: alphanumerics and single inner hyphens, an Enterprise Managed
	# User suffix `_shortcode`, and `[bot]` for App bots.
	if [[ "$POSTER_LOGIN" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*(_[A-Za-z0-9]+)?(\[bot\])?$ &&
		"$POSTER_ID" =~ ^[1-9][0-9]{0,18}$ ]]; then
		return 0
	fi
	POSTER_LOGIN=""
	POSTER_ID=""
	echo "::warning::post-pr-comment: could not determine the account this token posts as (GraphQL viewer: ${reason}); no existing comment is updated or deleted (upsert posts a new comment, update and delete-on-empty skip)"
}

# Put BLOCK into BODY under its first heading: the first line that is not
# blank and not a one-line HTML comment, when it is an ATX heading. Otherwise
# BLOCK goes at the top. Blank lines separate it from what is around it.
# Usage: insert_fields_block BODY BLOCK
insert_fields_block() {
	local body="$1" block="$2" rest="$1" head="" line next
	local comment_re='^[[:space:]]*<!--.*-->[[:space:]]*$'
	local heading_re='^ {0,3}#{1,6}([[:space:]]|$)'
	while [[ -n "$rest" ]]; do
		line="${rest%%$'\n'*}"
		next=""
		[[ "$line" == "$rest" ]] || next="${rest#*$'\n'}"
		if [[ -z "${line//[[:space:]]/}" || "$line" =~ $comment_re ]]; then
			head+="${line}"$'\n'
			rest="$next"
			continue
		fi
		if [[ "$line" =~ $heading_re ]]; then
			while [[ "$next" == $'\n'* ]]; do
				next="${next#$'\n'}"
			done
			printf '%s%s\n\n%s' "$head" "$line" "$block"
			[[ -z "$next" ]] || printf '\n\n%s' "$next"
			return 0
		fi
		break
	done
	printf '%s\n\n%s' "$block" "$body"
}

# Fixed stand-ins, written by lgtm-ci, for when the renderer cannot run or
# the block does not fit. FIELDS_UNREADABLE_STAMP is base64 of
# {"v":1,"f":[],"n":0,"u":1}: the history line then says "fields unreadable".
FIELDS_UNREADABLE_STAMP="eyJ2IjoxLCJmIjpbXSwibiI6MCwidSI6MX0="
# The comment-fields budget of #1703, in characters, and the room kept for
# the marker line and the history stamp. It was set as GitHub's limit, which
# is in fact 262,144 bytes (COMMENT_MAX_BYTES); it is kept as a conservative
# budget for the block and its note, not as the limit on the comment.
FIELDS_COMMENT_BUDGET=65536
COMMENT_HEADROOM=2048
# Room kept beside the short size-limit note: the marker line and the stamp
# line only, since the note stands in for the block.
COMMENT_NOTE_HEADROOM=512

# A note in place of the fields, with the run link; logs one ::warning.
# Usage: fields_fallback REASON
fields_fallback() {
	local reason="$1" link=""
	if [[ "$FIELDS_RUN_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/actions/runs/[0-9]+$ ]]; then
		link=" ([job log](${FIELDS_RUN_URL}))"
	fi
	FIELDS_BLOCK="> ⚠️ \`comment-fields\` could not be read: ${reason}${link}"
	FIELDS_STAMP="$FIELDS_UNREADABLE_STAMP"
	echo "::warning title=comment-fields::comment-fields could not be read: ${reason}; no field is shown"
}

# Run the renderer into FIELDS_BLOCK and FIELDS_STAMP. Never fails: a missing
# temporary directory, a renderer that exits non-zero or writes no block
# file, all give the fixed note and one warning.
render_comment_fields() {
	local dir=""
	FIELDS_BLOCK=""
	FIELDS_STAMP=""
	dir="$(mktemp -d 2>/dev/null)" || dir=""
	if [[ -z "$dir" || ! -d "$dir" ]]; then
		fields_fallback "internal error, see the job log"
		return 0
	fi
	if COMMENT_FIELDS_RUN_URL="$FIELDS_RUN_URL" comment_fields render --env COMMENT_FIELDS \
		--style block --out "${dir}/block" --stamp "${dir}/stamp" &&
		[[ -f "${dir}/block" ]]; then
		FIELDS_BLOCK="$(cat "${dir}/block" 2>/dev/null)" || FIELDS_BLOCK=""
		FIELDS_STAMP="$(cat "${dir}/stamp" 2>/dev/null)" || FIELDS_STAMP=""
		[[ "$FIELDS_STAMP" =~ ^[A-Za-z0-9+/=]*$ ]] || FIELDS_STAMP=""
	else
		fields_fallback "internal error, see the job log"
	fi
	rm -rf "$dir"
}

# Parse COMMENT_FIELDS with the shared renderer and insert its block into
# COMMENT_BODY; sets FIELDS_STAMP for the history line. A bad line, an
# unreadable input or a renderer failure never fails the step: a note takes
# the place of the fields and the reasons are logged with one ::warning. The
# renderer caps the block (about 4,000 characters); when the body is already
# so large that the block would pass FIELDS_COMMENT_BUDGET, a short note
# replaces it, and when not even the note fits the report is posted as it is.
add_comment_fields() {
	export COMMENT_FIELDS
	# shellcheck source=../lib/github/comment_fields.sh
	source "${SCRIPT_DIR}/../lib/github/comment_fields.sh"
	FIELDS_RUN_URL=""
	if [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]]; then
		FIELDS_RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	fi
	render_comment_fields
	local total=$((${#COMMENT_BODY} + ${#FIELDS_BLOCK} + ${#FIELDS_STAMP} + COMMENT_HEADROOM))
	if [[ -n "$FIELDS_BLOCK" ]] && ((total > FIELDS_COMMENT_BUDGET)); then
		fields_fallback "the comment is at GitHub's size limit"
		# The note is text too. A report that fits on its own must never be
		# pushed over the limit by it: when even the note has no room, nothing
		# is added and the warning above is the only trace.
		total=$((${#COMMENT_BODY} + ${#FIELDS_BLOCK} + ${#FIELDS_STAMP} + COMMENT_NOTE_HEADROOM))
		if ((total > FIELDS_COMMENT_BUDGET)); then
			FIELDS_BLOCK=""
			FIELDS_STAMP=""
			echo "comment-fields: the report leaves no room for a note; the comment is posted without one"
		fi
	fi
	if [[ -n "$FIELDS_BLOCK" ]]; then
		COMMENT_BODY="$(insert_fields_block "$COMMENT_BODY" "$FIELDS_BLOCK")"
	fi
}

# Compose the history body from NEW_BODY_FILE over EXISTING_BODY (stdin of
# the composer). The composer holds it to MAX_BYTES (default
# HISTORY_MAX_BYTES, else 60,000), and never above GitHub's limit.
# Usage: compose_history SUMMARY FIELDS_STAMP [MAX_BYTES]
compose_history() {
	printf '%s' "$EXISTING_BODY" |
		NEW_BODY_FILE="$NEW_BODY_FILE" \
			MARKER_TAG="$MARKER_TAG" \
			HISTORY_LIMIT="${HISTORY_LIMIT:-3}" \
			HISTORY_SUMMARY="$1" \
			HISTORY_FIELDS="$2" \
			HISTORY_MAX_BYTES="${3:-${HISTORY_MAX_BYTES:-60000}}" \
			HISTORY_NOW="$HISTORY_NOW" \
			HEAD_SHA="${EVENT_PULL_REQUEST_HEAD_SHA:-${GITHUB_SHA:-unknown}}" \
			RUN_ID="$RUN_ID" \
			RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}" \
			RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}" \
			RUN_URL="$RUN_URL" \
			bash "${SCRIPT_DIR}/post-pr-comment-history.sh"
}

# Byte length of TEXT; prints nothing when it cannot be measured.
# Usage: byte_length TEXT
byte_length() {
	local n
	n="$(printf '%s' "$1" | wc -c | tr -d '[:space:]')" || n=""
	if [[ "$n" =~ ^[0-9]+$ ]]; then
		printf '%s' "$n"
	fi
}

# Measure FULL_BODY as GitHub will store it and prepare it for the API
# (#1705). Sets BODY_BYTES to that size, or to "" when it cannot be measured.
# A body within COMMENT_FIELD_MAX_BYTES goes as `-f body=` (PAYLOAD_JSON
# empty). A larger one is encoded by jq into PAYLOAD_JSON and measured there:
# jq replaces invalid UTF-8 with U+FFFD, which can make it longer than the
# bytes it came from, so what is measured is exactly what is sent. Returns 1
# when the body is over COMMENT_MAX_BYTES or cannot be measured.
prepare_payload() {
	local bytes
	PAYLOAD_JSON=""
	BODY_BYTES="$(byte_length "$FULL_BODY")"
	[[ -n "$BODY_BYTES" ]] || return 1
	if ((BODY_BYTES <= COMMENT_FIELD_MAX_BYTES)); then
		return 0
	fi
	if ((BODY_BYTES > COMMENT_MAX_BYTES)); then
		return 1
	fi
	BODY_BYTES=""
	if [[ -z "$PAYLOAD_FILE" ]]; then
		PAYLOAD_FILE="$(mktemp)"
		TEMP_FILES+=("$PAYLOAD_FILE")
	fi
	if ! printf '%s' "$FULL_BODY" |
		jq -cn --rawfile body /dev/stdin '{body: $body}' >"$PAYLOAD_FILE" 2>/dev/null; then
		return 1
	fi
	bytes="$(jq -j '.body | utf8bytelength' "$PAYLOAD_FILE" 2>/dev/null)" || bytes=""
	[[ "$bytes" =~ ^[0-9]+$ ]] || return 1
	BODY_BYTES="$bytes"
	((BODY_BYTES <= COMMENT_MAX_BYTES)) || return 1
	PAYLOAD_JSON="$PAYLOAD_FILE"
}

# Create (POST) or update (PATCH) a comment with FULL_BODY as prepared by
# prepare_payload; prints the API response.
# Usage: api_write METHOD PATH
api_write() {
	if [[ -n "$PAYLOAD_JSON" ]]; then
		gh api \
			-X "$1" \
			-H "Accept: application/vnd.github+json" \
			-H "Content-Type: application/json" \
			"$2" \
			--input "$PAYLOAD_JSON"
	else
		gh api \
			-X "$1" \
			-H "Accept: application/vnd.github+json" \
			"$2" \
			-f body="$FULL_BODY"
	fi
}

# 262144 -> 262,144
group_digits() {
	local n="$1" out=""
	while ((${#n} > 3)); do
		out=",${n: -3}${out}"
		n="${n:0:${#n}-3}"
	done
	printf '%s%s' "$n" "$out"
}

# How large the replaced summary was, for the notice and the log.
# Usage: replaced_size BYTES STATE   (STATE: over or unmeasured)
replaced_size() {
	if [[ "$2" == "unmeasured" ]]; then
		printf 'could not be measured'
	elif [[ -n "$1" ]]; then
		printf 'is %s bytes' "$(group_digits "$1")"
	else
		printf 'is over that limit'
	fi
}

# The fixed text posted in place of a body over GitHub's limit. Written by
# lgtm-ci from values it checks here (a byte count, a commit id, a run link),
# so nothing from the body reaches it. It states no result: the poster cannot
# know one, and a result from an earlier run does not apply to this one.
# Usage: oversized_notice BYTES STATE
oversized_notice() {
	local sha="${EVENT_PULL_REQUEST_HEAD_SHA:-${GITHUB_SHA:-}}"
	local run="this run" outcome="this pull request's checks"
	local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
	if [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]]; then
		run="this run (commit \`${sha:0:7}\`)"
	fi
	if [[ "$run_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/actions/runs/[0-9]+$ ]]; then
		outcome="the [workflow run](${run_url})"
	fi
	printf '%s\n\n%s\n%s\n%s\n%s\n' "### ⚠️ Summary too long to post" "> [!WARNING]" \
		"> GitHub accepts at most $(group_digits "$COMMENT_MAX_BYTES") bytes in one comment." \
		"> The summary for ${run} $(replaced_size "$1" "$2"), so it is not shown." \
		"> **No result is shown for this run**, and no earlier result applies to it: see ${outcome} for the outcome."
}

# Replace FULL_BODY with the notice: the marker line first, so the upsert
# overwrites the stale comment and the next run finds it, and with history
# the stamp and the archive of earlier runs. The stamp keeps no
# history-summary and no fields: they describe the body that is not shown.
# Sets REPLACED; the step fails once the notice is posted. When not even the
# notice can be posted, fails now with one ::error and posts nothing.
# Usage: replace_oversized_body BYTES STATE
replace_oversized_body() {
	local notice
	REPLACED=true
	REPLACED_TEXT="$(replaced_size "$1" "$2")"
	notice="$(oversized_notice "$1" "$2")"
	if [[ "$HISTORY_ENABLED" == "true" ]]; then
		printf '%s\n' "$notice" >"$NEW_BODY_FILE"
		FULL_BODY="$(compose_history "" "")"
		if ! prepare_payload; then
			FULL_BODY="$(compose_history "" "" 0)"
		fi
	else
		FULL_BODY="${MARKER_TAG}
${notice}"
	fi
	if ! prepare_payload; then
		echo "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most $(group_digits "$COMMENT_MAX_BYTES") bytes in one comment, and the summary for this run ${REPLACED_TEXT}. The notice that would replace it cannot be measured within the limit either, so nothing was posted and the previous comment is unchanged."
		exit 1
	fi
}

# A body that is empty, as opposed to one over the limit and not read.
body_is_empty() {
	[[ -z "${COMMENT_BODY:-}" && "$BODY_OVERSIZED" != "true" ]]
}

# create mode with a body never reads existing comments.
if [[ "$MODE" != "create" ]] || body_is_empty; then
	resolve_poster

	# Read every page of comments. A listing miss would post a duplicate or,
	# with history, lose the archive, so a listing error fails the step.
	if ! COMMENTS_JSON=$(gh api \
		--paginate \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100" |
		jq -s 'add // []'); then
		echo "::error::Could not list comments on PR #${PR_NUMBER}; refusing to post without knowing which comment is ours"
		exit 1
	fi

	# Own marker comments, oldest first: written by POSTER_LOGIN with id
	# POSTER_ID and opened by the marker line exactly (a trailing CR is
	# tolerated). Empty when the identity is unknown.
	OWN_COMMENTS_JSON=$(jq -c --arg marker "$MARKER_TAG" --arg login "$POSTER_LOGIN" \
		--arg id "$POSTER_ID" '
		if $login == "" or $id == "" then [] else
			[.[] | select(((.user.login // "") == $login)
				and (((.user.id // "") | tostring) == $id)
				and (((.body // "") | split("\n")[0] | rtrimstr("\r")) == $marker))]
		end' <<<"$COMMENTS_JSON")
fi
EXISTING_COMMENT_IDS=$(jq -r '.[].id' <<<"$OWN_COMMENTS_JSON")

if [[ "$HISTORY_ENABLED" == "true" ]]; then
	# Survivor: the newest own marker comment carrying a history stamp or
	# archive, else the newest own marker comment.
	EXISTING_COMMENT_ID=$(jq -r '
		. as $matches
		| ([$matches[] | select(.body | test("<!-- lgtm-ci:history:(latest |start -->)"))]) as $stamped
		| (if ($stamped | length) > 0 then $stamped else $matches end)
		| max_by(.id) // empty | .id' <<<"$OWN_COMMENTS_JSON")
else
	EXISTING_COMMENT_ID=$(head -1 <<<"$EXISTING_COMMENT_IDS")
fi

# Handle empty body
if body_is_empty; then
	if [[ "$DELETE_ON_EMPTY" == "true" && -n "$EXISTING_COMMENT_ID" ]]; then
		# Overlapping runs can each create a marker comment, so delete every
		# own match on every page, archive included. An overlapping run may
		# already have deleted one; that DELETE gets a 404 because the
		# comment is gone. Any other error still fails.
		while read -r comment_id; do
			if DELETE_ERROR=$(gh api \
				-X DELETE \
				"/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" 2>&1 >/dev/null); then
				echo "Deleted comment $comment_id"
			elif [[ "$DELETE_ERROR" == *"HTTP 404"* ]]; then
				echo "Comment $comment_id was already deleted"
			else
				echo "$DELETE_ERROR" >&2
				exit 1
			fi
		done <<<"$EXISTING_COMMENT_IDS"
		echo "action-taken=deleted" >>"$GITHUB_OUTPUT"
		exit 0
	else
		echo "action-taken=skipped" >>"$GITHUB_OUTPUT"
		echo "Skipped: empty body"
		exit 0
	fi
fi

# Caller fields (#1677), added only now: the marker alone decides which
# comment is ours and the report alone decides delete-on-empty above. With
# COMMENT_FIELDS unset or blank nothing here runs, so the body is unchanged.
# A report over GitHub's limit on its own is replaced below, fields and all,
# so they are not rendered for it: the log then reports the size once.
FIELDS_STAMP=""
FIELDS_INPUT="${COMMENT_FIELDS:-}"
if [[ -n "${FIELDS_INPUT//[[:space:]]/}" && "$BODY_OVERSIZED" != "true" ]]; then
	REPORT_BYTES="$(byte_length "${MARKER_TAG}"$'\n'"${COMMENT_BODY}")"
	if [[ -n "$REPORT_BYTES" ]] && ((REPORT_BYTES <= COMMENT_MAX_BYTES)); then
		add_comment_fields
	fi
fi

# Prepare full comment body with marker
FULL_BODY=""
if [[ "$HISTORY_ENABLED" == "true" ]]; then
	EXISTING_BODY=""
	if [[ "$MODE" != "create" && -n "$EXISTING_COMMENT_ID" ]]; then
		# Overlapping runs can each create a marker comment. The survivor is
		# rewritten below; the other duplicates are deleted only once that
		# write has succeeded (see the end of this script).
		DELETE_DUPLICATES=true
		EXISTING_BODY=$(jq -r --argjson id "$EXISTING_COMMENT_ID" \
			'.[] | select(.id == $id) | .body' <<<"$OWN_COMMENTS_JSON")
	fi
	NEW_BODY_FILE="$(mktemp)"
	TEMP_FILES+=("$NEW_BODY_FILE")
	RUN_ID="${GITHUB_RUN_ID:-0}"
	RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}"
	HISTORY_NOW="${HISTORY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
	if [[ "$BODY_OVERSIZED" != "true" ]]; then
		printf '%s\n' "$COMMENT_BODY" >"$NEW_BODY_FILE"
		FULL_BODY=$(compose_history "${HISTORY_SUMMARY:-}" "$FIELDS_STAMP")
	fi
elif [[ "$BODY_OVERSIZED" != "true" ]]; then
	FULL_BODY="${MARKER_TAG}
${COMMENT_BODY}"
fi

# GitHub rejects a comment over its limit, and the comment of the previous run
# would stay up with a result that is no longer current (#1705). History is
# trimmed first: the composer drops archive entries, oldest first, then the
# archive; only a result too long on its own is replaced by the notice. A
# body that fits is posted unchanged. Checked only when something is written:
# update mode without a comment, and an unknown mode, skip below.
REPLACED=false
PAYLOAD_JSON=""
if [[ "$MODE" == "create" || "$MODE" == "upsert" ||
	("$MODE" == "update" && -n "$EXISTING_COMMENT_ID") ]]; then
	if [[ "$BODY_OVERSIZED" == "true" ]]; then
		replace_oversized_body "$BODY_FILE_BYTES" over
	elif ! prepare_payload; then
		if [[ "$HISTORY_ENABLED" == "true" && -n "$BODY_BYTES" ]]; then
			# The composer counts bytes before jq encodes the body; invalid
			# UTF-8 can grow in the encoding. Drop the archive before the
			# result itself is replaced.
			FULL_BODY=$(compose_history "${HISTORY_SUMMARY:-}" "$FIELDS_STAMP" 0)
			if ! prepare_payload; then
				replace_oversized_body "$BODY_BYTES" over
			fi
		elif [[ -n "$BODY_BYTES" ]]; then
			replace_oversized_body "$BODY_BYTES" over
		else
			replace_oversized_body "" unmeasured
		fi
	fi
fi

# A failed write fails the step. When the notice was being written, say so:
# the previous comment is still up.
# Usage: write_failed [MESSAGE]
write_failed() {
	if [[ "$REPLACED" == "true" ]]; then
		echo "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most $(group_digits "$COMMENT_MAX_BYTES") bytes in one comment, and the summary for this run ${REPLACED_TEXT}. Posting the notice that replaces it failed too (${1:-the API call failed}); the previous comment is unchanged."
	elif [[ -n "${1:-}" ]]; then
		echo "::error::${1}"
	fi
	exit 1
}

# Perform action based on mode
if [[ "$MODE" == "create" || ("$MODE" == "upsert" && -z "$EXISTING_COMMENT_ID") ]]; then
	# Create new comment
	RESPONSE=$(api_write POST "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments") ||
		write_failed ""

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
	if [[ -z "$COMMENT_ID" ]]; then
		write_failed "Failed to create comment - invalid API response"
	fi
	echo "action-taken=created" >>"$GITHUB_OUTPUT"
	echo "Created comment $COMMENT_ID"

elif [[ "$MODE" == "update" || "$MODE" == "upsert" ]] && [[ -n "$EXISTING_COMMENT_ID" ]]; then
	# Update existing comment
	RESPONSE=$(api_write PATCH "/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_COMMENT_ID}") ||
		write_failed ""

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
	if [[ -z "$COMMENT_ID" ]]; then
		write_failed "Failed to update comment - invalid API response"
	fi
	echo "action-taken=updated" >>"$GITHUB_OUTPUT"
	echo "Updated comment $COMMENT_ID"

else
	echo "action-taken=skipped" >>"$GITHUB_OUTPUT"
	echo "Skipped: no existing comment to update"
	exit 0
fi

echo "comment-id=$COMMENT_ID" >>"$GITHUB_OUTPUT"
echo "comment-url=$COMMENT_URL" >>"$GITHUB_OUTPUT"

# History mode: the survivor now holds this run's result, so our other marker
# comments can go. A failed write exits above and deletes nothing.
# EXISTING_COMMENT_IDS holds only our own comments. Losing a DELETE race
# (404) or a 403 is not worth failing the publish.
if [[ "${DELETE_DUPLICATES:-false}" == "true" ]]; then
	while read -r comment_id; do
		[[ -z "$comment_id" || "$comment_id" == "$EXISTING_COMMENT_ID" ]] && continue
		if DELETE_ERROR=$(gh api \
			-X DELETE \
			"/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" 2>&1 >/dev/null); then
			echo "Deleted duplicate comment $comment_id"
		elif [[ "$DELETE_ERROR" == *"HTTP 404"* || "$DELETE_ERROR" == *"HTTP 403"* ]]; then
			echo "::warning::Could not delete duplicate comment ${comment_id}: ${DELETE_ERROR}"
		else
			echo "$DELETE_ERROR" >&2
			exit 1
		fi
	done <<<"$EXISTING_COMMENT_IDS"
fi

# The notice is up and the stale result is gone; the step still fails, so an
# oversized report turns the job red as an unposted one did before (#1705).
if [[ "$REPLACED" == "true" ]]; then
	echo "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most $(group_digits "$COMMENT_MAX_BYTES") bytes in one comment, and the summary for this run ${REPLACED_TEXT}. A notice with no result was posted in its place (comment ${COMMENT_ID}); see this run's log for the outcome."
	exit 1
fi
