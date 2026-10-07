#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/python-dist.sh preflight step

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
	export ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
	mkdir -p "$REPO_ROOT"
	cd "$REPO_ROOT" || return 1
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_write_pyproject() {
	local version="$1"
	sed "s|__VERSION__|${version}|g" \
		"${FIXTURES_DIR}/python/pyproject-version.toml" >pyproject.toml
}

_init_repo_on_main() {
	git init -b main
	git config user.email "test@example.com"
	git config user.name "Test User"
	git config tag.gpgSign false
	git config commit.gpgsign false
	_write_pyproject "$1"
	git add pyproject.toml
	git commit -m "init"
	git tag -m "test release" "v$1"
	git init --bare "$ORIGIN"
	git remote add origin "$ORIGIN"
	git push -u origin main
	git push origin "v$1"
}

_run_preflight() {
	local verify="${1:-true}"
	local ensure="${2:-true}"
	run env \
		STEP=preflight \
		WORKING_DIRECTORY=. \
		VERIFY_TAG_VERSION="$verify" \
		ENSURE_TAG_ON_DEFAULT_BRANCH="$ensure" \
		DEFAULT_BRANCH=main \
		GITHUB_REF_NAME="$GITHUB_REF_NAME" \
		GITHUB_REF="$GITHUB_REF" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
}

_run_build() {
	local working_directory="${1:-.}"
	run env \
		STEP=build \
		WORKING_DIRECTORY="$working_directory" \
		GITHUB_WORKSPACE="$REPO_ROOT" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
}

@test "python-dist preflight: passes when tag matches pyproject version on main" {
	_init_repo_on_main "1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"
	git remote set-url origin "https://github.invalid/private/repository.git"

	_run_preflight true true

	assert_success
	assert_output --partial "Tag version matches pyproject.toml"
	assert_output --partial "Tag commit is on main"
	# Full history: origin/main exists, so no fetch is attempted (#1031).
	refute_output --partial "fetching refs/heads/main"
}

# Mimic a default actions/checkout on a tag event: a fresh repository with the
# remote configured, only the tag fetched at depth 1, nothing under
# refs/remotes/origin/. The result is shallow and has no origin/<default>
# ref (second argument, default main).
_shallow_checkout_of_tag() {
	local tag="$1"
	local default_branch="${2:-main}"
	local dir="${BATS_TEST_TMPDIR}/shallow"
	mkdir -p "$dir"
	cd "$dir" || return 1
	git init -q
	git remote add origin "$ORIGIN"
	git fetch -q --no-tags --depth=1 origin "+refs/tags/${tag}:refs/tags/${tag}"
	git checkout -q --detach "$tag"
	[[ "$(git rev-parse --is-shallow-repository)" == "true" ]]
	! git show-ref --verify --quiet "refs/remotes/origin/${default_branch}"
}

@test "python-dist preflight: shallow checkout without origin/main fetches the default branch and passes" {
	_init_repo_on_main "1.2.3"
	# An extra tag on the remote that the preflight fetch must leave behind.
	git tag -m "other release" v0.0.1
	git push -q origin v0.0.1
	_shallow_checkout_of_tag "v1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"

	_run_preflight true true

	assert_success
	assert_output --partial "refs/remotes/origin/main is missing (shallow checkout); fetching refs/heads/main from origin"
	assert_output --partial "Tag commit is on main"
	# The fetch brought only the default branch: no tags, still shallow.
	run git show-ref --verify --quiet refs/remotes/origin/main
	assert_success
	run git show-ref --verify --quiet refs/tags/v0.0.1
	assert_failure
	run git rev-parse --is-shallow-repository
	assert_output "true"
}

@test "python-dist preflight: shallow checkout with a default-branch missing on the remote points at default-branch" {
	_init_repo_on_main "1.2.3"
	_shallow_checkout_of_tag "v1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"

	run env \
		STEP=preflight \
		WORKING_DIRECTORY=. \
		VERIFY_TAG_VERSION=false \
		ENSURE_TAG_ON_DEFAULT_BRANCH=true \
		DEFAULT_BRANCH=nope \
		GITHUB_REF_NAME="$GITHUB_REF_NAME" \
		GITHUB_REF="$GITHUB_REF" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_failure
	assert_output --partial "Could not fetch refs/heads/nope from origin"
	assert_output --partial "set default-branch"
}

