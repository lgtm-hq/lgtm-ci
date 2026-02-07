#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/docker/core.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# get_default_platforms tests
# =============================================================================

@test "get_default_platforms: returns linux/amd64,linux/arm64" {
	run bash -c '
		source "$LIB_DIR/docker/core.sh"
		get_default_platforms
	'
	assert_success
	assert_output "linux/amd64,linux/arm64"
}

# =============================================================================
# get_current_platform tests
# =============================================================================

@test "get_current_platform: returns platform in os/arch format" {
	run bash -c '
		source "$LIB_DIR/docker/core.sh"
		result=$(get_current_platform)
		# Should match pattern like linux/amd64 or darwin/arm64
		if [[ "$result" =~ ^[a-z]+/[a-z0-9/]+$ ]]; then
			echo "valid"
		else
			echo "invalid: $result"
		fi
	'
	assert_success
	assert_output "valid"
}

@test "get_current_platform: normalizes x86_64 to amd64" {
	run bash -c '
		# Mock uname to return x86_64
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		get_current_platform
	'
	assert_success
	assert_output "linux/amd64"
}

@test "get_current_platform: normalizes aarch64 to arm64" {
	run bash -c '
		# Mock uname to return aarch64
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "aarch64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		get_current_platform
	'
	assert_success
	assert_output "linux/arm64"
}

@test "get_current_platform: handles armv7l" {
	run bash -c '
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "armv7l" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		get_current_platform
	'
	assert_success
	assert_output "linux/arm/v7"
}

@test "get_current_platform: lowercases OS name" {
	run bash -c '
		uname() {
			case "$1" in
				-s) echo "Darwin" ;;
				-m) echo "arm64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		get_current_platform
	'
	assert_success
	assert_output "darwin/arm64"
}

# =============================================================================
# needs_qemu tests
# =============================================================================

@test "needs_qemu: returns false for empty platforms" {
	run bash -c '
		source "$LIB_DIR/docker/core.sh"
		needs_qemu ""
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "needs_qemu: returns false for whitespace-only platforms" {
	run bash -c '
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "   "
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "needs_qemu: returns false when only current platform requested" {
	run bash -c '
		# Mock to return linux/amd64 as current
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "linux/amd64"
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "needs_qemu: returns true when different platform requested" {
	run bash -c '
		# Mock to return linux/amd64 as current
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "linux/arm64"
		echo "result=$?"
	'
	assert_success
	assert_output "result=0"
}

@test "needs_qemu: returns true when any platform differs from current" {
	run bash -c '
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "linux/amd64,linux/arm64"
		echo "result=$?"
	'
	assert_success
	# linux/arm64 differs from linux/amd64, so QEMU needed
	assert_output "result=0"
}

@test "needs_qemu: handles platforms with whitespace" {
	run bash -c '
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "linux/amd64, linux/arm64"
		echo "result=$?"
	'
	assert_success
	assert_output "result=0"
}

@test "needs_qemu: skips empty entries in platform list" {
	run bash -c '
		uname() {
			case "$1" in
				-s) echo "Linux" ;;
				-m) echo "x86_64" ;;
			esac
		}
		export -f uname
		source "$LIB_DIR/docker/core.sh"
		needs_qemu "linux/amd64,,"
		echo "result=$?"
	'
	assert_success
	# Only linux/amd64 (current platform), so no QEMU needed
	assert_output "result=1"
}

# =============================================================================
# check_docker_available tests (mocked)
# =============================================================================

@test "check_docker_available: returns failure when docker command not found" {
	run bash -c '
		# Remove docker from PATH
		PATH=""
		source "$LIB_DIR/docker/core.sh"
		check_docker_available
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "check_docker_available: returns failure when docker daemon not running" {
	run bash -c '
		# Mock docker to fail on info
		docker() {
			if [[ "$1" == "info" ]]; then
				return 1
			fi
			command docker "$@"
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		check_docker_available
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

# =============================================================================
# check_buildx_available tests (mocked)
# =============================================================================

@test "check_buildx_available: returns failure when buildx not available" {
	run bash -c '
		# Mock docker to fail on buildx
		docker() {
			if [[ "$1" == "buildx" ]]; then
				return 1
			fi
			command docker "$@"
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		check_buildx_available
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "check_buildx_available: returns success when buildx available" {
	run bash -c '
		# Mock docker buildx version to succeed
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "version" ]]; then
				echo "github.com/docker/buildx v0.12.0"
				return 0
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		check_buildx_available
		echo "result=$?"
	'
	assert_success
	assert_output "result=0"
}

# =============================================================================
# setup_buildx_builder tests (mocked)
# =============================================================================

@test "setup_buildx_builder: uses default builder name" {
	run bash -c '
		# Track which builder name is used
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				echo "inspecting: $3" >&2
				# Simulate builder exists
				return 0
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "use" ]]; then
				echo "using: $3" >&2
				return 0
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder 2>&1 | grep "using:"
	'
	assert_success
	assert_output "using: lgtm-builder"
}

@test "setup_buildx_builder: uses custom builder name" {
	run bash -c '
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				return 0
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "use" ]]; then
				echo "using: $3"
				return 0
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder "my-custom-builder"
	'
	assert_success
	assert_output "using: my-custom-builder"
}

@test "setup_buildx_builder: creates builder when it does not exist" {
	run bash -c '
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				return 1  # Builder does not exist
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "create" ]]; then
				echo "creating builder"
				return 0
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder "new-builder"
	'
	assert_success
	assert_output "creating builder"
}

@test "setup_buildx_builder: sets DOCKER_BUILDER_NAME on success" {
	run bash -c '
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				return 0
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "use" ]]; then
				return 0
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder "test-builder"
		echo "builder=$DOCKER_BUILDER_NAME"
	'
	assert_success
	assert_output "builder=test-builder"
}

@test "setup_buildx_builder: returns failure when use fails" {
	run bash -c '
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				return 0
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "use" ]]; then
				return 1
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder "test-builder" 2>/dev/null
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

@test "setup_buildx_builder: returns failure when create fails" {
	run bash -c '
		docker() {
			if [[ "$1" == "buildx" ]] && [[ "$2" == "inspect" ]]; then
				return 1  # Builder does not exist
			fi
			if [[ "$1" == "buildx" ]] && [[ "$2" == "create" ]]; then
				return 1  # Create fails
			fi
			return 1
		}
		export -f docker
		source "$LIB_DIR/docker/core.sh"
		setup_buildx_builder "fail-builder" 2>/dev/null
		echo "result=$?"
	'
	assert_success
	assert_output "result=1"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "docker/core.sh: exports check_docker_available function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type check_docker_available"'
	assert_success
}

@test "docker/core.sh: exports check_buildx_available function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type check_buildx_available"'
	assert_success
}

@test "docker/core.sh: exports setup_buildx_builder function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type setup_buildx_builder"'
	assert_success
}

@test "docker/core.sh: exports get_default_platforms function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type get_default_platforms"'
	assert_success
}

@test "docker/core.sh: exports get_current_platform function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type get_current_platform"'
	assert_success
}

@test "docker/core.sh: exports needs_qemu function" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && bash -c "type needs_qemu"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "docker/core.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/docker/core.sh" && echo "${_LGTM_CI_DOCKER_CORE_LOADED}"'
	assert_success
	assert_output "1"
}
