#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for the ghcr-prune-tags maintenance script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/ghcr-prune-tags.sh"

# Fixed timestamps relative to the default retention windows (30d / 90d).
# "AGED" predates both cutoffs by years; "RECENT" is computed at runtime so it
# is always inside both windows.
AGED="2020-01-01T00:00:00Z"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
	export AGED

	RECENT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	export RECENT

	export PACKAGE_NAME="test-package"
	export GITHUB_ORG="test-org"
	export GH_TOKEN="test-token"
	export DRY_RUN="false"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Mock gh: serve a versions payload and record every DELETE call.
mock_gh_versions() {
	local versions_json="$1"
	local delete_exit="${2:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local versions_file="${mock_bin}/.gh_versions"
	printf '%s' "$versions_json" >"$versions_file"

	DELETE_LOG="${mock_bin}/.gh_deletes"
	export DELETE_LOG
	: >"$DELETE_LOG"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*--method\ DELETE*) printf '%s\n' "\$*" >>'$DELETE_LOG'; exit $delete_exit;;
	*packages/container*) cat '$versions_file';;
	*) exit 1;;
esac
EOF
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

deleted_ids() {
	grep -o '/versions/[0-9]*' "$DELETE_LOG" 2>/dev/null | sed 's|/versions/||' | sort -u
}

# =============================================================================
# Required env var validation
# =============================================================================

@test "ghcr-prune-tags: fails when PACKAGE_NAME is not set" {
	run bash -c 'unset PACKAGE_NAME; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "PACKAGE_NAME is required"
}

@test "ghcr-prune-tags: fails when GITHUB_ORG is not set" {
	run bash -c 'unset GITHUB_ORG; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "GITHUB_ORG is required"
}

@test "ghcr-prune-tags: rejects a non-numeric MAIN_RETENTION_DAYS" {
	export MAIN_RETENTION_DAYS="thirty"
	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "MAIN_RETENTION_DAYS must be a non-negative integer"
}

@test "ghcr-prune-tags: rejects a non-numeric PRERELEASE_RETENTION_DAYS" {
	export PRERELEASE_RETENTION_DAYS="ninety"
	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "PRERELEASE_RETENTION_DAYS must be a non-negative integer"
}

# =============================================================================
# THE RULE THAT MUST NOT BE INVERTED
# =============================================================================

@test "ghcr-prune-tags: ALL tags must agree - release manifest survives its aged sha- tag" {
	# One manifest, three tags: latest + semver + sha-<commit>, all long past
	# the main cutoff. Invert the rule to "delete if ANY tag is deletable" and
	# this release image disappears while :latest still points at it.
	#
	# If this test needs "fixing", the policy has been inverted. Fix the
	# policy, not the test.
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"latest\", \"1.2.3\", \"sha-abc1234\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-def5678\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	# Only the lone aged sha- version is deleted; the release manifest stays.
	run deleted_ids
	assert_output "2"
}

# =============================================================================
# Retention classes end to end
# =============================================================================

