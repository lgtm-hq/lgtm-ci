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
#   TESTS_TOTAL_EXCLUDES_SKIPPED  "true": Total Tests uses passed + failed
#                       (the Rust reusable's historical total); the pass rate
#                       is passed / (passed + failed) either way (#1684)
#   Document status "error" is passed on as RESULTS_PARSE_STATUS=error, which
#   omits the counts table (#1371). A document "incomplete" reason (#1531) is
#   passed on as RESULTS_INCOMPLETE. counts.xfailed and counts.xpassed
#   (#1685) are passed on as TESTS_XFAILED and TESTS_XPASSED (empty when the
#   document has none), and the document's expected_failures object as the
#   file RESULTS_EXPECTED_FAILURES_FILE (a file: the list can be larger than
#   one environment variable may hold).
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

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

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
# Expected failures and unexpected passes (#1685): "-" when absent, which the
# generator reads as none, so a document without them renders as before.
IFS=$'\t' read -r TESTS_XFAILED TESTS_XPASSED < <(
	jq -r '[(.counts.xfailed // "-"), (.counts.xpassed // "-")] | @tsv' "$RESULTS_FILE"
)
[[ "$TESTS_XFAILED" == "-" ]] && TESTS_XFAILED=""
[[ "$TESTS_XPASSED" == "-" ]] && TESTS_XPASSED=""
RESULTS_EXPECTED_FAILURES_FILE=""
if jq -e 'has("expected_failures")' "$RESULTS_FILE" >/dev/null; then
	RESULTS_EXPECTED_FAILURES_FILE="${work_dir}/expected-failures.json"
	jq -c '.expected_failures' "$RESULTS_FILE" >"$RESULTS_EXPECTED_FAILURES_FILE"
fi
export TESTS_XFAILED TESTS_XPASSED RESULTS_EXPECTED_FAILURES_FILE
# Rust has always reported passed + failed as its total; counts.total in the
# document stays inclusive.
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
# A cut-short run (#1531) renders as incomplete, with no totals or percentage.
RESULTS_INCOMPLETE="$(jq -r '.incomplete // ""' "$RESULTS_FILE")"
export RESULTS_INCOMPLETE
# An errored document (missing or invalid native report) carries no real counts.
if [[ "$RESULTS_STATUS" == "error" ]]; then
	RESULTS_PARSE_STATUS="error"
else
	RESULTS_PARSE_STATUS="ok"
fi
export RESULTS_PARSE_STATUS
export TESTS_PASSED TESTS_FAILED TESTS_SKIPPED TESTS_TOTAL COVERAGE_PERCENT

# Not exec: the EXIT trap removes work_dir after the generator ran.
bash "$SCRIPT_DIR/generate-test-summary.sh"
