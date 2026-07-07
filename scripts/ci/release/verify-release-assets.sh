#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify release asset globs match at least one file before creating a release
#
# Required environment variables:
#   FILES - Newline-separated asset glob patterns
#
# Optional environment variables:
#   ARTIFACT_PATH - Artifact directory (for error messages only)

set -euo pipefail

: "${FILES:?FILES is required}"
: "${ARTIFACT_PATH:=dist}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/release/assets.sh
source "$SCRIPT_DIR/../lib/release/assets.sh"

count=$(release_collect_asset_files "$FILES")

if ((count == 0)); then
	log_error "No release assets matched FILES patterns (artifact-path=${ARTIFACT_PATH})"
	exit 1
fi

log_success "Found ${count} release asset(s)"
