#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the coverage, test-result and security entry points on
# well-formed fixtures for golden comparison (#1692)
#
# The rows of the #1692 main-against-head differential check that no other
# golden covers: the collect-coverage convert, merge-to-LCOV and summary
# steps, the badge on JSON reports, the pytest, vitest, Rust and Playwright
# parse steps (their GITHUB_OUTPUT and results.v1 document), and the security
# comment formatter. Each case prints its exit status, its GITHUB_OUTPUT
# lines, its job summary and the files it wrote, with the work directory,
# random delimiters and timestamps normalised. The converters run with lcov,
# nyc, pycobertura, lcov_cobertura and the coverage CLI off PATH, so the
# built-in fallbacks are what is compared. Every case runs under golden_env
# (golden_env.bash): a fixed environment, never the runner's GITHUB_*
# variables, with its stderr discarded.
# tests/fixtures/entrypoint-golden/well-formed.main.txt holds what main's
# scripts printed; well-formed reports must render byte for byte the same.
#
# Usage: load "../../../helpers/entrypoint_golden"
#        entrypoint_golden_render WORK_DIR   (prints the rendering)

# shellcheck source=tests/helpers/golden_env.bash
source "${BASH_SOURCE[0]%/*}/golden_env.bash"

#: The optional converters hidden from PATH.
ENTRYPOINT_GOLDEN_HIDDEN=(lcov nyc pycobertura lcov_cobertura coverage)

# Internal: tell whether a command name is one of the hidden converters.
# Usage: _entrypoint_golden_hidden NAME
_entrypoint_golden_hidden() {
	local tool
	for tool in "${ENTRYPOINT_GOLDEN_HIDDEN[@]}"; do
		[[ "$1" == "$tool" ]] && return 0
	done
	return 1
}

# Internal: PATH with the optional converters hidden (each directory that
# holds one is replaced by a directory of links to everything else in it).
# Usage: _entrypoint_golden_path WORK
_entrypoint_golden_path() {
	local work="$1" dir entry stand_in kept=() index=0 tool hidden
	local -a dirs
	IFS=: read -r -a dirs <<<"$PATH"
	for dir in "${dirs[@]}"; do
		[[ -n "$dir" ]] || continue
		hidden=false
		for tool in "${ENTRYPOINT_GOLDEN_HIDDEN[@]}"; do
			[[ -e "${dir}/${tool}" ]] && hidden=true
		done
		if [[ "$hidden" == false ]]; then
			kept+=("$dir")
			continue
		fi
		index=$((index + 1))
		stand_in="${work}/path-${index}"
		mkdir -p "$stand_in"
		for entry in "$dir"/*; do
			_entrypoint_golden_hidden "${entry##*/}" || ln -s "$entry" "${stand_in}/${entry##*/}"
		done
		kept+=("$stand_in")
	done
	local IFS=:
	printf '%s' "${kept[*]}"
}

# Internal: normalise what varies between runs.
_entrypoint_golden_norm() {
	sed -E -e "s|$1|<work>|g" -e "s|${PROJECT_ROOT}|<root>|g" \
		-e 's/ghadelimiter_[A-Za-z0-9_]+/<delim>/g' -e 's/^([a-z-]+)<<[A-Za-z0-9_]{8,}$/\1<<<delim>/' \
		-e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?/<ts>/g' \
		-e 's/Generated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}/Generated:** <date>/'
}

