#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the Lighthouse parser and gate for golden comparison (#1692)
#
# For every well-formed Lighthouse report in tests/fixtures/lighthouse (the
# parse-lighthouse-json-*.json files, including reports that ran only some
# categories, as a config with onlyCategories does), prints what
# parse_lighthouse_json sets, what run-lighthouse.sh STEP=parse writes to
# GITHUB_OUTPUT with its exit status at the default thresholds and at
# thresholds of 0, the job summary STEP=summary writes from the outputs at
# the default thresholds, and what generate-lighthouse-comment.sh writes to
# GITHUB_OUTPUT (its random delimiter and the date normalised).
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
		: >"$outputs"
		rc=0
		(cd "$work" && env GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" STEP=parse \
			RESULTS_PATH="$fixture" OUTPUT_DIR="$work" RUN_MARKER="" THRESHOLD_PERFORMANCE=0 \
			THRESHOLD_ACCESSIBILITY=0 THRESHOLD_BEST_PRACTICES=0 THRESHOLD_SEO=0 \
			bash "${PROJECT_ROOT}/scripts/ci/actions/run-lighthouse.sh") >/dev/null 2>&1 || rc=$?
		printf -- '--- parse step, thresholds 0, exit=%s\n' "$rc"
		cat "$outputs"
		: >"$outputs"
		rc=0
		(cd "$work" && env GITHUB_OUTPUT="$outputs" RESULTS_PATH="$fixture" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/generate-lighthouse-comment.sh") >/dev/null 2>&1 || rc=$?
		printf -- '--- comment exit=%s\n' "$rc"
		sed -E -e 's/ghadelimiter_[A-Za-z0-9_]+/<delim>/g' \
			-e 's/^([a-z-]+)<<[A-Za-z0-9_]{8,}$/\1<<<delim>/' -e 's/^[A-Za-z0-9_]{20,}$/<delim>/' \
			-e 's/Generated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}/Generated:** <date>/' "$outputs"
	done
}
