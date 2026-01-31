#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate GitHub Actions matrix JSON from comma-separated inputs
#
# Required environment variables:
#   STEP - Which step to run: e2e-matrix, shard-config
#
# For e2e-matrix step:
#   SUITES - Comma-separated test suites (e.g., "smoke,visual,a11y")
#   BROWSERS - Comma-separated browsers (e.g., "chromium,firefox")
#   SHARDS - Number of shards (default: 1)
#
# For shard-config step:
#   SHARD - Current shard number
#   TOTAL_SHARDS - Total number of shards

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
e2e-matrix)
	: "${SUITES:=smoke}"
	: "${BROWSERS:=chromium}"
	: "${SHARDS:=1}"

	# Validate SHARDS is a positive integer
	if ! [[ "$SHARDS" =~ ^[1-9][0-9]*$ ]]; then
		log_error "SHARDS must be a positive integer, got: $SHARDS"
		exit 1
	fi

	log_info "Generating E2E test matrix..."
	log_info "Suites: $SUITES"
	log_info "Browsers: $BROWSERS"
	log_info "Shards: $SHARDS"

	# Convert comma-separated inputs to JSON arrays (trim whitespace from each entry)
	suites_json=$(echo "$SUITES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
	browsers_json=$(echo "$BROWSERS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)

	# Generate shard array if sharding enabled
	if [[ "$SHARDS" -gt 1 ]]; then
		shards_json=$(seq 1 "$SHARDS" | jq -R . | jq -s .)
	else
		shards_json='["1"]'
	fi

	# Build matrix JSON
	matrix=$(jq -n \
		--argjson suites "$suites_json" \
		--argjson browsers "$browsers_json" \
		--argjson shards "$shards_json" \
		--arg total_shards "$SHARDS" \
		'{suite: $suites, browser: $browsers, shard: $shards, total_shards: $total_shards}')

	set_github_output "matrix" "$matrix"

	log_success "Generated matrix: $matrix"
	;;

shard-config)
	: "${SHARD:=1}"
	: "${TOTAL_SHARDS:=1}"

	# Validate inputs are positive integers
	if ! [[ "$SHARD" =~ ^[1-9][0-9]*$ ]] || ! [[ "$TOTAL_SHARDS" =~ ^[1-9][0-9]*$ ]]; then
		log_error "SHARD and TOTAL_SHARDS must be positive integers"
		exit 1
	fi
	if [[ "$SHARD" -gt "$TOTAL_SHARDS" ]]; then
		log_error "SHARD ($SHARD) cannot exceed TOTAL_SHARDS ($TOTAL_SHARDS)"
		exit 1
	fi

	if [[ "$TOTAL_SHARDS" -gt 1 ]]; then
		config="${SHARD}/${TOTAL_SHARDS}"
		log_info "Shard config: $config"
		set_github_output "config" "$config"
	else
		log_info "Sharding disabled"
		set_github_output "config" ""
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
