#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-playwright-tests.sh (#521)

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-playwright-tests.sh"

setup() {
	setup_temp_dir
	save_path
	# Cache-key cases exercise package.json fallback without an ambient package lookup.
	mock_command npx "" 1
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	# results.v1 document (#1080) goes under the test tmpdir, never the repo root.
	export RESULTS_OUTPUT="${BATS_TEST_TMPDIR}/results/results.json"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	# Never read the host os-release; each test picks its own runner image (#1313).
	export OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
	printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$OS_RELEASE_FILE"
	# System packages go through the apt helper on Linux (#1432); record it
	# instead of running apt.
	export RUNNER_OS=Linux
	mock_command_record python3
}

teardown() {
	restore_path
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

# cache-key (#1433): exact key from the installed Playwright version, the
# runner OS release and architecture, install mode and browsers; the real
# playwright_browsers.py composes it (the python3 mock is removed).

_cache_key_env() {
	rm -f "${BATS_TEST_TMPDIR}/bin/python3"
	# A fixed path: python normalises the // that TMPDIR may leave in BATS_TEST_TMPDIR.
	export RUNNER_ARCH=X64 PLAYWRIGHT_BROWSERS_PATH=/nonexistent/ms-playwright
}

@test "run-playwright-tests cache-key: installed version, OS release, arch, mode and browsers" {
	_cache_key_env
	mock_command npx "Version 1.56.1"
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" BROWSERS="firefox chromium" bash "$SCRIPT"

	assert_success
	assert_equal "1.56.1" "$(_github_output_value playwright-version)"
	assert_equal "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-chromium-firefox" \
		"$(_github_output_value cache-key)"
	assert_equal "/nonexistent/ms-playwright" "$(_github_output_value cache-path)"
}

@test "run-playwright-tests cache-key: headless-shell mode gets its own key" {
	_cache_key_env
	mock_command npx "Version 1.56.1"
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" BROWSER_INSTALL_MODE=headless-shell bash "$SCRIPT"

	assert_success
	assert_equal "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-headless-shell-chromium" \
		"$(_github_output_value cache-key)"
}

@test "run-playwright-tests cache-key: a package.json range keys nothing (no inexact cache)" {
	_cache_key_env
	cat >"${WORK_DIR}/package.json" <<'EOF'
{
  "devDependencies": {
    "@playwright/test": "^1.49.1"
  }
}
EOF
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" BROWSERS="chromium" bash "$SCRIPT"

	assert_success
	assert_equal "1.49.1" "$(_github_output_value playwright-version)"
	assert_equal "" "$(_github_output_value cache-key)"
	assert_output --partial "the browser cache is skipped"
}

@test "run-playwright-tests cache-key: unknown version keys nothing" {
	_cache_key_env
	cat >"${WORK_DIR}/package.json" <<'EOF'
{
  "name": "no-playwright"
}
EOF
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" BROWSERS="chromium" bash "$SCRIPT"

	assert_success
	assert_equal "unknown" "$(_github_output_value playwright-version)"
	assert_equal "" "$(_github_output_value cache-key)"
}

@test "run-playwright-tests cache-key: browsers inside node_modules key nothing" {
	_cache_key_env
	mock_command npx "Version 1.56.1"
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" PLAYWRIGHT_BROWSERS_PATH=0 bash "$SCRIPT"

	assert_success
	assert_equal "" "$(_github_output_value cache-key)"
	assert_equal "" "$(_github_output_value cache-path)"
}

@test "run-playwright-tests cache-key: an unknown install mode fails" {
	_cache_key_env
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" BROWSER_INSTALL_MODE=shell bash "$SCRIPT"

	assert_failure 2
	assert_output --partial "BROWSER_INSTALL_MODE must be one of: full headless-shell (got 'shell')"
}

@test "run-playwright-tests cache-key: a relative browsers path resolves in the working directory" {
	_cache_key_env
	mock_command npx "Version 1.56.1"
	mkdir -p "${WORK_DIR}/web"
	run env STEP=cache-key WORKING_DIRECTORY="${WORK_DIR}/web" PLAYWRIGHT_BROWSERS_PATH=.pw-browsers \
		bash "$SCRIPT"

	assert_success
	assert_equal "$(_github_output_value cache-path)" "$(cd "${WORK_DIR}/web" && pwd -P)/.pw-browsers"
	assert_equal "$(_github_output_value cache-key)" "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-chromium"
}

_failing_python() {
	printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/python3"
	cp "${BATS_TEST_TMPDIR}/bin/python3" "${BATS_TEST_TMPDIR}/bin/python"
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3" "${BATS_TEST_TMPDIR}/bin/python"
}

@test "run-playwright-tests cache-key: no usable Python skips the cache and the step succeeds" {
	_cache_key_env
	_failing_python
	mock_command npx "Version 1.56.1"
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"

	assert_success
	assert_output --partial "No Python 3.10+"
	assert_equal "$(_github_output_value cache-key)" ""
	assert_equal "$(_github_output_value cache-path)" ""
}

@test "run-playwright-tests cache-key: a failing cache-path empties the key too" {
	_cache_key_env
	local real_python
	real_python="$(PATH="${PATH//${BATS_TEST_TMPDIR}\/bin:/}" command -v python3)"
	printf '#!/usr/bin/env bash\n[[ "$3" == cache-path ]] && exit 1\nexec "%s" "$@"\n' "$real_python" \
		>"${BATS_TEST_TMPDIR}/bin/python3"
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3"
	mock_command npx "Version 1.56.1"
	run env STEP=cache-key WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"

	assert_success
	assert_equal "$(_github_output_value cache-key)" ""
	assert_equal "$(_github_output_value cache-path)" ""
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

# install-browsers minimum @playwright/test on Ubuntu 26.04 (#1313)

_mock_playwright_cli() {
	local version="$1"
	mock_command_record npx "Version ${version}"
}

@test "install-browsers: Ubuntu 26.04 below the minimum fails with found version, minimum and fix" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	_mock_playwright_cli 1.55.0
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::@playwright/test 1.55.0"
	assert_output --partial "1.61 or newer is required"
	assert_output --partial "Bump @playwright/test"
	assert_output --partial "runner-image: ubuntu-24.04"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	refute_output --partial "playwright install"
}

@test "install-browsers: Ubuntu 26.04 at the minimum installs" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	_mock_playwright_cli 1.61.0
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output --partial "playwright install chromium"
}

@test "install-browsers: Ubuntu 26.04 above the minimum installs" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	_mock_playwright_cli 1.70.2
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
}

