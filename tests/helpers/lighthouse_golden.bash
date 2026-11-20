#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the Lighthouse parser and gate for golden comparison (#1692)
#
# For every well-formed Lighthouse report in tests/fixtures/lighthouse (the
# parse-lighthouse-json-*.json files), prints what parse_lighthouse_json sets,
# what run-lighthouse.sh STEP=parse writes to GITHUB_OUTPUT with its exit
# status, and the job summary STEP=summary writes from those outputs.
# tests/fixtures/lighthouse/run-lighthouse.golden.txt holds what main's
# scripts printed before #1692 made unreadable scores fail; well-formed
# reports must render byte for byte the same.
#
# Usage: load "../../../helpers/lighthouse_golden"
#        lighthouse_golden_render WORK_DIR   (prints the rendering)

# Usage: lighthouse_golden_render WORK_DIR
lighthouse_golden_render() {
	local work="$1" fixture name outputs="$1/github-output" summary="$1/step-summary" rc
	mkdir -p "$work"
	for fixture in "${PROJECT_ROOT}"/tests/fixtures/lighthouse/parse-lighthouse-json-*.json; do
		name="${fixture##*/}"
		printf '=== %s\n--- parser\n' "$name"
		bash -c 'source "$1/scripts/ci/lib/testing/parse/lighthouse.sh"
			parse_lighthouse_json "$2"
			echo "rc=$? perf=$LH_PERFORMANCE a11y=$LH_ACCESSIBILITY bp=$LH_BEST_PRACTICES seo=$LH_SEO pwa=$LH_PWA"
			check_lighthouse_thresholds 80 90 80 80
			echo "thresholds=$? failed=$LH_FAILED_CATEGORIES"
			format_lighthouse_summary' _ "$PROJECT_ROOT" "$fixture"
		: >"$outputs"
		: >"$summary"
		rc=0
		(cd "$work" && env GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" STEP=parse \
			RESULTS_PATH="$fixture" OUTPUT_DIR="$work" RUN_MARKER="" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/run-lighthouse.sh") >/dev/null 2>&1 || rc=$?
		printf -- '--- parse step exit=%s\n' "$rc"
		cat "$outputs"
		(cd "$work" && env GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" STEP=summary \
			PARSE_OUTCOME=success \
			PERFORMANCE="$(sed -n 's/^performance=//p' "$outputs")" \
			ACCESSIBILITY="$(sed -n 's/^accessibility=//p' "$outputs")" \
			BEST_PRACTICES="$(sed -n 's/^best-practices=//p' "$outputs")" \
			SEO="$(sed -n 's/^seo=//p' "$outputs")" \
			PASSED="$(sed -n 's/^passed=//p' "$outputs")" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/run-lighthouse.sh") >/dev/null 2>&1
		printf -- '--- summary\n'
		cat "$summary"
	done
}
