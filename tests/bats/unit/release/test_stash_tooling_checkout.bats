#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/stash-tooling-checkout.sh (#1622)
#
# The version-pr job of reusable-release-version-pr.yml moves the tooling
# checkout out of the workspace with this script before PR creation and puts
# it back afterwards with the generated verify-extract-hook-tooling block, so
# these tests run both: the stash script, then the block's source script with
# the digest the stash recorded.

load "../../../helpers/common"

STASH="${PROJECT_ROOT}/scripts/ci/release/stash-tooling-checkout.sh"
RESTORE="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-extract-hook-tooling.sh"

setup() {
	WS="${BATS_TEST_TMPDIR}/ws"
	TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	TOOLING="${WS}/.lgtm-ci-tooling"
	mkdir -p "$TEMP" "${TOOLING}/scripts/ci/release" "${TOOLING}/.git/hooks" \
		"${TOOLING}/.github/actions/checkout-and-harden"
	printf '#!/usr/bin/env bash\necho tool\n' >"${TOOLING}/scripts/ci/release/tool.sh"
	chmod +x "${TOOLING}/scripts/ci/release/tool.sh"
	echo "name: harden" >"${TOOLING}/.github/actions/checkout-and-harden/action.yml"
	echo "[core]" >"${TOOLING}/.git/config"
	: >"$OUTPUT"
	TARBALL="${TEMP}/tooling-stash/tooling.tar.gz"
}

_stash() {
	run env GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$TEMP" GITHUB_OUTPUT="$OUTPUT" \
		bash "$STASH"
}

# The digest the stash step wrote to its output.
_digest() {
	sed -n 's/^digest=//p' "$OUTPUT"
}

_restore() {
	cd "$WS"
	run env TARBALL="$TARBALL" EXPECTED_DIGEST="$1" bash "$RESTORE"
}

@test "stash-tooling-checkout: moves the tooling out and records the tarball digest" {
	_stash
	assert_success
	assert_output --partial "Moved the lgtm-ci tooling checkout to ${TARBALL}"
	[ ! -e "$TOOLING" ]
	[ -f "$TARBALL" ]
	local digest
	digest="$(_digest)"
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]]
	[ "$digest" = "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" ]
	run sed -n 's/^path=//p' "$OUTPUT"
	assert_output "$TARBALL"
}

@test "stash-tooling-checkout: a matching digest restores the tooling, bits and all" {
	_stash
	assert_success
	_restore "$(_digest)"
	assert_success
	assert_output --partial "${TARBALL}: OK"
	[ -x "${TOOLING}/scripts/ci/release/tool.sh" ]
	[ -f "${TOOLING}/.github/actions/checkout-and-harden/action.yml" ]
	# .git is not carried: no later step reads it.
	[ ! -e "${TOOLING}/.git" ]
	run "${TOOLING}/scripts/ci/release/tool.sh"
	assert_output "tool"
}

@test "stash-tooling-checkout: a tarball changed after the stash is refused" {
	_stash
	assert_success
	local digest work="${BATS_TEST_TMPDIR}/tamper"
	digest="$(_digest)"
	mkdir -p "$work"
	tar -xzf "$TARBALL" -C "$work"
	printf '#!/usr/bin/env bash\necho planted\n' >"${work}/scripts/ci/release/tool.sh"
	COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$work" .
	_restore "$digest"
	assert_failure
	assert_output --partial "FAILED"
	[ ! -e "$TOOLING" ]
}

@test "stash-tooling-checkout: a missing tarball is refused" {
	_stash
	assert_success
	local digest
	digest="$(_digest)"
	rm -f "$TARBALL"
	_restore "$digest"
	assert_failure
	[ ! -e "$TOOLING" ]
}

@test "stash-tooling-checkout: a tooling directory put back in between is never merged into" {
	_stash
	assert_success
	mkdir -p "${TOOLING}/scripts"
	_restore "$(_digest)"
	assert_failure
	[ ! -e "${TOOLING}/scripts/ci" ]
}

@test "stash-tooling-checkout: a missing tooling directory fails and writes nothing" {
	rm -rf "$TOOLING"
	_stash
	assert_failure
	assert_output --partial "no tooling checkout at ${TOOLING}"
	[ ! -e "${TEMP}/tooling-stash" ]
	[ ! -s "$OUTPUT" ]
}

@test "stash-tooling-checkout: a symlinked tooling directory is refused" {
	mv "$TOOLING" "${BATS_TEST_TMPDIR}/elsewhere"
	ln -s "${BATS_TEST_TMPDIR}/elsewhere" "$TOOLING"
	_stash
	assert_failure
	assert_output --partial "no tooling checkout"
	[ -d "${BATS_TEST_TMPDIR}/elsewhere/scripts" ]
	[ ! -s "$OUTPUT" ]
}

@test "stash-tooling-checkout: a checkout holding only .git is refused and kept" {
	rm -rf "${TOOLING}/scripts" "${TOOLING}/.github"
	_stash
	assert_failure
	assert_output --partial "is empty"
	[ -d "${TOOLING}/.git" ]
	[ ! -s "$OUTPUT" ]
}

@test "stash-tooling-checkout: an existing stash directory is never reused" {
	mkdir -p "${TEMP}/tooling-stash"
	_stash
	assert_failure
	assert_output --partial "already exists"
	[ -d "${TOOLING}/scripts" ]
	[ ! -s "$OUTPUT" ]
}

@test "stash-tooling-checkout: fails without its environment" {
	local name
	for name in GITHUB_WORKSPACE RUNNER_TEMP GITHUB_OUTPUT; do
		run env GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$TEMP" GITHUB_OUTPUT="$OUTPUT" \
			bash -c 'unset "$1"; bash "$2"' _ "$name" "$STASH"
		assert_failure
		assert_output --partial "${name} is required"
	done
	[ -d "${TOOLING}/scripts" ]
}
