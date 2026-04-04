#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate ecosystem version updaters
#
# Parses the ECOSYSTEMS CSV and ECOSYSTEM_CONFIG JSON, then invokes
# each ecosystem script with the correct environment variables.
#
# Required environment variables:
#   NEXT_VERSION     - The version to set (e.g., 1.2.3)
#   ECOSYSTEMS       - Comma-separated ecosystem identifiers
#
# Optional environment variables:
#   ECOSYSTEM_CONFIG - JSON object with per-ecosystem path overrides

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEMS:?ECOSYSTEMS is required}"
: "${ECOSYSTEM_CONFIG:={}}"

export NEXT_VERSION

# Validate ecosystem config JSON upfront
if ! echo "$ECOSYSTEM_CONFIG" | jq empty 2>/dev/null; then
	log_error "ECOSYSTEM_CONFIG is not valid JSON: $ECOSYSTEM_CONFIG"
	exit 1
fi

log_info "Running ecosystem updaters for: $ECOSYSTEMS"
log_info "Target version: $NEXT_VERSION"

# Parse comma-separated ecosystems, trimming whitespace
IFS=',' read -ra ECOSYSTEM_LIST <<<"$ECOSYSTEMS"

FAILED=0

for ecosystem in "${ECOSYSTEM_LIST[@]}"; do
	# Trim whitespace
	ecosystem=$(echo "$ecosystem" | xargs)
	[[ -z "$ecosystem" ]] && continue

	if [[ "$ecosystem" =~ [/\\] || "$ecosystem" == *..* ]]; then
		log_error "Invalid ecosystem identifier: $ecosystem"
		FAILED=1
		continue
	fi

	SCRIPT="$SCRIPT_DIR/${ecosystem}.sh"

	if [[ ! -f "$SCRIPT" ]]; then
		log_error "Unknown ecosystem: $ecosystem (no script at $SCRIPT)"
		FAILED=1
		continue
	fi

	# Extract per-ecosystem config from JSON and export as env vars
	# Each ecosystem script reads its own ECOSYSTEM_* vars
	CONFIG_JSON=$(echo "$ECOSYSTEM_CONFIG" | jq -r --arg eco "$ecosystem" '.[$eco] // empty')

	if [[ -n "$CONFIG_JSON" ]]; then
		log_info "[$ecosystem] Config overrides: $CONFIG_JSON"
		export ECOSYSTEM_CONFIG_JSON="$CONFIG_JSON"
	else
		export ECOSYSTEM_CONFIG_JSON="{}"
	fi

	log_info "[$ecosystem] Running version updater..."
	if "$SCRIPT"; then
		log_success "[$ecosystem] Version updated to $NEXT_VERSION"
	else
		log_error "[$ecosystem] Version update failed"
		FAILED=1
	fi
done

if [[ "$FAILED" -ne 0 ]]; then
	log_error "One or more ecosystem updaters failed"
	exit 1
fi

log_success "All ecosystem updaters completed successfully"
