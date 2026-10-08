#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run Lighthouse CI audits
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#   PACKAGE_MANAGER - bun, npm, or pnpm (setup and run steps; never inferred
#                     from lockfiles, see lib/node/pm.sh)
#
# Optional environment variables:
#   URL - URL to audit (required for run step)
#   CONFIG_PATH - Path to lighthouserc.json
#   OUTPUT_DIR - Directory for results (default: lighthouse-reports)
#   RUN_MARKER - Marker file from the run step; parse only accepts reports
#                newer than it (default: unset, any report in OUTPUT_DIR)
#   THRESHOLD_PERFORMANCE - Minimum performance score (default: 80)
#   THRESHOLD_ACCESSIBILITY - Minimum accessibility score (default: 90)
#   THRESHOLD_BEST_PRACTICES - Minimum best practices score (default: 80)
#   THRESHOLD_SEO - Minimum SEO score (default: 80)
#   EXTRA_ARGS - Additional arguments to pass to LHCI
#   PARSE_OUTCOME - Outcome of the parse step (summary step; default: success)
#
# @lhci/cli is a consumer prerequisite: either already on PATH, or installed
# in the project tree (resolved from the current directory) by the selected
# package manager. Nothing is installed here (#1077).

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"
# shellcheck source=../lib/node/pm.sh
source "$SCRIPT_DIR/../lib/node/pm.sh"

# Run lhci from PATH when present, otherwise from the project tree via the
# selected package manager. Shared by the setup and run steps.
run_lhci() {
	if command -v lhci &>/dev/null; then
		lhci "$@"
	else
		pm_exec lhci "$@"
	fi
}

