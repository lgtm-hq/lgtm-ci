#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions environment simulation for BATS tests
#
# Usage: In your .bats file:
#   load "../helpers/github_env"

# =============================================================================
# GitHub Actions environment simulation
# =============================================================================

# Setup simulated GitHub Actions environment
# Usage: setup_github_env (in setup function)
# Creates temp files for GITHUB_OUTPUT, GITHUB_ENV, GITHUB_PATH, GITHUB_STEP_SUMMARY
setup_github_env() {
	# Ensure temp dir exists
	if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
		BATS_TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bats-test.XXXXXXXXXX")
		export BATS_TEST_TMPDIR
	fi

	# Create GitHub Actions environment files
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	export GITHUB_ENV="${BATS_TEST_TMPDIR}/github_env"
	export GITHUB_PATH="${BATS_TEST_TMPDIR}/github_path"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/github_step_summary"

	# Initialize empty files
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_ENV"
	: >"$GITHUB_PATH"
	: >"$GITHUB_STEP_SUMMARY"

	# Set common GitHub Actions environment variables
	export GITHUB_ACTIONS="true"
	export GITHUB_WORKFLOW="test-workflow"
	export GITHUB_RUN_ID="12345"
	export GITHUB_RUN_NUMBER="1"
	export GITHUB_JOB="test-job"
	export GITHUB_ACTION="test-action"
	export GITHUB_ACTOR="test-user"
	export GITHUB_REPOSITORY="test-org/test-repo"
	export GITHUB_EVENT_NAME="push"
	export GITHUB_SHA="abc1234567890123456789012345678901234567"
	export GITHUB_REF="refs/heads/main"
	export GITHUB_REF_NAME="main"
	export GITHUB_REF_TYPE="branch"
	export GITHUB_HEAD_REF=""
	export GITHUB_BASE_REF=""
	export GITHUB_SERVER_URL="https://github.com"
	export GITHUB_API_URL="https://api.github.com"
	export GITHUB_GRAPHQL_URL="https://api.github.com/graphql"
	export RUNNER_OS="Linux"
	export RUNNER_ARCH="X64"
	export RUNNER_NAME="test-runner"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner_temp"

	mkdir -p "$RUNNER_TEMP"
}

# Teardown GitHub Actions environment
# Usage: teardown_github_env (in teardown function)
teardown_github_env() {
	unset GITHUB_OUTPUT GITHUB_ENV GITHUB_PATH GITHUB_STEP_SUMMARY
	unset GITHUB_ACTIONS GITHUB_WORKFLOW GITHUB_RUN_ID GITHUB_RUN_NUMBER
	unset GITHUB_JOB GITHUB_ACTION GITHUB_ACTOR GITHUB_REPOSITORY
	unset GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REF GITHUB_REF_NAME GITHUB_REF_TYPE
	unset GITHUB_HEAD_REF GITHUB_BASE_REF
	unset GITHUB_SERVER_URL GITHUB_API_URL GITHUB_GRAPHQL_URL
	unset RUNNER_OS RUNNER_ARCH RUNNER_NAME RUNNER_TEMP
}

# =============================================================================
# GitHub output helpers
# =============================================================================

# Get a value from GITHUB_OUTPUT
# Usage: value=$(get_github_output "key")
get_github_output() {
	local key="$1"

	if [[ ! -f "${GITHUB_OUTPUT:-}" ]]; then
		return 1
	fi

	# Handle simple key=value format
	local value
	value=$(grep "^${key}=" "$GITHUB_OUTPUT" | head -1 | cut -d= -f2-)

	if [[ -n "$value" ]]; then
		echo "$value"
		return 0
	fi

	# Handle multiline format: key<<DELIMITER ... DELIMITER
	local in_multiline=0
	local delimiter=""
	local result=""

	while IFS= read -r line; do
		if [[ $in_multiline -eq 1 ]]; then
			if [[ "$line" == "$delimiter" ]]; then
				echo "$result"
				return 0
			else
				if [[ -n "$result" ]]; then
					result="${result}"$'\n'"${line}"
				else
					result="$line"
				fi
			fi
		elif [[ "$line" =~ ^${key}\<\<(.+)$ ]]; then
			in_multiline=1
			delimiter="${BASH_REMATCH[1]}"
		fi
	done <"$GITHUB_OUTPUT"

	return 1
}

