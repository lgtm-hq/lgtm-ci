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

# Validate NEXT_VERSION is a valid semver string (defense-in-depth)
if [[ ! "$NEXT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
	log_error "NEXT_VERSION is not valid semver: $NEXT_VERSION"
	exit 1
fi

export NEXT_VERSION

# Allowlist of supported ecosystem identifiers
ALLOWED_ECOSYSTEMS="node rust python ruby swift dart kotlin"

# Validate ecosystem config JSON upfront — must be a JSON object
# so per-ecosystem lookups like .[$eco] work as expected.
if ! echo "$ECOSYSTEM_CONFIG" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_error "ECOSYSTEM_CONFIG is not a valid JSON object: $ECOSYSTEM_CONFIG"
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

	if [[ ! " $ALLOWED_ECOSYSTEMS " == *" $ecosystem "* ]]; then
		log_error "Unknown ecosystem: $ecosystem (allowed: $ALLOWED_ECOSYSTEMS)"
		FAILED=1
		continue
	fi

	SCRIPT="$SCRIPT_DIR/${ecosystem}.sh"

	# Defense-in-depth: verify the script file exists even after allowlist
	if [[ ! -f "$SCRIPT" ]]; then
		log_error "Ecosystem script missing: $SCRIPT"
		FAILED=1
		continue
	fi

	# Extract per-ecosystem config from JSON and export as env vars.
	# Each ecosystem script reads its own ECOSYSTEM_CONFIG_JSON var.
	# The value must be a JSON object — reject any other type.
	CONFIG_TYPE=$(echo "$ECOSYSTEM_CONFIG" | jq -r --arg eco "$ecosystem" '.[$eco] | type')

	if [[ "$CONFIG_TYPE" == "null" ]]; then
		export ECOSYSTEM_CONFIG_JSON="{}"
	elif [[ "$CONFIG_TYPE" == "object" ]]; then
		CONFIG_JSON=$(echo "$ECOSYSTEM_CONFIG" | jq -c --arg eco "$ecosystem" '.[$eco]')
		log_info "[$ecosystem] Config overrides: $CONFIG_JSON"
		export ECOSYSTEM_CONFIG_JSON="$CONFIG_JSON"
	else
		BAD_VALUE=$(echo "$ECOSYSTEM_CONFIG" | jq -c --arg eco "$ecosystem" '.[$eco]')
		log_error "[$ecosystem] Config must be a JSON object, got $CONFIG_TYPE: $BAD_VALUE"
		FAILED=1
		continue
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
