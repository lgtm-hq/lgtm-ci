#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/verify-published.sh
# Guards against publishing a dangling multi-arch index (children 404) as green.

load "../../../../helpers/common"
load "../../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/verify-published.sh"

AMD64_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
ARM64_DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	export MATRIX='[{"platform":"linux/amd64","slug":"amd64"},{"platform":"linux/arm64","slug":"arm64"}]'
	export TARGET_TAGS=$'ghcr.io/org/repo:1.0.0\nghcr.io/org/repo:latest'
	export INDEX_FILE="${BATS_TEST_TMPDIR}/index.json"
	# Keep retry loops instant in unit tests.
	export VERIFY_ATTEMPTS=1
	export VERIFY_DELAY=0
}

teardown() {
	restore_path
	teardown_temp_dir
}

_write_index() {
	cat >"$INDEX_FILE"
}

# Mock docker so `imagetools inspect --raw <ref>` returns the index JSON, and
# `imagetools inspect <image>@<digest>` succeeds only for RESOLVABLE_DIGESTS.
_mock_docker() {
	export RESOLVABLE="$1"
	mock_command_multi "docker" '
		*imagetools\ inspect\ --raw*) cat "$INDEX_FILE";;
		*imagetools\ inspect\ *@*)
			for d in $RESOLVABLE; do
				case "$*" in *"$d"*) exit 0;; esac
			done
			exit 1;;
		*) exit 0;;
	'
}

@test "verify-published: passes when all platform children resolve" {
	_write_index <<EOF
{"manifests":[
  {"digest":"${AMD64_DIGEST}","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"${ARM64_DIGEST}","platform":{"os":"linux","architecture":"arm64"}}
]}
EOF
	_mock_docker "${AMD64_DIGEST} ${ARM64_DIGEST}"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "all platform children resolve"
}

@test "verify-published: fails when a child manifest 404s (dangling index)" {
	_write_index <<EOF
{"manifests":[
  {"digest":"${AMD64_DIGEST}","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"${ARM64_DIGEST}","platform":{"os":"linux","architecture":"arm64"}}
]}
EOF
	# arm64 child does not resolve in the registry.
	_mock_docker "${AMD64_DIGEST}"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "does not resolve in registry"
	assert_output --partial "incomplete"
}

@test "verify-published: retries absorb read-after-write lag then succeed" {
	_write_index <<EOF
{"manifests":[
  {"digest":"${AMD64_DIGEST}","platform":{"os":"linux","architecture":"amd64"}}
]}
EOF
	export MATRIX='[{"platform":"linux/amd64","slug":"amd64"}]'
	export VERIFY_ATTEMPTS=3
	export VERIFY_DELAY=0
	# Child resolves only on the 2nd inspect attempt (transient 404 first).
	mock_command_multi "docker" '
		*imagetools\ inspect\ --raw*) cat "$INDEX_FILE";;
		*imagetools\ inspect\ *@*)
			n_file="${BATS_TEST_TMPDIR}/child_attempts"
			n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
			echo "$n" > "$n_file"
			[ "$n" -ge 2 ] && exit 0 || exit 1;;
		*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "all platform children resolve"
}

@test "verify-published: matches variant platforms (linux/arm/v7)" {
	export MATRIX='[{"platform":"linux/arm/v7","slug":"armv7"}]'
	export TARGET_TAGS="ghcr.io/org/repo:1.0.0"
	_write_index <<EOF
{"manifests":[
  {"digest":"${ARM64_DIGEST}","platform":{"os":"linux","architecture":"arm","variant":"v7"}}
]}
EOF
	_mock_docker "${ARM64_DIGEST}"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "all platform children resolve"
}

@test "verify-published: fails when index is missing a platform child" {
	_write_index <<EOF
{"manifests":[
  {"digest":"${AMD64_DIGEST}","platform":{"os":"linux","architecture":"amd64"}}
]}
EOF
	_mock_docker "${AMD64_DIGEST} ${ARM64_DIGEST}"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no child manifest for platform linux/arm64"
}

@test "verify-published: fails when ref is not a multi-arch index" {
	_write_index <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}
EOF
	_mock_docker "${AMD64_DIGEST} ${ARM64_DIGEST}"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not a multi-arch index"
}

@test "verify-published: fails when the published ref does not resolve" {
	mock_command_multi "docker" '
		*imagetools\ inspect\ --raw*) exit 1;;
		*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not resolvable in registry"
}

@test "verify-published: fails when TARGET_TAGS is empty" {
	export TARGET_TAGS=$'\n  \n'
	_mock_docker ""

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "No target tag found"
}

@test "verify-published: requires MATRIX" {
	run env -u MATRIX bash "$SCRIPT"
	assert_failure
	assert_output --partial "MATRIX is required"
}
