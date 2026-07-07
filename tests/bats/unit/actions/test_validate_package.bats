#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-package.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/validate-package.sh"

setup() {
	setup_temp_dir
	setup_github_env

	PKG_DIR="${BATS_TEST_TMPDIR}/pkg"
	mkdir -p "$PKG_DIR"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

write_package_json() {
	cat >"${PKG_DIR}/package.json" <<'EOF'
{
  "name": "test-package",
  "version": "1.2.3"
}
EOF
}

@test "validate-package: fails without STEP" {
	run env -u STEP PACKAGE_TYPE="npm" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "validate-package: fails without PACKAGE_TYPE" {
	run env -u PACKAGE_TYPE STEP="detect" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "PACKAGE_TYPE is required"
}

@test "validate-package: detect finds package.json for npm" {
	write_package_json

	STEP="detect" PACKAGE_TYPE="npm" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Found package.json"
}

@test "validate-package: detect fails without package.json for npm" {
	STEP="detect" PACKAGE_TYPE="npm" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "No package.json found"
}

@test "validate-package: detect finds pyproject.toml for pypi" {
	printf '[project]\nname = "pkg"\nversion = "1.0.0"\n' >"${PKG_DIR}/pyproject.toml"

	STEP="detect" PACKAGE_TYPE="pypi" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Found pyproject.toml"
}

@test "validate-package: detect finds gemspec for gem" {
	touch "${PKG_DIR}/testgem.gemspec"

	STEP="detect" PACKAGE_TYPE="gem" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Found gemspec"
}

@test "validate-package: detect fails on unknown package type" {
	STEP="detect" PACKAGE_TYPE="cargo" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown package type"
}

@test "validate-package: validate passes for valid npm package" {
	write_package_json

	STEP="validate" PACKAGE_TYPE="npm" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Package validation passed: test-package@1.2.3"

	assert_file_contains "$GITHUB_OUTPUT" "valid=true"
	assert_file_contains "$GITHUB_OUTPUT" "name=test-package"
	assert_file_contains "$GITHUB_OUTPUT" "version=1.2.3"
}

@test "validate-package: validate fails for invalid npm package" {
	printf '{}' >"${PKG_DIR}/package.json"

	STEP="validate" PACKAGE_TYPE="npm" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Package validation failed"
	assert_file_contains "$GITHUB_OUTPUT" "valid=false"
}

@test "validate-package: validate passes for pypi metadata without dist" {
	printf '[project]\nname = "pkg"\nversion = "1.0.0"\n' >"${PKG_DIR}/pyproject.toml"

	STEP="validate" PACKAGE_TYPE="pypi" PACKAGE_PATH="$PKG_DIR" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "valid=true"
	assert_file_contains "$GITHUB_OUTPUT" "name=pkg"
	assert_file_contains "$GITHUB_OUTPUT" "version=1.0.0"
}

@test "validate-package: summary reports validation result" {
	STEP="summary" PACKAGE_TYPE="npm" PACKAGE_NAME="test-package" \
		PACKAGE_VERSION="1.2.3" VALID="true" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Package Validation"
	assert_output --partial "Valid"
}

@test "validate-package: fails on unknown step" {
	STEP="bogus" PACKAGE_TYPE="npm" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}
