#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write version PR step summary
#
# Writes a summary explaining what the version PR workflow did:
# created a PR, skipped (and why), or found no releasable commits.
#
# Environment variables:
#   IS_RELEASE     - Whether the last commit was a release commit
#   PR_EXISTS      - Whether an open version PR already exists
#   RELEASE_NEEDED - Whether releasable commits were found
#   NEXT_VERSION   - The computed next version
#   BUMP_TYPE      - The bump type (major, minor, patch)
#   PR_URL         - URL of the created/updated PR
#   PR_OP          - PR operation (created, updated)
#   ECOSYSTEMS     - Comma-separated list of ecosystems updated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${IS_RELEASE:=false}"
: "${PR_EXISTS:=false}"
: "${RELEASE_NEEDED:=false}"
: "${NEXT_VERSION:=}"
: "${BUMP_TYPE:=}"
: "${PR_URL:=}"
: "${PR_OP:=}"
: "${ECOSYSTEMS:=}"

add_github_summary "## Version PR Summary"
add_github_summary ""

if [[ "$IS_RELEASE" == "true" ]]; then
	add_github_summary "Skipped: last commit is a release commit (loop prevention)"
elif [[ "$PR_EXISTS" == "true" ]]; then
	add_github_summary "Skipped: version PR already exists"
elif [[ "$RELEASE_NEEDED" != "true" ]]; then
	add_github_summary "Skipped: no releasable commits found"
else
	add_github_summary "- **Version:** $NEXT_VERSION"
	add_github_summary "- **Bump type:** $BUMP_TYPE"
	add_github_summary "- **PR:** ${PR_URL:-not created}"
	add_github_summary "- **Operation:** ${PR_OP:-unknown}"
	if [[ -n "$ECOSYSTEMS" ]]; then
		add_github_summary "- **Ecosystems:** $ECOSYSTEMS"
	fi
fi
