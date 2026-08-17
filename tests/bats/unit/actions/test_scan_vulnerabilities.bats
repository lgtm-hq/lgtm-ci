#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/scan-vulnerabilities.sh counts step

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_run_counts() {
	local results_file="$1"
	run env \
		STEP=counts \
		RESULTS_FILE="$results_file" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"
}

_write_results_fixture() {
	local file="$1"
	cat >"$file" <<'EOF'
{
  "matches": [
    {"vulnerability": {"severity": "Critical", "id": "CVE-1"}, "artifact": {"name": "a", "version": "1.0"}},
    {"vulnerability": {"severity": "High", "id": "CVE-2"}, "artifact": {"name": "b", "version": "1.0"}},
    {"vulnerability": {"severity": "High", "id": "CVE-3"}, "artifact": {"name": "c", "version": "1.0"}},
    {"vulnerability": {"severity": "Medium", "id": "CVE-4"}, "artifact": {"name": "d", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-5"}, "artifact": {"name": "e", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-6"}, "artifact": {"name": "f", "version": "1.0"}},
    {"vulnerability": {"severity": "Low", "id": "CVE-7"}, "artifact": {"name": "g", "version": "1.0"}},
    {"vulnerability": {"severity": "Negligible", "id": "CVE-8"}, "artifact": {"name": "h", "version": "1.0"}}
  ]
}
EOF
}

@test "scan-vulnerabilities counts: fails when RESULTS_FILE is not set" {
	run env STEP=counts \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"

	assert_failure
	assert_output --partial "RESULTS_FILE is required"
}

@test "scan-vulnerabilities counts: fails when results file is missing" {
	_run_counts "${BATS_TEST_TMPDIR}/does-not-exist.json"

	assert_failure
	assert_output --partial "Results file not found or unreadable"
	run grep -qE -- '^critical-count=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "scan-vulnerabilities counts: fails on malformed JSON" {
	printf 'not-json{{{\n' >"${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_failure
	assert_output --partial "Failed to parse grype results with jq"
	run grep -qE -- '^critical-count=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "scan-vulnerabilities counts: emits correct counts for known severities" {
	_write_results_fixture "${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^vulnerabilities-found=true$'
	assert_file_contains "$GITHUB_OUTPUT" '^critical-count=1$'
	assert_file_contains "$GITHUB_OUTPUT" '^high-count=2$'
	assert_file_contains "$GITHUB_OUTPUT" '^medium-count=1$'
	assert_file_contains "$GITHUB_OUTPUT" '^low-count=3$'
}

@test "scan-vulnerabilities counts: emits zeros when no matches present" {
	printf '{"matches": []}\n' >"${BATS_TEST_TMPDIR}/results.json"

	_run_counts "${BATS_TEST_TMPDIR}/results.json"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^vulnerabilities-found=false$'
	assert_file_contains "$GITHUB_OUTPUT" '^critical-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^high-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^medium-count=0$'
	assert_file_contains "$GITHUB_OUTPUT" '^low-count=0$'
}

@test "scan-vulnerabilities resolve-target: prefers SBOM_FILE when target-type is sbom" {
	run env \
		STEP=resolve-target \
		TARGET=ignored-path \
		TARGET_TYPE=sbom \
		SBOM_FILE=/tmp/sbom.json \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^path=/tmp/sbom.json$'
}

@test "scan-vulnerabilities resolve-target: uses TARGET otherwise" {
	run env \
		STEP=resolve-target \
		TARGET=/tmp/image:tag \
		TARGET_TYPE=image \
		SBOM_FILE=/tmp/sbom.json \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^path=/tmp/image:tag$'
}

@test "scan-vulnerabilities resolve-target: fails when TARGET_TYPE unset" {
	run env -u TARGET_TYPE \
		STEP=resolve-target \
		TARGET=/tmp/target \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"

	assert_failure
	assert_output --partial "TARGET_TYPE is required"
}

@test "scan-vulnerabilities action: grype-version default reads CycloneDX 1.7 (#865)" {
	local action_file="${PROJECT_ROOT}/.github/actions/scan-vulnerabilities/action.yml"
	local version
	version="$(grep -A6 '^  grype-version:' "$action_file" |
		grep -Eo 'default: "v[0-9]+\.[0-9]+\.[0-9]+"' |
		grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
	[ -n "$version" ]
	# grype >= 0.115.0 is required to parse CycloneDX 1.7 SBOMs from syft >= 1.44
	run sort -C -V <(printf '0.115.0\n%s\n' "$version")
	assert_success
}

@test "scan-vulnerabilities action: grype-version pin has renovate annotation (#865)" {
	local action_file="${PROJECT_ROOT}/.github/actions/scan-vulnerabilities/action.yml"
	run grep -B1 'default: "v' "$action_file"
	assert_success
	assert_output --partial "renovate: datasource=github-releases depName=anchore/grype"
}

@test "scan-vulnerabilities action: scan and sarif steps both use the pin (#865, #867)" {
	local action_file="${PROJECT_ROOT}/.github/actions/scan-vulnerabilities/action.yml"
	run grep -F 'grype-version: ${{ inputs.grype-version }}' "$action_file"
	assert_success
	run grep -F 'GRYPE_VERSION: ${{ inputs.grype-version }}' "$action_file"
	assert_success
}

@test "scan-vulnerabilities action: renovate.json manager covers the grype pin (#865)" {
	local renovate_file="${PROJECT_ROOT}/renovate.json"
	# The custom manager must target the action file...
	run grep -F 'scan-vulnerabilities/action\\.yml' "$renovate_file"
	assert_success
	# ...and its matchString must expect the quoted default line shape used there
	run grep -F 'default: \"v(?<currentValue>' "$renovate_file"
	assert_success
}

_run_sarif() {
	run env \
		STEP=sarif \
		TARGET="$1" \
		TARGET_TYPE=sbom \
		GRYPE_VERSION="${2:-}" \
		RUNNER_TOOL_CACHE="${3:-${BATS_TEST_TMPDIR}/no-cache}" \
		RUNNER_TEMP="$BATS_TEST_TMPDIR" \
		SARIF_FILE="${BATS_TEST_TMPDIR}/out.sarif" \
		PATH="$PATH" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/scan-vulnerabilities.sh"
}

@test "scan-vulnerabilities sarif: uses pinned grype from tool cache (#867)" {
	local cache="${BATS_TEST_TMPDIR}/toolcache"
	mkdir -p "$cache/grype/0.117.0/x64"
	printf '#!/usr/bin/env bash\necho "pinned-sarif"\n' >"$cache/grype/0.117.0/x64/grype"
	chmod +x "$cache/grype/0.117.0/x64/grype"
	printf '{}' >"${BATS_TEST_TMPDIR}/sbom.json"

	_run_sarif "${BATS_TEST_TMPDIR}/sbom.json" "v0.117.0" "$cache"

	assert_success
	assert_output --partial "Using pinned grype v0.117.0 from tool cache"
	assert_file_contains "${BATS_TEST_TMPDIR}/out.sarif" '^pinned-sarif$'
}

@test "scan-vulnerabilities sarif: warns and falls back to PATH grype when pin absent (#867)" {
	printf '{}' >"${BATS_TEST_TMPDIR}/sbom.json"

	_run_sarif "${BATS_TEST_TMPDIR}/sbom.json" "v0.117.0"

	assert_success
	assert_output --partial "not in tool cache; using PATH grype"
}
