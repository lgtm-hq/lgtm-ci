#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/update-floating-tag.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	setup_mock_git_repo
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

# Create an annotated release tag in the mock repo
# Usage: create_release_tag "v1.2.3"
create_release_tag() {
	local tag="$1"
	git -C "$MOCK_GIT_REPO" tag -a "$tag" -m "Release $tag"
}

run_update_floating_tag() {
	local tag="$1"
	(
		cd "$MOCK_GIT_REPO" || exit 1
		env TAG="$tag" PUSH=false \
			bash "${PROJECT_ROOT}/scripts/ci/release/update-floating-tag.sh"
	)
}

# Add a bare origin remote to the mock repo
# Usage: setup_bare_remote
setup_bare_remote() {
	BARE_REMOTE="${BATS_TEST_TMPDIR}/remote.git"
	git init -q --bare "$BARE_REMOTE"
	git -C "$MOCK_GIT_REPO" remote add origin "$BARE_REMOTE"
}

run_update_floating_tag_push() {
	local tag="$1"
	shift
	(
		cd "$MOCK_GIT_REPO" || exit 1
		env TAG="$tag" PUSH=true PUSH_RETRY_DELAY=0 "$@" \
			bash "${PROJECT_ROOT}/scripts/ci/release/update-floating-tag.sh"
	)
}

# Install a pre-receive hook on the bare remote that rejects the first
# N pushes, then accepts (simulates transient GitHub ref-update errors)
# Usage: fail_remote_pushes <count>
fail_remote_pushes() {
	local count="$1"
	local counter_file="${BATS_TEST_TMPDIR}/push-failures"
	echo 0 >"$counter_file"
	cat >"${BARE_REMOTE}/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
n=\$(cat "$counter_file")
if [ "\$n" -lt "$count" ]; then
	echo \$((n + 1)) >"$counter_file"
	echo "fatal error in commit_refs" >&2
	exit 1
fi
exit 0
EOF
	chmod +x "${BARE_REMOTE}/hooks/pre-receive"
}

@test "update-floating-tag: creates floating tag for release" {
	create_release_tag "v1.2.3"

	run run_update_floating_tag "v1.2.3"

	assert_success
	assert_output --partial "floating-tag=v1"
	assert_output --partial "source-tag=v1.2.3"
	git -C "$MOCK_GIT_REPO" rev-parse --verify refs/tags/v1
}

@test "update-floating-tag: floating tag is annotated" {
	create_release_tag "v1.2.3"

	run run_update_floating_tag "v1.2.3"
	assert_success

	run git -C "$MOCK_GIT_REPO" cat-file -t refs/tags/v1
	assert_success
	assert_output "tag"
}

@test "update-floating-tag: floating tag points at commit, not nested tag" {
	create_release_tag "v1.2.3"

	run run_update_floating_tag "v1.2.3"
	assert_success

	# The immediate target of the annotated floating tag must be a commit,
	# not the release tag object (regression test for nested tags, #373)
	run bash -c "git -C '$MOCK_GIT_REPO' cat-file tag refs/tags/v1 | grep '^type '"
	assert_success
	assert_output "type commit"

	local target_type
	target_type=$(git -C "$MOCK_GIT_REPO" cat-file -t "$(git -C "$MOCK_GIT_REPO" rev-parse 'v1^{}')")
	assert_equal "commit" "$target_type"
}

@test "update-floating-tag: floating tag dereferences to release commit" {
	create_release_tag "v1.2.3"

	run run_update_floating_tag "v1.2.3"
	assert_success

	local floating_commit release_commit
	floating_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1^{}')
	release_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1.2.3^{}')
	assert_equal "$release_commit" "$floating_commit"
}

@test "update-floating-tag: force-updates existing floating tag to new release" {
	create_release_tag "v1.2.3"
	run run_update_floating_tag "v1.2.3"
	assert_success

	# New commit and new release tag
	(
		cd "$MOCK_GIT_REPO" || exit 1
		echo "update" >>README.md
		git add README.md
		git commit -q -m "feat: another change"
	)
	create_release_tag "v1.3.0"

	run run_update_floating_tag "v1.3.0"
	assert_success

	local floating_commit release_commit
	floating_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1^{}')
	release_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1.3.0^{}')
	assert_equal "$release_commit" "$floating_commit"

	run bash -c "git -C '$MOCK_GIT_REPO' cat-file tag refs/tags/v1 | grep '^type '"
	assert_success
	assert_output "type commit"
}

@test "update-floating-tag: fails on invalid semver tag" {
	run run_update_floating_tag "not-a-version"

	assert_failure
	assert_output --partial "Invalid semver tag"
}

@test "update-floating-tag: pushes floating tag to origin" {
	setup_bare_remote
	create_release_tag "v1.2.3"

	run run_update_floating_tag_push "v1.2.3"

	assert_success
	assert_output --partial "Pushed floating tag: v1"

	local remote_commit release_commit
	remote_commit=$(git -C "$BARE_REMOTE" rev-parse 'v1^{}')
	release_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1.2.3^{}')
	assert_equal "$release_commit" "$remote_commit"
}

@test "update-floating-tag: skips push when remote floating tag already current (rerun)" {
	setup_bare_remote
	create_release_tag "v1.2.3"

	run run_update_floating_tag_push "v1.2.3"
	assert_success

	run run_update_floating_tag_push "v1.2.3"
	assert_success
	assert_output --partial "skipping push"
}

@test "update-floating-tag: retries transient push failure then succeeds" {
	setup_bare_remote
	create_release_tag "v1.2.3"
	fail_remote_pushes 2

	run run_update_floating_tag_push "v1.2.3"

	assert_success
	assert_output --partial "retrying"
	assert_output --partial "Pushed floating tag: v1"

	local remote_commit release_commit
	remote_commit=$(git -C "$BARE_REMOTE" rev-parse 'v1^{}')
	release_commit=$(git -C "$MOCK_GIT_REPO" rev-parse 'v1.2.3^{}')
	assert_equal "$release_commit" "$remote_commit"
}

@test "update-floating-tag: fails after exhausting push attempts" {
	setup_bare_remote
	create_release_tag "v1.2.3"
	fail_remote_pushes 99

	run run_update_floating_tag_push "v1.2.3" PUSH_MAX_ATTEMPTS=3

	assert_failure
	assert_output --partial "after 3 attempts"
}

@test "update-floating-tag: writes GitHub Actions outputs" {
	create_release_tag "v2.0.0"

	run run_update_floating_tag "v2.0.0"

	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "floating-tag=v2"
	assert_file_contains "$GITHUB_OUTPUT" "source-tag=v2.0.0"
}
