#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the coverage gate's outputs for golden comparison (#1692)
#
# The merge (collect-coverage.sh STEP=merge), the threshold check
# (check-coverage-threshold.sh) and the badge (generate-coverage-badge.sh)
# read the percentage extract_coverage_percent gives. Each case below runs one
# of them on a well-formed report from tests/fixtures/coverage and prints its
# exit status, its GITHUB_OUTPUT lines and the files it wrote, with the work
# directory replaced by <work>. tests/fixtures/coverage-gate-golden/<case>.txt
# holds what the scripts printed before #1692 routed the percentage through
# the validated readers; the outputs must stay byte for byte the same. Every
# script runs under golden_env (golden_env.bash): a fixed environment, never
# the runner's GITHUB_* variables, with its stderr discarded.
#
# Usage: load "../../../helpers/coverage_gate_golden"
#        coverage_gate_render CASE WORK_DIR   (prints the rendering)
#        COVERAGE_GATE_CASES                  (every case name)

# shellcheck source=tests/helpers/golden_env.bash
source "${BASH_SOURCE[0]%/*}/golden_env.bash"

# shellcheck disable=SC2034 # read by the tests that load this file
COVERAGE_GATE_CASES=(
	merge-lcov-full
	merge-lcov-line-only-pair
	merge-cobertura
	merge-istanbul
	badge-calculate-lcov-full
	badge-calculate-lcov-line-only
	badge-calculate-lcov-empty
	badge-calculate-cobertura
	badge-calculate-coverage-py
	badge-generate-svg
	badge-generate-json
	badge-summary
	threshold-below
	threshold-met
	threshold-zero
)

# Run one script with a fresh GITHUB_OUTPUT inside WORK and print the result.
# Usage: _coverage_gate_run WORK SCRIPT [NAME=VALUE ...]
_coverage_gate_run() {
	local work="$1" script="$2"
	shift 2
	local outputs="${work}/github-output" summary="${work}/step-summary" rc=0
	: >"$outputs"
	: >"$summary"
	(cd "$work" && golden_env GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" "$@" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/${script}") >/dev/null 2>&1 || rc=$?
	printf 'exit=%s\n--- outputs\n' "$rc"
	sed "s|${work}|<work>|g" "$outputs"
	if [[ -s "$summary" ]]; then
		printf -- '--- summary\n'
		sed "s|${work}|<work>|g" "$summary"
	fi
}

# Print one file under a heading; sorted when the producer's order is not fixed.
# Usage: _coverage_gate_file WORK NAME [sorted]
_coverage_gate_file() {
	local path="${1}/${2}"
	printf -- '--- %s\n' "$2"
	if [[ ! -f "$path" ]]; then
		printf '(absent)\n'
	elif [[ "${3:-}" == sorted ]]; then
		LC_ALL=C sort "$path"
	else
		cat "$path"
	fi
}

