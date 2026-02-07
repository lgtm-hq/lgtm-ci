#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/docker/registry.sh

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
# docker_login_ghcr tests
# =============================================================================

@test "docker_login_ghcr: fails without token" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_ghcr "" 2>&1'
	assert_failure
	assert_output --partial "GitHub token required"
}

@test "docker_login_ghcr: fails without username when GITHUB_ACTOR unset" {
	mock_command_record "docker" "" 0
	mock_command "git" "" 1

	run bash -c '
		export GITHUB_ACTOR=""
		source "$LIB_DIR/docker/registry.sh"
		docker_login_ghcr "test-token" 2>&1
	'
	assert_failure
	assert_output --partial "Could not determine username"
}

@test "docker_login_ghcr: uses GITHUB_ACTOR as default username" {
	mock_command_record "docker" "Login Succeeded" 0

	run bash -c '
		export GITHUB_ACTOR="testuser"
		source "$LIB_DIR/docker/registry.sh"
		docker_login_ghcr "test-token" 2>&1
	'
	assert_success
	assert_output --partial "Login Succeeded"

	# Verify docker was called with correct arguments
	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_docker")
	if [[ "$calls" != *"ghcr.io"* ]]; then
		echo "expected 'ghcr.io' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
	if [[ "$calls" != *"-u testuser"* ]]; then
		echo "expected '-u testuser' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
}

@test "docker_login_ghcr: uses explicit username over GITHUB_ACTOR" {
	mock_command_record "docker" "Login Succeeded" 0

	run bash -c '
		export GITHUB_ACTOR="wrong-user"
		source "$LIB_DIR/docker/registry.sh"
		docker_login_ghcr "test-token" "explicit-user" 2>&1
	'
	assert_success

	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_docker")
	if [[ "$calls" != *"-u explicit-user"* ]]; then
		echo "expected '-u explicit-user' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
}

@test "docker_login_ghcr: falls back to git config user.name" {
	mock_command_record "docker" "Login Succeeded" 0
	mock_command "git" "gituser" 0

	run bash -c '
		export GITHUB_ACTOR=""
		source "$LIB_DIR/docker/registry.sh"
		docker_login_ghcr "test-token" 2>&1
	'
	assert_success

	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_docker")
	if [[ "$calls" != *"-u gituser"* ]]; then
		echo "expected '-u gituser' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
}

# =============================================================================
# docker_login_dockerhub tests
# =============================================================================

@test "docker_login_dockerhub: fails without username" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_dockerhub "" "token" 2>&1'
	assert_failure
	assert_output --partial "Username and token required"
}

@test "docker_login_dockerhub: fails without token" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_dockerhub "user" "" 2>&1'
	assert_failure
	assert_output --partial "Username and token required"
}

@test "docker_login_dockerhub: calls docker login without registry" {
	mock_command_record "docker" "Login Succeeded" 0

	run bash -c '
		source "$LIB_DIR/docker/registry.sh"
		docker_login_dockerhub "testuser" "test-token" 2>&1
	'
	assert_success
	assert_output --partial "Login Succeeded"

	# Verify docker was called without a specific registry (Docker Hub default)
	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_docker")
	if [[ "$calls" != *"-u testuser"* ]]; then
		echo "expected '-u testuser' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
	if [[ "$calls" == *"ghcr.io"* ]]; then
		echo "expected no 'ghcr.io' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
}

# =============================================================================
# docker_login_generic tests
# =============================================================================

@test "docker_login_generic: fails without registry" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_generic "" "user" "pass" 2>&1'
	assert_failure
	assert_output --partial "Registry, username, and password required"
}

@test "docker_login_generic: fails without username" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_generic "reg.example.com" "" "pass" 2>&1'
	assert_failure
	assert_output --partial "Registry, username, and password required"
}

@test "docker_login_generic: fails without password" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && docker_login_generic "reg.example.com" "user" "" 2>&1'
	assert_failure
	assert_output --partial "Registry, username, and password required"
}

@test "docker_login_generic: logs in to custom registry" {
	mock_command_record "docker" "Login Succeeded" 0

	run bash -c '
		source "$LIB_DIR/docker/registry.sh"
		docker_login_generic "registry.example.com" "testuser" "testpass" 2>&1
	'
	assert_success

	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_docker")
	if [[ "$calls" != *"registry.example.com"* ]]; then
		echo "expected 'registry.example.com' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
	if [[ "$calls" != *"-u testuser"* ]]; then
		echo "expected '-u testuser' in mock_calls_docker, got: $calls" >&2
		return 1
	fi
}

# =============================================================================
# get_registry_url tests
# =============================================================================

@test "get_registry_url: returns docker.io for simple image name" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "nginx"'
	assert_success
	assert_output "docker.io"
}

@test "get_registry_url: returns docker.io for user/image format" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "library/nginx"'
	assert_success
	assert_output "docker.io"
}

@test "get_registry_url: extracts ghcr.io from image" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "ghcr.io/owner/image"'
	assert_success
	assert_output "ghcr.io"
}

@test "get_registry_url: extracts custom registry with port" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "localhost:5000/myimage"'
	assert_success
	assert_output "localhost:5000"
}

