#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write release summary to GitHub step summary
#
# Required environment variables:
#   SUMMARY_TYPE - Type of summary: 'dry-run' or 'release'
#   VERSION - The version being released (required)
#
# For dry-run:
#   TAG_PREFIX - Tag prefix (e.g., 'v')
#   BUMP_TYPE - The bump type (major, minor, patch)
#   CHANGELOG - The changelog content
#
# For release:
#   TAG_NAME - The created tag name
#   RELEASE_URL - The release URL

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${SUMMARY_TYPE:=release}"
: "${VERSION:?VERSION is required}"

case "$SUMMARY_TYPE" in
dry-run)
	: "${TAG_PREFIX:=v}"
	: "${BUMP_TYPE:=}"
	: "${CHANGELOG:=}"

	add_github_summary "## Dry Run Summary"
	add_github_summary ""
	add_github_summary "Would create release:"
	add_github_summary "- **Version:** $VERSION"
	add_github_summary "- **Tag:** ${TAG_PREFIX}${VERSION}"
	add_github_summary "- **Bump type:** $BUMP_TYPE"
	add_github_summary ""
	add_github_summary "### Changelog Preview"
	add_github_summary ""
	add_github_summary "$CHANGELOG"
	;;
release)
	: "${TAG_NAME:=}"
	: "${RELEASE_URL:=}"

	add_github_summary "## Release Created"
	add_github_summary ""
	add_github_summary "- **Version:** $VERSION"
	add_github_summary "- **Tag:** $TAG_NAME"
	add_github_summary "- **Release:** $RELEASE_URL"
	;;
*)
	echo "Unknown summary type: $SUMMARY_TYPE" >&2
	exit 1
	;;
esac
