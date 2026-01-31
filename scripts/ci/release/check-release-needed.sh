#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Check if a release is needed based on version calculation
#
# Required environment variables:
#   RELEASE_NEEDED - Whether release is needed (from calculate-version)
#   NEXT_VERSION - The next version (from calculate-version)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${RELEASE_NEEDED:=false}"
: "${NEXT_VERSION:=}"

if [[ "$RELEASE_NEEDED" == "true" ]]; then
	if [[ -z "$NEXT_VERSION" ]]; then
		echo "::error::Release is needed but NEXT_VERSION is empty"
		exit 1
	fi
	set_github_output "release-needed" "true"
	echo "::notice::Release needed: $NEXT_VERSION"
else
	set_github_output "release-needed" "false"
	echo "::notice::No release needed"
fi
