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
	unset PROJECT PLAYWRIGHT_BROWSER REPORTER SHARD EXTRA_ARGS PACKAGE_MANAGER
	mock_command_record bun
	mock_command_record npm
	mock_command_record npx
	mock_command_record pnpm
	# System packages go through the apt helper on Linux (#1432); record it
	# instead of running apt.
	export RUNNER_OS=Linux
	mock_command_record python3
	# Never read the host os-release (a 26.04 runner would trigger the #1313 check).
	printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"${BATS_TEST_TMPDIR}/os-release"
	export OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
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
	run env STEP=setup PACKAGE_MANAGER=npm PLAYWRIGHT_BROWSER=firefox WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls npx
	assert_line --index 0 "--no-install playwright install-deps --dry-run firefox"
	assert_line --index 1 "--no-install playwright install firefox"
	assert_equal "$(_calls bun)" ""
	run _calls python3
	assert_line --index 0 --regexp '^-I .*/scripts/ci/lib/testing/\.\./apt_helper\.py update$'
	assert_line --index 1 --regexp '^-I .*/playwright_deps\.py --exit-code 0$'
}

@test "run-playwright setup: off Linux keeps install --with-deps, no apt helper (#1432)" {
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.49.1"}}}'
	run env STEP=setup PACKAGE_MANAGER=npm RUNNER_OS=macOS WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx)" "--no-install playwright install --with-deps chromium"
	assert_equal "$(_calls python3)" ""
}

@test "run-playwright setup: an apt helper failure stops before the browser install (#1432)" {
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.49.1"}}}'
	mock_command_record python3 "::error::apt could not reach a package mirror (DNS or network failure) after all retries" 100
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 100
	assert_output --partial "::error::apt could not reach a package mirror (DNS or network failure) after all retries"
	assert_equal "$(_calls npx)" ""
}

@test "run-playwright setup pnpm: PLAYWRIGHT_BROWSER=all installs every browser through pnpm exec" {
	mock_command_record pnpm '[{"name":"fixture","devDependencies":{"@playwright/test":{"version":"1.49.1"}}}]'
	run env STEP=setup PACKAGE_MANAGER=pnpm PLAYWRIGHT_BROWSER=all WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls pnpm
	assert_line --index 0 "ls --json --depth 0 @playwright/test"
	assert_line --index 1 "exec playwright install-deps --dry-run"
	assert_line --index 2 "exec playwright install"
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
	assert_line --index 1 "x --no-install playwright install-deps --dry-run chromium"
	assert_line --index 2 "x --no-install playwright install chromium"
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

# GitHub expressions read `JUnit` as junit, so the runner must too (#1474):
# before, it fell through to the JSON default.
@test "run-playwright run npm REPORTER=JUnit: runs the junit reporter like junit" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=JUnit SHARD=1/3 WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=junit --shard=1/3"
}

@test "run-playwright run npm REPORTER=HTML: mixed case still writes the JSON sidecar" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=HTML WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=html,json"
}

# Run and parse share playwright_effective_reporter (#1474): a value the run
# maps to JSON must parse as JSON, not as "Cannot parse" zero totals.
@test "run-playwright run npm REPORTER=html,junit: runs JSON and reports the normalised reporter" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER="html,junit" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=json"
	assert_equal "$(_github_output_value reporter)" "json"
}

@test "run-playwright run npm REPORTER=' HTML ': whitespace and case are ignored" {
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=" HTML " WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_equal "$(_calls npx)" "--no-install playwright test --project=chromium --reporter=html,json"
	# The action gates its HTML report upload on this output.
	assert_equal "$(_github_output_value reporter)" "html"
}

@test "run-playwright action: the HTML report upload gates on the normalised reporter" {
	run grep -F "if: steps.run.outputs.reporter == 'html' && always()" \
		"${PROJECT_ROOT}/.github/actions/run-playwright/action.yml"
	assert_success
}

