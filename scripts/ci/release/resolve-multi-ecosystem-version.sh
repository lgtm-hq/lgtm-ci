#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve next version for multi-ecosystem release (auto or explicit)
#
# Required environment variables:
#   BUMP_MODE - auto-from-commits | explicit
#
# Optional environment variables:
#   EXPLICIT_VERSION - Required when BUMP_MODE=explicit (semver, optional v prefix)
#   PRERELEASE_TAG   - Appended as -<tag> when set (e.g. rc.1 → 1.2.3-rc.1)
#   MAX_BUMP         - Passed through to calculate-version.sh (default: minor)
#   FROM_REF / TO_REF - Passed through to calculate-version.sh

set -euo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$RELEASE_SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${BUMP_MODE:?BUMP_MODE is required}"
: "${EXPLICIT_VERSION:=""}"
: "${PRERELEASE_TAG:=""}"
: "${MAX_BUMP:=minor}"

CURRENT_VERSION=""
NEXT_VERSION=""
BUMP_TYPE=""
RELEASE_NEEDED="false"

case "$BUMP_MODE" in
auto-from-commits)
	tmp_out=$(mktemp)
	# Isolate calculate-version outputs so we can rewrite after prerelease.
	# Use RELEASE_SCRIPT_DIR — sourcing lib/release.sh overwrites SCRIPT_DIR.
	if ! (
		export MAX_BUMP
		export GITHUB_OUTPUT="$tmp_out"
		"$RELEASE_SCRIPT_DIR/calculate-version.sh"
	); then
		rm -f "$tmp_out"
		log_error "calculate-version.sh failed"
		exit 1
	fi
	CURRENT_VERSION=$(grep -E '^current-version=' "$tmp_out" | head -1 | cut -d= -f2- || true)
	NEXT_VERSION=$(grep -E '^next-version=' "$tmp_out" | head -1 | cut -d= -f2- || true)
	BUMP_TYPE=$(grep -E '^bump-type=' "$tmp_out" | head -1 | cut -d= -f2- || true)
	RELEASE_NEEDED=$(grep -E '^release-needed=' "$tmp_out" | head -1 | cut -d= -f2- || true)
	rm -f "$tmp_out"
	CURRENT_VERSION="${CURRENT_VERSION:-0.0.0}"
	BUMP_TYPE="${BUMP_TYPE:-none}"
	RELEASE_NEEDED="${RELEASE_NEEDED:-false}"
	;;
explicit)
	if [[ -z "$EXPLICIT_VERSION" ]]; then
		log_error "EXPLICIT_VERSION is required when BUMP_MODE=explicit"
		exit 1
	fi
	NEXT_VERSION="${EXPLICIT_VERSION#v}"
	if ! validate_semver "$NEXT_VERSION"; then
		log_error "EXPLICIT_VERSION is not valid semver: $EXPLICIT_VERSION"
		exit 1
	fi
	CURRENT_VERSION=""
	BUMP_TYPE="explicit"
	RELEASE_NEEDED="true"
	log_info "Using explicit version: $NEXT_VERSION"
	;;
*)
	log_error "BUMP_MODE must be auto-from-commits or explicit, got: $BUMP_MODE"
	exit 1
	;;
esac

if [[ "$RELEASE_NEEDED" == "true" && -n "$PRERELEASE_TAG" ]]; then
	if [[ ! "$PRERELEASE_TAG" =~ ^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$ ]]; then
		log_error "PRERELEASE_TAG is invalid: $PRERELEASE_TAG"
		exit 1
	fi
	if [[ "$NEXT_VERSION" == *-* ]]; then
		log_error "NEXT_VERSION already has a prerelease suffix: $NEXT_VERSION"
		exit 1
	fi
	NEXT_VERSION="${NEXT_VERSION}-${PRERELEASE_TAG}"
	log_info "Applied prerelease tag → $NEXT_VERSION"
	if ! validate_semver "$NEXT_VERSION"; then
		log_error "Version with prerelease tag is not valid semver: $NEXT_VERSION"
		exit 1
	fi
fi

set_github_output "current-version" "$CURRENT_VERSION"
set_github_output "next-version" "$NEXT_VERSION"
set_github_output "bump-type" "$BUMP_TYPE"
set_github_output "release-needed" "$RELEASE_NEEDED"

echo "current-version=$CURRENT_VERSION"
echo "next-version=$NEXT_VERSION"
echo "bump-type=$BUMP_TYPE"
echo "release-needed=$RELEASE_NEEDED"