@test "python-dist preflight: rejects a default-branch that is not a valid branch name" {
	_init_repo_on_main "1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"

	run env \
		STEP=preflight \
		WORKING_DIRECTORY=. \
		VERIFY_TAG_VERSION=false \
		ENSURE_TAG_ON_DEFAULT_BRANCH=true \
		DEFAULT_BRANCH='*' \
		GITHUB_REF_NAME="$GITHUB_REF_NAME" \
		GITHUB_REF="$GITHUB_REF" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_failure
	assert_output --partial "Invalid default-branch: *"
}

@test "python-dist preflight: shallow checkout passes when the default branch has advanced past the tag" {
	_init_repo_on_main "1.2.3"
	# A commit after the tag, so origin/main's tip is not the tag commit. A
	# --depth=1 fetch of main would hide the tag commit behind the shallow
	# boundary and wrongly report the tag as off-branch.
	echo "# after tag" >>README.md
	git add README.md
	git commit -q -m "after tag"
	git push -q origin main
	_shallow_checkout_of_tag "v1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"

	_run_preflight true true

	assert_success
	assert_output --partial "fetching refs/heads/main from origin"
	assert_output --partial "Tag commit is on main"
}

@test "python-dist preflight: shallow checkout still rejects a tag that is not on the default branch" {
	_init_repo_on_main "1.2.3"
	git checkout -q -b feature
	echo "# feature" >>README.md
	git add README.md
	git commit -q -m "feature work"
	git tag -m "feature release" v1.2.4
	git push -q origin feature
	git push -q origin v1.2.4
	_shallow_checkout_of_tag "v1.2.4"
	export GITHUB_REF_NAME="v1.2.4"
	export GITHUB_REF="refs/tags/v1.2.4"

	_run_preflight false true

	assert_failure
	assert_output --partial "fetching refs/heads/main from origin"
	assert_output --partial "Tag commit is not on main"
}

@test "python-dist preflight: refused fetch on a shallow checkout names both remedies" {
	_init_repo_on_main "1.2.3"
	_shallow_checkout_of_tag "v1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"
	# Stand-in for a remote that rejects an unauthenticated fetch: a remote
	# the checkout can no longer reach (as after persist-credentials: false).
	git remote set-url origin "${BATS_TEST_TMPDIR}/no-such-origin.git"

	_run_preflight true true

	assert_failure
	assert_output --partial "Could not fetch refs/heads/main from origin for the tag-on-default-branch check"
	assert_output --partial "persist-credentials: false"
	assert_output --partial "fetch-depth: 0"
	assert_output --partial "persist-credentials: true"
	refute_output --partial "Tag commit is on main"
}

@test "python-dist preflight: fails when tag version mismatches pyproject" {
	_init_repo_on_main "1.2.3"
	export GITHUB_REF_NAME="v9.9.9"
	export GITHUB_REF="refs/tags/v9.9.9"
	git tag -m "mismatch release" v9.9.9
	git push origin v9.9.9

	_run_preflight true false

	assert_failure
	assert_output --partial "Version mismatch: pyproject=1.2.3 tag=v9.9.9"
}

@test "python-dist preflight: fails when tag is not on default branch" {
	git init -b main
	git config user.email "test@example.com"
	git config user.name "Test User"
	git config tag.gpgSign false
	git config commit.gpgsign false
	_write_pyproject "2.0.0"
	git add pyproject.toml
	git commit -m "main init"

	git checkout -b feature
	echo "# feature" >>README.md
	git add README.md
	git commit -m "feature work"
	git tag -m "feature release" v2.0.0

	git init --bare "$ORIGIN"
	git remote add origin "$ORIGIN"
	git push origin main
	git push origin feature
	git push origin v2.0.0

	export GITHUB_REF_NAME="v2.0.0"
	export GITHUB_REF="refs/tags/v2.0.0"

	_run_preflight false true

	assert_failure
	assert_output --partial "Tag commit is not on main"
}

_run_validate() {
	run env \
		STEP=validate \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
}

