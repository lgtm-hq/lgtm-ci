#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/supply_chain.sh (#1096): committed-digest
#          verification, the LGTM_CI_ALLOW_UNVERIFIED=1 escape hatch, and the
#          rule that a mismatch is never downgraded.

load "../../../helpers/common"

LIB="${PROJECT_ROOT}/scripts/ci/lib/supply_chain.sh"

setup() {
	setup_temp_dir
	export ARTIFACT="${BATS_TEST_TMPDIR}/artifact.bin"
	printf 'committed bytes\n' >"$ARTIFACT"
	if command -v sha256sum >/dev/null 2>&1; then
		GOOD="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
	else
		GOOD="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
	fi
	export GOOD
	export BAD="0000000000000000000000000000000000000000000000000000000000000000"
}

teardown() {
	teardown_temp_dir
}

# Run a snippet in a fresh bash with the library sourced.
_sc() {
	run bash -c "source '$LIB'; $1"
}

@test "supply_chain: sha256 match against the committed default succeeds" {
	_sc "DEFAULT_TOOL_SHA256_X='$GOOD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X 1.0.0 1.0.0"
	assert_success
	assert_output --partial "sha256 verified against committed TOOL_SHA256_X"
}

@test "supply_chain: sha256 mismatch fails closed" {
	_sc "DEFAULT_TOOL_SHA256_X='$BAD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X; echo NOT-REACHED"
	assert_failure
	assert_output --partial "::error title=digest mismatch::"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: sha256 mismatch is never downgraded by LGTM_CI_ALLOW_UNVERIFIED=1" {
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; DEFAULT_TOOL_SHA256_X='$BAD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X; echo NOT-REACHED"
	assert_failure
	assert_output --partial "digest mismatch"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: env override of the digest wins over the committed default" {
	_sc "DEFAULT_TOOL_SHA256_X='$BAD'; export TOOL_SHA256_X='$GOOD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X 2.0.0 1.0.0"
	assert_success
	assert_output --partial "sha256 verified"
}

@test "supply_chain: missing committed digest is a hard error by default" {
	_sc "supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_MISSING; echo NOT-REACHED"
	assert_failure
	assert_output --partial "::error title=unverified install::no committed digest for TOOL_SHA256_MISSING"
	assert_output --partial "Set LGTM_CI_ALLOW_UNVERIFIED=1"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: missing committed digest is a warning with the escape hatch" {
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_MISSING && echo CONTINUED"
	assert_success
	assert_output --partial "::warning title=unverified install::"
	assert_output --partial "CONTINUED"
}

@test "supply_chain: version override without a matching digest is a hard error" {
	_sc "DEFAULT_TOOL_SHA256_X='$GOOD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X 9.9.9 1.0.0; echo NOT-REACHED"
	assert_failure
	assert_output --partial "version overridden to 9.9.9 (pinned 1.0.0) without a matching TOOL_SHA256_X"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: version override without a digest continues with the escape hatch" {
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; DEFAULT_TOOL_SHA256_X='$GOOD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X 9.9.9 1.0.0 && echo CONTINUED"
	assert_success
	assert_output --partial "::warning title=unverified install::"
	assert_output --partial "CONTINUED"
}

@test "supply_chain: malformed committed digest is rejected even with the escape hatch" {
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; DEFAULT_TOOL_SHA256_X='not-hex'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X; echo NOT-REACHED"
	assert_failure
	assert_output --partial "is not a valid digest"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: missing sha256 tool is a hard error by default" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	ln -s "$(command -v bash)" "$mock_bin/bash"
	ln -s "$(command -v awk)" "$mock_bin/awk"
	ln -s "$(command -v basename)" "$mock_bin/basename"
	run env -i PATH="$mock_bin" HOME="$HOME" bash -c "source '$LIB'; DEFAULT_TOOL_SHA256_X='$GOOD'; supply_chain_verify_sha256 '$ARTIFACT' TOOL_SHA256_X; echo NOT-REACHED"
	assert_failure
	assert_output --partial "sha256sum is required"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: require_tool returns 1 under the escape hatch so callers skip" {
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; if supply_chain_require_tool definitely-not-a-tool 'the check'; then echo PRESENT; else echo SKIPPED; fi"
	assert_success
	assert_output --partial "definitely-not-a-tool is required for the check"
	assert_output --partial "SKIPPED"
}

@test "supply_chain: require_tool exits 1 without the escape hatch" {
	_sc "supply_chain_require_tool definitely-not-a-tool 'the check'; echo NOT-REACHED"
	assert_failure
	assert_output --partial "::error title=unverified install::definitely-not-a-tool is required for the check"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: commit pin verifies a clone's HEAD" {
	local repo="${BATS_TEST_TMPDIR}/repo" head
	mkdir -p "$repo"
	(cd "$repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
	head="$(git -C "$repo" rev-parse HEAD)"
	_sc "DEFAULT_TOOL_COMMIT='$head'; supply_chain_verify_commit '$repo' TOOL_COMMIT v1 v1"
	assert_success
	assert_output --partial "commit verified against committed TOOL_COMMIT"
}

@test "supply_chain: commit pin mismatch fails closed even with the escape hatch" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$repo"
	(cd "$repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
	_sc "export LGTM_CI_ALLOW_UNVERIFIED=1; DEFAULT_TOOL_COMMIT='0000000000000000000000000000000000000000'; supply_chain_verify_commit '$repo' TOOL_COMMIT; echo NOT-REACHED"
	assert_failure
	assert_output --partial "::error title=commit mismatch::"
	refute_output --partial "NOT-REACHED"
}

@test "supply_chain: var_suffix upper-cases a target triple" {
	_sc "supply_chain_var_suffix x86_64-unknown-linux-gnu; echo; supply_chain_var_suffix linux_amd64; echo"
	assert_success
	assert_line --index 0 "X86_64_UNKNOWN_LINUX_GNU"
	assert_line --index 1 "LINUX_AMD64"
}

@test "supply_chain: public functions are exported" {
	_sc "declare -F | grep -c '^declare -fx supply_chain_'"
	assert_success
	assert_output "6"
}
