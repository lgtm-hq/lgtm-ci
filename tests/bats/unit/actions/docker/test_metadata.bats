#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/metadata.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/metadata.sh"
VALID_DIGEST="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export REGISTRY="ghcr.io"
	export IMAGE_NAME="org/repo"
	unset BUILT_TAGS || true
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_imagetools_inspect() {
	local digest="${1:-}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_docker"
	mkdir -p "$mock_bin"
	: >"$calls_file"
	cat >"${mock_bin}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> '${calls_file}'
if [[ "\$1" == "buildx" && "\$2" == "imagetools" && "\$3" == "inspect" ]]; then
	if [[ -n '${digest}' ]]; then
		echo '${digest}'
		exit 0
	fi
	exit 1
fi
exit 1
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:$PATH"
}

@test "metadata.sh: extracts digest from first built tag" {
	export BUILT_TAGS=$'ghcr.io/org/repo:sha-abc\nghcr.io/org/repo:main'
	_mock_imagetools_inspect "$VALID_DIGEST"

	run bash "$SCRIPT"
	assert_success
	assert_github_output "digest" "$VALID_DIGEST"
	assert_output --partial "Extracted digest"
	run grep -F "imagetools inspect ghcr.io/org/repo:sha-abc" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "metadata.sh: falls back to image:latest when BUILT_TAGS empty" {
	export BUILT_TAGS=""
	_mock_imagetools_inspect "$VALID_DIGEST"

	run bash "$SCRIPT"
	assert_success
	assert_github_output "digest" "$VALID_DIGEST"
	run grep -F "imagetools inspect ghcr.io/org/repo:latest" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "metadata.sh: outputs empty digest and warns when inspect fails" {
	export BUILT_TAGS="ghcr.io/org/repo:missing"
	_mock_imagetools_inspect ""

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Could not extract digest"
	# Empty values are written as "digest="; get_github_output skips blanks.
	run grep -Fx "digest=" "$GITHUB_OUTPUT"
	assert_success
}
