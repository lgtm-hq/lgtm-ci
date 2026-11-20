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
#   JUNIT_DIR           Directory holding one sub-directory per downloaded
#                       JUnit artifact (#1686): each becomes one results.v1
#                       leg from the files matching JUNIT_PATH (default
#                       **/*.xml) and the legs are rendered as RESULTS_DIR
#                       legs are. JUNIT_DIR with RESULTS_DIR or RESULTS_FILE
#                       is an error. COVERAGE_PERCENT still applies (a JUnit
#                       report carries no coverage).
#                       With none of the three set the legacy TESTS_* /
#                       COVERAGE_PERCENT environment is rendered as before
#   EXPECTED_COUNT      (optional) Number of legs RESULTS_DIR (or JUNIT_DIR
#                       artifacts) must contain
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
# shellcheck source=../lib/testing/parse/junit.sh
source "$SCRIPT_DIR/../lib/testing/parse/junit.sh"

: "${RESULTS_FILE:=}"
: "${RESULTS_DIR:=}"
: "${JUNIT_DIR:=}"
: "${JUNIT_PATH:=}"
: "${EXPECTED_COUNT:=}"
[[ -z "$JUNIT_PATH" ]] && JUNIT_PATH='**/*.xml'

if [[ -n "$JUNIT_DIR" && (-n "$RESULTS_DIR" || -n "$RESULTS_FILE") ]]; then
	echo "::error title=conflicting test summary sources::junit-artifact and" \
		"results-artifact-pattern cannot both be set: pass one of them" >&2
	exit 1
fi

if [[ -z "$RESULTS_FILE" && -z "$RESULTS_DIR" && -z "$JUNIT_DIR" ]]; then
	# Legacy direct callers of reusable-publish-test-summary.yml still pass
	# counts as inputs; render those unchanged. The inputs carry no list, so
	# a RESULTS_EXPECTED_FAILURES_FILE an earlier step left in the
	# environment (GITHUB_ENV) must not reach the generator (#1702).
	unset RESULTS_EXPECTED_FAILURES_FILE
	exec bash "$SCRIPT_DIR/generate-test-summary.sh"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# JUnit artifacts (#1686): one results.v1 leg per artifact, then the
# RESULTS_DIR path below. A missing or empty artifact fails the job by name.
junit_coverage=""
if [[ -n "$JUNIT_DIR" ]]; then
	junit_coverage="${COVERAGE_PERCENT:-}"
	if [[ ! -d "$JUNIT_DIR" ]]; then
		echo "::error title=JUnit artifact missing::no artifact matched junit-artifact" >&2
		exit 1
	fi
	mapfile -t artifacts < <(find "$JUNIT_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
	if ((${#artifacts[@]} == 0)); then
		echo "::error title=JUnit artifact missing::no artifact matched junit-artifact" >&2
		exit 1
	fi
	leg_index=0
	for artifact in "${artifacts[@]}"; do
		leg_index=$((leg_index + 1))
		leg_dir="${work_dir}/junit-legs/${leg_index}"
		mkdir -p "$leg_dir"
		leg_status=0
		MATRIX_KEY=artifact MATRIX_VALUE="${artifact##*/}" \
			junit_artifact_results_v1 "$artifact" "$JUNIT_PATH" "${work_dir}/junit-reader.json" \
			>"${leg_dir}/results.json" || leg_status=$?
		if ((leg_status == 3)); then
			# Job log only. Characters outside a safe set become "?", so a
			# name cannot end the line and start a workflow command.
			shown_name="${artifact##*/}"
			shown_name="${shown_name//[^A-Za-z0-9._ +@=-]/?}"
			shown_path="${JUNIT_PATH//[^A-Za-z0-9._ +@=\/\*\{\},-]/?}"
			echo "::error title=JUnit report missing::artifact ${shown_name} has no file" \
				"matching junit-path ${shown_path}" >&2
			exit 1
		elif ((leg_status != 0)); then
			echo "::error::render-test-summary: could not read the JUnit artifacts" >&2
			exit 1
		fi
	done
	RESULTS_DIR="${work_dir}/junit-legs"
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
# A JUnit report has no coverage; the caller's coverage-percent stays (#1686).
[[ -n "$junit_coverage" ]] && COVERAGE_PERCENT="$junit_coverage"
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
