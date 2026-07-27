#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the publish-test-results path inputs of
#          reusable-publish-test-results-pages.yml against the directory the
#          caller's artifact was extracted into (#770).
#
# The shared Pages publisher downloads one artifact into a fixed local directory
# and then hands `publish-test-results` up to three paths *inside* it. Callers
# describe those paths relative to the artifact root, not to the runner
# workspace, because the extraction directory is an implementation detail of the
# publisher and must not leak into a caller's `with:` block.
#
# '.' means "the artifact root" and is distinct from the empty string, which
# means "this kind of content is not in this artifact". Collapsing the two would
# make an unset `coverage-path` indistinguishable from a coverage report sitting
# at the artifact root, and `publish-test-results` treats the empty string as
# "skip".
#
# The relative paths are validated for the same reason
# validate-pages-target-dir.sh validates its input: they are caller-controlled
# strings that become filesystem paths the publisher reads and stages into a
# site artifact. A leading '/' or a '..' hop would stage content from outside
# the downloaded artifact.
#
# Environment:
#   DOWNLOAD_DIR  (required) Directory the artifact was extracted into
#   RESULTS_PATH  (optional) Test-report path relative to the artifact root
#   COVERAGE_PATH (optional) Coverage-report path relative to the artifact root
#   BADGE_PATH    (optional) Badge path relative to the artifact root
#
# Outputs (GITHUB_OUTPUT): results-path, coverage-path, badge-path

set -euo pipefail

: "${DOWNLOAD_DIR:?DOWNLOAD_DIR is required}"
: "${RESULTS_PATH:=}"
: "${COVERAGE_PATH:=}"
: "${BADGE_PATH:=}"

if [[ -z "$RESULTS_PATH" && -z "$COVERAGE_PATH" ]]; then
	echo "::error::at least one of results-path or coverage-path must be set, or the publisher would deploy an empty site over the live one" >&2
	exit 1
fi

# Resolve one caller-relative path against DOWNLOAD_DIR. Echoes the resolved
# path, or nothing when the input is empty.
resolve_path() {
	local input_name="$1" value="$2" segment

	if [[ -z "$value" ]]; then
		return 0
	fi

	if [[ "$value" == /* ]]; then
		echo "::error::${input_name} must be relative to the artifact root (got '${value}'): a leading '/' would stage content from outside the downloaded artifact" >&2
		return 1
	fi

	# Segment-wise, so a directory whose name merely contains dots is not
	# collateral damage while every real '..' hop is caught.
	local segments=()
	IFS='/' read -r -a segments <<<"$value"
	for segment in "${segments[@]}"; do
		if [[ "$segment" == ".." ]]; then
			echo "::error::${input_name} must not contain '..' segments (got '${value}'): traversal would stage content from outside the downloaded artifact" >&2
			return 1
		fi
	done

	# Allowlist, not denylist: whitespace, shell and glob metacharacters and
	# control characters have no place in an artifact-relative path.
	if [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
		echo "::error::${input_name} must match [A-Za-z0-9._/-]+ (got '${value}')" >&2
		return 1
	fi

	if [[ "$value" == "." ]]; then
		printf '%s' "$DOWNLOAD_DIR"
		return 0
	fi

	printf '%s/%s' "$DOWNLOAD_DIR" "$value"
}

results_resolved="$(resolve_path results-path "$RESULTS_PATH")"
coverage_resolved="$(resolve_path coverage-path "$COVERAGE_PATH")"
badge_resolved="$(resolve_path badge-path "$BADGE_PATH")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "results-path=${results_resolved}"
		echo "coverage-path=${coverage_resolved}"
		echo "badge-path=${badge_resolved}"
	} >>"$GITHUB_OUTPUT"
fi

echo "results-path: ${results_resolved:-<unset>}"
echo "coverage-path: ${coverage_resolved:-<unset>}"
echo "badge-path: ${badge_resolved:-<unset>}"
