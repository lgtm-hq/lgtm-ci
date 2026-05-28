#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Fixture-based tests for publish-test-results live-site merge

load "../../helpers/common"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_staging_dir_from_output() {
	grep '^staging-dir=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

_run_prepare() {
	run env \
		STEP=prepare \
		RESULTS_PATH="${RESULTS_PATH:-}" \
		COVERAGE_PATH="${COVERAGE_PATH:-}" \
		BADGE_PATH="${BADGE_PATH:-}" \
		TARGET_DIR="${TARGET_DIR:-.}" \
		MERGE_EXISTING_SITE="${MERGE_EXISTING_SITE:-false}" \
		BASE_SITE_PATH="${BASE_SITE_PATH:-}" \
		GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-lgtm-hq/example}" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/publish-test-results.sh"
}

@test "publish-test-results prepare: merge preserves sibling target-dir trees" {
	local base_site="${BATS_TEST_TMPDIR}/base-site"
	local coverage="${BATS_TEST_TMPDIR}/vitest-coverage"
	mkdir -p "${base_site}/python/coverage"
	echo "python-report" >"${base_site}/python/coverage/index.html"
	mkdir -p "$coverage"
	echo "vitest-report" >"${coverage}/index.html"

	export BASE_SITE_PATH="$base_site"
	export MERGE_EXISTING_SITE=true
	export TARGET_DIR="vitest"
	export COVERAGE_PATH="$coverage"

	_run_prepare
	assert_success

	local staging_dir
	staging_dir=$(_staging_dir_from_output)
	run test -f "${staging_dir}/python/coverage/index.html"
	assert_success
	run grep -q "python-report" "${staging_dir}/python/coverage/index.html"
	assert_success
	run test -f "${staging_dir}/vitest/coverage/index.html"
	assert_success
	run grep -q "vitest-report" "${staging_dir}/vitest/coverage/index.html"
	assert_success
}

@test "publish-test-results prepare: merge overlays matching target-dir content" {
	local base_site="${BATS_TEST_TMPDIR}/base-site"
	local results="${BATS_TEST_TMPDIR}/vitest-results"
	mkdir -p "${base_site}/vitest/tests"
	echo "stale" >"${base_site}/vitest/tests/output.json"
	mkdir -p "$results"
	echo "fresh" >"${results}/output.json"

	export BASE_SITE_PATH="$base_site"
	export MERGE_EXISTING_SITE=true
	export TARGET_DIR="vitest"
	export RESULTS_PATH="$results"

	_run_prepare
	assert_success

	local staging_dir
	staging_dir=$(_staging_dir_from_output)
	run grep -q "fresh" "${staging_dir}/vitest/tests/output.json"
	assert_success
}

@test "publish-test-results prepare: without merge only publishes target-dir" {
	local base_site="${BATS_TEST_TMPDIR}/base-site"
	local coverage="${BATS_TEST_TMPDIR}/vitest-coverage"
	mkdir -p "${base_site}/python/coverage"
	echo "python-report" >"${base_site}/python/coverage/index.html"
	mkdir -p "$coverage"
	echo "vitest-report" >"${coverage}/index.html"

	export BASE_SITE_PATH="$base_site"
	export MERGE_EXISTING_SITE=false
	export TARGET_DIR="vitest"
	export COVERAGE_PATH="$coverage"

	_run_prepare
	assert_success

	local staging_dir
	staging_dir=$(_staging_dir_from_output)
	run test ! -e "${staging_dir}/python/coverage/index.html"
	assert_success
	run test -f "${staging_dir}/vitest/coverage/index.html"
	assert_success
}

@test "publish-test-results prepare: merge with target-dir . overlays at root" {
	local base_site="${BATS_TEST_TMPDIR}/base-site"
	local coverage="${BATS_TEST_TMPDIR}/root-coverage"
	mkdir -p "${base_site}/existing"
	echo "keep-me" >"${base_site}/existing/report.html"
	mkdir -p "$coverage"
	echo "root-coverage" >"${coverage}/index.html"

	export BASE_SITE_PATH="$base_site"
	export MERGE_EXISTING_SITE=true
	export TARGET_DIR="."
	export COVERAGE_PATH="$coverage"

	_run_prepare
	assert_success

	local staging_dir
	staging_dir=$(_staging_dir_from_output)
	run test -f "${staging_dir}/existing/report.html"
	assert_success
	run grep -q "keep-me" "${staging_dir}/existing/report.html"
	assert_success
	run test -f "${staging_dir}/coverage/index.html"
	assert_success
	run grep -q "root-coverage" "${staging_dir}/coverage/index.html"
	assert_success
}

@test "publish-test-results prepare: rejects invalid base-site-path" {
	export BASE_SITE_PATH="${BATS_TEST_TMPDIR}/missing-base"
	export MERGE_EXISTING_SITE=true
	export TARGET_DIR="vitest"

	_run_prepare
	assert_failure
	assert_output --partial "base-site-path is not a directory"
}

@test "publish-test-results prepare: merge without base-site-path or GITHUB_REPOSITORY fails" {
	run env \
		STEP=prepare \
		RESULTS_PATH="" \
		COVERAGE_PATH="" \
		BADGE_PATH="" \
		TARGET_DIR="vitest" \
		MERGE_EXISTING_SITE=true \
		BASE_SITE_PATH="" \
		GITHUB_REPOSITORY="" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/publish-test-results.sh"
	assert_failure
	assert_output --partial "merge-existing-site requires base-site-path or GITHUB_REPOSITORY"
}

@test "publish-test-results action: exposes merge inputs" {
	local action="${PROJECT_ROOT}/.github/actions/publish-test-results/action.yml"
	run grep -q 'merge-existing-site:' "$action"
	assert_success
	run grep -q 'base-site-path:' "$action"
	assert_success
	run grep -q 'MERGE_EXISTING_SITE:' "$action"
	assert_success
	run grep -q 'BASE_SITE_PATH:' "$action"
	assert_success
}
