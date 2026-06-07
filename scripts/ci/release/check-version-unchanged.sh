#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compare current and previous versions for auto-tag skip logic
#
# Required environment variables:
#   CURRENT_VERSION - Version to tag
#
# Optional environment variables:
#   PREVIOUS_VERSION - Version from latest tag (empty when no prior tag)
#
# Outputs:
#   unchanged  - true when versions match
#   should-tag - false when tagging should be skipped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${CURRENT_VERSION:?CURRENT_VERSION is required}"
: "${PREVIOUS_VERSION:=}"

if [[ -z "$PREVIOUS_VERSION" ]]; then
	log_info "No previous tag version; tagging $CURRENT_VERSION"
	set_github_output "unchanged" "false"
	set_github_output "should-tag" "true"
	echo "unchanged=false"
	echo "should-tag=true"
	exit 0
fi

if [[ "$CURRENT_VERSION" == "$PREVIOUS_VERSION" ]]; then
	log_info "Version unchanged: $CURRENT_VERSION"
	set_github_output "unchanged" "true"
	set_github_output "should-tag" "false"
	echo "unchanged=true"
	echo "should-tag=false"
	exit 0
fi

log_info "Version changed: $PREVIOUS_VERSION -> $CURRENT_VERSION"
set_github_output "unchanged" "false"
set_github_output "should-tag" "true"
echo "unchanged=false"
echo "should-tag=true"
