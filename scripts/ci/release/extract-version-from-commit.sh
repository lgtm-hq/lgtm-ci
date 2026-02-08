#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Extract version from a release commit message
#
# Parses the version number from a commit message matching
# 'chore(release): version X.Y.Z'. Used by the auto-tag
# workflow to determine which version to tag.
#
# Optional environment variables:
#   COMMIT_MESSAGE - Override commit message (default: HEAD commit subject)
#
# Outputs:
#   version - Extracted version number (e.g., 1.2.3)
#   found   - true if version was extracted successfully

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${COMMIT_MESSAGE:=$(git log -1 --format='%s' HEAD)}"

log_info "Extracting version from commit: $COMMIT_MESSAGE"

if [[ "$COMMIT_MESSAGE" =~ ^chore\(release\):\ version\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
	EXTRACTED_VERSION="${BASH_REMATCH[1]}"

	if ! validate_semver "$EXTRACTED_VERSION"; then
		log_error "Extracted version is not valid semver: $EXTRACTED_VERSION"
		set_github_output "version" ""
		set_github_output "found" "false"
		exit 1
	fi

	log_success "Extracted version: $EXTRACTED_VERSION"
	set_github_output "version" "$EXTRACTED_VERSION"
	set_github_output "found" "true"
	echo "version=$EXTRACTED_VERSION"
	echo "found=true"
else
	log_error "Could not extract version from commit message: $COMMIT_MESSAGE"
	set_github_output "version" ""
	set_github_output "found" "false"
	echo "version="
	echo "found=false"
	exit 1
fi
