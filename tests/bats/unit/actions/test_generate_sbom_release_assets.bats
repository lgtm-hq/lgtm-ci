#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/generate-sbom-release-assets.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/generate-sbom-release-assets.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

@test "generate-sbom-release-assets: parse-formats defaults to spdx+cyclonedx json" {
	run env STEP=parse-formats bash "$SCRIPT"
	assert_success
	assert_output --partial "spdx-json"
	assert_output --partial "cyclonedx-json"
}

@test "generate-sbom-release-assets: parse-formats splits comma and space lists" {
	run env STEP=parse-formats FORMATS="spdx-json, cyclonedx-xml" bash "$SCRIPT"
	assert_success
	assert_equal "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" "2"
	assert_output --partial "spdx-json"
	assert_output --partial "cyclonedx-xml"
}

@test "generate-sbom-release-assets: parse-formats rejects unknown format with ::error::" {
	run env STEP=parse-formats FORMATS="not-a-format" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::Unsupported SBOM format: not-a-format"
}

@test "generate-sbom-release-assets: parse-formats rejects empty list with ::error::" {
	run env STEP=parse-formats FORMATS=" , " bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::formats must list at least one SBOM format"
}

@test "generate-sbom-release-assets: generate fails when FORMATS is invalid" {
	local target_dir="${BATS_TEST_TMPDIR}/src"
	mkdir -p "$target_dir"
	printf 'ok\n' >"${target_dir}/file.txt"

	run env \
		STEP=generate \
		TARGET="$target_dir" \
		TARGET_TYPE=dir \
		FORMATS="not-a-format" \
		OUTPUT_DIR="${BATS_TEST_TMPDIR}/sbom" \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::Unsupported SBOM format: not-a-format"
}

@test "generate-sbom-release-assets: generate writes files and assembles upload paths" {
	local target_dir="${BATS_TEST_TMPDIR}/src"
	mkdir -p "$target_dir"
	printf 'ok\n' >"${target_dir}/file.txt"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/syft" <<'EOF'
#!/usr/bin/env bash
# syft <target> -o format=outfile
outfile=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o)
		outfile="${2#*=}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
printf '{"bomFormat":"CycloneDX"}\n' >"$outfile"
EOF
	chmod +x "${mock_bin}/syft"
	export PATH="${mock_bin}:$PATH"

	run env \
		STEP=generate \
		TARGET="$target_dir" \
		TARGET_TYPE=dir \
		FORMATS="spdx-json,cyclonedx-json" \
		OUTPUT_DIR="${BATS_TEST_TMPDIR}/sbom" \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "Generated 2 SBOM file(s)"

	[[ -f "${BATS_TEST_TMPDIR}/sbom/sbom.spdx.json" ]]
	[[ -f "${BATS_TEST_TMPDIR}/sbom/sbom.cyclonedx.json" ]]

	run grep -E 'sbom-files|sbom\.spdx\.json|sbom\.cyclonedx\.json' "${GITHUB_OUTPUT}"
	assert_success
	assert_output --partial "sbom.spdx.json"
	assert_output --partial "sbom.cyclonedx.json"
}
