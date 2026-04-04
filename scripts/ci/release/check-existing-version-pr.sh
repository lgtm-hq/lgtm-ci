#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Check for an existing open version PR
#
# Queries GitHub for open pull requests matching the release PR
# title pattern. Prevents duplicate version PRs from being created.
#
# Required: GH_TOKEN must be set for gh CLI authentication
#
# Outputs:
#   pr-exists - true if an open version PR exists
#   pr-number - PR number (empty if none)
#   pr-url    - PR URL (empty if none)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

PR_TITLE_PREFIX="chore(release): version"

EXISTING_PR=$(gh pr list --state open --search "in:title ${PR_TITLE_PREFIX}" \
	--json number,title,url --jq '.[0]' 2>/dev/null || echo "")

if [[ -n "$EXISTING_PR" ]] && [[ "$EXISTING_PR" != "null" ]]; then
	PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number // empty')
	PR_URL=$(echo "$EXISTING_PR" | jq -r '.url // empty')
	PR_TITLE=$(echo "$EXISTING_PR" | jq -r '.title // empty')

	log_info "Existing version PR found: #${PR_NUMBER} - ${PR_TITLE}"

	set_github_output "pr-exists" "true"
	set_github_output "pr-number" "$PR_NUMBER"
	set_github_output "pr-url" "$PR_URL"
	echo "pr-exists=true"
	echo "pr-number=$PR_NUMBER"
	echo "pr-url=$PR_URL"
else
	log_info "No existing version PR found"

	set_github_output "pr-exists" "false"
	set_github_output "pr-number" ""
	set_github_output "pr-url" ""
	echo "pr-exists=false"
	echo "pr-number="
	echo "pr-url="
fi
