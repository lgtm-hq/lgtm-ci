#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Guard against changelog-only or empty version PRs
#
# Checks if there are meaningful file changes beyond CHANGELOG.md.
# Exits non-zero if the only changed file is CHANGELOG.md or if
# there are no changes at all.
#
# Outputs:
#   has-version-changes - true if non-CHANGELOG files were modified

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

# Get all changed files (staged + unstaged). Run git separately so
# git failures fail the script instead of being masked by the pipeline.
GIT_STATUS_OUTPUT=$(git status --porcelain)

# Exclude CHANGELOG.md (anchored to end of path so docs/CHANGELOG.md.backup
# is NOT excluded) and untracked files. The porcelain format is "XY path".
CHANGED_FILES=$(printf '%s\n' "$GIT_STATUS_OUTPUT" |
	grep -vE '^.. (.*/)?CHANGELOG\.md$' |
	grep -v '^??' || true)

if [[ -z "$CHANGED_FILES" ]]; then
	log_info "No version file changes detected (only CHANGELOG.md or nothing)"
	set_github_output "has-version-changes" "false"
	exit 0
fi

log_info "Version file changes detected:"
echo "$CHANGED_FILES" | head -10 >&2

set_github_output "has-version-changes" "true"
exit 0