# Usage: coverage_gate_render CASE WORK_DIR
coverage_gate_render() {
	local name="$1" work="$2" fixtures="${PROJECT_ROOT}/tests/fixtures/coverage"
	mkdir -p "$work"
	case "$name" in
	merge-lcov-full)
		cp "${fixtures}/lcov-full.info" "${work}/a.info"
		_coverage_gate_run "$work" collect-coverage.sh STEP=merge COVERAGE_FILES=a.info \
			INPUT_FORMAT=lcov OUTPUT_FORMAT=lcov OUTPUT_FILE=merged.info
		_coverage_gate_file "$work" merged.info
		;;
	merge-lcov-line-only-pair)
		# Two files without BR/FN records: the fallback merge (no lcov binary)
		# rebuilds the totals; its record order is awk's, so it is sorted.
		cp "${fixtures}/lcov-line-only.info" "${work}/a.info"
		cp "${fixtures}/lcov-empty.info" "${work}/b.info"
		_coverage_gate_run "$work" collect-coverage.sh STEP=merge COVERAGE_FILES="a.info b.info" \
			INPUT_FORMAT=lcov OUTPUT_FORMAT=lcov OUTPUT_FILE=merged.info PATH="$(_coverage_gate_path_without_lcov "$work")"
		_coverage_gate_file "$work" merged.info sorted
		;;
	merge-cobertura)
		cp "${fixtures}/sample_cobertura.xml" "${work}/coverage.xml"
		_coverage_gate_run "$work" collect-coverage.sh STEP=merge COVERAGE_FILES=coverage.xml \
			INPUT_FORMAT=cobertura OUTPUT_FORMAT= OUTPUT_FILE=merged.xml
		;;
	merge-istanbul)
		# An istanbul coverage-final.json converted without nyc (#1692 review).
		cat >"${work}/coverage-final.json" <<'JSON'
{"/src/app.js":{"path":"/src/app.js","statementMap":{"0":{"start":{"line":1,"column":0},"end":{"line":1,"column":10}},"1":{"start":{"line":2,"column":0},"end":{"line":2,"column":10}}},"fnMap":{},"branchMap":{},"s":{"0":1,"1":0},"f":{},"b":{},"lines":{"total":2,"covered":1},"branches":{"total":2,"covered":1},"functions":{"total":2,"covered":1},"statements":{"total":2,"covered":1}}}
JSON
		_coverage_gate_run "$work" collect-coverage.sh STEP=merge COVERAGE_FILES=coverage-final.json \
			INPUT_FORMAT=istanbul OUTPUT_FORMAT=lcov OUTPUT_FILE=merged.info \
			PATH="$(_coverage_gate_path_without_lcov "$work")"
		_coverage_gate_file "$work" merged.info
		;;
	badge-calculate-*)
		local source
		case "${name#badge-calculate-}" in
		lcov-full) source="lcov-full.info" ;;
		lcov-line-only) source="lcov-line-only.info" ;;
		lcov-empty) source="lcov-empty.info" ;;
		cobertura) source="sample_cobertura.xml" ;;
		coverage-py) source="coverage.json" ;;
		esac
		cp "${fixtures}/${source}" "${work}/${source}"
		_coverage_gate_run "$work" generate-coverage-badge.sh STEP=calculate COVERAGE_FILE="$source"
		;;
	badge-generate-svg | badge-generate-json)
		local format="${name#badge-generate-}"
		_coverage_gate_run "$work" generate-coverage-badge.sh STEP=generate COVERAGE_PERCENT=62.50 \
			FORMAT="$format" OUTPUT_PATH="badge.${format}"
		_coverage_gate_file "$work" "badge.${format}"
		;;
	badge-summary)
		_coverage_gate_run "$work" generate-coverage-badge.sh STEP=summary COVERAGE_PERCENT=62.50 \
			BADGE_FILE=badge.svg BADGE_URL="https://img.shields.io/badge/coverage-62.5%25-yellow?style=flat"
		;;
	threshold-below)
		_coverage_gate_run "$work" check-coverage-threshold.sh COVERAGE=62.50 THRESHOLD=80
		;;
	threshold-met)
		_coverage_gate_run "$work" check-coverage-threshold.sh COVERAGE=85.00 THRESHOLD=80
		;;
	threshold-zero)
		_coverage_gate_run "$work" check-coverage-threshold.sh COVERAGE=62.50 THRESHOLD=0
		;;
	*)
		echo "unknown case: $name" >&2
		return 1
		;;
	esac
}

# PATH with the optional merge tools (lcov, nyc) hidden and nothing else, so
# the merge takes its documented fallbacks on every machine. A directory that
# holds one is replaced by one of symbolic links to everything else in it
# (bash, sed and awk often sit beside lcov in /usr/bin), made under WORK.
# Usage: _coverage_gate_path_without_lcov WORK
_coverage_gate_path_without_lcov() {
	local work="$1" dir entry stand_in kept=() index=0
	local IFS=:
	for dir in $PATH; do
		[[ -n "$dir" ]] || continue
		if [[ ! -e "${dir}/lcov" && ! -e "${dir}/nyc" ]]; then
			kept+=("$dir")
			continue
		fi
		index=$((index + 1))
		stand_in="${work}/path-without-lcov-${index}"
		mkdir -p "$stand_in"
		for entry in "$dir"/*; do
			case "${entry##*/}" in
			lcov | nyc) ;;
			*) ln -s "$entry" "${stand_in}/${entry##*/}" ;;
			esac
		done
		kept+=("$stand_in")
	done
	printf '%s' "${kept[*]}"
}
