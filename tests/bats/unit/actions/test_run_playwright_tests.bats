#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-playwright-tests.sh (#521)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-playwright-tests.sh"

setup() {
	setup_temp_dir
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	# results.v1 document (#1080) goes under the test tmpdir, never the repo root.
	export RESULTS_OUTPUT="${BATS_TEST_TMPDIR}/results/results.json"
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

@test "run-playwright-tests upload-gate: upload-report-when=always uploads on success" {
	run env STEP=upload-gate UPLOAD_REPORT=true UPLOAD_REPORT_WHEN=always EXIT_CODE=0 bash "$SCRIPT"
	assert_success
	assert_equal "true" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests upload-gate: upload-report-when=always still honours upload-report=false" {
	run env STEP=upload-gate UPLOAD_REPORT=false UPLOAD_REPORT_WHEN=always EXIT_CODE=0 bash "$SCRIPT"
	assert_success
	assert_equal "false" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests upload-gate: empty upload-report-when defaults to failure" {
	run env STEP=upload-gate UPLOAD_REPORT=true UPLOAD_REPORT_WHEN="  " EXIT_CODE=0 bash "$SCRIPT"
	assert_success
	assert_equal "false" "$(_github_output_value should-upload)"
}

@test "run-playwright-tests upload-gate: rejects an unknown upload-report-when" {
	run env STEP=upload-gate UPLOAD_REPORT=true UPLOAD_REPORT_WHEN=sometimes EXIT_CODE=1 bash "$SCRIPT"
	assert_failure
	assert_output --partial "expected failure or always, got 'sometimes'"
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

# Stub Playwright: records argv and the reporter env, writes the outputs the
# requested reporters would (JSON sidecar, JUnit, HTML dir) unless
# FAKE_PW_SKIP_HTML is set, exits FAKE_PW_EXIT (default 0).
_install_fake_playwright() {
	cat >"${WORK_DIR}/fake-pw.sh" <<'EOF'
#!/usr/bin/env bash
here="$(dirname "$0")"
printf '%s\n' "$@" > "$here/argv.txt"
env | grep '^PLAYWRIGHT_' | sort > "$here/env.txt"
echo '{"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0,"duration":10.4}}' \
	> "$here/${PLAYWRIGHT_JSON_OUTPUT_NAME:-playwright-results.json}"
echo '<testsuites tests="1" failures="0" skipped="0" errors="0"></testsuites>' \
	> "$here/${PLAYWRIGHT_JUNIT_OUTPUT_NAME:-playwright-results.xml}"
if [[ -z "${FAKE_PW_SKIP_HTML:-}" ]]; then
	mkdir -p "$here/${PLAYWRIGHT_HTML_OUTPUT_DIR:-playwright-report}"
	echo '<html></html>' > "$here/${PLAYWRIGHT_HTML_OUTPUT_DIR:-playwright-report}/index.html"
fi
exit "${FAKE_PW_EXIT:-0}"
EOF
	chmod +x "${WORK_DIR}/fake-pw.sh"
}

@test "run-playwright-tests run: appends filters and exactly one reporter flag" {
	_install_fake_playwright

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
	assert_line --index 0 "test"
	assert_line --index 1 "--project=chromium"
	assert_line --index 2 "--grep=@smoke"
	assert_line --index 3 "--reporter=list,json,junit,html"
	# Playwright keeps only the last --reporter flag (#804): never two.
	run grep -c -- '^--reporter=' "${WORK_DIR}/argv.txt"
	assert_output "1"
	assert_equal "0" "$(_github_output_value exit-code)"
	assert_equal "playwright-results.json" "$(_github_output_value json-report-path)"
	assert_equal "playwright-results.xml" "$(_github_output_value junit-report-path)"
	assert_equal "playwright-report" "$(_github_output_value html-report-path)"
}

@test "run-playwright-tests run: pins reporter output locations through the environment" {
	_install_fake_playwright

	# Inherited values must not win: parse and the upload globs use the
	# fixed names, so an override would pass the HTML check with an empty artifact.
	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		PLAYWRIGHT_JSON_OUTPUT_NAME="elsewhere.json" \
		PLAYWRIGHT_JSON_OUTPUT_FILE="/tmp/elsewhere.json" \
		PLAYWRIGHT_JUNIT_OUTPUT_FILE="/tmp/elsewhere.xml" \
		PLAYWRIGHT_HTML_OUTPUT_DIR="elsewhere" \
		PLAYWRIGHT_HTML_REPORT="legacy-elsewhere" \
		PLAYWRIGHT_HTML_OPEN="always" \
		bash "$SCRIPT"

	assert_success
	run cat "${WORK_DIR}/env.txt"
	assert_line "PLAYWRIGHT_JSON_OUTPUT_NAME=playwright-results.json"
	assert_line "PLAYWRIGHT_JUNIT_OUTPUT_NAME=playwright-results.xml"
	assert_line "PLAYWRIGHT_HTML_OUTPUT_DIR=playwright-report"
	assert_line "PLAYWRIGHT_HTML_OPEN=never"
	assert_line "PLAYWRIGHT_HTML_REPORT=playwright-report"
	refute_output --partial "OUTPUT_FILE"
	assert_equal "playwright-report" "$(_github_output_value html-report-path)"
}

@test "run-playwright-tests run: missing HTML report fails a green run" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		FAKE_PW_SKIP_HTML=1 \
		bash "$SCRIPT"

	assert_failure 1
	assert_output --partial "::error title=Playwright HTML report missing::"
	assert_output --partial "expected playwright-report/"
	assert_equal "1" "$(_github_output_value exit-code)"
	# The sidecar is still reported so parse can run.
	assert_equal "playwright-results.json" "$(_github_output_value json-report-path)"
	run grep '^html-report-path=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "run-playwright-tests run: missing HTML report keeps Playwright's own exit code" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		FAKE_PW_SKIP_HTML=1 \
		FAKE_PW_EXIT=3 \
		bash "$SCRIPT"

	assert_failure 3
	assert_output --partial "Playwright HTML report missing"
	assert_equal "3" "$(_github_output_value exit-code)"
}

@test "run-playwright-tests run: test failure with HTML report present propagates the exit code" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		FAKE_PW_EXIT=1 \
		bash "$SCRIPT"

	assert_failure 1
	refute_output --partial "HTML report missing"
	assert_equal "1" "$(_github_output_value exit-code)"
	assert_equal "playwright-report" "$(_github_output_value html-report-path)"
}