# Internal: run one case in a fresh directory and print its record.
# Usage: _entrypoint_golden_case NAME WORK FILE:DEST... -- NAME=VALUE... COMMAND...
_entrypoint_golden_case() {
	local name="$1" base="$2" work rc=0 file
	shift 2
	work="$(mktemp -d "${base}/case.XXXXXX")"
	while [[ "$1" != "--" ]]; do
		mkdir -p "$(dirname "${work}/${1##*:}")"
		cp "${PROJECT_ROOT}/tests/fixtures/${1%%:*}" "${work}/${1##*:}"
		shift
	done
	shift
	: >"${work}/.out"
	: >"${work}/.summary"
	(cd "$work" && golden_env GITHUB_OUTPUT="${work}/.out" GITHUB_STEP_SUMMARY="${work}/.summary" \
		RESULTS_SOURCE_VERSION=fixed LGTM_CI_TOOLING_SHA=fixed "$@") >"${work}/.stdout" 2>/dev/null || rc=$?
	{
		printf '=== %s\nexit=%s\n--- outputs\n' "$name" "$rc"
		cat "${work}/.out"
		printf -- '--- summary\n'
		cat "${work}/.summary"
		for file in $(cd "$work" && find . -type f \( -name 'merged*' -o -name 'out.*' \
			-o -name 'results.json' \) | LC_ALL=C sort); do
			printf -- '--- %s\n' "$file"
			cat "${work}/${file}"
		done
		if [[ "$*" == *format-security-comment.py* ]]; then
			printf -- '--- stdout\n'
			cat "${work}/.stdout"
		fi
	} | _entrypoint_golden_norm "$work"
}

# Usage: entrypoint_golden_render WORK_DIR
entrypoint_golden_render() {
	local work="$1" bare actions="${PROJECT_ROOT}/scripts/ci/actions" fixture name toml
	mkdir -p "$work"
	bare="$(_entrypoint_golden_path "$work")"
	local -a collect=(env PATH="$bare" bash "${actions}/collect-coverage.sh")

	# collect-coverage convert and merge, the built-in converters.
	_entrypoint_golden_case convert-cobertura-lcov "$work" coverage/sample_cobertura.xml:coverage.xml -- \
		STEP=convert INPUT_FILE=coverage.xml INPUT_FORMAT=cobertura OUTPUT_FORMAT=lcov OUTPUT_FILE=out.lcov "${collect[@]}"
	_entrypoint_golden_case convert-cobertura-python-lcov "$work" detect/cobertura-python.xml:coverage.xml -- \
		STEP=convert INPUT_FILE=coverage.xml INPUT_FORMAT=auto OUTPUT_FORMAT=lcov OUTPUT_FILE=out.lcov "${collect[@]}"
	_entrypoint_golden_case convert-lcov-lcov "$work" rust/coverage-partial.lcov:coverage.lcov -- \
		STEP=convert INPUT_FILE=coverage.lcov INPUT_FORMAT=lcov OUTPUT_FORMAT=lcov OUTPUT_FILE=out.lcov "${collect[@]}"
	_entrypoint_golden_case convert-istanbul-json "$work" detect/istanbul-js.json:coverage-final.json -- \
		STEP=convert INPUT_FILE=coverage-final.json INPUT_FORMAT=istanbul OUTPUT_FORMAT=json OUTPUT_FILE=out.json \
		"${collect[@]}"
	_entrypoint_golden_case convert-coverage-py-json "$work" coverage/coverage.json:coverage.json -- \
		STEP=convert INPUT_FILE=coverage.json INPUT_FORMAT=coverage-py OUTPUT_FORMAT=json OUTPUT_FILE=out.json \
		"${collect[@]}"
	_entrypoint_golden_case merge-cobertura-to-lcov "$work" coverage/sample_cobertura.xml:coverage.xml -- \
		STEP=merge COVERAGE_FILES=coverage.xml INPUT_FORMAT=cobertura OUTPUT_FORMAT=lcov OUTPUT_FILE=merged.info \
		"${collect[@]}"
	_entrypoint_golden_case merge-lcov-to-lcov "$work" rust/coverage-full.lcov:a.info \
		coverage/lcov-full.info:b.info -- STEP=merge COVERAGE_FILES=a.info,b.info INPUT_FORMAT=lcov \
		OUTPUT_FORMAT=lcov OUTPUT_FILE=merged.info "${collect[@]}"

	# An empty coverage map (istanbul's blank summary: every pct "Unknown",
	# not measured), and reports read as the format the caller declared: an
	# istanbul report without an extension, a summary under another name.
	_entrypoint_golden_case merge-empty-map "$work" \
		vitest/coverage-summary-empty-map.json:coverage-summary.json -- STEP=merge \
		COVERAGE_FILES=coverage-summary.json INPUT_FORMAT=istanbul "${collect[@]}"
	_entrypoint_golden_case merge-declared-istanbul-no-extension "$work" \
		detect/istanbul-js.json:coverage-final -- STEP=merge COVERAGE_FILES=coverage-final \
		INPUT_FORMAT=istanbul "${collect[@]}"
	_entrypoint_golden_case merge-declared-istanbul-summary-no-extension "$work" \
		vitest/coverage-summary-standard.json:coverage-summary -- STEP=merge \
		COVERAGE_FILES=coverage-summary INPUT_FORMAT=istanbul "${collect[@]}"
	_entrypoint_golden_case comment-declared-istanbul "$work" \
		vitest/coverage-summary-standard.json:coverage.info -- COVERAGE_FILE=coverage.info FORMAT=istanbul \
		THRESHOLD_LINES=80 THRESHOLD_BRANCHES=70 THRESHOLD_FUNCTIONS=80 \
		bash "${actions}/generate-coverage-comment.sh"
	_entrypoint_golden_case comment-empty-map "$work" \
		vitest/coverage-summary-empty-map.json:coverage-summary.json -- COVERAGE_FILE=coverage-summary.json \
		THRESHOLD_LINES=0 THRESHOLD_BRANCHES=0 THRESHOLD_FUNCTIONS=0 \
		bash "${actions}/generate-coverage-comment.sh"

	# collect-coverage summary (a JSON summary's detail rows read 0 on main:
	# kept as it is here, a follow-up of #1692).
	for fixture in coverage/lcov-full.info coverage/sample_cobertura.xml coverage/coverage.json \
		vitest/coverage-summary-standard.json vitest/coverage-summary-empty-map.json \
		pytest/coverage-standard.json; do
		name="${fixture##*/}"
		_entrypoint_golden_case "summary-${name}" "$work" "${fixture}:${name}" -- \
			STEP=summary COVERAGE_FILE="$name" "${collect[@]}"
	done

	# The badge on the JSON and Rust reports the coverage gate goldens leave out.
	for fixture in vitest/coverage-summary-0.json vitest/coverage-summary-100.json \
		vitest/coverage-summary-standard.json pytest/coverage-0.json pytest/coverage-100.json \
		pytest/coverage-standard.json pytest/coverage-no-branches.json rust/coverage-full.lcov \
		rust/coverage-partial.lcov; do
		name="${fixture##*/}"
		_entrypoint_golden_case "badge-${fixture%%/*}-${name}" "$work" "${fixture}:${name}" -- \
			STEP=calculate COVERAGE_FILE="$name" bash "${actions}/generate-coverage-badge.sh"
	done

	# Parse steps: GITHUB_OUTPUT and the results.v1 document.
	_entrypoint_golden_case vitest-parse-summary "$work" vitest/all-passing.json:vitest-results.json \
		vitest/coverage-summary-standard.json:coverage/coverage-summary.json -- STEP=parse \
		COVERAGE_FILE=coverage/coverage-summary.json RESULTS_OUTPUT=results.json bash "${actions}/run-vitest.sh"
	_entrypoint_golden_case vitest-parse-empty-map "$work" vitest/all-passing.json:vitest-results.json \
		vitest/coverage-summary-empty-map.json:coverage/coverage-summary.json -- STEP=parse \
		COVERAGE_FILE=coverage/coverage-summary.json RESULTS_OUTPUT=results.json bash "${actions}/run-vitest.sh"
	for fixture in pytest/coverage-standard.json pytest/coverage-no-branches.json pytest/coverage-100.json \
		coverage/sample_cobertura.xml coverage/lcov-full.info; do
		name="${fixture##*/}"
		_entrypoint_golden_case "pytest-parse-${name}" "$work" pytest/all-passing.json:pytest-results.json \
			"${fixture}:${name}" -- STEP=parse COVERAGE_FILE="$name" RESULTS_OUTPUT=results.json \
			bash "${actions}/run-pytest.sh"
	done
	for fixture in rust/coverage-full.lcov rust/coverage-partial.lcov coverage/lcov-full.info; do
		name="${fixture##*/}"
		_entrypoint_golden_case "rust-parse-${name}" "$work" rust/junit-two-tests.xml:junit.xml \
			"${fixture}:${name}" -- JUNIT_FILE=junit.xml LCOV_FILE="$name" COVERAGE_ENABLED=true \
			RESULTS_OUTPUT=results.json bash "${PROJECT_ROOT}/scripts/ci/testing/rust/parse-rust-test-results.sh"
	done
	for fixture in "${PROJECT_ROOT}"/tests/fixtures/playwright/reports/json-*.json; do
		name="${fixture##*/}"
		_entrypoint_golden_case "playwright-parse-${name}" "$work" \
			"playwright/reports/${name}:playwright-results.json" -- STEP=parse \
			REPORT_PATH=playwright-results.json RESULTS_OUTPUT=results.json EXIT_CODE=0 \
			bash "${actions}/run-playwright-tests.sh"
	done

	# The security comment formatter, alone and with each scanner config.
	for fixture in "${PROJECT_ROOT}"/tests/fixtures/security/osv-results-*.json; do
		name="${fixture##*/}"
		_entrypoint_golden_case "security-${name}" "$work" "security/${name}:osv.json" -- \
			python3 -I "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" osv.json
		for toml in "${PROJECT_ROOT}"/tests/fixtures/security/osv-scanner-*.toml; do
			_entrypoint_golden_case "security-${name}-${toml##*/}" "$work" "security/${name}:osv.json" \
				"security/${toml##*/}:.osv-scanner.toml" -- \
				python3 -I "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" osv.json
		done
	done
}
