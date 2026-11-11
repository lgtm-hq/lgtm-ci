#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/stage-action-tooling.sh (#1451)

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/stage-action-tooling.sh"

setup() {
	setup_github_env
	WORKSPACE="${BATS_TEST_TMPDIR}/work/consumer/consumer"
	mkdir -p "$WORKSPACE"
}

teardown() {
	teardown_github_env
}

# Create a minimal tooling repository at $1 and print the directory of its
# `example` action. $2 is written into the files so a test can tell trees
# apart.
_make_tooling() {
	local root="$1"
	local tag="${2:-source}"

	mkdir -p "${root}/.github/actions/example" "${root}/.github/actions/sibling" \
		"${root}/scripts/ci/actions" "${root}/scripts/ci/lib"
	echo "name: example ${tag}" >"${root}/.github/actions/example/action.yml"
	echo "name: sibling ${tag}" >"${root}/.github/actions/sibling/action.yml"
	printf '#!/usr/bin/env bash\necho "%s"\n' "$tag" >"${root}/scripts/ci/actions/tool.sh"
	chmod +x "${root}/scripts/ci/actions/tool.sh"
	echo "# lib ${tag}" >"${root}/scripts/ci/lib/lib.sh"
	echo "${root}/.github/actions/example"
}

_stage() {
	local action_dir="$1"
	shift
	run env GITHUB_ACTION_PATH="$action_dir" GITHUB_WORKSPACE="$WORKSPACE" "$@" bash "$SCRIPT"
}

@test "stage-action-tooling.sh: stages a remote _actions layout owned by a mirror" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"

	_stage "$action_dir"
	assert_success
	refute_output --partial "::warning"

	local dest="${WORKSPACE}/.lgtm-ci-tooling"
	run cat "${dest}/.github/actions/sibling/action.yml"
	assert_output "name: sibling mirror"
	run cat "${dest}/scripts/ci/lib/lib.sh"
	assert_output "# lib mirror"
	run grep -x "SCRIPTS_DIR=${dest}/scripts" "$GITHUB_ENV"
	assert_success
	# Scripts are executed directly, so the mode has to survive the copy.
	run "${dest}/scripts/ci/actions/tool.sh"
	assert_success
	assert_output "mirror"
	# A staged sibling finds its script the way setup-python does.
	[ -f "${dest}/.github/actions/sibling/../../../scripts/ci/actions/tool.sh" ]
	# The source the runner downloaded is left as it was.
	[ -f "${root}/scripts/ci/actions/tool.sh" ]
}

@test "stage-action-tooling.sh: copies only .github/actions and scripts" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root")"
	mkdir -p "${root}/.github/workflows" "${root}/docs"
	echo "x" >"${root}/.github/workflows/ci.yml"
	echo "x" >"${root}/docs/readme.md"

	_stage "$action_dir"
	assert_success
	[ ! -e "${WORKSPACE}/.lgtm-ci-tooling/.github/workflows" ]
	[ ! -e "${WORKSPACE}/.lgtm-ci-tooling/docs" ]
}

@test "stage-action-tooling.sh: ignores an unrelated repository enclosing _actions" {
	# On a self-hosted runner the work directory can sit inside some other
	# checkout; git would report that one as the toplevel.
	local outer="${BATS_TEST_TMPDIR}/work"
	git -C "$outer" init >/dev/null 2>&1
	mkdir -p "${outer}/scripts/ci/actions"
	echo "echo outer" >"${outer}/scripts/ci/actions/tool.sh"
	local root="${outer}/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"

	_stage "$action_dir"
	assert_success
	run "${WORKSPACE}/.lgtm-ci-tooling/scripts/ci/actions/tool.sh"
	assert_output "mirror"
}

