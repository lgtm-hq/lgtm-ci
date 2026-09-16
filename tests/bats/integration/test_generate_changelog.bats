#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for the default changelog range of
#          generate-changelog.sh, create-tag.sh and create-github-release.sh

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
# Helper
# =============================================================================

# Run generate-changelog.sh in the mock git repo with FROM_REF unset
# Usage: run_generate_changelog [VERSION]
run_generate_changelog() {
	local version="${1:-}"
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export FROM_REF=
		export TO_REF=HEAD
		export VERSION='$version'
		export FORMAT=simple
		'$PROJECT_ROOT/scripts/ci/release/generate-changelog.sh' 2>&1
	"
}

# =============================================================================
# Default FROM_REF
# =============================================================================

@test "generate-changelog: ranges from the latest stable tag, not a nearer checkpoint prerelease" {
	# calculate-version.sh already bumps from the stable tag (#1000); the
	# changelog must cover the same range, or the version PR summarises only
	# the commits since the last checkpoint and drops the rest (#1012).
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: shipped in the last stable"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: before the checkpoint"
		git commit -q --allow-empty -m "ci(release): checkpoint prerelease 0.1.1a4"
		git tag "v0.1.1a4"
		git tag "v0.1.1rc1"
		git commit -q --allow-empty -m "fix: after the checkpoint"
	)

	run_generate_changelog "0.2.0"
	assert_success
	assert_line --partial "from 'v0.1.0' to 'HEAD'"
	assert_output --partial "before the checkpoint"
	assert_output --partial "after the checkpoint"
	refute_output --partial "shipped in the last stable"
}

@test "generate-changelog: with no stable tag the range starts at the beginning" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: only ever a checkpoint"
		git tag "v0.1.0rc1"
	)

	run_generate_changelog
	assert_success
	assert_line --partial "from 'beginning' to 'HEAD'"
	assert_output --partial "only ever a checkpoint"
}

@test "generate-changelog: an explicit FROM_REF is used as given" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: old"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: newer"
		git tag "v0.2.0"
		git commit -q --allow-empty -m "fix: newest"
	)

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export FROM_REF=v0.1.0
		export FORMAT=simple
		'$PROJECT_ROOT/scripts/ci/release/generate-changelog.sh' 2>&1
	"
	assert_success
	assert_line --partial "from 'v0.1.0' to 'HEAD'"
	assert_output --partial "newer"
	assert_output --partial "newest"
}

@test "generate-changelog: honours a non-default TAG_PREFIX for the default range" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: shipped in the last stable"
		git tag "release-0.1.0"
		git commit -q --allow-empty -m "feat: since the stable"
		git tag "release-0.1.1rc1"
		git commit -q --allow-empty -m "fix: after the checkpoint"
	)

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export FROM_REF=
		export TAG_PREFIX=release-
		export FORMAT=simple
		'$PROJECT_ROOT/scripts/ci/release/generate-changelog.sh' 2>&1
	"
	assert_success
	assert_line --partial "from 'release-0.1.0' to 'HEAD'"
	assert_output --partial "since the stable"
	refute_output --partial "shipped in the last stable"
}

# =============================================================================
# The same default range in create-tag.sh and create-github-release.sh
# =============================================================================

@test "create-tag: the annotated tag message ranges from the latest stable tag, skipping a checkpoint" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: shipped in the last stable"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: before the checkpoint"
		git tag "v0.1.1rc1"
		git commit -q --allow-empty -m "fix: after the checkpoint"
	)

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export VERSION=0.2.0
		export PUSH=false
		'$PROJECT_ROOT/scripts/ci/release/create-tag.sh' 2>&1
	"
	assert_success
	run git -C "$MOCK_GIT_REPO" for-each-ref refs/tags/v0.2.0 --format='%(contents)'
	assert_success
	assert_output --partial "before the checkpoint"
	assert_output --partial "after the checkpoint"
	refute_output --partial "shipped in the last stable"
}

@test "create-github-release: generated notes range from the latest stable tag below the release" {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO"
		git commit -q --allow-empty -m "feat: shipped in the last stable"
		git tag "v0.1.0"
		git commit -q --allow-empty -m "feat: before the checkpoint"
		git tag "v0.1.1rc1"
		git commit -q --allow-empty -m "fix: after the checkpoint"
		git tag "v0.2.0"
	)
	# No existing release; capture the create call's arguments.
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
"release view "*) exit 1 ;;
"release create "*)
	printf '%s\\n' "\$*" >'${BATS_TEST_TMPDIR}/gh-create.args'
	echo 'https://github.com/test/repo/releases/tag/v0.2.0'
	;;
*) exit 0 ;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:${PATH}"

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_OUTPUT='$GITHUB_OUTPUT'
		export TAG=v0.2.0
		export REPO=test/repo
		'$PROJECT_ROOT/scripts/ci/release/create-github-release.sh' 2>&1
	"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/gh-create.args"
	assert_success
	assert_output --partial "before the checkpoint"
	assert_output --partial "after the checkpoint"
	refute_output --partial "shipped in the last stable"
}