@test "install-browsers: Ubuntu 24.04 below the minimum still installs" {
	_mock_playwright_cli 1.55.0
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	refute_output --partial "::error::"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output --partial "playwright install chromium"
}

@test "install-browsers: Ubuntu 26.04 with an unresolvable version warns and continues" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	cat >"${BATS_TEST_TMPDIR}/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${BATS_TEST_TMPDIR}/mock_calls_npx"
[[ "$*" == *"--version"* ]] && exit 1
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/npx"
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::Could not resolve the @playwright/test version"
	assert_output --partial "Playwright browser install complete"
}

# install-browsers system packages through the shared apt helper (#1432)

@test "install-browsers: Linux asks Playwright for its packages, then installs browsers" {
	mock_command_record npx
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSERS="chromium firefox" bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	assert_line --index 0 --regexp '^-I .*/apt_helper\.py update$'
	assert_line --index 1 --regexp '^-I .*/playwright_deps\.py --exit-code 0$'
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_line --index 0 "playwright install-deps --dry-run chromium firefox"
	assert_line --index 1 "playwright install chromium firefox"
	refute_output --partial "--with-deps"
}

@test "install-browsers: all passes no browser names" {
	mock_command_record npx
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSERS=all bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_line --index 0 "playwright install-deps --dry-run"
	assert_line --index 1 "playwright install"
}

@test "install-browsers: an apt helper failure fails the step before the browser install" {
	mock_command_record npx
	mock_command_record python3 "::error::apt could not reach a package mirror (DNS or network failure) after all retries" 100
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 100
	assert_output --partial "::error::apt could not reach a package mirror (DNS or network failure) after all retries"
	refute_output --partial "Playwright browser install complete"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output ""
}

@test "install-browsers: Windows keeps install --with-deps and skips the apt helper" {
	mock_command_record npx
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" RUNNER_OS=Windows bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	assert_output ""
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output "playwright install --with-deps chromium"
}

# install-browsers cache hit and system-deps (#1433). The real
# playwright_browsers.py decides; apt_helper.py and playwright_deps.py stay
# recorded by a python3 wrapper. npx answers `install --dry-run` with the
# checked-in Playwright 1.56.1 listing (full chromium: browser, headless shell,
# FFmpeg) under PLAYWRIGHT_BROWSERS_PATH.

DRY_RUN_FIXTURE="${PROJECT_ROOT}/tests/fixtures/playwright-browsers/install-dry-run-chromium.txt"

