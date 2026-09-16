#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate changelog from conventional commits
#
# Required environment variables:
#   None (uses git history)
#
# Optional environment variables:
#   FROM_REF - Reference to start from (default: latest stable tag reachable from HEAD)
#   TO_REF - Reference to end at (default: HEAD)
#   VERSION - Version for changelog header
#   FORMAT - Output format: full, simple, with-type (default: full)
#   OUTPUT_FILE - File to write changelog to (default: stdout)

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${FROM_REF:=}"
: "${TO_REF:=HEAD}"
: "${VERSION:=}"
: "${FORMAT:=full}"
: "${OUTPUT_FILE:=}"

# Get from_ref if not specified
if [[ -z "$FROM_REF" ]]; then
	# Latest STABLE semver tag reachable from HEAD, the same lookup
	# calculate-version.sh bumps from (#1000). A bare `git describe` picks the
	# nearest tag, which on a main that carries checkpoint prereleases
	# (v1.2.3a1, v1.2.3rc1) is the checkpoint, and the version PR's changelog
	# then covers only the commits since it and silently drops the rest
	# (#1012).
	FROM_REF=$(latest_stable_tag HEAD) || true
	FROM_REF="${FROM_REF:-}"
fi

log_info "Generating changelog from '${FROM_REF:-beginning}' to '$TO_REF'"

# Generate changelog
CHANGELOG=$(generate_changelog "$FROM_REF" "$TO_REF" "$VERSION" "$FORMAT")

if [[ -n "$OUTPUT_FILE" ]]; then
	echo "$CHANGELOG" >"$OUTPUT_FILE"
	log_success "Changelog written to: $OUTPUT_FILE"
else
	echo "$CHANGELOG"
fi

# Output for GitHub Actions (multiline)
set_github_output_multiline "changelog" "$CHANGELOG"