# Get a value from GITHUB_ENV
# Usage: value=$(get_github_env "key")
get_github_env() {
	local key="$1"

	if [[ ! -f "${GITHUB_ENV:-}" ]]; then
		return 1
	fi

	grep "^${key}=" "$GITHUB_ENV" | head -1 | cut -d= -f2-
}

# Get paths added to GITHUB_PATH
# Usage: paths=$(get_github_path)
get_github_path() {
	if [[ -f "${GITHUB_PATH:-}" ]]; then
		cat "$GITHUB_PATH"
	fi
}

# Get step summary content
# Usage: summary=$(get_github_step_summary)
get_github_step_summary() {
	if [[ -f "${GITHUB_STEP_SUMMARY:-}" ]]; then
		cat "$GITHUB_STEP_SUMMARY"
	fi
}

# =============================================================================
# Assertion helpers for GitHub outputs
# =============================================================================

# Assert that a GitHub output was set to a specific value
# Usage: assert_github_output "key" "expected_value"
assert_github_output() {
	local key="$1"
	local expected="$2"

	local actual
	actual=$(get_github_output "$key")

	if [[ "$actual" != "$expected" ]]; then
		echo "# GitHub output '$key' mismatch" >&2
		echo "# Expected: $expected" >&2
		echo "# Actual:   $actual" >&2
		return 1
	fi
}

# Assert that a GitHub output contains a value
# Usage: assert_github_output_contains "key" "partial_value"
assert_github_output_contains() {
	local key="$1"
	local expected="$2"

	local actual
	actual=$(get_github_output "$key")

	if [[ "$actual" != *"$expected"* ]]; then
		echo "# GitHub output '$key' does not contain expected value" >&2
		echo "# Expected to contain: $expected" >&2
		echo "# Actual: $actual" >&2
		return 1
	fi
}

# Assert that a GitHub env var was set
# Usage: assert_github_env "key" "expected_value"
assert_github_env() {
	local key="$1"
	local expected="$2"

	local actual
	actual=$(get_github_env "$key")

	if [[ "$actual" != "$expected" ]]; then
		echo "# GitHub env '$key' mismatch" >&2
		echo "# Expected: $expected" >&2
		echo "# Actual:   $actual" >&2
		return 1
	fi
}

# Assert that a path was added to GITHUB_PATH
# Usage: assert_github_path_contains "/some/path"
assert_github_path_contains() {
	local expected="$1"

	if ! grep -qF "$expected" "$GITHUB_PATH" 2>/dev/null; then
		echo "# GITHUB_PATH does not contain: $expected" >&2
		echo "# Actual contents:" >&2
		cat "$GITHUB_PATH" >&2
		return 1
	fi
}

# =============================================================================
# Pull request environment simulation
# =============================================================================

# Setup environment for pull request event
# Usage: setup_github_pr_env "feature-branch" "main" "123"
setup_github_pr_env() {
	local head_ref="${1:-feature-branch}"
	local base_ref="${2:-main}"
	local pr_number="${3:-123}"

	export GITHUB_EVENT_NAME="pull_request"
	export GITHUB_HEAD_REF="$head_ref"
	export GITHUB_BASE_REF="$base_ref"
	export GITHUB_REF="refs/pull/${pr_number}/merge"
	export GITHUB_REF_NAME="${pr_number}/merge"
}

# Setup environment for workflow_dispatch event
# Usage: setup_github_dispatch_env
setup_github_dispatch_env() {
	export GITHUB_EVENT_NAME="workflow_dispatch"
	export GITHUB_REF="refs/heads/main"
	export GITHUB_REF_NAME="main"
}

# Setup environment for release event
# Usage: setup_github_release_env "v1.0.0"
setup_github_release_env() {
	local tag="${1:-v1.0.0}"

	export GITHUB_EVENT_NAME="release"
	export GITHUB_REF="refs/tags/${tag}"
	export GITHUB_REF_NAME="$tag"
	export GITHUB_REF_TYPE="tag"
}