@test "ghcr-prune-tags: deletes a lone aged sha- version" {
	mock_gh_versions "[
		{\"id\": 7, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "Deleted version 7"

	run deleted_ids
	assert_output "7"
}

@test "ghcr-prune-tags: deletes an aged main+sha- manifest" {
	mock_gh_versions "[
		{\"id\": 8, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"main\", \"sha-abc1234\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	run deleted_ids
	assert_output "8"
}

@test "ghcr-prune-tags: retains latest, semver and unrecognised tags however old" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"latest\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1\"]}}},
		{\"id\": 3, \"name\": \"sha256:ccc\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2\"]}}},
		{\"id\": 4, \"name\": \"sha256:ddd\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2.3\"]}}},
		{\"id\": 5, \"name\": \"sha256:eee\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"custom-channel\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "0 deleted, 5 retained"

	run deleted_ids
	assert_output ""
}

@test "ghcr-prune-tags: retains recent main and sha- versions" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$RECENT\",
		 \"metadata\": {\"container\": {\"tags\": [\"main\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$RECENT\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	run deleted_ids
	assert_output ""
}

@test "ghcr-prune-tags: prerelease shapes past retention are deleted" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2.3-alpha.1\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"2.0.0-beta\"]}}},
		{\"id\": 3, \"name\": \"sha256:ccc\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2.3-rc1\"]}}},
		{\"id\": 4, \"name\": \"sha256:ddd\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.0.0-pre.2\"]}}},
		{\"id\": 5, \"name\": \"sha256:eee\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"dev\"]}}},
		{\"id\": 6, \"name\": \"sha256:fff\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"3.1.0-snapshot\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "6 deleted, 0 retained"

	# Every one of the six pre-release shapes must be deleted, not just some.
	run deleted_ids
	assert_output "1
2
3
4
5
6"
}

@test "ghcr-prune-tags: prerelease shapes within retention are retained" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$RECENT\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2.3-rc1\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$RECENT\",
		 \"metadata\": {\"container\": {\"tags\": [\"2.0.0-beta\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	run deleted_ids
	assert_output ""
}

@test "ghcr-prune-tags: prerelease keeps its longer window than main" {
	# 60 days old: past the 30d main window, inside the 90d prerelease window.
	local sixty_days_ago
	sixty_days_ago=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -v-60d +%Y-%m-%dT%H:%M:%SZ)

	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$sixty_days_ago\",
		 \"metadata\": {\"container\": {\"tags\": [\"1.2.3-rc1\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$sixty_days_ago\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	run deleted_ids
	assert_output "2"
}

# =============================================================================
# Untagged versions are out of scope
# =============================================================================

@test "ghcr-prune-tags: never touches untagged versions" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": []}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "No tagged versions to prune"

	run deleted_ids
	assert_output ""
}

# =============================================================================
# Dry run
# =============================================================================

@test "ghcr-prune-tags: dry run logs every candidate and deletes nothing" {
	export DRY_RUN="true"
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}},
		{\"id\": 2, \"name\": \"sha256:bbb\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"main\", \"sha-def5678\"]}}},
		{\"id\": 3, \"name\": \"sha256:ccc\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"latest\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "[dry-run] Would delete version 1"
	assert_output --partial "[dry-run] Would delete version 2"
	assert_output --partial "Dry run complete: 2 version(s) would be deleted, 1 retained"

	run deleted_ids
	assert_output ""
}

@test "ghcr-prune-tags: defaults to dry run when DRY_RUN is unset" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]"

	run bash -c 'unset DRY_RUN; bash "$SCRIPT" 2>&1'
	assert_success
	assert_output --partial "[dry-run]"

	run deleted_ids
	assert_output ""
}

# =============================================================================
# Failure handling and summary
# =============================================================================

@test "ghcr-prune-tags: reports failure when deletion fails" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]" 1

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "Failed to delete version 1"
}

@test "ghcr-prune-tags: writes a step summary" {
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$AGED\",
		 \"metadata\": {\"container\": {\"tags\": [\"latest\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	local summary
	summary=$(cat "$GITHUB_STEP_SUMMARY")
	[[ "$summary" == *"GHCR Tagged Retention"* ]]
	[[ "$summary" == *"test-org/test-package"* ]]
	[[ "$summary" == *"Retained | 1"* ]]
}

@test "ghcr-prune-tags: honours custom retention windows" {
	local ten_days_ago
	ten_days_ago=$(date -u -d "10 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)

	export MAIN_RETENTION_DAYS="5"
	mock_gh_versions "[
		{\"id\": 1, \"name\": \"sha256:aaa\", \"updated_at\": \"$ten_days_ago\",
		 \"metadata\": {\"container\": {\"tags\": [\"sha-abc1234\"]}}}
	]"

	run bash -c 'bash "$SCRIPT" 2>&1'
	assert_success

	run deleted_ids
	assert_output "1"
}
