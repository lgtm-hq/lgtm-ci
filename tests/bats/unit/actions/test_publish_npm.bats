#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/publish-npm.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/publish-npm.sh"

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

@test "publish-npm: fails without STEP" {
	run env -u STEP bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "publish-npm: fails on unknown step" {
	STEP="bogus" WORKING_DIRECTORY="$PKG_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}

@test "publish-npm: validate passes for valid package.json" {
	write_package_json

	STEP="validate" WORKING_DIRECTORY="$PKG_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Package valid: test-package@1.2.3"
}

@test "publish-npm: validate fails when package.json is missing" {
	STEP="validate" WORKING_DIRECTORY="$PKG_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "package.json not found"
}

@test "publish-npm: validate fails on invalid version" {
	cat >"${PKG_DIR}/package.json" <<'EOF'
{
  "name": "test-package",
  "version": "not-semver"
}
EOF

	STEP="validate" WORKING_DIRECTORY="$PKG_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "validation failed"
}

@test "publish-npm: publish uses OIDC when NODE_AUTH_TOKEN unset" {
	write_package_json
	mock_command_multi "npm" '
		--version) echo "11.5.1";;
		*) exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" PROVENANCE="false" \
		run env -u NODE_AUTH_TOKEN bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "OIDC trusted publishing"
	assert_output --partial "Published successfully"
}

@test "publish-npm: OIDC publish rejects npm below 11.5.1" {
	write_package_json
	mock_command_multi "npm" '
		--version) echo "10.9.2";;
		*) exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" \
		run env -u NODE_AUTH_TOKEN bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "OIDC trusted publishing requires npm 11.5.1+"
}

@test "publish-npm: empty NODE_AUTH_TOKEN uses OIDC path" {
	write_package_json
	mock_command_multi "npm" '
		--version) echo "11.6.0";;
		*) exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" NODE_AUTH_TOKEN="" \
		PROVENANCE="false" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "OIDC trusted publishing"
}

@test "publish-npm: publish runs npm publish without provenance" {
	write_package_json
	mock_command_record "npm" ""

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" NODE_AUTH_TOKEN="tok" \
		PROVENANCE="false" DIST_TAG="next" ACCESS="restricted" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "legacy NODE_AUTH_TOKEN"
	assert_output --partial "Published successfully"

	grep -qF -- "publish --tag next --access restricted" "${BATS_TEST_TMPDIR}/mock_calls_npm"
	! grep -qF -- "--provenance" "${BATS_TEST_TMPDIR}/mock_calls_npm"
	assert_file_contains "$GITHUB_OUTPUT" "published=true"
}

@test "publish-npm: publish adds --provenance on modern npm" {
	write_package_json
	mock_command_multi "npm" '
		--version) echo "10.2.0";;
		*) exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" NODE_AUTH_TOKEN="tok" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "npm publish"
	assert_output --partial "provenance"
}

@test "publish-npm: OIDC publish adds --provenance as explicit intent" {
	write_package_json
	: >"${BATS_TEST_TMPDIR}/mock_calls_npm"
	mock_command_multi "npm" '
		--version) echo "11.5.1";;
		*) echo "$*" >> "'"${BATS_TEST_TMPDIR}"'/mock_calls_npm"; exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" PROVENANCE="true" \
		run env -u NODE_AUTH_TOKEN bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "OIDC trusted publishing"
	grep -qF -- "--provenance" "${BATS_TEST_TMPDIR}/mock_calls_npm"
}

@test "publish-npm: publish rejects provenance on old npm" {
	write_package_json
	mock_command_multi "npm" '
		--version) echo "9.4.2";;
		*) exit 0;;
	'

	STEP="publish" WORKING_DIRECTORY="$PKG_DIR" NODE_AUTH_TOKEN="tok" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "npm 9.5.0+ required for provenance"
}

@test "publish-npm: summary reports dry run" {
	STEP="summary" WORKING_DIRECTORY="$PKG_DIR" PACKAGE_NAME="test-package" \
		PACKAGE_VERSION="1.2.3" DRY_RUN="true" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "npm Publishing"
	assert_output --partial "Dry Run"
}

@test "publish-npm: summary reports published with URL" {
	STEP="summary" WORKING_DIRECTORY="$PKG_DIR" PACKAGE_NAME="test-package" \
		PACKAGE_VERSION="1.2.3" PUBLISHED="true" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Published"
	assert_output --partial "https://www.npmjs.com/package/test-package/v/1.2.3"
}