@test "run-playwright parse: reporters the run maps to JSON parse the JSON report" {
	local reporter
	for reporter in "html,junit" " HTML " "Blob" "list"; do
		: >"$GITHUB_OUTPUT"
		run env STEP=parse REPORTER="$reporter" \
			REPORT_PATH="${FIXTURES_DIR}/playwright/reports/json-passing.json" bash "$SCRIPT"
		assert_success
		refute_output --partial "Cannot parse results"
		assert_equal "$(_github_output_value tests-passed)" "1"
		assert_equal "$(_github_output_value tests-skipped)" "1"
	done
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
[[ -z "${PLAYWRIGHT_JSON_OUTPUT_FILE:-}${PLAYWRIGHT_JUNIT_OUTPUT_FILE:-}" ]] || { echo "inherited *_OUTPUT_FILE leaked" >&2; exit 8; }
echo '{"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0,"duration":10.4}}' > "${PLAYWRIGHT_JSON_OUTPUT_NAME:?}"
[[ "${PLAYWRIGHT_HTML_OPEN:-}" == "never" ]] || { echo "PLAYWRIGHT_HTML_OPEN not pinned" >&2; exit 9; }
exit 0
EOF
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/mock_calls_npx"
	# An inherited *_OUTPUT_FILE must not redirect the sidecar (the mock fails
	# on an unset PLAYWRIGHT_JSON_OUTPUT_NAME and writes where NAME points).
	run env STEP=run PACKAGE_MANAGER=npm REPORTER=html WORKING_DIRECTORY="$WORK_DIR" \
		PLAYWRIGHT_JSON_OUTPUT_FILE=/tmp/elsewhere.json PLAYWRIGHT_JUNIT_OUTPUT_FILE=/tmp/elsewhere.xml \
		bash "$SCRIPT"
	assert_success
	refute_output --partial "HTML report missing"
	assert_file_exists "${WORK_DIR}/playwright-results.json"
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
	assert_equal "$(_github_output_value tests-passed)" "0"
	assert_equal "$(_github_output_value tests-failed)" "0"
	assert_equal "$(_github_output_value tests-skipped)" "0"
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

@test "run-playwright setup: Ubuntu 26.04 with @playwright/test below the minimum fails before install (#1313)" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.55.0"}}}'
	mock_command_record npx "Version 1.55.0"
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error::@playwright/test 1.55.0"
	assert_output --partial "1.61"
	assert_output --partial "runner-image: ubuntu-24.04"
	run _calls npx
	refute_output --partial "playwright install"
}

@test "run-playwright setup: Ubuntu 26.04 with an unresolvable version warns and still installs (#1313)" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.61.0"}}}'
	mock_command_record npx ""
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning::Could not resolve the @playwright/test version"
	run _calls npx
	assert_output --partial "playwright install chromium"
}

@test "run-playwright setup: Ubuntu 26.04 with @playwright/test at the minimum installs (#1313)" {
	printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$OS_RELEASE_FILE"
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.61.0"}}}'
	mock_command_record npx "Version 1.61.0"
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls npx
	assert_output --partial "playwright install chromium"
}

# Browser cache and install options (#1433). The real playwright_browsers.py
# runs (the python3 mock is removed); apt never runs because these cases are
# off Linux or never reach it.

_real_browsers_py() {
	rm -f "${BATS_TEST_TMPDIR}/bin/python3"
	export RUNNER_ARCH=X64 PLAYWRIGHT_BROWSERS_PATH=/nonexistent/ms-playwright
}

@test "run-playwright cache-key npm: key from the installed version through the package manager" {
	_real_browsers_py
	mock_command_record npx "Version 1.56.1"
	run env STEP=cache-key PACKAGE_MANAGER=npm PLAYWRIGHT_BROWSER=webkit WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value cache-key)" "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-webkit"
	assert_equal "$(_github_output_value cache-path)" "/nonexistent/ms-playwright"
	assert_equal "$(_calls npx)" "--no-install playwright --version"
}

@test "run-playwright cache-key: no installed Playwright means no cache" {
	_real_browsers_py
	mock_command_record npx "" 1
	run env STEP=cache-key PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value cache-key)" ""
	assert_output --partial "the browser cache is skipped"
}

@test "run-playwright cache-key: an unknown install mode fails the step" {
	_real_browsers_py
	run env STEP=cache-key PACKAGE_MANAGER=npm BROWSER_INSTALL_MODE=tiny WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "BROWSER_INSTALL_MODE must be one of: full headless-shell"
}

