#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: JUnit XML result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/junit.sh"
#   parse_junit_xml "results.xml"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_JUNIT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_JUNIT_LOADED=1

# Parse JUnit XML report and extract test counts
# Usage: parse_junit_xml "results.xml"
# Sets: TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL, TESTS_ERRORS,
#       TESTS_XFAILED (pytest's <skipped type="pytest.xfail"> elements, which
#       the skipped attribute also counts; 0 for other producers, #1685)
parse_junit_xml() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		TESTS_PASSED=0
		TESTS_FAILED=0
		TESTS_SKIPPED=0
		TESTS_TOTAL=0
		TESTS_ERRORS=0
		TESTS_XFAILED=0
		return 1
	fi

	# Extract from testsuite or testsuites root element
	# Skip XML prolog, DOCTYPE, and comments to find actual root element.
	# One awk process reads the file: the former `grep -v | grep -v | grep -m1`
	# pipeline SIGPIPE'd its writers on large reports once grep -m1 exited
	# (#1080). Leftmost-longest match, so <testsuites wins over <testsuite.
	local root_element
	root_element=$(awk '
		/^[[:space:]]*<[?!]/ { next }
		match($0, /<testsuites?/) { print substr($0, RSTART, RLENGTH); exit }
	' "$file")

	if [[ "$root_element" == "<testsuites" ]]; then
		# First try to extract from the <testsuites> root element itself
		local testsuites_line
		testsuites_line=$(grep '<testsuites' "$file" | head -1)
		TESTS_TOTAL=$(echo "$testsuites_line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
		TESTS_FAILED=$(echo "$testsuites_line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
		TESTS_ERRORS=$(echo "$testsuites_line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
		TESTS_SKIPPED=$(echo "$testsuites_line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')

		# For each missing attribute, sum from child <testsuite> elements
		# Handle each field independently to preserve partial root data
		local need_total need_failed need_errors need_skipped
		need_total=$([[ -z "$TESTS_TOTAL" ]] && echo 1 || echo 0)
		need_failed=$([[ -z "$TESTS_FAILED" ]] && echo 1 || echo 0)
		need_errors=$([[ -z "$TESTS_ERRORS" ]] && echo 1 || echo 0)
		need_skipped=$([[ -z "$TESTS_SKIPPED" ]] && echo 1 || echo 0)

		if [[ "$need_total" -eq 1 ]] || [[ "$need_failed" -eq 1 ]] || [[ "$need_errors" -eq 1 ]] || [[ "$need_skipped" -eq 1 ]]; then
			# Initialize only the missing fields
			[[ "$need_total" -eq 1 ]] && TESTS_TOTAL=0
			[[ "$need_failed" -eq 1 ]] && TESTS_FAILED=0
			[[ "$need_errors" -eq 1 ]] && TESTS_ERRORS=0
			[[ "$need_skipped" -eq 1 ]] && TESTS_SKIPPED=0

			# Sum from child <testsuite> elements (exclude <testsuites> lines)
			while IFS= read -r line; do
				local t f e s
				t=$(echo "$line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
				f=$(echo "$line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
				e=$(echo "$line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
				s=$(echo "$line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')
				[[ "$need_total" -eq 1 ]] && TESTS_TOTAL=$((TESTS_TOTAL + ${t:-0}))
				[[ "$need_failed" -eq 1 ]] && TESTS_FAILED=$((TESTS_FAILED + ${f:-0}))
				[[ "$need_errors" -eq 1 ]] && TESTS_ERRORS=$((TESTS_ERRORS + ${e:-0}))
				[[ "$need_skipped" -eq 1 ]] && TESTS_SKIPPED=$((TESTS_SKIPPED + ${s:-0}))
			done < <(grep '<testsuite' "$file" | grep -v '<testsuites')
		fi
	else
		# Single testsuite element - extract from first testsuite tag
		local testsuite_line
		testsuite_line=$(grep '<testsuite' "$file" | head -1)
		TESTS_TOTAL=$(echo "$testsuite_line" | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')
		TESTS_FAILED=$(echo "$testsuite_line" | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
		TESTS_ERRORS=$(echo "$testsuite_line" | sed -n 's/.*errors="\([0-9]*\)".*/\1/p')
		TESTS_SKIPPED=$(echo "$testsuite_line" | sed -n 's/.*skipped="\([0-9]*\)".*/\1/p')
	fi

	# Ensure values are set
	TESTS_TOTAL="${TESTS_TOTAL:-0}"
	TESTS_FAILED="${TESTS_FAILED:-0}"
	TESTS_ERRORS="${TESTS_ERRORS:-0}"
	TESTS_SKIPPED="${TESTS_SKIPPED:-0}"

	# Combine errors into failures for total failure count, but preserve TESTS_ERRORS
	TESTS_FAILED=$((TESTS_FAILED + TESTS_ERRORS))
	TESTS_PASSED=$((TESTS_TOTAL - TESTS_FAILED - TESTS_SKIPPED))

	# Ensure passed is not negative
	if [[ "$TESTS_PASSED" -lt 0 ]]; then
		TESTS_PASSED=0
	fi

	# pytest's junitxml writes an expected failure as <skipped
	# type="pytest.xfail" message="..."> (type before message) and counts it in
	# skipped. A non-strict unexpected pass is written as a plain passing
	# testcase, so JUnit cannot give xpassed. Only real elements count: CDATA
	# sections (captured <system-out> text) and comments are removed first,
	# and outside them a well-formed file has no raw "<" in text, so a test
	# log that quotes the tag is not counted (#1702). A count larger than
	# skipped is not this shape and is ignored.
	# Nothing skipped means nothing to move, so the file is not scanned. The
	# stripping is one pass over the pieces between openers (linear in the
	# file size): a piece is dropped up to its closer, and a piece with no
	# closer is still inside the section the previous opener started.
	TESTS_XFAILED=0
	if [[ "$TESTS_SKIPPED" -gt 0 ]]; then
		TESTS_XFAILED=$(awk '
			BEGIN { RS = "\001" }
			{ doc = doc $0 }
			function strip(text, opener_re, closer,    out, parts, count, i, stop) {
				count = split(text, parts, opener_re)
				out = parts[1]
				for (i = 2; i <= count; i++) {
					stop = index(parts[i], closer)
					if (stop > 0) {
						out = out substr(parts[i], stop + length(closer))
					}
				}
				return out
			}
			END {
				doc = strip(doc, "<!\\[CDATA\\[", "]]>")
				doc = strip(doc, "<!--", "-->")
				print gsub(/<skipped[ \t\r\n][^>]*type="pytest\.xfail"/, "", doc) + 0
			}
		' "$file" 2>/dev/null || echo "0")
	fi
	if [[ ! "$TESTS_XFAILED" =~ ^[0-9]+$ || "$TESTS_XFAILED" -gt "$TESTS_SKIPPED" ]]; then
		TESTS_XFAILED=0
	fi

	return 0
}

# Export functions
export -f parse_junit_xml

# JUnit XML (plus optional LCOV coverage) to results.v1 on stdout.
# Usage: junit_results_v1 "results.xml" ["coverage.lcov"]
# Reads: RESULTS_TOOL (default junit; nextest callers pass cargo-nextest),
#        RESULTS_RUNNER (default run-junit), EXIT_CODE, MATRIX_KEY,
#        MATRIX_VALUE, RESULTS_ARTIFACTS, RESULTS_SOURCE_VERSION
junit_results_v1() {
	local file="${1:-}"
	local coverage_file="${2:-}"
	local parse_status="ok"

	TESTS_DURATION_MS=0
	if [[ ! -f "$file" ]]; then
		parse_status="missing"
		parse_junit_xml "$file" || true
	elif ! grep -q '<testsuite' "$file"; then
		parse_status="invalid"
		parse_junit_xml "/nonexistent/junit.xml" || true
	else
		parse_junit_xml "$file" || true
		# Root element time="<seconds>" when the producer reports one. The
		# prolog and doctype are stripped in place (a one-line report keeps
		# its root on the prolog line). The root tag is picked with a bash
		# regex rather than `grep | head`: an early-closing reader makes the
		# writer hit SIGPIPE, which errexit/pipefail turn into a failure and
		# GNU grep reports as "write error: Broken pipe" (#1080).
		local content root_tag root_time=""
		content=$(sed -e 's/<?[^>]*?>//g' -e 's/<![^>]*>//g' "$file" | tr '\n' ' ')
		local root_re='<testsuites?[[:space:]][^>]*'
		local time_re='[[:space:]]time="([0-9.]+)"'
		if [[ "$content" =~ $root_re ]]; then
			root_tag="${BASH_REMATCH[0]}"
			if [[ "$root_tag" =~ $time_re ]]; then
				root_time="${BASH_REMATCH[1]}"
			fi
		fi
		if [[ -n "$root_time" ]]; then
			TESTS_DURATION_MS=$(awk -v t="$root_time" 'BEGIN { printf "%d", (t * 1000) + 0.5 }')
		fi
	fi

	COVERAGE_LINES=""
	COVERAGE_BRANCHES=""
	COVERAGE_FUNCTIONS=""
	if [[ -n "$coverage_file" && -f "$coverage_file" ]] &&
		declare -f extract_coverage_details >/dev/null 2>&1; then
		extract_coverage_details "$coverage_file" || true
	fi

	# Expected failures leave skipped for their own count (#1685); a report
	# without any keeps a document without the field.
	local xfailed=""
	if [[ "$parse_status" == "ok" && "${TESTS_XFAILED:-0}" -gt 0 ]]; then
		xfailed="$TESTS_XFAILED"
		TESTS_SKIPPED=$((TESTS_SKIPPED - xfailed))
	fi

	RESULTS_TOOL="${RESULTS_TOOL:-junit}" RESULTS_RUNNER="${RESULTS_RUNNER:-run-junit}" \
		RESULTS_PARSE_STATUS="$parse_status" TESTS_XFAILED="$xfailed" TESTS_XPASSED="" \
		results_v1_build
}

export -f junit_results_v1

# The case-level reader (#1686): junit_reader.py, standard library only, run
# as python3 -I. parse_junit_xml above stays the reader of the runner
# reusables (totals from the suite attributes); the case-level reader serves
# junit-artifact and the pytest reasons, and tests/python/test_junit_reader.py
# holds the two to the same counts on every JUnit fixture both can read.
_LGTM_CI_JUNIT_READER_PY="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)/junit_reader.py"
export _LGTM_CI_JUNIT_READER_PY

# One downloaded artifact of JUnit reports to one results.v1 leg on stdout.
# Usage: junit_artifact_results_v1 <artifact-dir> <glob> <scratch-file>
# Every regular file under <artifact-dir> matching <glob> is read and summed.
# A report that is unreadable, over a limit, or whose totals disagree with
# its cases gives a leg with status error (rendered as "counts unreadable"),
# never a passing one. Returns 3, writing nothing, when no file matches.
# Reads: MATRIX_KEY, MATRIX_VALUE, RESULTS_SOURCE_VERSION
junit_artifact_results_v1() {
	local dir="${1:?artifact directory is required}"
	local pattern="${2:?glob is required}"
	local scratch="${3:?scratch file is required}"
	local status reason
	python3 -I "$_LGTM_CI_JUNIT_READER_PY" leg "$dir" "$pattern" >"$scratch" || return 2
	status="$(jq -r '.status' "$scratch")"
	case "$status" in
	ok)
		local passed failed skipped total xfailed
		IFS=$'\t' read -r passed failed skipped total xfailed < <(
			jq -r '.counts | [.passed, .failed, .skipped, .total, .xfailed] | @tsv' "$scratch"
		)
		# No expected failures keeps a document without the field, as
		# junit_results_v1 does. JUnit cannot tell a non-strict unexpected
		# pass from a pass, so counts.xpassed is never written.
		[[ "$xfailed" == "0" ]] && xfailed=""
		RESULTS_TOOL=junit RESULTS_RUNNER=junit-artifact RESULTS_PARSE_STATUS=ok \
			TESTS_PASSED="$passed" TESTS_FAILED="$failed" TESTS_SKIPPED="$skipped" \
			TESTS_TOTAL="$total" TESTS_XFAILED="$xfailed" TESTS_XPASSED="" TESTS_DURATION_MS=0 \
			COVERAGE_LINES="" COVERAGE_BRANCHES="" COVERAGE_FUNCTIONS="" EXIT_CODE="" \
			RESULTS_ARTIFACTS="" RESULTS_INCOMPLETE="" RESULTS_STATUS="" \
			RESULTS_EXPECTED_FAILURES_FILE=<(jq -c '.expected_failures' "$scratch") \
			results_v1_build
		;;
	missing)
		return 3
		;;
	*)
		# The reason names a file and a rule; the reader keeps it to a safe
		# character set, so it cannot start a workflow command.
		reason="$(jq -r '.reason // "unknown"' "$scratch")"
		echo "::warning title=JUnit report unreadable::${MATRIX_VALUE:-artifact}: ${reason}" >&2
		RESULTS_TOOL=junit RESULTS_RUNNER=junit-artifact RESULTS_PARSE_STATUS=invalid \
			TESTS_PASSED=0 TESTS_FAILED=0 TESTS_SKIPPED=0 TESTS_TOTAL=0 TESTS_XFAILED="" \
			TESTS_XPASSED="" TESTS_DURATION_MS=0 COVERAGE_LINES="" COVERAGE_BRANCHES="" \
			COVERAGE_FUNCTIONS="" EXIT_CODE="" RESULTS_ARTIFACTS="" RESULTS_INCOMPLETE="" \
			RESULTS_STATUS="" RESULTS_EXPECTED_FAILURES_FILE="" \
			results_v1_build
		;;
	esac
}

# Expected-failure reasons of one JUnit report as a JSON object keyed by
# "<classname>::<name>" on stdout; {} when the file is missing or unreadable.
# Usage: junit_xfail_reasons <file>
junit_xfail_reasons() {
	local file="${1:-}"
	if [[ -z "$file" || ! -f "$file" ]]; then
		printf '{}\n'
		return 0
	fi
	python3 -I "$_LGTM_CI_JUNIT_READER_PY" reasons "$file" 2>/dev/null |
		jq -c 'if .status == "ok" then .reasons else {} end' 2>/dev/null || printf '{}\n'
}

export -f junit_artifact_results_v1 junit_xfail_reasons
