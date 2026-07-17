#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-playwright-tests.sh (#521)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-playwright-tests.sh"

setup() {
	setup_temp_dir
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

_github_output_value() {
	local key="$1"
	grep "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "run-playwright-tests assemble-args: empty when no filters" {
	run env STEP=assemble-args PROJECT="" GREP="" bash "$SCRIPT"
	assert_success
	assert_equal "" "$(_github_output_value filter-args)"
}

@test "run-playwright-tests assemble-args: project only" {
	run env STEP=assemble-args PROJECT="chromium" GREP="" bash "$SCRIPT"
	assert_success
	assert_equal "--project=chromium" "$(_github_output_value filter-args)"
	assert_output --partial "--project=chromium"
}

@test "run-playwright-tests assemble-args: grep only" {
	run env STEP=assemble-args PROJECT="" GREP="@smoke" bash "$SCRIPT"
	assert_success
	assert_equal "--grep=@smoke" "$(_github_output_value filter-args)"
}

@test "run-playwright-tests assemble-args: project and grep" {
	run env STEP=assemble-args PROJECT="webkit" GREP="@a11y" bash "$SCRIPT"
	assert_success
	assert_equal "--project=webkit --grep=@a11y" "$(_github_output_value filter-args)"
}

@test "run-playwright-tests cache-key: derives version from package.json" {
	cat >"${WORK_DIR}/package.json" <<'EOF'
{
  "devDependencies": {
    "@playwright/test": "^1.49.1"
  }
}
EOF

	run env \
		STEP=cache-key \
		WORKING_DIRECTORY="$WORK_DIR" \
		BROWSERS="chromium" \
		bash "$SCRIPT"

	assert_success
	assert_equal "1.49.1" "$(_github_output_value playwright-version)"
	assert_equal "playwright-1.49.1-chromium" "$(_github_output_value cache-key)"
}

@test "run-playwright-tests cache-key: normalizes multi-browser list" {
	cat >"${WORK_DIR}/package.json" <<'EOF'
{
  "dependencies": {
    "@playwright/test": "1.40.0"
  }
}
EOF

	run env \
		STEP=cache-key \
		WORKING_DIRECTORY="$WORK_DIR" \
		BROWSERS="chromium firefox" \
		bash "$SCRIPT"

	assert_success
	assert_equal "playwright-1.40.0-chromium-firefox" "$(_github_output_value cache-key)"
}

@test "run-playwright-tests cache-key: unknown when package.json missing playwright" {
	cat >"${WORK_DIR}/package.json" <<'EOF'
{
  "name": "no-playwright"
}
EOF

	run env \
		STEP=cache-key \
		WORKING_DIRECTORY="$WORK_DIR" \
		BROWSERS="chromium" \
		PATH="/usr/bin:/bin" \
		bash "$SCRIPT"

	assert_success
	assert_equal "unknown" "$(_github_output_value playwright-version)"
	assert_equal "playwright-unknown-chromium" "$(_github_output_value cache-key)"
}

@test "run-playwright-tests upload-gate: uploads on failure when enabled" {
	run env STEP=upload-gate UPLOAD_REPORT=true EXIT_CODE=1 bash "$SCRIPT"
	assert_success
	assert_equal "true" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests upload-gate: skips on success even when enabled" {
	run env STEP=upload-gate UPLOAD_REPORT=true EXIT_CODE=0 bash "$SCRIPT"
	assert_success
	assert_equal "false" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests upload-gate: skips when upload-report false" {
	run env STEP=upload-gate UPLOAD_REPORT=false EXIT_CODE=2 bash "$SCRIPT"
	assert_success
	assert_equal "false" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests run: fails when working directory missing" {
	run env \
		STEP=run \
		WORKING_DIRECTORY="${WORK_DIR}/missing" \
		TEST_COMMAND='echo should-not-run' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "Working directory does not exist"
}

@test "run-playwright-tests run: fails when TEST_COMMAND empty" {
	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND='   ' \
		bash "$SCRIPT"

	assert_failure
	assert_output --partial "TEST_COMMAND must not be empty"
}

@test "run-playwright-tests run: appends filters and reporters" {
	# Stub command that records argv; skip real playwright.
	cat >"${WORK_DIR}/fake-pw.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/argv.txt"
# Minimal JSON for parse path downstream
echo '{"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0,"duration":10}}' \
	> "$(dirname "$0")/playwright-results.json"
EOF
	chmod +x "${WORK_DIR}/fake-pw.sh"

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		PROJECT="chromium" \
		GREP="@smoke" \
		BASE_URL="http://127.0.0.1:4173" \
		WEB_SERVER="npm run preview" \
		bash "$SCRIPT"

	assert_success
	assert_file_exists "${WORK_DIR}/argv.txt"
	run cat "${WORK_DIR}/argv.txt"
	assert_output --partial "test"
	assert_output --partial "--project=chromium"
	assert_output --partial "--grep=@smoke"
	assert_output --partial "--reporter=html"
	assert_output --partial "--reporter=json"
	assert_equal "0" "$(_github_output_value exit-code)"
}

@test "run-playwright-tests parse: reads playwright JSON results" {
	cat >"${WORK_DIR}/playwright-results.json" <<'EOF'
{
  "stats": {
    "expected": 3,
    "unexpected": 1,
    "flaky": 0,
    "skipped": 2,
    "duration": 1500
  }
}
EOF

	run env \
		STEP=parse \
		WORKING_DIRECTORY="$WORK_DIR" \
		REPORT_PATH="${WORK_DIR}/playwright-results.json" \
		bash "$SCRIPT"

	assert_success
	assert_equal "3" "$(_github_output_value tests-passed)"
	assert_equal "1" "$(_github_output_value tests-failed)"
	assert_equal "2" "$(_github_output_value tests-skipped)"
	assert_equal "6" "$(_github_output_value tests-total)"
}
