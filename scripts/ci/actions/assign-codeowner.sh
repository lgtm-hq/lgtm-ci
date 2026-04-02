#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Assign a random CODEOWNER to a pull request
#
# Required environment variables:
#   GH_TOKEN        - GitHub token for API access
#   PR_NUMBER       - Pull request number
#   PR_AUTHOR       - Login of the PR author
#   CODEOWNERS_PATH - Path to CODEOWNERS file
#
# Optional environment variables:
#   PR_AUTHOR_TYPE  - GitHub user type (e.g. "User", "Bot")

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${PR_AUTHOR:?PR_AUTHOR is required}"
: "${CODEOWNERS_PATH:?CODEOWNERS_PATH is required}"

# Extract usernames from CODEOWNERS, filtering out commented lines first
# Pipeline: remove comments -> extract @mentions -> dedupe -> remove @ -> filter individuals
# The regex '^[A-Za-z0-9_-]+$' excludes team entries by disallowing '/' characters
owners=""
pipeline_output=$(grep -v '^\s*#' "$CODEOWNERS_PATH" |
	grep -oE '@[a-zA-Z0-9_/-]+' |
	sort -u | tr -d '@' | grep -E '^[A-Za-z0-9_-]+$') &&
	exit_code=0 || exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	owners="$pipeline_output"
elif [[ $exit_code -eq 1 ]]; then
	# grep exit code 1 means no matches - expected when no individual owners
	echo "No matches found in pipeline, treating as empty result"
	owners=""
else
	# Any other exit code indicates an actual error
	echo "Error: Pipeline failed with exit code $exit_code"
	exit "$exit_code"
fi

if [[ -z "$owners" ]]; then
	echo "No valid individual CODEOWNERS found, skipping assignment"
	exit 0
fi

# Convert to array using mapfile (shellcheck-safe)
mapfile -t owner_array <<<"$owners"

# Filter out the PR author from candidates
filtered_array=()
for owner in "${owner_array[@]}"; do
	if [[ "$owner" != "$PR_AUTHOR" ]]; then
		filtered_array+=("$owner")
	fi
done
owner_array=("${filtered_array[@]}")
count=${#owner_array[@]}

if [[ $count -eq 0 ]]; then
	echo "No other assignees available, falling back to full CODEOWNERS list"
	mapfile -t owner_array <<<"$owners"
	count=${#owner_array[@]}
fi

random_index=$((RANDOM % count))
selected="${owner_array[$random_index]}"

echo "Selected assignee: $selected (from $count eligible CODEOWNERS)"
gh pr edit "$PR_NUMBER" --add-assignee "$selected"

# Request a review from the selected CODEOWNER for bot-authored PRs
# (e.g. version bumps, Renovate dependency updates)
if [[ "${PR_AUTHOR_TYPE:-}" == "Bot" ]]; then
	if [[ "$selected" == "$PR_AUTHOR" ]]; then
		echo "Bot-authored PR detected, but selected CODEOWNER is the PR author ($selected); skipping review request"
	else
		echo "Bot-authored PR detected, requesting review from $selected"
		gh pr edit "$PR_NUMBER" --add-reviewer "$selected"
	fi
fi