@test "stage-action-tooling.sh: stages a local action checked out at the workspace root" {
	local action_dir
	action_dir="$(_make_tooling "$WORKSPACE" local)"

	_stage "$action_dir" TOOLING_REF=some-ref
	assert_success
	# The ref of a local checkout is not readable from the path: no guess.
	refute_output --partial "::warning"
	run cat "${WORKSPACE}/.lgtm-ci-tooling/.github/actions/sibling/action.yml"
	assert_output "name: sibling local"
	# The staged tree is not copied into itself.
	[ ! -e "${WORKSPACE}/.lgtm-ci-tooling/.lgtm-ci-tooling" ]
	run grep -x "SCRIPTS_DIR=${WORKSPACE}/.lgtm-ci-tooling/scripts" "$GITHUB_ENV"
	assert_success
}

@test "stage-action-tooling.sh: stages a local action checked out in a workspace subdirectory" {
	local action_dir
	action_dir="$(_make_tooling "${WORKSPACE}/vendor/ci" nested)"

	_stage "$action_dir"
	assert_success
	run "${WORKSPACE}/.lgtm-ci-tooling/scripts/ci/actions/tool.sh"
	assert_output "nested"
}

@test "stage-action-tooling.sh: replaces a pre-existing tooling directory as a whole, with a warning" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"
	# A caller's earlier checkout of some other commit.
	local dest="${WORKSPACE}/.lgtm-ci-tooling"
	_make_tooling "$dest" stale >/dev/null
	mkdir -p "${dest}/.git"
	echo "stale only" >"${dest}/scripts/ci/actions/removed-later.sh"

	_stage "$action_dir"
	assert_success
	assert_output --partial "::warning title=tooling directory replaced::"
	assert_output --partial "replaced as a whole"
	# Nothing of the old tree survives next to the new one.
	[ ! -e "${dest}/scripts/ci/actions/removed-later.sh" ]
	[ ! -e "${dest}/.git" ]
	run "${dest}/scripts/ci/actions/tool.sh"
	assert_output "mirror"
	run cat "${dest}/.github/actions/sibling/action.yml"
	assert_output "name: sibling mirror"
}

@test "stage-action-tooling.sh: restaging its own tree does not warn" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" first)"
	_stage "$action_dir"
	assert_success

	echo "name: sibling second" >"${root}/.github/actions/sibling/action.yml"
	_stage "$action_dir"
	assert_success
	refute_output --partial "::warning"
	run cat "${WORKSPACE}/.lgtm-ci-tooling/.github/actions/sibling/action.yml"
	assert_output "name: sibling second"
}

@test "stage-action-tooling.sh: replaces a symlinked tooling directory without touching its target" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"
	local target="${BATS_TEST_TMPDIR}/elsewhere"
	mkdir -p "$target"
	echo "keep" >"${target}/keep.txt"
	ln -s "$target" "${WORKSPACE}/.lgtm-ci-tooling"

	_stage "$action_dir"
	assert_success
	[ ! -L "${WORKSPACE}/.lgtm-ci-tooling" ]
	[ -f "${target}/keep.txt" ]
	[ ! -e "${target}/scripts" ]
	run "${WORKSPACE}/.lgtm-ci-tooling/scripts/ci/actions/tool.sh"
	assert_output "mirror"
}

@test "stage-action-tooling.sh: uses the tooling directory in place when the action was loaded from it" {
	local dest="${WORKSPACE}/.lgtm-ci-tooling"
	local action_dir
	action_dir="$(_make_tooling "$dest" checkout)"
	echo "extra" >"${dest}/extra.txt"

	_stage "$action_dir"
	assert_success
	assert_output --partial "in place"
	refute_output --partial "::warning"
	[ -f "${dest}/extra.txt" ]
	run grep -x "SCRIPTS_DIR=${dest}/scripts" "$GITHUB_ENV"
	assert_success
}

@test "stage-action-tooling.sh: fails when the action lives deeper inside the tooling directory" {
	local dest="${WORKSPACE}/.lgtm-ci-tooling"
	local action_dir
	action_dir="$(_make_tooling "${dest}/nested" checkout)"

	_stage "$action_dir"
	assert_failure
	assert_output --partial "loaded from inside"
	# The source was not deleted and nothing was exported.
	[ -f "${dest}/nested/scripts/ci/actions/tool.sh" ]
	run grep -c SCRIPTS_DIR "$GITHUB_ENV"
	assert_output "0"
}

