#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-playwright.sh package-manager
#          dispatch (#1077): @playwright/test is a prerequisite, browsers are
#          installed through the selected manager, bun is never implied.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-playwright.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	# Start every test from clean runner defaults regardless of the CI env.
	unset PROJECT BROWSER REPORTER SHARD EXTRA_ARGS PACKAGE_MANAGER
	mock_command_record bun
	mock_command_record npm
	mock_command_record npx
	mock_command_record pnpm
}

teardown() {
	restore_path
	teardown_temp_dir
}

_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_$1"
}

_github_output_value() {
	grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "run-playwright setup: empty PACKAGE_MANAGER fails with the required-input message" {
	run env STEP=setup PACKAGE_MANAGER="" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
	assert_equal "$(_calls bun)$(_calls npm)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-playwright setup npm: missing @playwright/test fails with an actionable message, no install" {
	mock_command_record npm '{"name":"fixture","dependencies":{}}' 1
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "@playwright/test is not installed"
	assert_output --partial "install @playwright/test as a devDependency"
	assert_equal "$(_calls npm)" "ls --json --depth=0 @playwright/test"
	assert_equal "$(_calls npx)" ""
	assert_equal "$(_calls bun)" ""
}

@test "run-playwright setup npm: installs the selected browser through npx --no-install" {
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.49.1"}}}'
	run env STEP=setup PACKAGE_MANAGER=npm BROWSER=firefox WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx)" "--no-install playwright install --with-deps firefox"
	assert_equal "$(_calls bun)" ""
}

@test "run-playwright setup pnpm: BROWSER=all installs every browser through pnpm exec" {
	mock_command_record pnpm '[{"name":"fixture","devDependencies":{"@playwright/test":{"version":"1.49.1"}}}]'
	run env STEP=setup PACKAGE_MANAGER=pnpm BROWSER=all WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls pnpm
	assert_line --index 0 "ls --json --depth 0 @playwright/test"
	assert_line --index 1 "exec playwright install --with-deps"
}

@test "run-playwright setup bun: present package installs browsers via bun run" {
	cat >"${BATS_TEST_TMPDIR}/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CALLS}"
[[ "$1" == "pm" ]] && printf '%s\n' '/tmp/node_modules (1)' '└── @playwright/test@1.49.1'
exit 0
EOF
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/mock_calls_bun"
	run env STEP=setup PACKAGE_MANAGER=bun WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls bun
	assert_line --index 0 "pm ls"
	assert_line --index 1 "x --no-install playwright install --with-deps chromium"
	# No `bun add` / bare `bun install`: the package is a prerequisite.
	refute_output --partial "add"
	run grep -E '^install' "${MOCK_CALLS}"
	assert_failure
}

@test "run-playwright run npm: executes npx --no-install playwright test with reporter and shard" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=junit SHARD=1/3 WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=junit --shard=1/3"
	assert_equal "$(_calls bun)" ""
	assert_equal "$(_github_output_value exit-code)" "0"
}

@test "run-playwright run bun: executes bun x --no-install playwright" {
	run env STEP=run PACKAGE_MANAGER=bun PROJECT=desktop WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls bun)" "x --no-install playwright test --project=desktop --reporter=json"
}

@test "run-playwright run npm REPORTER=html: one combined reporter flag, missing report dir fails a green run" {
	# The recording npx mock exits 0 without writing playwright-report/.
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=html WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=html,json"
	assert_output --partial "::error title=Playwright HTML report missing::"
	assert_equal "$(_github_output_value exit-code)" "1"
	run grep '^report-path=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "run-playwright run npm REPORTER=html: report dir present passes and is the report-path" {
	cat >"${BATS_TEST_TMPDIR}/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CALLS}"
mkdir -p playwright-report && echo '<html></html>' > playwright-report/index.html
echo '{"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0,"duration":10.4}}' > "${PLAYWRIGHT_JSON_OUTPUT_NAME:?}"
[[ "${PLAYWRIGHT_HTML_OPEN:-}" == "never" ]] || { echo "PLAYWRIGHT_HTML_OPEN not pinned" >&2; exit 9; }
exit 0
EOF
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/mock_calls_npx"
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=html WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	refute_output --partial "HTML report missing"
	assert_equal "$(_github_output_value exit-code)" "0"
	assert_equal "$(_github_output_value report-path)" "playwright-report"
	assert_equal "$(_github_output_value json-report-path)" "playwright-results.json"
}

@test "run-playwright run: warns when extra-args already carries --reporter" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=json EXTRA_ARGS="--reporter=dot" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=reporter::extra-args passes --reporter"
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=json --reporter=dot"
}

@test "run-playwright run REPORTER=html: a failing run with no report keeps Playwright's exit code" {
	mock_command_record npx "" 1
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=html WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Playwright HTML report missing"
	assert_equal "$(_github_output_value exit-code)" "1"
}

@test "run-playwright parse REPORTER=json: malformed report warns and reports zero tests" {
	run env STEP=parse REPORTER=json REPORT_PATH="${FIXTURES_DIR}/playwright/reports/json-malformed.json" bash "$SCRIPT"
	assert_success
	assert_output --partial "Results file is not valid JSON"
	assert_equal "$(_github_output_value tests-total)" "0"
}

@test "run-playwright parse REPORTER=html: reads the JSON sidecar next to the report" {
	cp -R "${FIXTURES_DIR}/playwright/reports/html-sidecar/." "$WORK_DIR/"
	cd "$WORK_DIR"
	run env STEP=parse REPORTER=html REPORT_PATH="playwright-report" bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value tests-passed)" "1"
	assert_equal "$(_github_output_value tests-skipped)" "1"
	assert_equal "$(_github_output_value tests-total)" "2"
}

@test "run-playwright parse REPORTER=junit: reads Playwright's junit reporter output" {
	run env STEP=parse REPORTER=junit REPORT_PATH="${FIXTURES_DIR}/playwright/reports/junit-mixed.xml" bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value tests-passed)" "2"
	assert_equal "$(_github_output_value tests-failed)" "1"
	assert_equal "$(_github_output_value tests-skipped)" "1"
	assert_equal "$(_github_output_value tests-total)" "4"
}

@test "run-playwright run: empty PACKAGE_MANAGER fails before running anything" {
	run env STEP=run PACKAGE_MANAGER="" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_equal "$(_calls bun)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-playwright: no hard-coded bun, bunx, npx or pnpm invocation remains in the script" {
	run grep -nE '^\s*(bun|bunx|npx|pnpm) ' "$SCRIPT"
	assert_failure
	refute_output
}
