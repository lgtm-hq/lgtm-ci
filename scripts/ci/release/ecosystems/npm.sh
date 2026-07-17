#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update package.json version field for a manifests entry (kind: npm)
#
# Delegates to node.sh with the package path override so npm and node stay
# a single implementation.
#
# Required environment variables:
#   NEXT_VERSION  - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFEST_PATH - Path to package.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFEST_PATH:?MANIFEST_PATH is required}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
	log_error "[npm] package.json not found at: $MANIFEST_PATH"
	exit 1
fi

export ECOSYSTEM_CONFIG_JSON
ECOSYSTEM_CONFIG_JSON=$(jq -nc --arg p "$MANIFEST_PATH" '{package: $p}')

if [[ ! -f "$SCRIPT_DIR/node.sh" ]]; then
	log_error "[npm] node.sh missing at: $SCRIPT_DIR/node.sh"
	exit 1
fi

log_info "[npm] Delegating to node updater for $MANIFEST_PATH"
"$SCRIPT_DIR/node.sh"
