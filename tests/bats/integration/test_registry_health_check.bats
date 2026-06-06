#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for registry-health-check maintenance script

load "../../helpers/common"
load "../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/registry-health-check.sh"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "registry-health-check: passes when all digest pins resolve" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/workflow.yml" <<'YAML'
jobs:
  quality:
    env:
      LINTRO_IMAGE: ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578
YAML

	mock_command_multi "docker" '
		*manifest*inspect*) exit 0;;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All digest-pinned container images resolve"
}

@test "registry-health-check: fails when a digest pin is unreachable" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/workflow.yml" <<'YAML'
jobs:
  quality:
    env:
      LINTRO_IMAGE: ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
YAML

	mock_command_multi "docker" '
		*manifest*inspect*) exit 1;;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "digest unreachable after 3 manifest inspect attempts"
}

@test "registry-health-check: ignores markdown files in scan paths" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/docs.md" <<'MD'
Example only: ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
MD

	mock_command_record "docker" "" 0

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "No digest-pinned container images found"
	run test ! -s "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "registry-health-check: strips docker:// prefix before manifest inspect" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/workflow.yml" <<'YAML'
jobs:
  container:
    steps:
      - uses: docker://ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578
YAML

	mock_command_multi "docker" '
		*manifest*inspect*ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578*) exit 0;;
		*manifest*inspect*) exit 1;;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All digest-pinned container images resolve"
}

@test "registry-health-check: ignores digest pins in YAML comment lines" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/workflow.yml" <<'YAML'
jobs:
  quality:
    env:
      # LINTRO_IMAGE: ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
      LINTRO_IMAGE: ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578
YAML

	mock_command_record "docker" "" 0

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run bash -c 'wc -l < "'"${BATS_TEST_TMPDIR}"'/mock_calls_docker" | tr -d " "'
	assert_output "1"
}

@test "registry-health-check: sets digest-failure output when pins are unreachable" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/workflow.yml" <<'YAML'
jobs:
  quality:
    env:
      LINTRO_IMAGE: ghcr.io/lgtm-hq/py-lintro@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
YAML

	mock_command_multi "docker" '
		*manifest*inspect*) exit 1;;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		export GITHUB_OUTPUT="'"${BATS_TEST_TMPDIR}"'/github_output"
		: >"$GITHUB_OUTPUT"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	run grep -F "digest-failure=true" "${BATS_TEST_TMPDIR}/github_output"
	assert_success
}

@test "registry-health-check: deduplicates repeated digest pins" {
	local scan_dir="${BATS_TEST_TMPDIR}/scan"
	mkdir -p "$scan_dir"
	cat >"${scan_dir}/a.yml" <<'YAML'
image: ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578
YAML
	cp "${scan_dir}/a.yml" "${scan_dir}/b.yml"

	mock_command_record "docker" "" 0

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run bash -c 'wc -l < "'"${BATS_TEST_TMPDIR}"'/mock_calls_docker" | tr -d " "'
	assert_output "1"
}
