#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Common test utilities for BATS tests
#
# Usage: In your .bats file:
#   load "../helpers/common"

# =============================================================================
# Path setup
# =============================================================================
# Find project root by looking for .git directory or tests directory
_find_project_root() {
	local dir

	# Safely determine starting directory
	if [[ -n "${BATS_TEST_DIRNAME:-}" ]] && [[ -d "$BATS_TEST_DIRNAME" ]]; then
		dir="$BATS_TEST_DIRNAME"
	else
		dir="$(pwd)"
	fi

	while [[ "$dir" != "/" ]]; do
		if [[ -d "$dir/.git" ]] || [[ -d "$dir/scripts/ci/lib" ]]; then
			echo "$dir"
			return 0
		fi
		local parent
		parent="$(dirname "$dir" 2>/dev/null)" || {
			echo "Error: Failed to get parent directory of $dir" >&2
			return 1
		}
		# Prevent infinite loop if dirname returns same value
		if [[ "$parent" == "$dir" ]]; then
			break
		fi
		dir="$parent"
	done

	# Fallback: try to use BATS_TEST_DIRNAME parent or current directory
	if [[ -n "${BATS_TEST_DIRNAME:-}" ]]; then
		local fallback_dir
		fallback_dir="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/../.." 2>/dev/null && pwd)" || {
			echo "Error: Could not find project root" >&2
			return 1
		}
		echo "$fallback_dir"
		return 0
	fi

	echo "Error: Could not find project root (BATS_TEST_DIRNAME not set)" >&2
	return 1
}

export PROJECT_ROOT="${PROJECT_ROOT:-$(_find_project_root)}"

# Validate PROJECT_ROOT before computing dependent paths
if [[ -z "$PROJECT_ROOT" ]] || [[ ! -d "$PROJECT_ROOT" ]]; then
	echo "ERROR: PROJECT_ROOT is invalid or does not exist: '${PROJECT_ROOT:-<empty>}'" >&2
	echo "ERROR: _find_project_root failed to locate the project directory" >&2
	exit 1
fi

export LIB_DIR="${PROJECT_ROOT}/scripts/ci/lib"
export FIXTURES_DIR="${PROJECT_ROOT}/tests/fixtures"
export HELPERS_DIR="${PROJECT_ROOT}/tests/helpers"

# =============================================================================
# Bash 4+ detection and usage
# =============================================================================
# Find bash 4+ for tests that require modern bash features
_find_modern_bash() {
	# Check Homebrew bash first (macOS)
	for path in /opt/homebrew/bin/bash /usr/local/bin/bash; do
		if [[ -x "$path" ]]; then
			local ver
			# shellcheck disable=SC2016 # Intentionally not expanding - evaluated by spawned bash
			ver=$("$path" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)
			if [[ "${ver:-0}" -ge 4 ]]; then
				echo "$path"
				return 0
			fi
		fi
	done
	# Fall back to system bash if it's 4+
	local sys_ver
	sys_ver=$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)
	if [[ "${sys_ver:-0}" -ge 4 ]]; then
		echo "bash"
		return 0
	fi
	return 1
}

# Export MODERN_BASH if available (bash 4+)
if MODERN_BASH=$(_find_modern_bash 2>/dev/null); then
	export MODERN_BASH
	export BASH4_AVAILABLE=1
else
	export BASH4_AVAILABLE=0
fi

# Helper to check if bash 4+ is available
bash4_available() {
	[[ "${BASH4_AVAILABLE:-0}" -eq 1 ]]
}

# Skip test if bash 4+ is not available (for tests that use bash 4+ syntax)
# Usage: require_bash4 (at start of test)
require_bash4() {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
}

# Run command with modern bash (use in tests that need bash 4+ features)
# Usage: run_with_modern_bash 'source "$LIB_DIR/log.sh" && log_verbose "test"'
run_with_modern_bash() {
	if bash4_available; then
		run "$MODERN_BASH" -c "$1"
	else
		skip "requires bash 4+"
	fi
}

# =============================================================================
# Load bats helper libraries
# =============================================================================
# These are loaded via bats-core's built-in support when available
# Fallback paths for local installations

_load_bats_library() {
	local name="$1"
	local paths=(
		# bats-core standard locations
		"${BATS_TEST_DIRNAME}/../../node_modules/bats-${name}/load.bash"
		"${BATS_TEST_DIRNAME}/../../../node_modules/bats-${name}/load.bash"
		# Homebrew on macOS
		"/opt/homebrew/lib/bats-${name}/load.bash"
		"/usr/local/lib/bats-${name}/load.bash"
		# Linux system paths
		"/usr/lib/bats-${name}/load.bash"
		"/usr/share/bats-${name}/load.bash"
		# npm global
		"/usr/local/lib/node_modules/bats-${name}/load.bash"
	)

	for path in "${paths[@]}"; do
		if [[ -f "$path" ]]; then
			# shellcheck disable=SC1090
			source "$path"
			return 0
		fi
	done

	# If library not found, provide stub implementations
	return 1
}

