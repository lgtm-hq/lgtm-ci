#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Decide whether a release PR should be created based on the
# working-tree state and whether the caller expects version files to
# change.
#
# Two modes, selected by EXPECT_VERSION_FILES:
#   true  — The caller has ecosystems or a version-update-script
#           configured, so version files SHOULD have changed. CHANGELOG-only
#           diffs are treated as a script bug: we emit an error and refuse
#           to open a PR. Empty diff also refuses.
#   false — The caller is CHANGELOG-only (e.g., lgtm-ci itself). Any
#           change (including CHANGELOG-only) is a valid reason to open a
#           PR. Empty diff still refuses.
#
# Untracked files (?? lines) are never counted — the workflow only
# commits tracked changes.
#
# Outputs:
#   has-pr-changes - true if a PR should be opened

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${EXPECT_VERSION_FILES:=true}"

# Capture git status separately so git failures fail this script
# instead of being masked by the grep pipeline.
GIT_STATUS_OUTPUT=$(git status --porcelain)

# Strip untracked (??) entries — we never commit those.
TRACKED_CHANGES=$(printf '%s\n' "$GIT_STATUS_OUTPUT" | grep -v '^??' || true)

# Strip CHANGELOG.md entries, anchored to end of path so
# docs/CHANGELOG.md.backup is NOT excluded. Porcelain format is "XY path".
NON_CHANGELOG_CHANGES=$(printf '%s\n' "$TRACKED_CHANGES" |
	grep -vE '^.. (.*/)?CHANGELOG\.md$' || true)

if [[ -z "$TRACKED_CHANGES" ]]; then
	log_info "No tracked changes detected"
	set_github_output "has-pr-changes" "false"
	exit 0
fi

if [[ "$EXPECT_VERSION_FILES" == "true" ]]; then
	# Caller has ecosystems/script configured — version files MUST change
	if [[ -z "$NON_CHANGELOG_CHANGES" ]]; then
		log_error "Only CHANGELOG.md changed, but ecosystems/version-update-script were configured"
		log_error "This indicates an ecosystem script or update script did not update any version files"
		echo "$TRACKED_CHANGES" | head -10 >&2
		set_github_output "has-pr-changes" "false"
		exit 0
	fi
	log_info "Version file changes detected:"
	echo "$NON_CHANGELOG_CHANGES" | head -10 >&2
else
	# CHANGELOG-only caller — any tracked change is valid
	log_info "Changes detected (CHANGELOG-only caller mode):"
	echo "$TRACKED_CHANGES" | head -10 >&2
fi

set_github_output "has-pr-changes" "true"
exit 0
