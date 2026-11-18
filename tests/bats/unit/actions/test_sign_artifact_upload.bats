#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for the release upload in
#          scripts/ci/actions/sign-artifact.sh (STEP=upload-release): the
#          repository input must be OWNER/REPO, never HOST/OWNER/REPO, because
#          gh would send its token to the host a host part names (#1624).

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/sign-artifact.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export STEP="upload-release"
	export RELEASE_TAG="v1.2.3"
	export SIGNATURES_DIR="${BATS_TEST_TMPDIR}/signatures"
	mkdir -p "$SIGNATURES_DIR"
	printf 'sig\n' >"${SIGNATURES_DIR}/one.tar.gz.sig"
	printf 'pem\n' >"${SIGNATURES_DIR}/one.tar.gz.pem"
	mock_gh
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Replace gh with a stub that records its arguments, one per line, and the
# GH_REPO it sees, so the test can tell which repository gh was pointed at.
mock_gh() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export GH_CALLS
	: >"$GH_CALLS"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'GH_REPO=%s\n' "${GH_REPO:-}" >>"$GH_CALLS"
printf 'arg=%s\n' "$@" >>"$GH_CALLS"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

@test "sign-artifact upload: an OWNER/REPO repository reaches gh" {
	run env -u GH_REPO SIGN_REPOSITORY="my-org/my.repo_1" bash "$SCRIPT"
	assert_success
	run cat "$GH_CALLS"
	assert_line "arg=release"
	assert_line "arg=upload"
	assert_line "arg=v1.2.3"
	assert_line "arg=--repo"
	assert_line "arg=my-org/my.repo_1"
	assert_line "arg=--clobber"
	assert_line "arg=${SIGNATURES_DIR}/one.tar.gz.sig"
	assert_line "arg=${SIGNATURES_DIR}/one.tar.gz.pem"
}

@test "sign-artifact upload: a host-qualified repository is refused before gh runs" {
	run env -u GH_REPO SIGN_REPOSITORY="host.example/owner/repo" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::"
	assert_output --partial "repository input"
	assert_output --partial "host.example/owner/repo"
	run cat "$GH_CALLS"
	refute_output
}

@test "sign-artifact upload: another shape of repository is refused" {
	local value
	for value in "owner" "-owner/repo" "owner/repo/extra" "owner/re po" \
		'owner/$(id)' "https://host.example/owner/repo"; do
		run env -u GH_REPO SIGN_REPOSITORY="$value" bash "$SCRIPT"
		assert_failure
		assert_output --partial "::error::"
		assert_output --partial "repository input"
	done
	run cat "$GH_CALLS"
	refute_output
}

@test "sign-artifact upload: an empty repository is refused" {
	run env -u GH_REPO SIGN_REPOSITORY="" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::"
	assert_output --partial "repository input"
	run env -u GH_REPO -u SIGN_REPOSITORY bash "$SCRIPT"
	assert_failure
	assert_output --partial "repository input"
	run cat "$GH_CALLS"
	refute_output
}

@test "sign-artifact upload: an inherited GH_REPO does not choose the repository" {
	run env GH_REPO="host.example/other/repo" SIGN_REPOSITORY="owner/repo" \
		bash "$SCRIPT"
	assert_success
	run cat "$GH_CALLS"
	assert_line "arg=--repo"
	assert_line "arg=owner/repo"
}
