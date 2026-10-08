#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pure renderer (#1080): results.v1 document(s) -> PR test-summary comment.
#
# The publisher hands this script the results.json artifacts it downloaded
# (one per runner leg) and nothing else about the tests. Several legs are
# folded through aggregate-results.sh first. The markdown itself comes from
# generate-test-summary.sh, so a comment rendered from results.json is
# byte-identical to one rendered from the pre-contract job outputs for the
# same counts.
#
# Environment:
#   RESULTS_FILE        One results.v1 document to render; or
#   RESULTS_DIR         Directory holding one or more <...>/results.json legs;
#                       with neither set the legacy TESTS_* / COVERAGE_PERCENT
#                       environment is rendered as before
#   EXPECTED_COUNT      (optional) Number of legs RESULTS_DIR must contain
#   TESTS_TOTAL_EXCLUDES_SKIPPED  "true": Total Tests / pass rate use
#                       passed + failed (the Rust reusable's historical total)
#   TEST_SUITE_NAME, COVERAGE_ENABLED, COVERAGE_THRESHOLD, JOB_RESULT,
#   COMMENT_OUTPUT, GITHUB_*  Passed through to generate-test-summary.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

: "${RESULTS_FILE:=}"
: "${RESULTS_DIR:=}"
: "${EXPECTED_COUNT:=}"

if [[ -z "$RESULTS_FILE" && -z "$RESULTS_DIR" ]]; then
	# Legacy direct callers of reusable-publish-test-summary.yml still pass
	# counts as inputs; render those unchanged.
	exec bash "$SCRIPT_DIR/generate-test-summary.sh"
fi

if [[ -z "$RESULTS_FILE" ]]; then
	if [[ ! -d "$RESULTS_DIR" ]]; then
		echo "::error::render-test-summary: RESULTS_DIR does not exist: ${RESULTS_DIR}" >&2
		exit 1
	fi
	leg_count="$(find "$RESULTS_DIR" -type f -name 'results.json' | wc -l | tr -d ' ')"
	if [[ -n "$EXPECTED_COUNT" && "$leg_count" != "$EXPECTED_COUNT" ]]; then
		echo "::error::render-test-summary: expected ${EXPECTED_COUNT} results.json legs under ${RESULTS_DIR}, found ${leg_count}" >&2
		exit 1
	fi
	work_dir="$(mktemp -d)"
	trap 'rm -rf "$work_dir"' EXIT
	# aggregate-results.sh validates every leg and writes the merged document.
	GITHUB_OUTPUT="${work_dir}/outputs" AGGREGATE_OUTPUT="${work_dir}/results.json" \
		RESULTS_DIR="$RESULTS_DIR" MATRIX_JSON="" \
		bash "$SCRIPT_DIR/aggregate-results.sh" >/dev/null
	RESULTS_FILE="${work_dir}/results.json"
else
	results_v1_validate "$RESULTS_FILE"
fi

IFS=$'\t' read -r TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL COVERAGE_PERCENT RESULTS_STATUS < <(
	jq -r '[.counts.passed, .counts.failed, .counts.skipped, .counts.total,
		(.coverage.lines // "-"), .status] | @tsv' "$RESULTS_FILE"
)
# "-" marks an absent coverage: bash collapses adjacent tab separators.
[[ "$COVERAGE_PERCENT" == "-" ]] && COVERAGE_PERCENT=""
# Rust has always reported passed + failed as its total (pass rate without
# skipped tests); counts.total in the document stays inclusive.
if [[ "${TESTS_TOTAL_EXCLUDES_SKIPPED:-}" == "true" ]]; then
	TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED))
fi
# The document status is authoritative when the caller gave no job result:
# a failed or error leg must not render as PASSED because its failed count
# happens to be zero.
if [[ -z "${JOB_RESULT:-}" || "${JOB_RESULT}" == "unknown" ]]; then
	case "$RESULTS_STATUS" in
	passed) JOB_RESULT="success" ;;
	failed | error) JOB_RESULT="failure" ;;
	esac
	export JOB_RESULT
fi
export TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL COVERAGE_PERCENT

exec bash "$SCRIPT_DIR/generate-test-summary.sh"
