#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/sign-sbom-release-assets.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/sign-sbom-release-assets.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export PROJECT_ROOT
	export SCRIPT
	export SBOM_DIR="${BATS_TEST_TMPDIR}/sbom"
	mkdir -p "$SBOM_DIR"
	printf '{"bomFormat":"CycloneDX"}\n' >"${SBOM_DIR}/sbom.cyclonedx.json"
	printf '{"spdxVersion":"SPDX-2.3"}\n' >"${SBOM_DIR}/sbom.spdx.json"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_cosign_bundle() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/cosign" <<'MOCK'
#!/usr/bin/env bash
bundle=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--bundle=*)
		bundle="${1#--bundle=}"
		shift
		;;
	--bundle)
		bundle="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
if [[ -n "$bundle" ]]; then
	echo '{"payload":"fake"}' >"$bundle"
fi
exit 0
MOCK
	chmod +x "${mock_bin}/cosign"
	export PATH="${mock_bin}:$PATH"
}

@test "sign-sbom-release-assets: skips when sign is false" {
	run env SIGN=false bash "$SCRIPT"
	assert_success
	assert_output --partial "Skipping SBOM signing"
	[[ ! -f "${SBOM_DIR}/sbom.cyclonedx.json.bundle" ]]
}

@test "sign-sbom-release-assets: skips when sign is off" {
	run env SIGN=off bash "$SCRIPT"
	assert_success
	assert_output --partial "Skipping SBOM signing"
}

@test "sign-sbom-release-assets: signs sbom files when sign is true" {
	_mock_cosign_bundle
	run env SIGN=true bash "$SCRIPT"
	assert_success
	assert_output --partial "Successfully signed 2 SBOM file(s)"
	[[ -f "${SBOM_DIR}/sbom.cyclonedx.json.bundle" ]]
	[[ -f "${SBOM_DIR}/sbom.spdx.json.bundle" ]]
}

@test "sign-sbom-release-assets: fails when SBOM_DIR missing" {
	run env SBOM_DIR="${BATS_TEST_TMPDIR}/missing" SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::SBOM directory not found"
}

@test "sign-sbom-release-assets: fails when no sbom files present" {
	rm -f "${SBOM_DIR}"/*
	_mock_cosign_bundle
	run env SIGN=true bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::No SBOM files found to sign"
}