# Report of the representative run listed in LHCI's manifest.json, or nothing.
# With several runs per URL (collect.numberOfRuns > 1) the representative
# (median) run is the one LHCI asserts on; the newest file is not. LHCI writes
# the reports flat next to the manifest with an absolute jsonPath, which goes
# stale once the directory moves, so an absolute path is looked up by name
# inside the directory (keeping the result in the same form as OUTPUT_DIR); a
# relative one is taken relative to the directory. Only the first URL's
# representative run is scored; a multi-URL manifest gets a warning.
# A manifest, or the report it names, older than the marker belongs to an
# earlier audit and is ignored.
manifest_lighthouse_report() {
	local dir="$1" marker="${2:-}" manifest="$1/manifest.json" path reps
	[[ -f "$manifest" ]] || return 0
	[[ -z "$marker" || "$manifest" -nt "$marker" ]] || return 0
	path=$(jq -r '([.[] | select(.isRepresentativeRun == true)][0] // .[0]).jsonPath // empty' \
		"$manifest" 2>/dev/null) || path=""
	if [[ -z "$path" ]]; then
		log_warn "manifest.json names no report; falling back to the newest report file"
		return 0
	fi
	if [[ "$path" == /* ]]; then
		path="$dir/$(basename "$path")"
	else
		path="$dir/$path"
	fi
	if [[ ! -f "$path" ]] || [[ -n "$marker" && ! "$path" -nt "$marker" ]]; then
		log_warn "manifest.json names ${path}, which is missing or predates this audit; falling back to the newest report file"
		return 0
	fi
	reps=$(jq '[.[] | select(.isRepresentativeRun == true)] | length' "$manifest" 2>/dev/null || echo 0)
	if [[ "$reps" -gt 1 ]]; then
		log_warn "manifest.json lists ${reps} URLs; only the first URL's representative run is scored"
	fi
	printf '%s\n' "$path"
}

# Lighthouse report (LHR JSON) under a filesystem-upload directory.
# `lhci autorun --upload.target=filesystem` writes `<slug>.report.json` files
# and a manifest.json naming the representative run; that report wins. Without
# a usable manifest the newest `*.report.json` (or legacy `lhr-*.json`) is
# taken. With a marker file as the second argument only reports written after
# it count, so a report left over from an earlier audit in the same directory
# is never mistaken for this run's result.
find_lighthouse_report() {
	local dir="$1" marker="${2:-}" newest="" f
	newest=$(manifest_lighthouse_report "$dir" "$marker")
	if [[ -n "$newest" ]]; then
		printf '%s\n' "$newest"
		return 0
	fi
	local -a find_args=("$dir" -type f \( -name "*.report.json" -o -name "lhr-*.json" \))
	if [[ -n "$marker" ]]; then
		find_args+=(-newer "$marker")
	fi
	while IFS= read -r f; do
		if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
			newest="$f"
		fi
	done < <(find "${find_args[@]}" 2>/dev/null | sort)
	printf '%s\n' "$newest"
}

case "$STEP" in
setup)
	pm_require >/dev/null || exit $?

	log_info "Checking Lighthouse CI installation (${PACKAGE_MANAGER})..."

	if ! command -v lhci &>/dev/null && ! pm_has @lhci/cli; then
		die "@lhci/cli is not installed in $(pwd): install @lhci/cli as a devDependency and commit the ${PACKAGE_MANAGER} lockfile"
	fi

	log_success "Lighthouse CI available: $(run_lhci --version)"
	;;

run)
	: "${URL:?URL is required for run step}"
	: "${CONFIG_PATH:=}"
	: "${OUTPUT_DIR:=lighthouse-reports}"
	: "${EXTRA_ARGS:=}"

	pm_require >/dev/null || exit $?

	mkdir -p "$OUTPUT_DIR"

	# Anything in OUTPUT_DIR older than this marker predates the audit.
	run_marker=$(mktemp "${TMPDIR:-/tmp}/lhci-run-marker.XXXXXX")

	# Build LHCI command
	LHCI_ARGS=()
	LHCI_ARGS+=("autorun")

	# Always enforce output directory (CLI flags override config file)
	LHCI_ARGS+=("--upload.target=filesystem")
	LHCI_ARGS+=("--upload.outputDir=$OUTPUT_DIR")

	# Use config file if provided, otherwise generate inline config
	if [[ -n "$CONFIG_PATH" ]] && [[ -f "$CONFIG_PATH" ]]; then
		LHCI_ARGS+=("--config=$CONFIG_PATH")
		log_info "Using config from $CONFIG_PATH"
	else
		# Generate minimal config for single URL audit
		log_info "Running audit for URL: $URL"
		LHCI_ARGS+=("--collect.url=$URL")
		LHCI_ARGS+=("--collect.numberOfRuns=1")
		LHCI_ARGS+=("--collect.settings.chromeFlags=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage")
	fi

	# Add extra args
	if [[ -n "$EXTRA_ARGS" ]]; then
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		LHCI_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running Lighthouse CI..."

	exit_code=0
	run_lhci "${LHCI_ARGS[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"
	set_github_output "output-dir" "$OUTPUT_DIR"
	# The parse step reuses the marker so its fallback search cannot pick a
	# report that predates this audit either.
	set_github_output "run-marker" "$run_marker"

	# Find the results file
	if [[ -d "$OUTPUT_DIR" ]]; then
		results_file=$(find_lighthouse_report "$OUTPUT_DIR" "$run_marker")
		if [[ -n "$results_file" ]]; then
			set_github_output "results-path" "$results_file"
		fi
	fi

	exit "$exit_code"
	;;

parse)
	: "${RESULTS_PATH:=}"
	: "${OUTPUT_DIR:=lighthouse-reports}"
	: "${RUN_MARKER:=}"
	: "${THRESHOLD_PERFORMANCE:=80}"
	: "${THRESHOLD_ACCESSIBILITY:=90}"
	: "${THRESHOLD_BEST_PRACTICES:=80}"
	: "${THRESHOLD_SEO:=80}"

	# Find results file if not specified. With RUN_MARKER (set by the run
	# step) only a report written by that audit qualifies; a marker that no
	# longer exists means nothing can qualify.
	if [[ -z "$RESULTS_PATH" ]] || [[ ! -f "$RESULTS_PATH" ]]; then
		if [[ -n "$RUN_MARKER" && ! -f "$RUN_MARKER" ]]; then
			log_warn "Run marker not found: $RUN_MARKER"
			RESULTS_PATH=""
		elif [[ -d "$OUTPUT_DIR" ]]; then
			RESULTS_PATH=$(find_lighthouse_report "$OUTPUT_DIR" "$RUN_MARKER")
		fi
	fi

	# A missing report is its own failure, not a threshold miss: fail here
	# with an annotation instead of reporting four zero scores.
	if [[ -z "$RESULTS_PATH" ]] || [[ ! -f "$RESULTS_PATH" ]]; then
		set_github_output "performance" "0"
		set_github_output "accessibility" "0"
		set_github_output "best-practices" "0"
		set_github_output "seo" "0"
		set_github_output "passed" "false"
		echo "::error title=No Lighthouse report::No Lighthouse results found in ${OUTPUT_DIR} (expected manifest.json and *.report.json from lhci's filesystem upload target)" >&2
		exit 1
	fi

	# Parse the results
	parse_lighthouse_json "$RESULTS_PATH"

	# Set score outputs
	set_github_output "performance" "$LH_PERFORMANCE"
	set_github_output "accessibility" "$LH_ACCESSIBILITY"
	set_github_output "best-practices" "$LH_BEST_PRACTICES"
	set_github_output "seo" "$LH_SEO"

	# Check thresholds
	if check_lighthouse_thresholds "$THRESHOLD_PERFORMANCE" "$THRESHOLD_ACCESSIBILITY" "$THRESHOLD_BEST_PRACTICES" "$THRESHOLD_SEO"; then
		set_github_output "passed" "true"
		log_success "All Lighthouse scores meet thresholds"
	else
		set_github_output "passed" "false"
		set_github_output "failed-categories" "$LH_FAILED_CATEGORIES"
		log_warn "Failed categories: $LH_FAILED_CATEGORIES"
	fi

	log_info "Lighthouse scores: $(format_lighthouse_summary)"
	;;

summary)
	: "${PERFORMANCE:=0}"
	: "${ACCESSIBILITY:=0}"
	: "${BEST_PRACTICES:=0}"
	: "${SEO:=0}"
	: "${PASSED:=false}"
	: "${THRESHOLD_PERFORMANCE:=80}"
	: "${THRESHOLD_ACCESSIBILITY:=90}"
	: "${THRESHOLD_BEST_PRACTICES:=80}"
	: "${THRESHOLD_SEO:=80}"

	: "${PARSE_OUTCOME:=success}"

	add_github_summary "## Lighthouse CI Results"
	add_github_summary ""

	# Parse failed (no report): say so instead of tabling four zero scores.
	if [[ "$PARSE_OUTCOME" != "success" ]]; then
		add_github_summary "**Status:** :x: No Lighthouse report was found, so nothing was scored"
		add_github_summary ""
		exit 0
	fi

	if [[ "$PASSED" == "true" ]]; then
		add_github_summary "**Status:** :white_check_mark: All scores meet thresholds"
	else
		add_github_summary "**Status:** :warning: Some scores below thresholds"
	fi
	add_github_summary ""

	# Score emoji helper
	score_icon() {
		local score=$1
		local threshold=$2
		if [[ "$score" -ge "$threshold" ]]; then
			echo ":green_circle:"
		elif [[ "$score" -ge $((threshold - 10)) ]]; then
			echo ":yellow_circle:"
		else
			echo ":red_circle:"
		fi
	}

	add_github_summary "| Category | Score | Threshold |"
	add_github_summary "|----------|-------|-----------|"
	add_github_summary "| $(score_icon "$PERFORMANCE" "$THRESHOLD_PERFORMANCE") Performance | **$PERFORMANCE** | $THRESHOLD_PERFORMANCE |"
	add_github_summary "| $(score_icon "$ACCESSIBILITY" "$THRESHOLD_ACCESSIBILITY") Accessibility | **$ACCESSIBILITY** | $THRESHOLD_ACCESSIBILITY |"
	add_github_summary "| $(score_icon "$BEST_PRACTICES" "$THRESHOLD_BEST_PRACTICES") Best Practices | **$BEST_PRACTICES** | $THRESHOLD_BEST_PRACTICES |"
	add_github_summary "| $(score_icon "$SEO" "$THRESHOLD_SEO") SEO | **$SEO** | $THRESHOLD_SEO |"
	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
