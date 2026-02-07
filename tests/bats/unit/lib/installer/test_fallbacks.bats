#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/installer/fallbacks.sh

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
# installer_fallback_go tests
# =============================================================================

@test "installer_fallback_go: succeeds when go is available" {
	mock_command_record "go" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_go "github.com/user/tool@v1.0.0" 2>&1'
	assert_success
	assert_output --partial "installed via go install"
}

@test "installer_fallback_go: returns 1 when go not available" {
	run bash -c '
		command() {
			if [[ "$2" == "go" ]]; then return 1; fi
			builtin command "$@"
		}
		source "$LIB_DIR/installer/fallbacks.sh"
		installer_fallback_go "github.com/user/tool@v1.0.0" 2>&1
	'
	assert_failure
}

@test "installer_fallback_go: shows output on failure in verbose mode" {
	mock_command "go" "build error: missing module" 1

	run bash -c 'export VERBOSE=1 && source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_go "github.com/user/tool@v1.0.0" 2>&1'
	assert_failure
}

@test "installer_fallback_go: uses TOOL_NAME in success message" {
	mock_command_record "go" ""

	run bash -c 'export TOOL_NAME="mytool" && source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_go "github.com/user/tool@v1.0.0" 2>&1'
	assert_success
	assert_output --partial "mytool installed via go install"
}

# =============================================================================
# installer_fallback_brew tests
# =============================================================================

@test "installer_fallback_brew: succeeds when brew is available" {
	mock_command_record "brew" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_brew "myformula" 2>&1'
	assert_success
	assert_output --partial "installed via Homebrew"
}

@test "installer_fallback_brew: returns 1 when brew not available" {
	run bash -c '
		command() {
			if [[ "$2" == "brew" ]]; then return 1; fi
			builtin command "$@"
		}
		source "$LIB_DIR/installer/fallbacks.sh"
		installer_fallback_brew "myformula" 2>&1
	'
	assert_failure
}

@test "installer_fallback_brew: passes --cask flag" {
	mock_command_record "brew" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_brew "myapp" "--cask" 2>&1'
	assert_success
	# Verify brew was called with --cask
	run cat "${BATS_TEST_TMPDIR}/mock_calls_brew"
	assert_output --partial "--cask"
}

@test "installer_fallback_brew: warns about version mismatch" {
	mock_command_record "brew" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_brew "myformula" 2>&1'
	assert_success
	assert_output --partial "may install different version"
}

# =============================================================================
# installer_fallback_cargo tests
# =============================================================================

@test "installer_fallback_cargo: succeeds with plain package name" {
	mock_command_record "cargo" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_cargo "ripgrep" 2>&1'
	assert_success
	assert_output --partial "installed via cargo"
	# Verify cargo was called with install ripgrep
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output --partial "install ripgrep"
}

@test "installer_fallback_cargo: handles package@version format" {
	mock_command_record "cargo" ""

	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && installer_fallback_cargo "ripgrep@14.0.0" 2>&1'
	assert_success
	# Verify cargo was called with --version flag
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cargo"
	assert_output --partial "install ripgrep --version 14.0.0"
}

@test "installer_fallback_cargo: returns 1 when cargo not available" {
	run bash -c '
		command() {
			if [[ "$2" == "cargo" ]]; then return 1; fi
			builtin command "$@"
		}
		source "$LIB_DIR/installer/fallbacks.sh"
		installer_fallback_cargo "ripgrep" 2>&1
	'
	assert_failure
}

# =============================================================================
# installer_run_chain tests
# =============================================================================

@test "installer_run_chain: returns 0 when first method succeeds" {
	run bash -c '
		source "$LIB_DIR/installer/fallbacks.sh"
		method1() { return 0; }
		method2() { return 0; }
		installer_run_chain method1 method2
	'
	assert_success
}

@test "installer_run_chain: tries second method when first fails" {
	run bash -c '
		source "$LIB_DIR/installer/fallbacks.sh"
		method1() { return 1; }
		method2() { echo "second ran"; return 0; }
		installer_run_chain method1 method2
	'
	assert_success
	assert_output "second ran"
}

@test "installer_run_chain: returns 1 when all methods fail" {
	run bash -c '
		source "$LIB_DIR/installer/fallbacks.sh"
		method1() { return 1; }
		method2() { return 1; }
		installer_run_chain method1 method2 2>&1
	'
	assert_failure
	assert_output --partial "Failed to install"
}

# =============================================================================
# installer_run tests
# =============================================================================

@test "installer_run: executes install function normally" {
	run bash -c '
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "installed"; }
		installer_run my_install
	'
	assert_success
	assert_output "installed"
}

@test "installer_run: dry-run with DRY_RUN=1" {
	run bash -c '
		export DRY_RUN=1
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "should not run"; }
		installer_run my_install 2>&1
	'
	assert_success
	assert_output --partial "[DRY-RUN]"
	refute_output --partial "should not run"
}

@test "installer_run: dry-run with DRY_RUN=true" {
	run bash -c '
		export DRY_RUN=true
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "should not run"; }
		installer_run my_install 2>&1
	'
	assert_success
	assert_output --partial "[DRY-RUN]"
}

@test "installer_run: dry-run with DRY_RUN=yes" {
	run bash -c '
		export DRY_RUN=yes
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "should not run"; }
		installer_run my_install 2>&1
	'
	assert_success
	assert_output --partial "[DRY-RUN]"
}

@test "installer_run: dry-run includes TOOL_NAME and TOOL_VERSION" {
	run bash -c '
		export DRY_RUN=1
		export TOOL_NAME="mytool"
		export TOOL_VERSION="2.0.0"
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "nope"; }
		installer_run my_install 2>&1
	'
	assert_success
	assert_output --partial "mytool"
	assert_output --partial "v2.0.0"
}

@test "installer_run: no dry-run when DRY_RUN=0" {
	run bash -c '
		export DRY_RUN=0
		source "$LIB_DIR/installer/fallbacks.sh"
		my_install() { echo "executed"; }
		installer_run my_install
	'
	assert_success
	assert_output "executed"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "fallbacks.sh: exports installer_fallback_go function" {
	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && declare -f installer_fallback_go >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "fallbacks.sh: exports installer_run_chain function" {
	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && declare -f installer_run_chain >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "fallbacks.sh: exports installer_run function" {
	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && declare -f installer_run >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "fallbacks.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/installer/fallbacks.sh"
		source "$LIB_DIR/installer/fallbacks.sh"
		declare -f installer_fallback_go >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "fallbacks.sh: sets _LGTM_CI_INSTALLER_FALLBACKS_LOADED guard" {
	run bash -c 'source "$LIB_DIR/installer/fallbacks.sh" && echo "${_LGTM_CI_INSTALLER_FALLBACKS_LOADED}"'
	assert_success
	assert_output "1"
}
