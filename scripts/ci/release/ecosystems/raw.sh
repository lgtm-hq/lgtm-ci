#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update a raw VERSION file (plain-text semver)
#
# Required environment variables:
#   NEXT_VERSION  - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFEST_PATH - Path to the VERSION file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFEST_PATH:?MANIFEST_PATH is required}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
	log_error "[raw] VERSION file not found at: $MANIFEST_PATH"
	exit 1
fi

log_info "[raw] Updating $MANIFEST_PATH → $NEXT_VERSION"

write_file_atomic "$MANIFEST_PATH" \
	printf '%s\n' "$NEXT_VERSION"

ACTUAL=$(tr -d '[:space:]' <"$MANIFEST_PATH")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[raw] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[raw] $MANIFEST_PATH updated to $NEXT_VERSION"
