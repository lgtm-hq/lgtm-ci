#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Guard that all py-lintro digest pins across the repo stay in sync

load "../../helpers/common"

@test "lintro digest pins: all py-lintro@sha256 pins in .github/, scripts/, and README.md are identical" {
	run bash -c '
		grep -rhoE "py-lintro@sha256:[a-f0-9]{64}" \
			"'"${PROJECT_ROOT}"'/.github" \
			"'"${PROJECT_ROOT}"'/scripts" \
			"'"${PROJECT_ROOT}"'/README.md" \
			| sort -u
	'
	assert_success
	local count
	count="$(printf '%s\n' "$output" | grep -c 'py-lintro@sha256:')"
	if [[ "$count" -ne 1 ]]; then
		echo "Expected exactly one unique py-lintro digest pin, found ${count}:" >&2
		echo "$output" >&2
		return 1
	fi
}