# npx answers `install --dry-run` with the headless shell and FFmpeg under
# PLAYWRIGHT_BROWSERS_PATH, as Playwright 1.56.1 lists them for
# `install --dry-run --only-shell chromium`.
_shell_cache() {
	local name
	export PLAYWRIGHT_BROWSERS_PATH="${BATS_TEST_TMPDIR}/ms-playwright"
	for name in chromium_headless_shell-1194 ffmpeg-1011; do
		mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}/${name}"
		: >"${PLAYWRIGHT_BROWSERS_PATH}/${name}/INSTALLATION_COMPLETE"
	done
	cat >"${BATS_TEST_TMPDIR}/bin/npx" <<MOCK
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/mock_calls_npx"
if [[ "\$*" == *"install --dry-run"* ]]; then
	printf 'browser: chromium-headless-shell version 141.0\\n  Install location:    %s\\n\\n' \\
		"\${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-1194"
	printf 'browser: ffmpeg\\n  Install location:    %s\\n' "\${PLAYWRIGHT_BROWSERS_PATH}/ffmpeg-1011"
fi
exit 0
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/npx"
	: >"${BATS_TEST_TMPDIR}/mock_calls_npx"
	mock_command_record npm '{"name":"fixture","dependencies":{"@playwright/test":{"version":"1.56.1"}}}'
}

@test "run-playwright setup: an exact cache hit with every artifact on disk downloads nothing" {
	_real_browsers_py
	_shell_cache
	run env STEP=setup PACKAGE_MANAGER=npm RUNNER_OS=macOS BROWSER_CACHE_HIT=true \
		BROWSER_INSTALL_MODE=headless-shell WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "download skipped"
	assert_equal "$(_calls npx)" "--no-install playwright install --dry-run --only-shell chromium"
}

@test "run-playwright setup: an exact cache hit without FFmpeg downloads again" {
	_real_browsers_py
	_shell_cache
	rm -rf "${PLAYWRIGHT_BROWSERS_PATH:?}/ffmpeg-1011"
	run env STEP=setup PACKAGE_MANAGER=npm RUNNER_OS=macOS BROWSER_CACHE_HIT=true \
		BROWSER_INSTALL_MODE=headless-shell WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx | tail -n 1)" "--no-install playwright install --with-deps --only-shell chromium"
}

@test "run-playwright setup: a Windows cache hit keeps Playwright's install-deps" {
	_real_browsers_py
	_shell_cache
	run env STEP=setup PACKAGE_MANAGER=npm RUNNER_OS=Windows BROWSER_CACHE_HIT=true \
		BROWSER_INSTALL_MODE=headless-shell WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx | tail -n 1)" "--no-install playwright install-deps chromium"
}

@test "run-playwright cache-key: no usable Python skips the cache and the step succeeds" {
	_real_browsers_py
	printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/python3"
	cp "${BATS_TEST_TMPDIR}/bin/python3" "${BATS_TEST_TMPDIR}/bin/python"
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3" "${BATS_TEST_TMPDIR}/bin/python"
	mock_command_record npx "Version 1.56.1"
	run env STEP=cache-key PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "No Python 3.10+"
	assert_equal "$(_github_output_value cache-key)" ""
	assert_equal "$(_github_output_value cache-path)" ""
}

@test "run-playwright cache-key: a relative browsers path resolves in the working directory" {
	_real_browsers_py
	mock_command_record npx "Version 1.56.1"
	mkdir -p "${WORK_DIR}/web"
	run env STEP=cache-key PACKAGE_MANAGER=npm WORKING_DIRECTORY="${WORK_DIR}/web" \
		PLAYWRIGHT_BROWSERS_PATH=../pw bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value cache-path)" "$(cd "$WORK_DIR" && pwd -P)/pw"
}

@test "run-playwright action: exact-key browser cache restore feeds the setup step" {
	local action="${PROJECT_ROOT}/.github/actions/run-playwright/action.yml"
	# Restore and save are split (#1659); the save condition is pinned in
	# tests/bats/contract/test_playwright_browser_cache.bats.
	run grep -F 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' "$action"
	assert_success
	run grep -F 'key: ${{ steps.browser-cache-key.outputs.cache-key }}' "$action"
	assert_success
	run grep -F "if: steps.browser-cache-key.outputs.cache-key != ''" "$action"
	assert_success
	run grep -F 'BROWSER_CACHE_HIT: ${{ steps.browser-cache.outputs.cache-hit }}' "$action"
	assert_success
	run grep -E '^ +restore-keys:' "$action"
	assert_failure
	run grep -F 'default: "always"' "$action"
	assert_success
}
