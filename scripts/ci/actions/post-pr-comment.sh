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
#
# Ownership (#1674): a comment is this publisher's only when its first line is
# exactly the marker line and its author is the account GH_TOKEN posts as.
# No other comment is ever updated or deleted. The body may not carry the
# reserved <!-- lgtm-ci: namespace; any occurrence is neutralised.

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
		body="$(
			cat "$COMMENT_FILE"
			printf x
		)"
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

# Reserve the namespace (#1674). A copy of our own marker line heading the
# body is redundant (we write it) and is dropped. Every other <!-- lgtm-ci:
# becomes visible text (`< !--`), so it can neither match a publisher nor
# forge a history stamp.
case "$COMMENT_BODY" in
"$MARKER_TAG") COMMENT_BODY="" ;;
"$MARKER_TAG"$'\n'*) COMMENT_BODY="${COMMENT_BODY#"$MARKER_TAG"$'\n'}" ;;
"$MARKER_TAG"$'\r\n'*) COMMENT_BODY="${COMMENT_BODY#"$MARKER_TAG"$'\r\n'}" ;;
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
# GET /installation need the App's JWT. Logins are unique and only App bots
# end in [bot], so an exact login match never takes another account's
# comment. Unknown identity fails closed: no comment counts as ours.
POSTER_LOGIN=""
OWN_COMMENTS_JSON="[]"
# create mode with a body never reads existing comments.
if [[ "$MODE" != "create" || -z "$COMMENT_BODY" ]]; then
	if VIEWER_JSON=$(gh api graphql -f query='query { viewer { login } }' 2>/dev/null); then
		POSTER_LOGIN=$(jq -r '.data.viewer.login // empty' <<<"$VIEWER_JSON" 2>/dev/null || true)
	fi
	if [[ ! "$POSTER_LOGIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\[bot\])?$ ]]; then
		POSTER_LOGIN=""
		echo "::warning::post-pr-comment: could not determine the account this token posts as (GraphQL viewer); no existing comment is updated or deleted (upsert posts a new comment, update and delete-on-empty skip)"
	fi

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

	# Own marker comments, oldest first: written by POSTER_LOGIN and opened
	# by the marker line exactly (a trailing CR is tolerated). Empty when the
	# identity is unknown.
	OWN_COMMENTS_JSON=$(jq -c --arg marker "$MARKER_TAG" --arg login "$POSTER_LOGIN" '
		if $login == "" then [] else
			[.[] | select(((.user.login // "") == $login)
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
	FULL_BODY=$(printf '%s' "$EXISTING_BODY" |
		NEW_BODY_FILE="$NEW_BODY_FILE" \
			MARKER_TAG="$MARKER_TAG" \
			HISTORY_LIMIT="${HISTORY_LIMIT:-3}" \
			HISTORY_SUMMARY="${HISTORY_SUMMARY:-}" \
			HISTORY_NOW="${HISTORY_NOW:-}" \
			HEAD_SHA="${EVENT_PULL_REQUEST_HEAD_SHA:-${GITHUB_SHA:-unknown}}" \
			RUN_ID="$RUN_ID" \
			RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}" \
			RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}" \
			RUN_URL="$RUN_URL" \
			bash "${SCRIPT_DIR}/post-pr-comment-history.sh")
else
	FULL_BODY="${MARKER_TAG}
${COMMENT_BODY}"
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
