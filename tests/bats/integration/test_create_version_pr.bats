#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/create-version-pr.sh

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Helpers
# =============================================================================

# Create a mock repo with CHANGELOG.md and conventional commits
setup_release_repo() {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1

		# Create a CHANGELOG.md
		cat >CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD
EOF
		git add CHANGELOG.md
		git commit -q -m "docs: add changelog"

		# Add a remote (mock: points to local bare repo)
		local bare_dir="${BATS_TEST_TMPDIR}/bare.git"
		git init -q --bare "$bare_dir"
		git remote add origin "$bare_dir"
		git push -q origin HEAD:main 2>/dev/null
	)
}

run_create_version_pr() {
	local max_bump="${1:-major}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export GITHUB_STEP_SUMMARY='$GITHUB_STEP_SUMMARY'
		export GITHUB_ACTIONS='true'
		export GITHUB_REF_NAME='main'
		export MAX_BUMP='$max_bump'
		export TAG_PREFIX='v'
		export PR_LABELS='release'
		export GH_TOKEN='fake-token'
		export PATH='$PATH'
		'$PROJECT_ROOT/scripts/ci/release/create-version-pr.sh' 2>&1
	"
}

# =============================================================================
# Tests
# =============================================================================

@test "create-version-pr: exits cleanly when no releasable commits" {
	setup_release_repo

	# Only non-releasable commits (docs: is not releasable by default)
	run_create_version_pr
	assert_success
	assert_line --partial "pr-created=false"
}

@test "create-version-pr: creates branch and commits with correct message" {
	setup_release_repo
	add_commit "feat: add new feature"

	# Mock gh to capture the PR creation call
	mock_command_record "gh" "https://github.com/test-org/test-repo/pull/1"

	run_create_version_pr "minor"
	assert_success

	# Verify the branch was created and the commit message is correct
	(
		cd "$MOCK_GIT_REPO" || exit 1
		local last_msg
		last_msg=$(git log -1 --format='%s' release/v0.1.0 2>/dev/null)
		[[ "$last_msg" == "chore(release): version 0.1.0" ]]
	)
}

@test "create-version-pr: calls gh pr create with correct title" {
	setup_release_repo
	add_commit "feat: add new feature"

	mock_command_record "gh" "https://github.com/test-org/test-repo/pull/1"

	run_create_version_pr "minor"
	assert_success

	# Verify gh was called with the right arguments
	local gh_calls
	gh_calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_gh")
	[[ "$gh_calls" == *"chore(release): version 0.1.0"* ]]
}

@test "create-version-pr: updates CHANGELOG.md with version section" {
	setup_release_repo
	add_commit "feat: add new feature"

	mock_command_record "gh" "https://github.com/test-org/test-repo/pull/1"

	run_create_version_pr "minor"
	assert_success

	# Verify CHANGELOG.md was updated
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git checkout release/v0.1.0 2>/dev/null
		grep -q '\[0\.1\.0\]' CHANGELOG.md
	)
}

@test "create-version-pr: outputs version and branch" {
	setup_release_repo
	add_commit "feat: add new feature"

	mock_command_record "gh" "https://github.com/test-org/test-repo/pull/1"

	run_create_version_pr "minor"
	assert_success
	assert_line --partial "pr-created=true"
	assert_line --partial "version=0.1.0"
	assert_line --partial "branch=release/v0.1.0"
}

@test "create-version-pr: respects max-bump clamping" {
	setup_release_repo
	add_commit "feat!: breaking change"

	mock_command_record "gh" "https://github.com/test-org/test-repo/pull/1"

	# Clamp to minor (so 0.0.0 -> 0.1.0 instead of 1.0.0)
	run_create_version_pr "minor"
	assert_success
	assert_line --partial "version=0.1.0"
}