@test "python-dist validate: accepts a PEP 440 prerelease version" {
	_write_pyproject "0.160.3a2"
	_run_validate
	assert_success
	assert_output --partial "Package metadata valid"
	assert_output --partial "@0.160.3a2"
}

@test "python-dist validate: accepts .post and .dev suffixes" {
	_write_pyproject "1.2.3rc1.post1.dev2"
	_run_validate
	assert_success
	assert_output --partial "@1.2.3rc1.post1.dev2"
}

@test "python-dist validate: rejects a SemVer hyphenated prerelease" {
	_write_pyproject "1.2.3-alpha.1"
	_run_validate
	assert_failure
	assert_output --partial "Invalid version format: 1.2.3-alpha.1"
	assert_output --partial "PEP 440"
}

@test "python-dist build: refuses filesystem root WORKING_DIRECTORY" {
	_init_repo_on_main "1.0.0"

	_run_build /

	assert_failure
	assert_output --partial "unsafe WORKING_DIRECTORY"
}

@test "python-dist build: refuses home WORKING_DIRECTORY" {
	_init_repo_on_main "1.0.0"

	_run_build '~'

	assert_failure
	assert_output --partial "unsafe WORKING_DIRECTORY"
}

@test "python-dist build: refuses parent directory outside repository root" {
	_init_repo_on_main "1.0.0"

	_run_build ..

	assert_failure
	assert_output --partial "outside repository root"
}

@test "python-dist extract-dist-metadata: reads name and version from wheel" {
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "1.2.3" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: reads name and version from sdist" {
	mkdir -p dist
	touch dist/example-4.5.6.tar.gz

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "4.5.6" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: reads hyphenated name from sdist" {
	mkdir -p dist
	touch dist/my-package-1.2.3.tar.gz

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "my-package" "$(get_github_output name)"
	assert_equal "1.2.3" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: prefers pyproject over wheel" {
	_write_pyproject "9.9.9"
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "9.9.9" "$(get_github_output version)"
}

@test "python-dist summary: uses PACKAGE_NAME and PACKAGE_VERSION env" {
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=summary \
		WORKING_DIRECTORY=. \
		PACKAGE_NAME=example \
		PACKAGE_VERSION=1.2.3 \
		PUBLISHED=true \
		TEST_PYPI=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"| Package | example |"* ]]
	[[ "$summary" == *"| Version | 1.2.3 |"* ]]
	[[ "$summary" == *"https://pypi.org/project/example/1.2.3/"* ]]
}

_make_dist() {
	mkdir -p dist
	printf 'wheel' >dist/pkg-1.0.0-py3-none-any.whl
	printf 'sdist' >dist/pkg-1.0.0.tar.gz
}

@test "python-dist write-checksums: lists every distribution file and not itself" {
	_make_dist
	STEP=write-checksums run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	[ -f dist/SHA256SUMS ]
	run cat dist/SHA256SUMS
	assert_output --partial "pkg-1.0.0-py3-none-any.whl"
	assert_output --partial "pkg-1.0.0.tar.gz"
	refute_output --partial "SHA256SUMS"
	run grep -c . dist/SHA256SUMS
	assert_output "2"
	run grep 'checksums-path=dist/SHA256SUMS' "$GITHUB_OUTPUT"
	assert_success
}

@test "python-dist write-checksums: the manifest verifies with sha256sum --check" {
	_make_dist
	STEP=write-checksums run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	if command -v sha256sum >/dev/null 2>&1; then
		run bash -c 'cd dist && sha256sum --check SHA256SUMS'
	else
		run bash -c 'cd dist && shasum -a 256 --check SHA256SUMS'
	fi
	assert_success
}

@test "python-dist write-checksums: fails when dist/ has no distribution files" {
	mkdir -p dist
	STEP=write-checksums run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_failure
	assert_output --partial "No distribution files"
}

@test "python-dist stage-sidecars: moves SHA256SUMS out of dist/ and reports its path" {
	_make_dist
	printf 'abc  pkg-1.0.0.tar.gz\n' >dist/SHA256SUMS
	STEP=stage-sidecars run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	[ -f .lgtm-ci-sidecars/SHA256SUMS ]
	[ ! -e dist/SHA256SUMS ]
	run grep 'checksums-path=.lgtm-ci-sidecars/SHA256SUMS' "$GITHUB_OUTPUT"
	assert_success
}