@test "get_registry_url: extracts AWS ECR registry" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "123456789.dkr.ecr.us-east-1.amazonaws.com/myapp"'
	assert_success
	assert_output "123456789.dkr.ecr.us-east-1.amazonaws.com"
}

@test "get_registry_url: extracts Google GCR registry" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url "gcr.io/project-id/image"'
	assert_success
	assert_output "gcr.io"
}

@test "get_registry_url: handles empty input" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && get_registry_url ""'
	assert_success
	assert_output "docker.io"
}

# =============================================================================
# normalize_registry_url tests
# =============================================================================

@test "normalize_registry_url: normalizes docker.io" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url "docker.io"'
	assert_success
	assert_output "docker.io"
}

@test "normalize_registry_url: normalizes index.docker.io" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url "index.docker.io"'
	assert_success
	assert_output "docker.io"
}

@test "normalize_registry_url: normalizes registry-1.docker.io" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url "registry-1.docker.io"'
	assert_success
	assert_output "docker.io"
}

@test "normalize_registry_url: normalizes empty string to docker.io" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url ""'
	assert_success
	assert_output "docker.io"
}

@test "normalize_registry_url: removes trailing slashes" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url "ghcr.io/"'
	assert_success
	assert_output "ghcr.io"
}

@test "normalize_registry_url: preserves custom registry" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && normalize_registry_url "registry.example.com"'
	assert_success
	assert_output "registry.example.com"
}

# =============================================================================
# check_registry_auth tests
# =============================================================================

@test "check_registry_auth: returns 0 when auth exists in config" {
	local config_dir="${BATS_TEST_TMPDIR}/docker"
	mkdir -p "$config_dir"
	cat >"$config_dir/config.json" <<'EOF'
{
	"auths": {
		"ghcr.io": {
			"auth": "test-auth-placeholder"
		}
	}
}
EOF

	mock_command "jq" "true" 0

	run bash -c "
		export DOCKER_CONFIG='$config_dir'
		source \"\$LIB_DIR/docker/registry.sh\"
		check_registry_auth 'ghcr.io'
	"
	assert_success
}

@test "check_registry_auth: returns 1 when auth missing" {
	local config_dir="${BATS_TEST_TMPDIR}/docker"
	mkdir -p "$config_dir"
	cat >"$config_dir/config.json" <<'EOF'
{
	"auths": {}
}
EOF

	mock_command "jq" "" 1

	run bash -c "
		export DOCKER_CONFIG='$config_dir'
		source \"\$LIB_DIR/docker/registry.sh\"
		check_registry_auth 'ghcr.io'
	"
	assert_failure
}

@test "check_registry_auth: returns 1 when config file missing" {
	local config_dir="${BATS_TEST_TMPDIR}/docker-nonexistent"

	run bash -c "
		export DOCKER_CONFIG='$config_dir'
		source \"\$LIB_DIR/docker/registry.sh\"
		check_registry_auth 'ghcr.io'
	"
	assert_failure
}

@test "check_registry_auth: defaults to docker.io" {
	local config_dir="${BATS_TEST_TMPDIR}/docker"
	mkdir -p "$config_dir"
	cat >"$config_dir/config.json" <<'EOF'
{
	"auths": {
		"docker.io": {
			"auth": "test-auth-placeholder"
		}
	}
}
EOF

	mock_command "jq" "true" 0

	run bash -c "
		export DOCKER_CONFIG='$config_dir'
		source \"\$LIB_DIR/docker/registry.sh\"
		check_registry_auth
	"
	assert_success
}

@test "check_registry_auth: normalizes registry URL before checking" {
	local config_dir="${BATS_TEST_TMPDIR}/docker"
	mkdir -p "$config_dir"
	cat >"$config_dir/config.json" <<'EOF'
{
	"auths": {
		"docker.io": {
			"auth": "test-auth-placeholder"
		}
	}
}
EOF

	mock_command "jq" "true" 0

	run bash -c "
		export DOCKER_CONFIG='$config_dir'
		source \"\$LIB_DIR/docker/registry.sh\"
		check_registry_auth 'index.docker.io'
	"
	assert_success
}

# =============================================================================
# Function export tests
# =============================================================================

@test "registry.sh: exports docker_login_ghcr function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type docker_login_ghcr"'
	assert_success
}

@test "registry.sh: exports docker_login_dockerhub function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type docker_login_dockerhub"'
	assert_success
}

@test "registry.sh: exports docker_login_generic function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type docker_login_generic"'
	assert_success
}

@test "registry.sh: exports get_registry_url function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type get_registry_url"'
	assert_success
}

@test "registry.sh: exports normalize_registry_url function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type normalize_registry_url"'
	assert_success
}

@test "registry.sh: exports check_registry_auth function" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && bash -c "type check_registry_auth"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "registry.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/docker/registry.sh"
		source "$LIB_DIR/docker/registry.sh"
		source "$LIB_DIR/docker/registry.sh"
		declare -F docker_login_ghcr >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "registry.sh: sets _LGTM_CI_DOCKER_REGISTRY_LOADED guard" {
	run bash -c 'source "$LIB_DIR/docker/registry.sh" && echo "${_LGTM_CI_DOCKER_REGISTRY_LOADED}"'
	assert_success
	assert_output "1"
}
