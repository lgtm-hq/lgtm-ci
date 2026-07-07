#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write skip summary to GitHub step summary
#
# Writes a summary explaining why the auto-tag workflow was skipped.
#
# Environment variables:
#   IS_RELEASE - Whether the last commit was a release commit (default: 'false')
#   VERSION_FOUND - Whether a version was resolved (default: 'false')
#   VERSION_UNCHANGED - Whether version matches the latest tag (default: 'false')
#   TAG_EXISTS        - Whether the target tag already exists (default: 'false')

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${IS_RELEASE:=false}"
: "${VERSION_FOUND:=false}"
: "${VERSION_UNCHANGED:=false}"
: "${TAG_EXISTS:=false}"

add_github_summary "## Auto Tag Summary"
add_github_summary ""
if [[ "$TAG_EXISTS" == "true" ]]; then
	add_github_summary "Skipped: tag already exists"
elif [[ "$VERSION_UNCHANGED" == "true" ]]; then
	add_github_summary "Skipped: version unchanged since last tag"
elif [[ "$VERSION_FOUND" != "true" ]]; then
	if [[ "$IS_RELEASE" != "true" ]]; then
		add_github_summary "Skipped: last commit is not a release commit"
	else
		add_github_summary "Skipped: version not found"
	fi
else
	add_github_summary "Skipped: unexpected auto-tag skip state (IS_RELEASE=$IS_RELEASE, VERSION_FOUND=$VERSION_FOUND, VERSION_UNCHANGED=$VERSION_UNCHANGED, TAG_EXISTS=$TAG_EXISTS)"
fi
