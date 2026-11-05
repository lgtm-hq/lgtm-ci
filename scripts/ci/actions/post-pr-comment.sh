#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post or update a PR comment with marker-based identification
#
# Environment variables:
#   STEP - Which step to run: pr-number or post
#   GH_TOKEN - GitHub token for API access
#   GITHUB_REPOSITORY - Repository in owner/repo format
#   COMMENT_BODY - Comment body content
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

set -euo pipefail

: "${STEP:=post}"

# -----------------------------------------------------------------------------
# Step: read-file - Read comment body from file
# -----------------------------------------------------------------------------
if [[ "$STEP" == "read-file" ]]; then
	: "${COMMENT_FILE:?COMMENT_FILE is required}"
	echo "file_provided=true" >>"$GITHUB_OUTPUT"
	if [[ ! -f "$COMMENT_FILE" ]]; then
		echo "::warning::Comment file not found: $COMMENT_FILE"
		echo "body=" >>"$GITHUB_OUTPUT"
	else
		EOF_MARKER="LGTM_EOF_$$_$(date +%s)"
		{
			echo "body<<$EOF_MARKER"
			cat "$COMMENT_FILE"
			echo "$EOF_MARKER"
		} >>"$GITHUB_OUTPUT"
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

# Determine COMMENT_BODY: prefer file content when file was provided (even if empty)
if [[ "${FILE_PROVIDED:-}" == "true" ]]; then
	COMMENT_BODY="${BODY_FROM_FILE:-}"
else
	COMMENT_BODY="${BODY_FROM_INPUT:-}"
fi

# Create marker comment (hidden in rendered markdown)
MARKER_TAG="<!-- lgtm-ci:${MARKER} -->"

HISTORY_ENABLED=false
DELETE_DUPLICATES=false
if [[ "${HISTORY:-false}" == "true" ]]; then
	HISTORY_ENABLED=true
fi

if [[ "$HISTORY_ENABLED" == "true" ]]; then
	# History mode reads the comment it rewrites, so a listing miss would
	# lose the archive or create a second comment: read every page and fail
	# closed on any listing error.
	if ! COMMENTS_JSON=$(gh api \
		--paginate \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100" |
		jq -s 'add // []'); then
		echo "::error::Could not list comments on PR #${PR_NUMBER}; refusing to post without the existing history"
		exit 1
	fi
	EXISTING_COMMENT_IDS=$(jq -r --arg marker "$MARKER_TAG" \
		'.[] | select(.body | contains($marker)) | .id' <<<"$COMMENTS_JSON")
	# Survivor: the newest marker comment carrying a history stamp or archive,
	# else the newest marker comment.
	EXISTING_COMMENT_ID=$(jq -r --arg marker "$MARKER_TAG" '
		[.[] | select(.body | contains($marker))] as $matches
		| ([$matches[] | select(.body | test("<!-- lgtm-ci:history:(latest |start -->)"))]) as $stamped
		| (if ($stamped | length) > 0 then $stamped else $matches end)
		| max_by(.id) // empty | .id' <<<"$COMMENTS_JSON")
else
	# Find existing comment with this marker
	# Use jq --arg to safely pass marker and avoid command injection
	EXISTING_COMMENT_IDS=$(gh api \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
		2>/dev/null | jq -r --arg marker "$MARKER_TAG" '.[] | select(.body | contains($marker)) | .id' || echo "")
	EXISTING_COMMENT_ID=$(head -1 <<<"$EXISTING_COMMENT_IDS")
fi

# Handle empty body
if [[ -z "${COMMENT_BODY:-}" ]]; then
	if [[ "$DELETE_ON_EMPTY" == "true" && -n "$EXISTING_COMMENT_ID" ]]; then
		# Overlapping runs can each create a marker comment, so delete every
		# match the listing returned, archive included. Without HISTORY the
		# listing reads only the first page of comments, so a match on a later
		# page is not found. An overlapping run may already have deleted one;
		# that DELETE gets a 404 because the comment is gone. Any other error
		# still fails.
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
			'.[] | select(.id == $id) | .body' <<<"$COMMENTS_JSON")
	fi
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# History mode: the survivor now holds this run's result, so the other marker
# comments can go. A failed write exits above and deletes nothing. Losing a
# DELETE race or lacking permission on someone else's comment is not worth
# failing the publish.
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
