#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Guard against infinite release loops
#
# Checks if the last commit on HEAD matches a skip pattern. Used by release
# workflows to prevent release/version commits from re-triggering Stage 1.
#
# Outputs:
#   is-release-commit - true if last commit should skip release-version work

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${SKIP_PATTERNS:=chore\\(release\\):}"

LAST_COMMIT_MSG=$(git log -1 --format='%s' HEAD)
log_info "Last commit: $LAST_COMMIT_MSG"

IS_RELEASE_COMMIT="false"
IFS=',' read -ra PATTERNS <<<"$SKIP_PATTERNS"
for pattern in "${PATTERNS[@]}"; do
	pattern="$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	if [[ -z "$pattern" ]]; then
		continue
	fi
	if grep -qE "$pattern" <<<"$LAST_COMMIT_MSG"; then
		IS_RELEASE_COMMIT="true"
		log_info "Commit matches skip pattern '$pattern' — version PR workflow will be skipped"
		break
	fi
done

if [[ "$IS_RELEASE_COMMIT" == "false" ]]; then
	log_info "No skip pattern matched — version PR workflow will proceed"
fi

set_github_output "is-release-commit" "$IS_RELEASE_COMMIT"
echo "is-release-commit=$IS_RELEASE_COMMIT"

# Always exit 0 — use output variable for conditional logic in workflow
exit 0
