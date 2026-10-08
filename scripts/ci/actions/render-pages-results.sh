#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pure renderer (#1080): results.v1 document(s) -> static Pages page.
#
# Writes <OUTPUT_DIR>/results.json (one aggregated document) and
# <OUTPUT_DIR>/index.html (a plain table), so a Pages site can show the test
# verdict next to the coverage and HTML reports without parsing anything
# native. Several legs are folded through aggregate-results.sh first.
#
# Environment:
#   RESULTS_FILE  One results.v1 document; or
#   RESULTS_DIR   Directory holding one or more <...>/results.json legs
#   OUTPUT_DIR    (required) Destination directory (created)
#   TITLE         Page heading (default: Test Results)

set -euo pipefail

: "${RESULTS_FILE:=}"
: "${RESULTS_DIR:=}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${TITLE:=Test Results}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

if [[ -z "$RESULTS_FILE" && -z "$RESULTS_DIR" ]]; then
	echo "::error::render-pages-results: RESULTS_FILE or RESULTS_DIR is required" >&2
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
if [[ -z "$RESULTS_FILE" ]]; then
	work_dir="$(mktemp -d)"
	trap 'rm -rf "$work_dir"' EXIT
	GITHUB_OUTPUT="${work_dir}/outputs" AGGREGATE_OUTPUT="${OUTPUT_DIR}/results.json" \
		RESULTS_DIR="$RESULTS_DIR" MATRIX_JSON="" \
		bash "$SCRIPT_DIR/aggregate-results.sh" >/dev/null
else
	results_v1_validate "$RESULTS_FILE"
	cp "$RESULTS_FILE" "${OUTPUT_DIR}/results.json"
fi

html_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

IFS=$'\t' read -r tool status passed failed skipped total duration coverage runner version < <(
	jq -r '[.tool, .status, .counts.passed, .counts.failed, .counts.skipped, .counts.total,
		.duration_ms, (.coverage.lines // "n/a"), .source.runner, .source.version] | @tsv' \
		"${OUTPUT_DIR}/results.json"
)

{
	printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
	printf '<title>%s</title>\n' "$(html_escape "$TITLE")"
	printf '<style>body{font-family:system-ui,sans-serif;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.4rem .8rem;text-align:left}</style>\n'
	printf '</head>\n<body>\n<h1>%s</h1>\n' "$(html_escape "$TITLE")"
	printf '<p>Status: <strong>%s</strong> (%s via %s)</p>\n' \
		"$(html_escape "$status")" "$(html_escape "$tool")" "$(html_escape "$runner")"
	printf '<table>\n<tr><th>Metric</th><th>Value</th></tr>\n'
	printf '<tr><td>Passed</td><td>%s</td></tr>\n' "$passed"
	printf '<tr><td>Failed</td><td>%s</td></tr>\n' "$failed"
	printf '<tr><td>Skipped</td><td>%s</td></tr>\n' "$skipped"
	printf '<tr><td>Total</td><td>%s</td></tr>\n' "$total"
	printf '<tr><td>Duration (ms)</td><td>%s</td></tr>\n' "$duration"
	printf '<tr><td>Line coverage</td><td>%s</td></tr>\n' "$(html_escape "$coverage")"
	printf '</table>\n'
	printf '<p><a href="results.json">results.json</a> (results.v1, tooling %s)</p>\n' "$(html_escape "$version")"
	printf '</body>\n</html>\n'
} >"${OUTPUT_DIR}/index.html"

echo "Rendered ${OUTPUT_DIR}/index.html from results.v1"
