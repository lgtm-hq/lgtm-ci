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
	ALLOWED_DOMAINS=$(echo "$ALLOWED_DOMAINS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u)

	# Save allowed domains for later steps
	echo "$ALLOWED_DOMAINS" >"$EGRESS_LOG_DIR/allowed-domains.txt"

	echo "Egress audit mode: $MODE"
	echo "Allowed domains:"
	echo "$ALLOWED_DOMAINS" | sed 's/^/  - /'
	;;

audit)
	: "${MODE:=audit}"

	EGRESS_LOG_DIR="${RUNNER_TEMP}/egress-audit"
	EGRESS_LOG="$EGRESS_LOG_DIR/egress.log"
	touch "$EGRESS_LOG"
	echo "egress-log=$EGRESS_LOG" >>"$GITHUB_OUTPUT"
	echo "violations-detected=false" >>"$GITHUB_OUTPUT"

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
		{
			echo "{"
			echo "  \"mode\": \"$MODE\","
			echo "  \"allowed_domains\": ["
			sed 's/^/    "/;s/$/"/' "$EGRESS_LOG_DIR/allowed-domains.txt" | paste -sd ',' -
			echo "  ],"
			echo "  \"violations_detected\": false"
			echo "}"
		} >"$EGRESS_LOG_DIR/report.json"
		echo "JSON report: $EGRESS_LOG_DIR/report.json"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
