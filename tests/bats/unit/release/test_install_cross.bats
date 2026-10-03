#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/install-cross.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/install-cross.sh"

@test "install-cross: uses the annotated CROSS_VERSION" {
	run grep -F 'cargo install cross --locked --version "$CROSS_VERSION"' "$SCRIPT"
	assert_success
	run grep -F 'DEFAULT_CROSS_VERSION="0.2.5"' "$SCRIPT"
	assert_success
	run grep -F '# renovate: datasource=crate depName=cross' "$SCRIPT"
	assert_success
}

@test "install-cross: empty CROSS_VERSION falls back to annotated default" {
	local default resolved
	default="$(sed -n 's/^DEFAULT_CROSS_VERSION="\([^"]*\)"/\1/p' "$SCRIPT")"
	[[ "$default" == "0.2.5" ]]
	resolved="$(
		CROSS_VERSION=""
		DEFAULT_CROSS_VERSION="$default"
		CROSS_VERSION="${CROSS_VERSION:-$DEFAULT_CROSS_VERSION}"
		printf '%s' "$CROSS_VERSION"
	)"
	[[ "$resolved" == "0.2.5" ]]
}
