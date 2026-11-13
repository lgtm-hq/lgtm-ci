#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: One normalisation of the Playwright `reporter` input (#1474)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/playwright_reporter.sh"
#   REPORTER=$(playwright_effective_reporter "$REPORTER")
#
# run-playwright.sh (run and parse steps) and the e2e matrix setup job
# (generate-matrix.sh e2e-reporter) all read the reporter through this
# function, so the reporter that runs, the file that is parsed and the merge's
# shard check cannot disagree.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PLAYWRIGHT_REPORTER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PLAYWRIGHT_REPORTER_LOADED=1

# Print the reporter run-playwright.sh actually runs for an input value:
# `json`, `html` (HTML plus the JSON sidecar) or `junit`.
#
# Case and surrounding whitespace are ignored, as in GitHub expressions. Any
# other value (`blob`, `list`, a comma list such as `html,junit`) runs the JSON
# reporter, so it maps to `json`; only a bare `junit` writes no JSON results.
# An empty value uses the default (second argument, `json` when omitted).
#
# Arguments:
#   $1 - reporter input
#   $2 - default for an empty input (optional, default json)
playwright_effective_reporter() {
	local reporter
	reporter=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$reporter" in
	"")
		printf '%s\n' "${2:-json}"
		;;
	json | html | junit)
		printf '%s\n' "$reporter"
		;;
	*)
		printf '%s\n' "json"
		;;
	esac
}
