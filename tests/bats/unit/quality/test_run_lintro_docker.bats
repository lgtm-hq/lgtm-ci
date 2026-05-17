#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/quality/run-lintro-docker.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/quality/run-lintro-docker.sh"
}

teardown() {
	teardown_temp_dir
}

@test "run-lintro-docker.sh --help exits zero" {
	run bash "$SCRIPT" --help
	assert_success
	assert_output --partial "py-lintro"
}

@test "run-lintro-docker.sh requires LINTRO_IMAGE" {
	run bash -c 'STEP=check "${SCRIPT:?}"'
	assert_failure
}

@test "run-lintro-docker.sh requires STEP" {
	run bash -c 'LINTRO_IMAGE=img:tag "${SCRIPT:?}"'
	assert_failure
}

@test "run-lintro-docker.sh reports docker pull failure" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${mock_bin}"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == pull ]]; then
	echo "pull denied" >&2
	exit 3
fi
exit 0
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:${PATH}"

	run env STEP=check LINTRO_IMAGE=img:tag bash "${SCRIPT}"

	assert_failure
	assert_equal "3" "$status"
	assert_output --partial "Failed to pull Lintro image img:tag: pull denied"
}

@test "run-lintro-docker.sh check invokes docker pull and chk with grid" {
	mock_command_record docker ""
	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=check LINTRO_IMAGE=ghcr.io/test/img:tag FAIL_ON_ERROR=true bash "${SCRIPT}"

	assert_success
	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_file_contains "${calls}" "pull ghcr.io/test/img:tag"
	assert_file_contains_literal "${calls}" "--exclude"
	assert_file_contains_literal "${calls}" ".lgtm-ci-tooling"
	assert_file_contains "${calls}" "chk --exclude"
	assert_file_contains "${calls}" ". --output-format grid"
	assert_file_contains "${GITHUB_OUTPUT}" "exit-code=0"
	assert_file_exists "${BATS_TEST_TMPDIR}/ws/chk-output.txt"
}

@test "run-lintro-docker.sh check passes --tools when TOOLS is set" {
	mock_command_record docker ""
	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=check LINTRO_IMAGE=img:tag TOOLS=ruff,yamllint FAIL_ON_ERROR=true bash "${SCRIPT}"

	assert_success
	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_file_contains_literal "${calls}" "--tools"
	assert_file_contains "${calls}" "ruff,yamllint"
}

@test "run-lintro-docker.sh check allows custom excludes" {
	mock_command_record docker ""
	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1

	run env STEP=check LINTRO_IMAGE=img:tag EXCLUDE="dist/**" bash "${SCRIPT}"

	assert_success
	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_file_contains_literal "${calls}" "chk"
	assert_file_contains_literal "${calls}" "--exclude"
	assert_file_contains_literal "${calls}" "dist/**"
}

@test "run-lintro-docker.sh format invokes docker with fmt" {
	mock_command_record docker ""
	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=format LINTRO_IMAGE=img:tag bash "${SCRIPT}"

	assert_success
	local calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_file_contains "${calls}" "fmt --exclude"
	assert_file_contains_literal "${calls}" ".lgtm-ci-tooling"
}

@test "run-lintro-docker.sh check fails when docker run exits non-zero and FAIL_ON_ERROR=true" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${mock_bin}"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == pull ]]; then exit 0; fi
if [[ "${1:-}" == run ]]; then exit 1; fi
exit 0
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:${PATH}"

	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=check LINTRO_IMAGE=img:tag FAIL_ON_ERROR=true bash "${SCRIPT}"

	assert_failure
	assert_file_contains "${GITHUB_OUTPUT}" "exit-code=1"
	assert_file_contains "${GITHUB_OUTPUT}" "status=failed"
}

@test "run-lintro-docker.sh check keeps docker exit code when tee also fails" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${mock_bin}"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == pull ]]; then exit 0; fi
if [[ "${1:-}" == run ]]; then exit 7; fi
exit 0
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:${PATH}"

	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=check LINTRO_IMAGE=img:tag FAIL_ON_ERROR=true OUTPUT_LOG=/ bash "${SCRIPT}"

	assert_failure
	assert_equal "7" "$status"
	assert_file_contains "${GITHUB_OUTPUT}" "exit-code=7"
	assert_file_contains "${GITHUB_OUTPUT}" "status=failed"
}

@test "run-lintro-docker.sh check exits zero when docker run fails but FAIL_ON_ERROR=false" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${mock_bin}"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == pull ]]; then exit 0; fi
if [[ "${1:-}" == run ]]; then exit 1; fi
exit 0
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:${PATH}"

	mkdir -p "${BATS_TEST_TMPDIR}/ws"
	cd "${BATS_TEST_TMPDIR}/ws" || exit 1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"

	run env STEP=check LINTRO_IMAGE=img:tag FAIL_ON_ERROR=false bash "${SCRIPT}"

	assert_success
	assert_file_contains "${GITHUB_OUTPUT}" "exit-code=1"
	assert_file_contains "${GITHUB_OUTPUT}" "status=failed"
}
