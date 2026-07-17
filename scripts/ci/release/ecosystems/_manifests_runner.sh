#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate kind-dispatching manifest version updaters
#
# Parses MANIFESTS (JSON object of file path → kind) and invokes the matching
# kind script with MANIFEST_PATH + NEXT_VERSION.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFESTS    - JSON object, e.g. {"package.json":"npm","VERSION":"raw"}
#
# Allowed kinds: npm, raw, gemspec, pep621

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFESTS:?MANIFESTS is required}"

if [[ ! "$NEXT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
	log_error "NEXT_VERSION is not valid semver: $NEXT_VERSION"
	exit 1
fi

export NEXT_VERSION

ALLOWED_KINDS="npm raw gemspec pep621"

if ! echo "$MANIFESTS" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_error "MANIFESTS is not a valid JSON object: $MANIFESTS"
	exit 1
fi

ENTRY_COUNT=$(echo "$MANIFESTS" | jq 'length')
if [[ "$ENTRY_COUNT" -eq 0 ]]; then
	log_error "MANIFESTS must list at least one file→kind entry"
	exit 1
fi

log_info "Running manifest updaters for $ENTRY_COUNT path(s)"
log_info "Target version: $NEXT_VERSION"

FAILED=0

while IFS= read -r path; do
	[[ -z "$path" ]] && continue

	kind=$(echo "$MANIFESTS" | jq -r --arg p "$path" '.[$p] | if type == "string" then . else empty end')
	if [[ -z "$kind" ]]; then
		BAD=$(echo "$MANIFESTS" | jq -c --arg p "$path" '.[$p]')
		log_error "[$path] kind must be a string, got: $BAD"
		FAILED=1
		continue
	fi

	if [[ ! " $ALLOWED_KINDS " == *" $kind "* ]]; then
		log_error "[$path] Unknown kind: $kind (allowed: $ALLOWED_KINDS)"
		FAILED=1
		continue
	fi

	SCRIPT="$SCRIPT_DIR/${kind}.sh"
	if [[ ! -f "$SCRIPT" ]]; then
		log_error "[$path] Kind script missing: $SCRIPT"
		FAILED=1
		continue
	fi

	export MANIFEST_PATH="$path"
	log_info "[$kind] Updating $path..."
	if "$SCRIPT"; then
		log_success "[$kind] $path updated to $NEXT_VERSION"
	else
		log_error "[$kind] Update failed for $path"
		FAILED=1
	fi
done < <(echo "$MANIFESTS" | jq -r 'keys_unsorted[]')

if [[ "$FAILED" -ne 0 ]]; then
	log_error "One or more manifest updaters failed"
	exit 1
fi

log_success "All manifest updaters completed successfully"
