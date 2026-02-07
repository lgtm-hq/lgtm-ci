#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/publish/registry.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# check_pypi_availability tests
# =============================================================================

@test "check_pypi_availability: returns 0 when package exists (200)" {
	mock_command "curl" "200"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_pypi_availability "my-package" "1.0.0"'
	assert_success
}

@test "check_pypi_availability: returns 1 when package not found (404)" {
	mock_command "curl" "404"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_pypi_availability "my-package" "1.0.0"'
	assert_failure
}

@test "check_pypi_availability: uses test-pypi URL when flag set" {
	mock_command_record "curl" "200"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_pypi_availability "my-package" "1.0.0" "true"'
	assert_success
	# Verify test.pypi.org was used
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "test.pypi.org"
}

@test "check_pypi_availability: requires package name" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_pypi_availability "" "1.0.0" 2>&1'
	assert_failure
}

# =============================================================================
# check_npm_availability tests
# =============================================================================

@test "check_npm_availability: returns 0 when package exists" {
	mock_command "curl" "200"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_npm_availability "my-package" "1.0.0"'
	assert_success
}

@test "check_npm_availability: returns 1 when package not found" {
	mock_command "curl" "404"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_npm_availability "my-package" "1.0.0"'
	assert_failure
}

@test "check_npm_availability: requires package name" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_npm_availability "" "1.0.0" 2>&1'
	assert_failure
}

# =============================================================================
# check_rubygems_availability tests
# =============================================================================

@test "check_rubygems_availability: returns 0 when version found" {
	mock_command "curl" '[{"number":"1.0.0"},{"number":"0.9.0"}]'

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_rubygems_availability "my-gem" "1.0.0"'
	assert_success
}

@test "check_rubygems_availability: returns 1 when version not found" {
	mock_command "curl" '[{"number":"0.9.0"}]'

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_rubygems_availability "my-gem" "2.0.0"'
	assert_failure
}

@test "check_rubygems_availability: returns 1 when gem not found" {
	mock_command "curl" "This rubygem could not be found."

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_rubygems_availability "nonexistent" "1.0.0"'
	assert_failure
}

@test "check_rubygems_availability: returns 1 for empty response" {
	mock_command "curl" ""

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_rubygems_availability "my-gem" "1.0.0"'
	assert_failure
}

@test "check_rubygems_availability: requires gem name" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && check_rubygems_availability "" "1.0.0" 2>&1'
	assert_failure
}

# =============================================================================
# wait_for_package tests
# =============================================================================

@test "wait_for_package: returns 1 for unknown registry" {
	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "unknown" "pkg" "1.0.0" 1 2>&1
	'
	assert_failure
	assert_output --partial "Unknown registry"
}

@test "wait_for_package: succeeds immediately when package available" {
	# Mock curl to return 200 for availability check
	mock_command "curl" "200"

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "pypi" "my-package" "1.0.0" 10 2>&1
	'
	assert_success
	assert_output --partial "is now available"
}

@test "wait_for_package: succeeds for npm registry" {
	mock_command "curl" "200"

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "npm" "my-package" "1.0.0" 10 2>&1
	'
	assert_success
	assert_output --partial "is now available"
}

@test "wait_for_package: succeeds for gem registry" {
	mock_command "curl" '[{"number":"1.0.0"}]'

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "gem" "my-gem" "1.0.0" 10 2>&1
	'
	assert_success
	assert_output --partial "is now available"
}

@test "wait_for_package: succeeds for rubygems alias" {
	mock_command "curl" '[{"number":"1.0.0"}]'

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "rubygems" "my-gem" "1.0.0" 10 2>&1
	'
	assert_success
	assert_output --partial "is now available"
}

@test "wait_for_package: times out when package not available" {
	mock_command "curl" "404"

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "pypi" "my-package" "1.0.0" 1 2>&1
	'
	assert_failure
	assert_output --partial "Timeout"
}

@test "wait_for_package: passes extra_arg to pypi check" {
	mock_command_record "curl" "200"

	run bash -c '
		source "$LIB_DIR/log.sh"
		source "$LIB_DIR/publish/registry.sh"
		wait_for_package "pypi" "my-package" "1.0.0" 10 "true" 2>&1
	'
	assert_success
	# Verify test.pypi.org was used
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "test.pypi.org"
}

# =============================================================================
# get_pypi_download_url tests
# =============================================================================

