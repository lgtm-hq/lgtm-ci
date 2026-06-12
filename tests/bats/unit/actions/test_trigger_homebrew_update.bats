#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/trigger-homebrew-update.sh

load "../../../helpers/common"
load "../../../helpers/github_env"
load "../../../helpers/mocks"

setup() {
	setup_temp_dir
	setup_github_env
	save_path
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_gh_dispatch() {
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_gh"
	local input_file="${BATS_TEST_TMPDIR}/mock_gh_input"
	: >"$calls_file"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${calls_file}'
if [[ "\$1" == "api" ]]; then
	while [[ \$# -gt 0 ]]; do
		case "\$1" in
			--input) cat >'${input_file}'; shift 2;;
			*) shift;;
		esac
	done
fi
exit 0
EOF
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi

	export MOCK_GH_CALLS="$calls_file"
	export MOCK_GH_INPUT="$input_file"
}

_mock_gh_dispatch_fail() {
	_mock_gh_dispatch
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${MOCK_GH_CALLS}'
if [[ "\$1" == "api" ]]; then
	while [[ \$# -gt 0 ]]; do
		case "\$1" in
			--input) cat >'${MOCK_GH_INPUT}'; shift 2;;
			*) shift;;
		esac
	done
fi
exit 1
EOF
	chmod +x "${mock_bin}/gh"
}

_run_dispatch() {
	run env \
		STEP=dispatch \
		FORMULA="${1:-winnow}" \
		VERSION="${2:-2.0.0}" \
		GH_TOKEN=test-token \
		TAP_REPOSITORY="${3:-lgtm-hq/homebrew-tap}" \
		PYPI_PACKAGE="${4:-}" \
		BINARY_ARM64_SHA="${5:-}" \
		BINARY_X86_SHA="${6:-}" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/trigger-homebrew-update.sh"
}

@test "trigger-homebrew-update: fails when FORMULA is missing" {
	run env STEP=dispatch VERSION=1.0.0 GH_TOKEN=test-token \
		bash "${PROJECT_ROOT}/scripts/ci/actions/trigger-homebrew-update.sh"

	assert_failure
	assert_output --partial "FORMULA is required"
}

@test "trigger-homebrew-update: fails when VERSION is missing" {
	run env STEP=dispatch FORMULA=winnow GH_TOKEN=test-token \
		bash "${PROJECT_ROOT}/scripts/ci/actions/trigger-homebrew-update.sh"

	assert_failure
	assert_output --partial "VERSION is required"
}

@test "trigger-homebrew-update: fails when GH_TOKEN is missing" {
	run env STEP=dispatch FORMULA=winnow VERSION=1.0.0 \
		bash "${PROJECT_ROOT}/scripts/ci/actions/trigger-homebrew-update.sh"

	assert_failure
	assert_output --partial "GH_TOKEN is required"
}

@test "trigger-homebrew-update: dispatches PyPI-only payload" {
	_mock_gh_dispatch

	_run_dispatch winnow 2.0.0 lgtm-hq/homebrew-tap

	assert_success
	assert_github_output "dispatched" "true"
	assert_github_output "tap-repository" "lgtm-hq/homebrew-tap"

	run jq -c '.client_payload' "$MOCK_GH_INPUT"
	assert_success
	assert_output '{"formula":"winnow","version":"2.0.0","pypi-package":"winnow"}'

	run grep -F "repos/lgtm-hq/homebrew-tap/dispatches" "$MOCK_GH_CALLS"
	assert_success

	run jq -r '.event_type' "$MOCK_GH_INPUT"
	assert_success
	assert_output "update-formula"
}

@test "trigger-homebrew-update: dispatches payload with binary assets" {
	_mock_gh_dispatch

	_run_dispatch lintro 3.0.0 lgtm-hq/homebrew-tap lintro arm64sha x86sha

	assert_success

	run jq -c '.client_payload' "$MOCK_GH_INPUT"
	assert_success
	assert_output '{"formula":"lintro","version":"3.0.0","pypi-package":"lintro","binary-assets":{"arm64-sha":"arm64sha","x86-sha":"x86sha"}}'
}

@test "trigger-homebrew-update: omits binary-assets when both SHAs empty" {
	_mock_gh_dispatch

	_run_dispatch winnow 2.0.0

	assert_success

	run jq -e '.client_payload | has("binary-assets") | not' "$MOCK_GH_INPUT"
	assert_success
}

@test "trigger-homebrew-update: fails when only one binary SHA is set" {
	_mock_gh_dispatch

	_run_dispatch lintro 3.0.0 lgtm-hq/homebrew-tap lintro arm64sha

	assert_failure
	assert_output --partial "binary-arm64-sha and binary-x86-sha must both be set or both omitted"
	assert_github_output "dispatched" "false"
}

@test "trigger-homebrew-update: sets dispatched false when gh api fails" {
	_mock_gh_dispatch_fail

	_run_dispatch winnow 2.0.0

	assert_failure
	assert_github_output "dispatched" "false"
	assert_github_output "tap-repository" "lgtm-hq/homebrew-tap"
}