@test "stage-action-tooling.sh: no warning when tooling-ref equals the loaded ref" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root")"

	_stage "$action_dir" TOOLING_REF=0123abc
	assert_success
	refute_output --partial "::warning"
}

@test "stage-action-tooling.sh: warns when tooling-ref differs from the loaded ref" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"

	_stage "$action_dir" TOOLING_REF=fedcba9
	assert_success
	assert_output --partial "::warning title=tooling-ref ignored::tooling-ref 'fedcba9' is not the ref this action was loaded at ('0123abc')"
	# The value is ignored: the loaded tree is what gets staged.
	run "${WORKSPACE}/.lgtm-ci-tooling/scripts/ci/actions/tool.sh"
	assert_output "mirror"
}

@test "stage-action-tooling.sh: reads a loaded ref that contains a slash" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/feature/x"
	local action_dir
	action_dir="$(_make_tooling "$root")"

	_stage "$action_dir" TOOLING_REF=feature/x
	assert_success
	refute_output --partial "::warning"

	_stage "$action_dir" TOOLING_REF=main
	assert_success
	assert_output --partial "loaded at ('feature/x')"
}

@test "stage-action-tooling.sh: skips the tooling-ref comparison outside the _actions layout" {
	local root="${BATS_TEST_TMPDIR}/somewhere/else"
	local action_dir
	action_dir="$(_make_tooling "$root")"

	_stage "$action_dir" TOOLING_REF=fedcba9
	assert_success
	refute_output --partial "::warning"
}

@test "stage-action-tooling.sh: a multi-line tooling-ref cannot start a workflow command" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root")"

	_stage "$action_dir" TOOLING_REF=$'x\n::error::injected'
	assert_success
	run grep -c '^::error' <<<"$output"
	assert_output "0"
}

@test "stage-action-tooling.sh: normalizes Windows-style backslashes" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root" mirror)"

	run env GITHUB_ACTION_PATH="${action_dir//\//\\}" \
		GITHUB_WORKSPACE="${WORKSPACE//\//\\}" bash "$SCRIPT"
	assert_success
	run grep -x "SCRIPTS_DIR=${WORKSPACE}/.lgtm-ci-tooling/scripts" "$GITHUB_ENV"
	assert_success
}

@test "stage-action-tooling.sh: fails when the action path is not <root>/.github/actions/<name>" {
	mkdir -p "${BATS_TEST_TMPDIR}/odd/place"

	_stage "${BATS_TEST_TMPDIR}/odd/place"
	assert_failure
	assert_output --partial "cannot derive the repository root"
	[ ! -e "${WORKSPACE}/.lgtm-ci-tooling" ]
}

@test "stage-action-tooling.sh: fails when the action's repository has no scripts tree" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	mkdir -p "${root}/.github/actions/example"
	# An existing directory must survive a failed run.
	mkdir -p "${WORKSPACE}/.lgtm-ci-tooling"
	echo "keep" >"${WORKSPACE}/.lgtm-ci-tooling/keep.txt"

	_stage "${root}/.github/actions/example"
	assert_failure
	assert_output --partial "scripts/ci' is missing"
	[ -f "${WORKSPACE}/.lgtm-ci-tooling/keep.txt" ]
}

@test "stage-action-tooling.sh: rejects a TOOLING_DIR that is not a single directory name" {
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir
	action_dir="$(_make_tooling "$root")"

	_stage "$action_dir" TOOLING_DIR=../outside
	assert_failure
	assert_output --partial "TOOLING_DIR must be a single directory name"
	_stage "$action_dir" TOOLING_DIR=..
	assert_failure
}

@test "stage-action-tooling.sh: fails without its required environment" {
	run env -u GITHUB_ACTION_PATH GITHUB_WORKSPACE="$WORKSPACE" bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_ACTION_PATH is required"
	run env -u GITHUB_WORKSPACE GITHUB_ACTION_PATH=/x/.github/actions/y bash "$SCRIPT"
	assert_failure
	assert_output --partial "GITHUB_WORKSPACE is required"
}