@test "get_pypi_download_url: extracts URL with jq" {
	local json='{"urls":[{"packagetype":"sdist","url":"https://files.pythonhosted.org/pkg-1.0.0.tar.gz"}]}'
	mock_command "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_download_url "my-package" "1.0.0"'
	assert_success
	assert_output "https://files.pythonhosted.org/pkg-1.0.0.tar.gz"
}

@test "get_pypi_download_url: returns 1 for empty response" {
	mock_command "curl" ""

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_download_url "my-package" "1.0.0"'
	assert_failure
}

@test "get_pypi_download_url: uses test-pypi URL when flag set" {
	local json='{"urls":[{"packagetype":"sdist","url":"https://test.pypi.org/pkg-1.0.0.tar.gz"}]}'
	mock_command_record "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_download_url "my-package" "1.0.0" "true"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "test.pypi.org"
}

@test "get_pypi_download_url: grep fallback when jq unavailable" {
	local json='{"urls":[{"packagetype":"sdist","url":"https://files.pythonhosted.org/pkg-1.0.0.tar.gz","digests":{"sha256":"abc"}}]}'
	mock_command "curl" "$json"

	run bash -c "
		# Hide jq by shadowing command builtin
		command() { case \"\$1\" in -v) [[ \"\$2\" != \"jq\" ]] && builtin command \"\$@\" || return 1;; *) builtin command \"\$@\";; esac; }
		source \"\$LIB_DIR/publish/registry.sh\"
		get_pypi_download_url \"my-package\" \"1.0.0\"
	"
	assert_success
	assert_output "https://files.pythonhosted.org/pkg-1.0.0.tar.gz"
}

@test "get_pypi_download_url: returns 1 when no sdist in response" {
	local json='{"urls":[{"packagetype":"bdist_wheel","url":"https://example.com/pkg.whl"}]}'
	mock_command "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_download_url "my-package" "1.0.0"'
	assert_failure
}

# =============================================================================
# get_pypi_sha256 tests
# =============================================================================

@test "get_pypi_sha256: extracts hash with jq" {
	local json='{"urls":[{"packagetype":"sdist","digests":{"sha256":"abc123def456"}}]}'
	mock_command "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_sha256 "my-package" "1.0.0"'
	assert_success
	assert_output "abc123def456"
}

@test "get_pypi_sha256: returns 1 for empty response" {
	mock_command "curl" ""

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_sha256 "my-package" "1.0.0"'
	assert_failure
}

@test "get_pypi_sha256: uses test-pypi when flag set" {
	local json='{"urls":[{"packagetype":"sdist","digests":{"sha256":"test123"}}]}'
	mock_command_record "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_sha256 "my-package" "1.0.0" "true"'
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_curl"
	assert_output --partial "test.pypi.org"
}

@test "get_pypi_sha256: returns 1 when no sdist in response" {
	local json='{"urls":[{"packagetype":"bdist_wheel","digests":{"sha256":"wheelonly"}}]}'
	mock_command "curl" "$json"

	run bash -c 'source "$LIB_DIR/publish/registry.sh" && get_pypi_sha256 "my-package" "1.0.0"'
	assert_failure
}

# =============================================================================
# Readonly variable tests
# =============================================================================

@test "registry.sh: sets PYPI_API_URL readonly" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && echo "$PYPI_API_URL"'
	assert_success
	assert_output "https://pypi.org/pypi"
}

@test "registry.sh: sets NPM_REGISTRY_URL readonly" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && echo "$NPM_REGISTRY_URL"'
	assert_success
	assert_output "https://registry.npmjs.org"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "registry.sh: exports check_pypi_availability function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f check_pypi_availability >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "registry.sh: exports wait_for_package function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f wait_for_package >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "registry.sh: exports get_pypi_download_url function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f get_pypi_download_url >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "registry.sh: exports get_pypi_sha256 function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f get_pypi_sha256 >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "registry.sh: exports check_npm_availability function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f check_npm_availability >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "registry.sh: exports check_rubygems_availability function" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && declare -f check_rubygems_availability >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "registry.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/publish/registry.sh"
		source "$LIB_DIR/publish/registry.sh"
		declare -f check_pypi_availability >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "registry.sh: sets _PUBLISH_REGISTRY_LOADED guard" {
	run bash -c 'source "$LIB_DIR/publish/registry.sh" && echo "${_PUBLISH_REGISTRY_LOADED}"'
	assert_success
	assert_output "1"
}
