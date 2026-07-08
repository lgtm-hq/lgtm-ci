#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/delete-run-pages-artifacts.sh (#415)

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/delete-run-pages-artifacts.sh"
	export GITHUB_REPOSITORY="lgtm-hq/py-lintro"
	export GITHUB_RUN_ID="123456789"
	export GH_TOKEN="test-token"
	export ARTIFACT_NAME="github-pages"
	export DELETE_CALLS="${BATS_TEST_TMPDIR}/delete_calls"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Mock gh: list run artifacts from the supplied JSON, record DELETE calls, and
# exit DELETE with the given code (default 0).
_mock_gh() {
	local artifacts_json="$1"
	local delete_exit="${2:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local artifacts_file="${mock_bin}/.artifacts.json"
	printf '%s' "$artifacts_json" >"$artifacts_file"
	: >"$DELETE_CALLS"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*--method\ DELETE*)
		echo "\$*" >> '${DELETE_CALLS}'
		exit ${delete_exit}
		;;
	*runs/*/artifacts*)
		cat '${artifacts_file}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

_artifacts() {
	# Build a {"artifacts":[...]} payload from name:id pairs.
	local entries=()
	local pair name id
	for pair in "$@"; do
		name="${pair%%:*}"
		id="${pair##*:}"
		entries+=("{\"id\": ${id}, \"name\": \"${name}\"}")
	done
	local joined
	joined="$(
		IFS=,
		echo "${entries[*]}"
	)"
	printf '{"total_count": %d, "artifacts": [%s]}' "$#" "$joined"
}

# =============================================================================
# Required env var validation
# =============================================================================

@test "delete-run-pages-artifacts: fails when GITHUB_REPOSITORY is unset" {
	_mock_gh "$(_artifacts)"
	run bash -c 'unset GITHUB_REPOSITORY; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "GITHUB_REPOSITORY is required"
}

@test "delete-run-pages-artifacts: fails when GITHUB_RUN_ID is unset" {
	_mock_gh "$(_artifacts)"
	run bash -c 'unset GITHUB_RUN_ID; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "GITHUB_RUN_ID is required"
}

# =============================================================================
# Zero pre-existing artifacts
# =============================================================================

@test "delete-run-pages-artifacts: no artifacts on run is a no-op success" {
	_mock_gh "$(_artifacts)"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "nothing to delete"
	[ ! -s "$DELETE_CALLS" ]
}

@test "delete-run-pages-artifacts: ignores artifacts with a different name" {
	_mock_gh "$(_artifacts "python-coverage:11" "sbom:22")"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "nothing to delete"
	[ ! -s "$DELETE_CALLS" ]
}

# =============================================================================
# One pre-existing artifact
# =============================================================================

@test "delete-run-pages-artifacts: deletes the single matching artifact" {
	_mock_gh "$(_artifacts "github-pages:42")"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Deleted stale 'github-pages' artifact 42"
	assert_output --partial "1 deleted, 0 failed"
	run grep -c -- "artifacts/42" "$DELETE_CALLS"
	assert_output "1"
}

@test "delete-run-pages-artifacts: leaves differently named artifacts untouched" {
	_mock_gh "$(_artifacts "github-pages:42" "python-coverage:11")"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "artifacts/42" "$DELETE_CALLS"
	assert_output "1"
	run grep -c -- "artifacts/11" "$DELETE_CALLS"
	assert_output "0"
}

# =============================================================================
# Multiple pre-existing artifacts
# =============================================================================

@test "delete-run-pages-artifacts: deletes every matching artifact on the run" {
	_mock_gh "$(_artifacts "github-pages:1" "github-pages:2" "github-pages:3")"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "3 deleted, 0 failed"
	local id
	for id in 1 2 3; do
		run grep -c -- "artifacts/${id}" "$DELETE_CALLS"
		assert_output "1"
	done
}

# =============================================================================
# Custom artifact name
# =============================================================================

@test "delete-run-pages-artifacts: honors a custom ARTIFACT_NAME" {
	export ARTIFACT_NAME="site"
	_mock_gh "$(_artifacts "github-pages:9" "site:7")"
	run bash "$SCRIPT"
	assert_success
	run grep -c -- "artifacts/7" "$DELETE_CALLS"
	assert_output "1"
	run grep -c -- "artifacts/9" "$DELETE_CALLS"
	assert_output "0"
}

# =============================================================================
# Dry run
# =============================================================================

@test "delete-run-pages-artifacts: DRY_RUN logs without deleting" {
	export DRY_RUN="true"
	_mock_gh "$(_artifacts "github-pages:42")"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "[dry-run] Would delete stale 'github-pages' artifact 42"
	[ ! -s "$DELETE_CALLS" ]
}

# =============================================================================
# Deletion failure
# =============================================================================

@test "delete-run-pages-artifacts: fails loudly when a delete call errors" {
	_mock_gh "$(_artifacts "github-pages:42")" 1
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Failed to delete"
}