_install_env() {
	local real_python name
	real_python="$(PATH="${PATH//${BATS_TEST_TMPDIR}\/bin:/}" command -v python3)"
	cat >"${BATS_TEST_TMPDIR}/bin/python3" <<MOCK
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/mock_calls_python3"
case "\$2" in
*/playwright_browsers.py | -c) exec "${real_python}" "\$@" ;;
esac
exit 0
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3"
	export PLAYWRIGHT_BROWSERS_PATH="${BATS_TEST_TMPDIR}/ms-playwright"
	for name in chromium-1194 chromium_headless_shell-1194 ffmpeg-1011; do
		mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}/${name}"
		: >"${PLAYWRIGHT_BROWSERS_PATH}/${name}/INSTALLATION_COMPLETE"
	done
	cat >"${BATS_TEST_TMPDIR}/bin/npx" <<MOCK
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/mock_calls_npx"
if [[ "\$*" == *"install --dry-run"* ]]; then
	sed "s|@ROOT@|\${PLAYWRIGHT_BROWSERS_PATH}|" "${DRY_RUN_FIXTURE}"
fi
exit 0
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/npx"
	: >"${BATS_TEST_TMPDIR}/mock_calls_npx"
}

@test "install-browsers: an exact cache hit with every artifact downloads nothing" {
	_install_env
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_CACHE_HIT=true bash "$SCRIPT"
	assert_success
	assert_output --partial "restored from the cache (exact key), download skipped"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_line "playwright install --dry-run chromium"
	refute_output --regexp 'playwright install( chromium|$)'
}

@test "install-browsers: a cache hit without the headless shell or FFmpeg still downloads" {
	local name
	for name in chromium_headless_shell-1194 ffmpeg-1011; do
		_install_env
		rm -rf "${PLAYWRIGHT_BROWSERS_PATH:?}/${name}"
		run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_CACHE_HIT=true bash "$SCRIPT"
		assert_success
		run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
		assert_line "playwright install chromium"
	done
}

@test "install-browsers: a cache hit with another chromium revision still downloads" {
	_install_env
	mv "${PLAYWRIGHT_BROWSERS_PATH}/chromium-1194" "${PLAYWRIGHT_BROWSERS_PATH}/chromium-1187"
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_CACHE_HIT=true bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_line "playwright install chromium"
}

@test "install-browsers: if-missing on a warm cache runs no apt when the probe passes" {
	_install_env
	# playwright_browsers.py answers present (0) and probe (0: every library
	# resolves); any other python3 call (the apt helper) is only recorded.
	cat >"${BATS_TEST_TMPDIR}/bin/python3" <<MOCK
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/mock_calls_python3"
exit 0
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3"
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_CACHE_HIT=true \
		BROWSER_SYSTEM_DEPS=if-missing bash "$SCRIPT"
	assert_success
	assert_output --partial "system packages present (ldd found every library), apt skipped"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	refute_output --partial "apt_helper.py"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output "playwright install --dry-run chromium"
}

@test "install-browsers: if-missing installs the system packages when the probe cannot decide" {
	_install_env
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_CACHE_HIT=true \
		BROWSER_SYSTEM_DEPS=if-missing bash "$SCRIPT"
	assert_success
	assert_output --partial "probe undecided"
	assert_output --partial "installing the system packages"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	assert_output --regexp 'apt_helper\.py update'
}

@test "install-browsers: if-missing with webkit always installs the system packages" {
	_install_env
	mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}/webkit-2215"
	: >"${PLAYWRIGHT_BROWSERS_PATH}/webkit-2215/INSTALLATION_COMPLETE"
	sed -i.bak "s|${DRY_RUN_FIXTURE}|${PROJECT_ROOT}/tests/fixtures/playwright-browsers/install-dry-run-webkit.txt|" \
		"${BATS_TEST_TMPDIR}/bin/npx"
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSERS=webkit BROWSER_CACHE_HIT=true \
		BROWSER_SYSTEM_DEPS=if-missing bash "$SCRIPT"
	assert_success
	assert_output --partial "download skipped"
	assert_output --partial "probe undecided: webkit loads system libraries with dlopen"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	assert_output --regexp 'apt_helper\.py update'
}

@test "install-browsers: an unknown system-deps value fails before installing" {
	_install_env
	run env STEP=install-browsers WORKING_DIRECTORY="$WORK_DIR" BROWSER_SYSTEM_DEPS=never bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "BROWSER_SYSTEM_DEPS must be one of: always if-missing (got 'never')"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_npx"
	assert_output ""
}
