#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Egress audit setup and reporting
#
# Required environment variables:
#   STEP - Which step to run: setup, audit, or report
#   MODE - Egress mode (audit, report, block)
#   ALLOWED_DOMAINS - Allowed domains list
#   REPORT_FORMAT - Report format (summary, json, none)

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
setup)
	: "${ALLOWED_DOMAINS:=}"
	: "${MODE:=audit}"

	# Create log directory
	EGRESS_LOG_DIR="${RUNNER_TEMP}/egress-audit"
	mkdir -p "$EGRESS_LOG_DIR"
	echo "log-dir=$EGRESS_LOG_DIR" >>"$GITHUB_OUTPUT"

	# Parse allowed domains into a normalized list
	# Convert to newline-separated, remove empty lines and whitespace
	# Use sed instead of grep -v to avoid exit code 1 on empty input under set -e
	ALLOWED_DOMAINS=$(echo "$ALLOWED_DOMAINS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u)

	# Save allowed domains for later steps
	echo "$ALLOWED_DOMAINS" >"$EGRESS_LOG_DIR/allowed-domains.txt"

	echo "Egress audit mode: $MODE"
	echo "Allowed domains:"
	# shellcheck disable=SC2001 # sed is appropriate for multiline prefix
	echo "$ALLOWED_DOMAINS" | sed 's/^/  - /'
	;;

audit)
	: "${MODE:=audit}"

	EGRESS_LOG_DIR="${RUNNER_TEMP}/egress-audit"
	EGRESS_LOG="$EGRESS_LOG_DIR/egress.log"
	touch "$EGRESS_LOG"
	{
		echo "egress-log=$EGRESS_LOG"
		echo "violations-detected=false"
	} >>"$GITHUB_OUTPUT"

	if [[ "$MODE" == "block" ]]; then
		echo "::notice::Egress blocking is configured via harden-runner action"
		echo "Use the harden-runner action with egress-policy: block for enforcement"
	fi

	echo "Egress audit initialized. Log: $EGRESS_LOG"
	;;

report)
	: "${REPORT_FORMAT:=summary}"
	: "${MODE:=audit}"

	EGRESS_LOG_DIR="${RUNNER_TEMP}/egress-audit"

	# Validate that setup step ran first
	if [[ ! -f "$EGRESS_LOG_DIR/allowed-domains.txt" ]]; then
		echo "::error::Setup step must run before report. Missing: $EGRESS_LOG_DIR/allowed-domains.txt"
		exit 1
	fi

	if [[ "$REPORT_FORMAT" == "summary" ]] && [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		{
			echo "## Egress Audit Report"
			echo ""
			echo "**Mode:** $MODE"
			echo ""
			echo "### Allowed Domains"
			echo ""
			echo '```'
			cat "$EGRESS_LOG_DIR/allowed-domains.txt"
			echo '```'
			echo ""
			echo "> **Note:** For comprehensive egress monitoring, use this action with \`harden-runner\`."
			echo "> StepSecurity's harden-runner provides actual network traffic auditing and blocking."
		} >>"$GITHUB_STEP_SUMMARY"
	fi

	if [[ "$REPORT_FORMAT" == "json" ]]; then
		# Use jq for safe JSON generation (handles special characters in mode/domains)
		jq -n \
			--arg mode "$MODE" \
			--rawfile domains "$EGRESS_LOG_DIR/allowed-domains.txt" \
			'{
				mode: $mode,
				allowed_domains: ($domains | split("\n") | map(select(length > 0))),
				violations_detected: false
			}' >"$EGRESS_LOG_DIR/report.json"
		echo "JSON report: $EGRESS_LOG_DIR/report.json"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