# Load bats-support (provides core test utilities)
if ! _load_bats_library "support"; then
	# Minimal fallback for bats-support (fail function only)
	fail() {
		echo "# $*" >&2
		return 1
	}
fi

# Load bats-assert (provides assertion functions)
if ! _load_bats_library "assert"; then
	# In CI, fail fast - libraries should be installed
	if [[ "${CI:-}" == "true" ]] || [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		echo "ERROR: bats-assert library not found. Install with the CI workflow." >&2
		exit 1
	fi

	# For local development, provide minimal fallback implementations
	echo "# WARNING: bats-assert not found, using fallback implementations" >&2

	assert_success() {
		if [[ "$status" -ne 0 ]]; then
			echo "# Expected success (exit 0), got exit $status" >&2
			echo "# Output: $output" >&2
			return 1
		fi
	}

	assert_failure() {
		local expected_code="${1:-}"
		if [[ -n "$expected_code" ]]; then
			# Specific exit code requested
			if [[ "$status" -ne "$expected_code" ]]; then
				echo "# Expected exit code $expected_code, got $status" >&2
				echo "# Output: $output" >&2
				return 1
			fi
		else
			# Any non-zero exit code
			if [[ "$status" -eq 0 ]]; then
				echo "# Expected failure (exit != 0), got exit 0" >&2
				echo "# Output: $output" >&2
				return 1
			fi
		fi
	}

	assert_output() {
		local expected
		if [[ "$1" == "--partial" ]]; then
			expected="$2"
			if [[ "$output" != *"$expected"* ]]; then
				echo "# Expected output to contain: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		elif [[ "$1" == "--regexp" ]]; then
			expected="$2"
			if ! [[ "$output" =~ $expected ]]; then
				echo "# Expected output to match regex: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		else
			expected="$1"
			if [[ "$output" != "$expected" ]]; then
				echo "# Expected output: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		fi
	}

	assert_line() {
		local index=""
		local partial=""
		local expected

		# Parse flags
		while [[ $# -gt 1 ]]; do
			case "$1" in
			--index)
				if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
					echo "# assert_line --index requires a numeric argument" >&2
					return 1
				fi
				index="$2"
				shift 2
				;;
			--partial)
				partial=1
				shift
				;;
			*)
				break
				;;
			esac
		done
		if [[ $# -eq 0 ]] || [[ "$1" == --* ]]; then
			echo "# assert_line requires an expected value" >&2
			return 1
		fi
		expected="$1"

		if [[ -n "$index" ]]; then
			# Index-based: check specific line
			local actual_line
			actual_line=$(echo "$output" | sed -n "$((index + 1))p")
			if [[ -n "$partial" ]]; then
				if [[ "$actual_line" != *"$expected"* ]]; then
					echo "# Expected line $index to contain: $expected" >&2
					echo "# Actual line $index: $actual_line" >&2
					echo "# Full output: $output" >&2
					return 1
				fi
			else
				if [[ "$actual_line" != "$expected" ]]; then
					echo "# Expected line $index: $expected" >&2
					echo "# Actual line $index: $actual_line" >&2
					echo "# Full output: $output" >&2
					return 1
				fi
			fi
		elif [[ -n "$partial" ]]; then
			local found=0
			while IFS= read -r line; do
				if [[ "$line" == *"$expected"* ]]; then
					found=1
					break
				fi
			done <<<"$output"
			if [[ $found -eq 0 ]]; then
				echo "# Expected a line containing: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		else
			local found=0
			while IFS= read -r line; do
				if [[ "$line" == "$expected" ]]; then
					found=1
					break
				fi
			done <<<"$output"
			if [[ $found -eq 0 ]]; then
				echo "# Expected line: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		fi
	}

	refute_output() {
		local partial=""
		local expected=""

		if [[ "${1:-}" == "--partial" ]]; then
			partial=1
			expected="${2:-}"
		else
			expected="${1:-}"
		fi

		if [[ -n "$partial" ]] && [[ -n "$expected" ]]; then
			if [[ "$output" == *"$expected"* ]]; then
				echo "# Expected output to NOT contain: $expected" >&2
				echo "# Actual output: $output" >&2
				return 1
			fi
		else
			if [[ -n "$output" ]]; then
				echo "# Expected no output, got: $output" >&2
				return 1
			fi
		fi
	}

	assert_equal() {
		local expected="$1"
		local actual="$2"
		if [[ "$expected" != "$actual" ]]; then
			echo "# Expected: $expected" >&2
			echo "# Actual:   $actual" >&2
			return 1
		fi
	}
fi

# Load bats-file (provides file assertion functions)
if ! _load_bats_library "file"; then
	# In CI, fail fast - libraries should be installed
	if [[ "${CI:-}" == "true" ]] || [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		echo "ERROR: bats-file library not found. Install with the CI workflow." >&2
		exit 1
	fi

	# For local development, provide minimal fallback implementations
	echo "# WARNING: bats-file not found, using fallback implementations" >&2

	assert_file_exists() {
		local file="$1"
		if [[ ! -f "$file" ]]; then
			echo "# Expected file to exist: $file" >&2
			return 1
		fi
	}

	assert_dir_exists() {
		local dir="$1"
		if [[ ! -d "$dir" ]]; then
			echo "# Expected directory to exist: $dir" >&2
			return 1
		fi
	}

	assert_file_not_exists() {
		local file="$1"
		if [[ -f "$file" ]]; then
			echo "# Expected file to NOT exist: $file" >&2
			return 1
		fi
	}

	assert_file_contains() {
		local file="$1"
		local expected="$2"
		if ! grep -q "$expected" "$file" 2>/dev/null; then
			echo "# Expected file '$file' to contain: $expected" >&2
			return 1
		fi
	}
fi

# =============================================================================
# Temporary directory management
# =============================================================================

# Setup a temporary directory for the test
# Usage: setup_temp_dir (in setup function)
# Creates BATS_TEST_TMPDIR that is auto-cleaned in teardown
setup_temp_dir() {
	BATS_TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bats-test.XXXXXXXXXX")
	export BATS_TEST_TMPDIR
}

# Teardown temporary directory
# Usage: teardown_temp_dir (in teardown function)
teardown_temp_dir() {
	if [[ -n "${BATS_TEST_TMPDIR:-}" ]] && [[ -d "$BATS_TEST_TMPDIR" ]]; then
		rm -rf "$BATS_TEST_TMPDIR"
	fi
}

# =============================================================================
# Library sourcing utilities
# =============================================================================

# Source a library file with clean environment
# Usage: source_lib "log.sh"
# Usage: source_lib "github/output.sh"
source_lib() {
	local lib_path="$1"

	# Handle both absolute and relative paths
	if [[ "$lib_path" = /* ]]; then
		# Absolute path
		# shellcheck disable=SC1090
		source "$lib_path"
	else
		# Relative to LIB_DIR
		# shellcheck disable=SC1090
		source "${LIB_DIR}/${lib_path}"
	fi
}

# Reset library load guards to allow re-sourcing
# Usage: reset_lib_guards
#
# NOTE: The library guard variables are declared readonly, which means they
# cannot be unset within the same process. This function is a NO-OP that exists
# for documentation purposes.
#
# To test library re-sourcing behavior, use subshell isolation instead:
#   run bash -c 'source "$LIB_DIR/log.sh" && ...'
#
# Each subshell starts with a fresh environment where guards are not set.
reset_lib_guards() {
	# The following guards are readonly and cannot be unset in-process:
	# - _LGTM_CI_LOG_LOADED
	# - _LGTM_CI_PLATFORM_LOADED
	# - _LGTM_CI_FS_LOADED
	# - _LGTM_CI_GIT_LOADED
	# - _LGTM_CI_GITHUB_OUTPUT_LOADED
	# - _RELEASE_VERSION_LOADED
	# - _LGTM_CI_NETWORK_CHECKSUM_LOADED
	#
	# Use subshell isolation (bash -c '...') in tests that need fresh state.
	:
}

# =============================================================================
# Test isolation helpers
# =============================================================================

# Run a command capturing both stdout and stderr
# Usage: run_capture_all command args...
# Sets: output (combined), stdout, stderr, status
run_capture_all() {
	local tmp_stdout tmp_stderr
	tmp_stdout=$(mktemp)
	tmp_stderr=$(mktemp)

	set +e
	"$@" >"$tmp_stdout" 2>"$tmp_stderr"
	status=$?
	set -e

	stdout=$(cat "$tmp_stdout")
	stderr=$(cat "$tmp_stderr")
	output="${stdout}${stderr}"

	rm -f "$tmp_stdout" "$tmp_stderr"
}

# =============================================================================
# Assertion helpers
# =============================================================================

# Assert that a function is exported
# Usage: assert_function_exported "log_info"
assert_function_exported() {
	local func_name="$1"
	if ! declare -F "$func_name" &>/dev/null; then
		echo "# Function not defined: $func_name" >&2
		return 1
	fi
	# Check if exported (visible in subshell)
	if ! bash -c "declare -F $func_name" &>/dev/null; then
		echo "# Function not exported: $func_name" >&2
		return 1
	fi
}

# Assert that a variable is set and readonly
# Usage: assert_readonly_var "LGTM_CI_RED"
assert_readonly_var() {
	local var_name="$1"
	if ! declare -p "$var_name" &>/dev/null; then
		echo "# Variable not defined: $var_name" >&2
		return 1
	fi
	# Use regex to ensure -r is in the flags field (e.g., "declare -r" or "declare -xr")
	# This avoids false positives from values/names containing "-r"
	if [[ ! "$(declare -p "$var_name")" =~ ^declare\ -[^[:space:]]*r ]]; then
		echo "# Variable not readonly: $var_name" >&2
		return 1
	fi
}

# Assert exit code
# Usage: assert_exit_code 0
assert_exit_code() {
	local expected="$1"
	if [[ "$status" -ne "$expected" ]]; then
		echo "# Expected exit code $expected, got $status" >&2
		echo "# Output: $output" >&2
		return 1
	fi
}
