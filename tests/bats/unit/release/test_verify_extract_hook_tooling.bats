#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/verify-extract-hook-tooling.sh (#1450)
#
# The source script of the generated "Verify and extract lgtm-ci tooling" steps
# in the release twins; sync_inline_blocks.py --check keeps those copies equal
# to this body, and integration/test_reusable_release_hook_isolation.bats pins
# where the steps sit in each job.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-extract-hook-tooling.sh"

setup() {
	WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK" "${BATS_TEST_TMPDIR}/src/scripts"
	echo "echo tool" >"${BATS_TEST_TMPDIR}/src/scripts/tool.sh"
	TARBALL="${BATS_TEST_TMPDIR}/hook-tooling.tar.gz"
	tar -czf "$TARBALL" -C "${BATS_TEST_TMPDIR}/src" scripts
	DIGEST="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
}

_verify() {
	cd "$WORK"
	run env TARBALL="$TARBALL" EXPECTED_DIGEST="$1" bash "$SCRIPT"
}

@test "verify-extract-hook-tooling: a matching digest extracts the tooling" {
	_verify "$DIGEST"
	assert_success
	assert_output --partial "${TARBALL}: OK"
	[ -f "${WORK}/.lgtm-ci-tooling/scripts/tool.sh" ]
}

@test "verify-extract-hook-tooling: a malformed or empty digest fails before hashing" {
	local digest upper
	upper="$(printf '%s' "$DIGEST" | tr '[:lower:]' '[:upper:]')"
	for digest in "" "not-a-digest" "$upper" "${DIGEST}0"; do
		_verify "$digest"
		assert_failure 1
		assert_output "::error::no tooling digest"
		[ ! -e "${WORK}/.lgtm-ci-tooling" ]
	done
}

@test "verify-extract-hook-tooling: a mismatched digest fails and extracts nothing" {
	_verify "$(printf '0%.0s' {1..64})"
	assert_failure
	assert_output --partial "FAILED"
	[ ! -e "${WORK}/.lgtm-ci-tooling" ]
}

@test "verify-extract-hook-tooling: an existing tooling directory is never merged into" {
	mkdir "${WORK}/.lgtm-ci-tooling"
	_verify "$DIGEST"
	assert_failure
	[ ! -e "${WORK}/.lgtm-ci-tooling/scripts" ]
}
