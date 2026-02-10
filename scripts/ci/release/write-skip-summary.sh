#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write skip summary to GitHub step summary
#
# Writes a summary explaining why the auto-tag workflow was skipped.
#
# Required environment variables:
#   IS_RELEASE - Whether the last commit was a release commit ('true'/'false')

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${IS_RELEASE:=false}"

add_github_summary "## Auto Tag Summary"
add_github_summary ""
if [[ "$IS_RELEASE" != "true" ]]; then
	add_github_summary "Skipped: last commit is not a release commit"
else
	add_github_summary "Skipped: version not found or guard step failed"
fi
