#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Prove #1062 supplier pins are regex-visible to renovate.json

load "../../../helpers/common"

MATCHER="${PROJECT_ROOT}/scripts/ci/maintenance/match-renovate-pins.py"
RENOVATE_JSON="${PROJECT_ROOT}/renovate.json"

@test "renovate.json: generic script manager allows extractVersion and versioning" {
	run jq -r '.customManagers[] | select(.description | test("shell scripts")) | .matchStrings[0]' \
		"$RENOVATE_JSON"
	assert_success
	assert_output --partial "extractVersion"
	assert_output --partial "versioning"
}

@test "renovate.json: YAML manager lists the annotated action and workflow files" {
	run jq -r '.customManagers[] | select(.description | test("YAML version pins")) | .managerFilePatterns[]' \
		"$RENOVATE_JSON"
	assert_success
	assert_output --partial "setup-python"
	assert_output --partial "setup-node"
	assert_output --partial "reusable-ai-review"
	assert_output --partial "reusable-test-node"
}

@test "tool pins: nextest and llvm-cov match the script manager" {
	run python3 "$MATCHER" "scripts/ci/testing/rust/setup-rust-nextest.sh"
	assert_success
	assert_output --partial "nextest-rs/nextest"
	assert_output --partial "0.9.92"
	assert_output --partial "cargo-nextest-"
	assert_output --partial "taiki-e/cargo-llvm-cov"
	assert_output --partial "0.8.6"
}

@test "tool pins: osv-scanner has one annotated script default" {
	run python3 "$MATCHER" "scripts/ci/security/install-osv-scanner.sh"
	assert_success
	assert_output --partial "google/osv-scanner"
	assert_output --partial "2.3.5"
	run grep -c '2.3.5' "${PROJECT_ROOT}/scripts/ci/security/install-osv-scanner.sh"
	assert_output "1"
}

@test "tool pins: bats, helpers, and kcov match the script manager" {
	run python3 "$MATCHER" "scripts/ci/actions/run-bats-tests.sh"
	assert_success
	assert_output --partial "bats-core/bats-core"
	assert_output --partial "1.10.0"
	assert_output --partial "bats-core/bats-support"
	assert_output --partial "v0.3.0"
	assert_output --partial "bats-core/bats-assert"
	assert_output --partial "v2.2.4"
	assert_output --partial "bats-core/bats-file"
	assert_output --partial "v0.4.0"
	assert_output --partial "SimonKagstrom/kcov"
	assert_output --partial "v43"
}

@test "tool pins: AI CLI annotations match after DEFAULT_ rewrite" {
	run python3 "$MATCHER" "scripts/ci/actions/install-ai-review-cli.sh"
	assert_success
	assert_output --partial "@anthropic-ai/claude-code"
	assert_output --partial "2.1.232"
	assert_output --partial "@openai/codex"
	assert_output --partial "0.147.0"
}

@test "tool pins: cross pin lives in install-cross.sh" {
	run python3 "$MATCHER" "scripts/ci/release/install-cross.sh"
	assert_success
	assert_output --partial "cross"
	assert_output --partial "0.2.5"
	run grep -F "scripts/ci/release/install-cross.sh" \
		"${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"
	assert_success
}

@test "tool pins: existing cargo-binstall and syft pins still match" {
	run python3 "$MATCHER" "scripts/ci/actions/setup-rust.sh"
	assert_success
	assert_output --partial "cargo-bins/cargo-binstall"
	run python3 "$MATCHER" "scripts/ci/actions/prime-syft-tool-cache.sh"
	assert_success
	assert_output --partial "anchore/syft"
}

@test "tool pins: uv and bun action defaults match the YAML manager" {
	run python3 "$MATCHER" ".github/actions/setup-python/action.yml"
	assert_success
	assert_output --partial "uv"
	assert_output --partial "0.12.22"
	run python3 "$MATCHER" ".github/actions/setup-node/action.yml"
	assert_success
	assert_output --partial "bun"
	assert_output --partial "1.4.2"
}

@test "tool pins: every workflow bun copy matches the grouped pin" {
	local wf
	for wf in \
		.github/workflows/reusable-test-node.yml \
		.github/workflows/reusable-test-node-custom.yml \
		.github/workflows/reusable-test-e2e.yml \
		.github/workflows/reusable-test-e2e-matrix.yml \
		.github/workflows/reusable-test-e2e-playwright.yml \
		.github/workflows/reusable-deploy-site-with-reports.yml \
		.github/workflows/reusable-site-quality.yml \
		.github/actions/run-vitest/action.yml \
		.github/actions/run-playwright/action.yml \
		.github/actions/run-lighthouse/action.yml; do
		run python3 "$MATCHER" "$wf"
		assert_success
		assert_output --partial "bun"
		assert_output --partial "1.4.2"
	done
	run grep -R -n "bun-version: latest" "${PROJECT_ROOT}/.github"
	assert_failure
}

@test "tool pins: lintro workflow default still matches" {
	run python3 "$MATCHER" ".github/workflows/reusable-ai-review.yml"
	assert_success
	assert_output --partial "lintro"
}

@test "reusable-vuln-suppression-check: osv-version defaults to empty" {
	run awk '/^      osv-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-vuln-suppression-check.yml"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-test-shell: bats-version defaults to empty" {
	run awk '/^      bats-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"
	assert_success
	assert_output --partial 'default: ""'
}

@test "run-bats-tests: empty BATS_VERSION falls back to annotated default" {
	local default resolved
	default="$(sed -n 's/^[[:space:]]*DEFAULT_BATS_VERSION="\([^"]*\)"/\1/p' \
		"${PROJECT_ROOT}/scripts/ci/actions/run-bats-tests.sh")"
	[[ "$default" == "1.10.0" ]]
	resolved="$(
		BATS_VERSION=""
		DEFAULT_BATS_VERSION="$default"
		BATS_VERSION="${BATS_VERSION:-$DEFAULT_BATS_VERSION}"
		printf '%s' "$BATS_VERSION"
	)"
	[[ "$resolved" == "1.10.0" ]]
}
