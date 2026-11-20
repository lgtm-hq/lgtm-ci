#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post or update a PR comment with marker-based identification
#
# Environment variables:
#   STEP - Which step to run: pr-number, read-file or post
#   GH_TOKEN - GitHub token for API access
#   GITHUB_REPOSITORY - Repository in owner/repo format
#   COMMENT_FILE - File holding the comment body (read-file step)
#   FILE_PROVIDED, BODY_FROM_FILE, BODY_FROM_INPUT - Comment body (post step)
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
# Size (#1705): a final body over GitHub's limit (65,536 characters) is never
# sent. A short notice that states no result takes its place, keeping the
# marker line and, with HISTORY=true, the stamp and archive; one ::warning.

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

# Determine COMMENT_BODY: prefer file content when file was provided (even if empty)
if [[ "${FILE_PROVIDED:-}" == "true" ]]; then
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
# GitHub's limit on a comment body, in characters, and the room kept for the
# marker line and the history stamp.
COMMENT_MAX_CHARS=65536
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
# so large that the block would push the comment past GitHub's limit, a short
# note replaces it, and when not even the note fits the report is posted as
# it is.
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
	if [[ -n "$FIELDS_BLOCK" ]] && ((total > COMMENT_MAX_CHARS)); then
		fields_fallback "the comment is at GitHub's size limit"
		# The note is text too. A report that fits on its own must never be
		# pushed over the limit by it: when even the note has no room, nothing
		# is added and the warning above is the only trace.
		total=$((${#COMMENT_BODY} + ${#FIELDS_BLOCK} + ${#FIELDS_STAMP} + COMMENT_NOTE_HEADROOM))
		if ((total > COMMENT_MAX_CHARS)); then
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
# the composer). HISTORY_MAX_CHARS lets the composer drop its size note when
# that note alone would push a fitting body over GitHub's limit.
# Usage: compose_history SUMMARY FIELDS_STAMP [MAX_BYTES]
compose_history() {
	printf '%s' "$EXISTING_BODY" |
		NEW_BODY_FILE="$NEW_BODY_FILE" \
			MARKER_TAG="$MARKER_TAG" \
			HISTORY_LIMIT="${HISTORY_LIMIT:-3}" \
			HISTORY_SUMMARY="$1" \
			HISTORY_FIELDS="$2" \
			HISTORY_MAX_BYTES="${3:-${HISTORY_MAX_BYTES:-60000}}" \
			HISTORY_MAX_CHARS="$COMMENT_MAX_CHARS" \
			HISTORY_NOW="$HISTORY_NOW" \
			HEAD_SHA="${EVENT_PULL_REQUEST_HEAD_SHA:-${GITHUB_SHA:-unknown}}" \
			RUN_ID="$RUN_ID" \
			RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}" \
			RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}" \
			RUN_URL="$RUN_URL" \
			bash "${SCRIPT_DIR}/post-pr-comment-history.sh"
}

# Whether BODY is within GitHub's limit (COMMENT_MAX_CHARS characters). The
# count is never below GitHub's: a character outside the Basic Multilingual
# Plane counts 2 (a UTF-16 surrogate pair). A body within the limit in bytes
# fits without counting. Sets BODY_CHARS to the count, or to "" when the body
# is over the limit in bytes and its characters cannot be counted: that body
# counts as not fitting.
# Usage: body_fits BODY
body_fits() {
	local bytes
	BODY_CHARS=""
	bytes="$(printf '%s' "$1" | wc -c | tr -d '[:space:]')" || bytes=""
	if [[ "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= COMMENT_MAX_CHARS)); then
		BODY_CHARS="$bytes"
		return 0
	fi
	# --rawfile, not -R: jq 1.7 -R splits a multibyte character that crosses
	# its 64 KiB read boundary into two replacement characters.
	BODY_CHARS="$(printf '%s' "$1" | jq -nj --rawfile body /dev/stdin \
		'[$body | explode[] | if . > 65535 then 2 else 1 end] | add // 0' 2>/dev/null)" ||
		BODY_CHARS=""
	[[ "$BODY_CHARS" =~ ^[0-9]+$ ]] || BODY_CHARS=""
	[[ -n "$BODY_CHARS" ]] && ((BODY_CHARS <= COMMENT_MAX_CHARS))
}

# 65536 -> 65,536
group_digits() {
	local n="$1" out=""
	while ((${#n} > 3)); do
		out=",${n: -3}${out}"
		n="${n:0:${#n}-3}"
	done
	printf '%s%s' "$n" "$out"
}

# The fixed text posted in place of a body over GitHub's limit. Written by
# lgtm-ci from values it checks here (a count, a commit id, a run link), so
# nothing from the body reaches it. It states no result: the poster cannot
# know one, and a result from an earlier run does not apply to this one.
# Usage: oversized_notice CHARS
oversized_notice() {
	local chars="$1" limit size sha="${EVENT_PULL_REQUEST_HEAD_SHA:-${GITHUB_SHA:-}}"
	local run="this run" outcome="this pull request's checks"
	local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
	limit="$(group_digits "$COMMENT_MAX_CHARS")"
	if [[ -n "$chars" ]]; then
		size="is $(group_digits "$chars") characters, over GitHub's limit of ${limit} for one comment"
	else
		size="could not be measured and may be over GitHub's limit of ${limit} characters for one comment"
	fi
	if [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]]; then
		run="this run (commit \`${sha:0:7}\`)"
	fi
	if [[ "$run_url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/actions/runs/[0-9]+$ ]]; then
		outcome="the [workflow run](${run_url})"
	fi
	printf '%s\n\n%s\n%s\n%s\n' "### ⚠️ Summary too long to post" "> [!WARNING]" \
		"> The summary for ${run} ${size}, so it is not shown." \
		"> **No result is shown for this run**, and no earlier result applies to it: see ${outcome} for the outcome."
}

# Replace FULL_BODY, over GitHub's limit, with the notice: the marker line
# first, so the upsert overwrites the stale comment and the next run finds it,
# and with history the stamp and the archive of earlier runs. The stamp keeps
# no history-summary and no fields: they describe the body that is not shown.
# Raises one ::warning. Exits non-zero only if even the notice does not fit.
replace_oversized_body() {
	local chars="$BODY_CHARS" notice size_text
	notice="$(oversized_notice "$chars")"
	if [[ "$HISTORY_ENABLED" == "true" ]]; then
		printf '%s\n' "$notice" >"$NEW_BODY_FILE"
		FULL_BODY="$(compose_history "" "")"
		if ! body_fits "$FULL_BODY"; then
			# The archive is held to its byte budget, so this is unexpected;
			# drop the archive rather than post nothing.
			FULL_BODY="$(compose_history "" "" 0)"
		fi
	else
		FULL_BODY="${MARKER_TAG}
${notice}"
	fi
	if ! body_fits "$FULL_BODY"; then
		echo "::error::post-pr-comment: the size-limit notice does not fit in a comment; nothing is posted"
		exit 1
	fi
	size_text="its size could not be measured"
	[[ -z "$chars" ]] || size_text="$(group_digits "$chars") characters"
	echo "::warning title=post-pr-comment::The comment body is over GitHub's limit of $(group_digits "$COMMENT_MAX_CHARS") characters (${size_text}); a notice that the summary was too long to post, with no result, was posted in its place. See this run for the outcome."
}

# create mode with a body never reads existing comments.
if [[ "$MODE" != "create" || -z "$COMMENT_BODY" ]]; then
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
if [[ -z "${COMMENT_BODY:-}" ]]; then
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
FIELDS_STAMP=""
FIELDS_INPUT="${COMMENT_FIELDS:-}"
if [[ -n "${FIELDS_INPUT//[[:space:]]/}" ]]; then
	add_comment_fields
fi

# Prepare full comment body with marker
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
	trap 'rm -f "$NEW_BODY_FILE"' EXIT
	printf '%s\n' "$COMMENT_BODY" >"$NEW_BODY_FILE"
	RUN_ID="${GITHUB_RUN_ID:-0}"
	RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}"
	HISTORY_NOW="${HISTORY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
	FULL_BODY=$(compose_history "${HISTORY_SUMMARY:-}" "$FIELDS_STAMP")
else
	FULL_BODY="${MARKER_TAG}
${COMMENT_BODY}"
fi

# GitHub rejects a comment over its limit, and the comment of the previous run
# would stay up with a result that is no longer current (#1705). History is
# trimmed first (the composer above); only a body too long on its own is
# replaced by the notice. A body that fits is posted unchanged. Checked only
# when something is written: update mode without a comment, and an unknown
# mode, skip below.
if [[ "$MODE" == "create" || "$MODE" == "upsert" ||
	("$MODE" == "update" && -n "$EXISTING_COMMENT_ID") ]] && ! body_fits "$FULL_BODY"; then
	replace_oversized_body
fi

# Perform action based on mode
if [[ "$MODE" == "create" || ("$MODE" == "upsert" && -z "$EXISTING_COMMENT_ID") ]]; then
	# Create new comment
	RESPONSE=$(gh api \
		-X POST \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
		-f body="$FULL_BODY")

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
	if [[ -z "$COMMENT_ID" ]]; then
		echo "::error::Failed to create comment - invalid API response"
		exit 1
	fi
	echo "action-taken=created" >>"$GITHUB_OUTPUT"
	echo "Created comment $COMMENT_ID"

elif [[ "$MODE" == "update" || "$MODE" == "upsert" ]] && [[ -n "$EXISTING_COMMENT_ID" ]]; then
	# Update existing comment
	RESPONSE=$(gh api \
		-X PATCH \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_COMMENT_ID}" \
		-f body="$FULL_BODY")

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
	if [[ -z "$COMMENT_ID" ]]; then
		echo "::error::Failed to update comment - invalid API response"
		exit 1
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
