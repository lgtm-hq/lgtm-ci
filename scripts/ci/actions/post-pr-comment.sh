#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post or update a PR comment with marker-based identification
#
# Required environment variables:
#   GH_TOKEN - GitHub token for API access
#   GITHUB_REPOSITORY - Repository in owner/repo format
#   COMMENT_BODY - Comment body content
#   PR_NUMBER - Pull request number
#   MARKER - Unique marker for this comment
#   MODE - Comment mode: upsert, create, or update
#   DELETE_ON_EMPTY - Whether to delete comment if body is empty

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${MARKER:?MARKER is required}"
: "${MODE:=upsert}"
: "${DELETE_ON_EMPTY:=false}"

# Create marker comment (hidden in rendered markdown)
MARKER_TAG="<!-- lgtm-ci:${MARKER} -->"

# Find existing comment with this marker
EXISTING_COMMENT_ID=$(gh api \
	-H "Accept: application/vnd.github+json" \
	"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
	--jq ".[] | select(.body | contains(\"${MARKER_TAG}\")) | .id" \
	2>/dev/null | head -1 || echo "")

# Handle empty body
if [[ -z "${COMMENT_BODY:-}" ]]; then
	if [[ "$DELETE_ON_EMPTY" == "true" && -n "$EXISTING_COMMENT_ID" ]]; then
		gh api \
			-X DELETE \
			"/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_COMMENT_ID}"
		echo "action-taken=deleted" >>"$GITHUB_OUTPUT"
		echo "Deleted comment $EXISTING_COMMENT_ID"
		exit 0
	else
		echo "action-taken=skipped" >>"$GITHUB_OUTPUT"
		echo "Skipped: empty body"
		exit 0
	fi
fi

# Prepare full comment body with marker
FULL_BODY="${MARKER_TAG}
${COMMENT_BODY}"

# Perform action based on mode
if [[ "$MODE" == "create" || ("$MODE" == "upsert" && -z "$EXISTING_COMMENT_ID") ]]; then
	# Create new comment
	RESPONSE=$(gh api \
		-X POST \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
		-f body="$FULL_BODY")

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url')
	echo "action-taken=created" >>"$GITHUB_OUTPUT"
	echo "Created comment $COMMENT_ID"

elif [[ "$MODE" == "update" || "$MODE" == "upsert" ]] && [[ -n "$EXISTING_COMMENT_ID" ]]; then
	# Update existing comment
	RESPONSE=$(gh api \
		-X PATCH \
		-H "Accept: application/vnd.github+json" \
		"/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_COMMENT_ID}" \
		-f body="$FULL_BODY")

	COMMENT_ID=$(echo "$RESPONSE" | jq -r '.id')
	COMMENT_URL=$(echo "$RESPONSE" | jq -r '.html_url')
	echo "action-taken=updated" >>"$GITHUB_OUTPUT"
	echo "Updated comment $COMMENT_ID"

else
	echo "action-taken=skipped" >>"$GITHUB_OUTPUT"
	echo "Skipped: no existing comment to update"
	exit 0
fi

echo "comment-id=$COMMENT_ID" >>"$GITHUB_OUTPUT"
echo "comment-url=$COMMENT_URL" >>"$GITHUB_OUTPUT"
