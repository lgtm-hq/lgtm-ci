#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate changelog from conventional commits
#
# Required environment variables:
#   None (uses git history)
#
# Optional environment variables:
#   FROM_REF - Reference to start from (default: latest stable TAG_PREFIX tag reachable from HEAD)
#   TAG_PREFIX - Prefix of the version tags the default FROM_REF is chosen from (default: v)
#   TO_REF - Reference to end at (default: HEAD)
#   VERSION - Version for changelog header
#   FORMAT - Output format: full, simple, with-type (default: full)
#   OUTPUT_FILE - File to write changelog to (default: stdout)
#   CATALOG_RELEASE_NOTES - true to merge the support-catalog diff between
#     FROM_REF and TO_REF (tier changes, deprecations, removals; #1082) into
#     the generated sections. Needs catalog/catalog.yml at both refs and a
#     python3 with PyYAML; a failure fails the script (default: false)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
# Resolved before sourcing: the release libraries reassign SCRIPT_DIR.
CATALOG_DIR="$SCRIPT_DIR/../catalog"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"
# shellcheck source=../lib/release/changelog_merge.sh
source "$LIB_DIR/release/changelog_merge.sh"

: "${FROM_REF:=}"
: "${TAG_PREFIX:=v}"
: "${TO_REF:=HEAD}"
: "${VERSION:=}"
: "${FORMAT:=full}"
: "${OUTPUT_FILE:=}"
: "${CATALOG_RELEASE_NOTES:=false}"

# Get from_ref if not specified
if [[ -z "$FROM_REF" ]]; then
	# Latest STABLE semver tag reachable from HEAD, the same lookup
	# calculate-version.sh bumps from (#1000). A bare `git describe` picks the
	# nearest tag, which on a main that carries checkpoint prereleases
	# (v1.2.3a1, v1.2.3rc1) is the checkpoint, and the version PR's changelog
	# then covers only the commits since it and silently drops the rest
	# (#1012).
	FROM_REF=$(latest_stable_tag HEAD "$TAG_PREFIX") || true
	FROM_REF="${FROM_REF:-}"
fi

log_info "Generating changelog from '${FROM_REF:-beginning}' to '$TO_REF'"

# Generate changelog
CHANGELOG=$(generate_changelog "$FROM_REF" "$TO_REF" "$VERSION" "$FORMAT")

# Support-catalog changes for callers (#1082): merged into the same Keep a
# Changelog sections as the commit bullets, so the release section says which
# entries changed tier and which inputs were deprecated or removed.
if [[ "$CATALOG_RELEASE_NOTES" == "true" && -n "$FROM_REF" ]]; then
	CATALOG_NOTES=$(python3 "$CATALOG_DIR/release_notes.py" \
		--repo-root . --base "$FROM_REF" --head "$TO_REF")
	if [[ -n "$CATALOG_NOTES" ]]; then
		CHANGELOG_HEADING=$(printf '%s\n' "$CHANGELOG" | head -n 1)
		CHANGELOG_SECTIONS=$(printf '%s\n' "$CHANGELOG" | tail -n +2)
		MERGED=$(merge_changelog_sections "$CHANGELOG_SECTIONS" "$CATALOG_NOTES")
		CHANGELOG="${CHANGELOG_HEADING}"$'\n\n'"${MERGED}"
		log_info "Merged support-catalog changes since '$FROM_REF'"
	fi
fi

if [[ -n "$OUTPUT_FILE" ]]; then
	echo "$CHANGELOG" >"$OUTPUT_FILE"
	log_success "Changelog written to: $OUTPUT_FILE"
else
	echo "$CHANGELOG"
fi

# Output for GitHub Actions (multiline)
set_github_output_multiline "changelog" "$CHANGELOG"
