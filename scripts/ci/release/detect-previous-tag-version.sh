#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Detect the version from the latest reachable git tag
#
# Optional environment variables:
#   TAG_PREFIX - Tag prefix to match and strip (default: v)
#
# Outputs:
#   version - Version without tag prefix (e.g., 1.2.3)
#   found   - true when a matching tag exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/git.sh
source "$LIB_DIR/git.sh"

: "${TAG_PREFIX:=v}"

pattern="${TAG_PREFIX}*"
tag="$(get_tags "$pattern" | head -1 || true)"

if [[ -z "$tag" ]]; then
	log_info "No tag found matching pattern: $pattern"
	set_github_output "version" ""
	set_github_output "found" "false"
	# Also echo to stdout for BATS test assertions
	echo "version="
	echo "found=false"
	exit 0
fi

version="${tag#"${TAG_PREFIX}"}"
if [[ -z "$version" ]]; then
	log_error "Tag $tag has empty version after removing prefix $TAG_PREFIX"
	set_github_output "version" ""
	set_github_output "found" "false"
	# Also echo to stdout for BATS test assertions
	echo "version="
	echo "found=false"
	exit 1
fi

log_info "Previous tag: $tag (version: $version)"
set_github_output "version" "$version"
set_github_output "found" "true"
# Also echo to stdout for BATS test assertions
echo "version=$version"
echo "found=true"
