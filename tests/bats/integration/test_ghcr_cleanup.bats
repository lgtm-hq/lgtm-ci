#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for ghcr-cleanup action script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/ghcr-cleanup.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT

	# Common env vars
	export PACKAGE_NAME="test-package"
	export GITHUB_ORG="test-org"
	export MIN_AGE_DAYS="7"
	export KEEP_LATEST="2"
	export DRY_RUN="false"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Helper: create a mock gh that returns version data
mock_gh_versions() {
	local versions_json="$1"
	local delete_exit="${2:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	# Write versions JSON to a file for the mock
	local versions_file="${mock_bin}/.gh_versions"
	printf '%s' "$versions_json" >"$versions_file"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*--method\ DELETE*) exit $delete_exit;;
	*packages/container*) cat '$versions_file';;
	*) exit 1;;
esac
EOF
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# =============================================================================
# Required env var validation
# =============================================================================

@test "ghcr-cleanup: fails when PACKAGE_NAME is not set" {
	run bash -c 'unset PACKAGE_NAME; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "PACKAGE_NAME is required"
}

@test "ghcr-cleanup: fails when GITHUB_ORG is not set" {
	run bash -c 'unset GITHUB_ORG; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "GITHUB_ORG is required"
}

# =============================================================================
# No versions to delete
# =============================================================================

@test "ghcr-cleanup: exits cleanly when no untagged versions exist" {
	# All versions have tags
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": ["latest"]}}}
	]'

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "nothing to delete"
}

@test "ghcr-cleanup: exits cleanly when all untagged are within keep-latest" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-02T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]'

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "nothing to delete"
}

# =============================================================================
# Dry run mode
# =============================================================================

@test "ghcr-cleanup: dry run logs what would be deleted without deleting" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-02T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 3, "name": "sha256:ccc", "updated_at": "2020-01-03T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 4, "name": "sha256:ddd", "updated_at": "2020-01-04T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]'

	export DRY_RUN="true"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "dry-run"
	assert_output --partial "Dry run complete"
}

# =============================================================================
# Actual deletion
# =============================================================================

@test "ghcr-cleanup: deletes eligible versions respecting keep-latest" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-02T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 3, "name": "sha256:ccc", "updated_at": "2020-01-03T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 4, "name": "sha256:ddd", "updated_at": "2020-01-04T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]'

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "Deleted"
	assert_output --partial "Cleanup complete"
}

# =============================================================================
# Deletion failure handling
# =============================================================================

@test "ghcr-cleanup: reports failure when deletion fails" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-02T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 3, "name": "sha256:ccc", "updated_at": "2020-01-03T00:00:00Z", "metadata": {"container": {"tags": []}}},
		{"id": 4, "name": "sha256:ddd", "updated_at": "2020-01-04T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]' 1

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "Failed to delete"
}

# =============================================================================
# Summary output
# =============================================================================

@test "ghcr-cleanup: generates step summary" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": ["latest"]}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-02T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]'

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	# Check summary was written
	local summary
	summary=$(cat "$GITHUB_STEP_SUMMARY")
	[[ "$summary" == *"GHCR Cleanup"* ]]
	[[ "$summary" == *"test-org/test-package"* ]]
}

# =============================================================================
# Tagged versions are preserved
# =============================================================================

@test "ghcr-cleanup: preserves tagged versions even if old" {
	mock_gh_versions '[
		{"id": 1, "name": "sha256:aaa", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": ["v1.0.0"]}}},
		{"id": 2, "name": "sha256:bbb", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": ["latest"]}}},
		{"id": 3, "name": "sha256:ccc", "updated_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}}
	]'

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	# Only 1 untagged, which is within keep-latest=2
	assert_output --partial "nothing to delete"
}