@test "python-dist stage-sidecars: never touches a caller-owned SHA256SUMS" {
	_make_dist
	printf 'abc  pkg-1.0.0.tar.gz\n' >dist/SHA256SUMS
	printf 'mine\n' >SHA256SUMS
	STEP=stage-sidecars run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run cat SHA256SUMS
	assert_output "mine"
	[ -f .lgtm-ci-sidecars/SHA256SUMS ]
}

@test "python-dist stage-sidecars and write-checksums: outputs are workspace-relative" {
	mkdir -p python && cd python && _make_dist
	OUTPUT_PREFIX=python STEP=write-checksums run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run grep 'checksums-path=python/dist/SHA256SUMS' "$GITHUB_OUTPUT"
	assert_success
	OUTPUT_PREFIX=python/ STEP=stage-sidecars run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run grep 'checksums-path=python/.lgtm-ci-sidecars/SHA256SUMS' "$GITHUB_OUTPUT"
	assert_success
}

@test "python-dist stage-sidecars: is a no-op without a manifest" {
	_make_dist
	STEP=stage-sidecars run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run grep 'checksums-path=$' "$GITHUB_OUTPUT"
	assert_success
}

_mock_gh_attestation() {
	# $1: newline-separated basenames whose verification succeeds
	local ok="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '%s\n' "$ok" >"${mock_bin}/.ok"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${mock_bin}/.calls"
[[ "\$1" == "attestation" && "\$2" == "verify" ]] || exit 2
grep -qx "\$(basename "\$3")" "${mock_bin}/.ok"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

@test "python-dist verify-attestations: passes when every distribution file verifies" {
	_make_dist
	_mock_gh_attestation $'pkg-1.0.0-py3-none-any.whl\npkg-1.0.0.tar.gz'
	GITHUB_REPOSITORY=lgtm-hq/example STEP=verify-attestations \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	assert_output --partial "All 2 distribution file(s) carry a valid attestation"
	run cat "${BATS_TEST_TMPDIR}/bin/.calls"
	assert_output --partial "--repo lgtm-hq/example"
	refute_output --partial "--signer-workflow"
	run grep 'attestations-verified=2' "$GITHUB_OUTPUT"
	assert_success
}

@test "python-dist verify-attestations: fails closed when one file lacks an attestation" {
	_make_dist
	_mock_gh_attestation 'pkg-1.0.0-py3-none-any.whl'
	GITHUB_REPOSITORY=lgtm-hq/example STEP=verify-attestations \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_failure
	assert_output --partial "No valid attestation for dist/pkg-1.0.0.tar.gz"
	assert_output --partial "1 of 2 distribution file(s) lack a valid attestation"
}

@test "python-dist verify-attestations: pins the signer workflow when given" {
	_make_dist
	_mock_gh_attestation $'pkg-1.0.0-py3-none-any.whl\npkg-1.0.0.tar.gz'
	GITHUB_REPOSITORY=lgtm-hq/example SIGNER_WORKFLOW=lgtm-hq/example/.github/workflows/publish.yml \
		STEP=verify-attestations run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/bin/.calls"
	assert_output --partial "--signer-workflow lgtm-hq/example/.github/workflows/publish.yml"
}

@test "python-dist verify-attestations: fails when gh is unavailable" {
	_make_dist
	GITHUB_REPOSITORY=lgtm-hq/example STEP=verify-attestations PATH="/nonexistent" \
		run /bin/bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_failure
}

@test "python-dist stage-sidecars: keeps other files an earlier call staged" {
	_make_dist
	mkdir -p .lgtm-ci-sidecars
	printf 'earlier\n' >.lgtm-ci-sidecars/other
	printf 'abc  pkg-1.0.0.tar.gz\n' >dist/SHA256SUMS
	STEP=stage-sidecars run bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
	assert_success
	run cat .lgtm-ci-sidecars/other
	assert_output "earlier"
	[ -f .lgtm-ci-sidecars/SHA256SUMS ]
}