@test "run-playwright-tests run: custom reporters are passed through as one flag" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		REPORTERS=" html , json, ./reporters/slack.js " \
		bash "$SCRIPT"

	assert_success
	run cat "${WORK_DIR}/argv.txt"
	assert_line --index 1 "--reporter=html,json,./reporters/slack.js"
	# junit was not requested: no junit output path is advertised.
	run grep '^junit-report-path=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "run-playwright-tests run: custom reporter path with spaces stays one argument" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		REPORTERS="json,html,./reporters/custom reporter.js" \
		bash "$SCRIPT"

	assert_success
	run cat "${WORK_DIR}/argv.txt"
	assert_line --index 1 "--reporter=json,html,./reporters/custom reporter.js"
	run wc -l <"${WORK_DIR}/argv.txt"
	assert_output --partial "2"
}

@test "run-playwright-tests run: pre-run validation failures publish exit-code=1" {
	# The workflow's run step is continue-on-error; without this output the
	# verdict step would have nothing to re-raise and the job stayed green.
	run env STEP=run WORKING_DIRECTORY="$WORK_DIR" TEST_COMMAND='   ' bash "$SCRIPT"
	assert_failure 1
	assert_equal "1" "$(_github_output_value exit-code)"

	: >"$GITHUB_OUTPUT"
	run env STEP=run WORKING_DIRECTORY="${WORK_DIR}/missing" TEST_COMMAND='echo x' bash "$SCRIPT"
	assert_failure 1
	assert_equal "1" "$(_github_output_value exit-code)"

	: >"$GITHUB_OUTPUT"
	run env STEP=run WORKING_DIRECTORY="$WORK_DIR" TEST_COMMAND='echo x' REPORTERS="list" bash "$SCRIPT"
	assert_failure 1
	assert_equal "1" "$(_github_output_value exit-code)"
}

@test "run-playwright-tests run: reporters without html fail before running anything" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		REPORTERS="list,json" \
		bash "$SCRIPT"

	assert_failure 1
	assert_output --partial "reporters must include json (metrics sidecar) and html"
	assert_file_not_exists "${WORK_DIR}/argv.txt"
}

@test "run-playwright-tests run: reporters without json fail before running anything" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		REPORTERS="html" \
		bash "$SCRIPT"

	assert_failure 1
	assert_output --partial "reporters must include json"
	assert_file_not_exists "${WORK_DIR}/argv.txt"
}

@test "run-playwright-tests run: empty reporters fail with the default spelled out" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test" \
		REPORTERS=" , " \
		bash "$SCRIPT"

	assert_failure 1
	assert_output --partial "reporters must not be empty (default: list,json,junit,html)"
}

@test "run-playwright-tests run: warns when test-command already carries --reporter" {
	_install_fake_playwright

	run env \
		STEP=run \
		WORKING_DIRECTORY="$WORK_DIR" \
		TEST_COMMAND="./fake-pw.sh test --reporter=dot" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "::warning title=reporters::test-command already passes --reporter"
	# Ours is appended last, so it is the one Playwright keeps.
	run tail -1 "${WORK_DIR}/argv.txt"
	assert_output "--reporter=list,json,junit,html"
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

@test "run-playwright-tests parse: fractional duration report parses without arithmetic errors" {
	run env \
		STEP=parse \
		WORKING_DIRECTORY="$WORK_DIR" \
		REPORT_PATH="${FIXTURES_DIR}/playwright/reports/json-fractional-duration.json" \
		bash "$SCRIPT"

	assert_success
	refute_output --partial "invalid arithmetic operator"
	assert_equal "1" "$(_github_output_value tests-passed)"
	assert_equal "1" "$(_github_output_value tests-total)"
}

@test "run-playwright-tests parse: malformed report warns and reports zero tests" {
	run env \
		STEP=parse \
		WORKING_DIRECTORY="$WORK_DIR" \
		REPORT_PATH="${FIXTURES_DIR}/playwright/reports/json-malformed.json" \
		bash "$SCRIPT"

	assert_success
	assert_output --partial "Results file is not valid JSON"
	assert_equal "0" "$(_github_output_value tests-passed)"
	assert_equal "0" "$(_github_output_value tests-failed)"
	assert_equal "0" "$(_github_output_value tests-total)"
}

@test "run-playwright-tests parse: merged shard report resolves relative to working directory" {
	install_fixture "playwright/reports/json-merged.json" "${WORK_DIR}/playwright-results.json"

	run env \
		STEP=parse \
		WORKING_DIRECTORY="$WORK_DIR" \
		REPORT_PATH="playwright-results.json" \
		bash "$SCRIPT"

	assert_success
	assert_equal "1" "$(_github_output_value tests-passed)"
	assert_equal "2" "$(_github_output_value tests-failed)"
	assert_equal "1" "$(_github_output_value tests-skipped)"
	assert_equal "4" "$(_github_output_value tests-total)"
}
