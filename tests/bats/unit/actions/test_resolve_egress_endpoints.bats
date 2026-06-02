#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for resolve-egress-endpoints.sh

load "../../../helpers/common"

RESOLVE="${PROJECT_ROOT}/scripts/ci/actions/resolve-egress-endpoints.sh"

teardown() {
	if [[ -n "${output_file:-}" && -f "$output_file" ]]; then
		rm -f "$output_file"
	fi
}

@test "resolve-egress: explicit allowed-endpoints override preset" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET=quality \
		ALLOWED_ENDPOINTS=$'github.com:443\n' \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_success
	run grep -E '^github\.com:443$' "$output_file"
	assert_success
	run grep -c 'docker\.io:443' "$output_file"
	assert_equal 0 "$output"
}

@test "resolve-egress: preset expands when allowed-endpoints empty" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET=github-minimal \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_success
	run grep -E '^api\.github\.com:443$' "$output_file"
	assert_success
}

@test "resolve-egress: block without preset or endpoints fails" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET="" \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_failure
	assert_output --partial 'egress-policy block requires'
}

@test "resolve-egress: trims whitespace around egress-preset name" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET=' quality ' \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_success
	run grep -E '^docker\.io:443$' "$output_file"
	assert_success
}

@test "resolve-egress: audit mode ignores preset" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=audit \
		EGRESS_PRESET=quality \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_success
	run grep -c 'ghcr\.io:443' "$output_file"
	assert_equal 0 "$output"
}

@test "resolve-egress: strips blank lines from allowed-endpoints override" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=block \
		EGRESS_PRESET=quality \
		ALLOWED_ENDPOINTS=$'github.com:443\n\n  \n' \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_success
	run grep -c 'github\.com:443' "$output_file"
	assert_equal 1 "$output"
	run grep -c 'docker\.io:443' "$output_file"
	assert_equal 0 "$output"
}

@test "resolve-egress: rejects invalid egress-policy" {
	output_file="$(mktemp)"
	run env \
		EGRESS_POLICY=wide-open \
		EGRESS_PRESET=github-minimal \
		ALLOWED_ENDPOINTS="" \
		GITHUB_OUTPUT="$output_file" \
		bash "$RESOLVE"
	assert_failure
	assert_output --partial "invalid EGRESS_POLICY"
}
