#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Guard against infinite release loops
#
# Checks if the last commit on HEAD is a release commit
# (starts with 'chore(release):'). Used by release workflows
# to prevent the version PR merge from re-triggering Stage 1.
#
# Outputs:
#   is-release-commit - true if last commit is a release commit

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

LAST_COMMIT_MSG=$(git log -1 --format='%s' HEAD)
log_info "Last commit: $LAST_COMMIT_MSG"

IS_RELEASE_COMMIT="false"
if [[ "$LAST_COMMIT_MSG" =~ ^chore\(release\): ]]; then
	IS_RELEASE_COMMIT="true"
	log_info "This is a release commit — version PR workflow will be skipped"
else
	log_info "Not a release commit — version PR workflow will proceed"
fi

set_github_output "is-release-commit" "$IS_RELEASE_COMMIT"
echo "is-release-commit=$IS_RELEASE_COMMIT"

# Always exit 0 — use output variable for conditional logic in workflow
exit 0
