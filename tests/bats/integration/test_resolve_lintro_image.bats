#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for resolve-lintro-image script

load "../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/quality/resolve-lintro-image.sh"
IMAGE="ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	teardown_temp_dir
}

write_source() {
	local file="$1"
	local image="$2"
	mkdir -p "$(dirname "$file")"
	printf 'lintro-image: %s\n' "$image" >"$file"
}

@test "resolve-lintro-image: resolves matching digest pins from CI files" {
	local root="${BATS_TEST_TMPDIR}/repo"
	write_source "${root}/.github/workflows/reusable-quality-lint.yml" "$IMAGE"
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT"
	'
	assert_success
	assert_output --partial "$IMAGE"
}

@test "resolve-lintro-image: fails when CI files disagree on digest pin" {
	local root="${BATS_TEST_TMPDIR}/repo"
	write_source "${root}/.github/workflows/reusable-quality-lint.yml" "$IMAGE"
	write_source "${root}/.github/actions/run-quality/action.yml" \
		"ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "Lintro image definitions disagree"
}

@test "resolve-lintro-image: uses INPUT_LINTRO_IMAGE override when provided" {
	run bash -c '
		export INPUT_LINTRO_IMAGE="'"$IMAGE"'"
		export GITHUB_OUTPUT="'"${BATS_TEST_TMPDIR}"'/github_output"
		: >"$GITHUB_OUTPUT"
		bash "$SCRIPT"
	'
	assert_success
	run grep -F "image=${IMAGE}" "${BATS_TEST_TMPDIR}/github_output"
	assert_success
}

@test "resolve-lintro-image: ignores commented stale digest before active default pin" {
	local root="${BATS_TEST_TMPDIR}/repo"
	local stale="ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	mkdir -p "${root}/.github/workflows"
	cat >"${root}/.github/workflows/reusable-quality-lint.yml" <<YAML
# lintro-image: ${stale}
lintro-image:
  description: pinned image
  default: "${IMAGE}"
YAML
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT"
	'
	assert_success
	assert_output --partial "$IMAGE"
	refute_output --partial "deadbeef"
}

@test "resolve-lintro-image: resolves digest from default under lintro-image block" {
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/.github/workflows"
	cat >"${root}/.github/workflows/reusable-quality-lint.yml" <<YAML
lintro-image:
  description: pinned image
  default: "${IMAGE}"
YAML
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT"
	'
	assert_success
	assert_output --partial "$IMAGE"
}

@test "resolve-lintro-image: resolves digest from block-scalar default value" {
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/.github/workflows"
	cat >"${root}/.github/workflows/reusable-quality-lint.yml" <<YAML
lintro-image:
  description: pinned image
  default: >-
    ${IMAGE}
YAML
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT"
	'
	assert_success
	assert_output --partial "$IMAGE"
}

@test "resolve-lintro-image: fails when source file has no digest pin" {
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/.github/workflows"
	cat >"${root}/.github/workflows/reusable-quality-lint.yml" <<YAML
lintro-image:
  description: pinned image
  default: "ghcr.io/lgtm-hq/py-lintro:latest"
YAML
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "No digest-pinned lintro image found"
}

@test "resolve-lintro-image: fails when LINTRO_IMAGE_SOURCES is whitespace only" {
	local root="${BATS_TEST_TMPDIR}/repo"
	write_source "${root}/.github/workflows/reusable-quality-lint.yml" "$IMAGE"
	write_source "${root}/.github/actions/run-quality/action.yml" "$IMAGE"

	run bash -c '
		cd "'"$root"'"
		export LINTRO_IMAGE_SOURCES="   "
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "No lintro image sources specified in LINTRO_IMAGE_SOURCES"
}
