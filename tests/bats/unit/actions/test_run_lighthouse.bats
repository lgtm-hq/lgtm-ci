#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-lighthouse.sh package-manager
#          dispatch (#1077): @lhci/cli is a prerequisite (on PATH or in the
#          project tree), nothing is installed, bun is never implied.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-lighthouse.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	cd "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	# Start every test from clean runner defaults regardless of the CI env.
	unset URL CONFIG_PATH OUTPUT_DIR EXTRA_ARGS PACKAGE_MANAGER
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

@test "run-lighthouse setup: empty PACKAGE_MANAGER fails with the required-input message" {
	run env STEP=setup PACKAGE_MANAGER="" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
	assert_equal "$(_calls bun)$(_calls npm)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-lighthouse setup npm: missing @lhci/cli fails with an actionable message, no install" {
	mock_command_record npm '{"name":"fixture","dependencies":{}}' 1
	run env STEP=setup PACKAGE_MANAGER=npm bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "@lhci/cli is not installed"
	assert_output --partial "install @lhci/cli as a devDependency"
	assert_equal "$(_calls npm)" "ls --json --depth=0 @lhci/cli"
	assert_equal "$(_calls bun)" ""
	assert_equal "$(_calls npx)" ""
}

@test "run-lighthouse setup npm: project-installed @lhci/cli is reported through npx --no-install" {
	mock_command_record npm '{"name":"fixture","dependencies":{"@lhci/cli":{"version":"0.14.0"}}}'
	mock_command_record npx "0.14.0"
	run env STEP=setup PACKAGE_MANAGER=npm bash "$SCRIPT"
	assert_success
	assert_output --partial "Lighthouse CI available: 0.14.0"
	assert_equal "$(_calls npx)" "--no-install lhci --version"
}

@test "run-lighthouse setup: lhci already on PATH skips the package lookup" {
	mock_command_record lhci "0.14.0"
	run env STEP=setup PACKAGE_MANAGER=pnpm bash "$SCRIPT"
	assert_success
	assert_output --partial "Lighthouse CI available: 0.14.0"
	assert_equal "$(_calls lhci)" "--version"
	assert_equal "$(_calls pnpm)" ""
}

@test "run-lighthouse run pnpm: executes pnpm exec lhci autorun with the filesystem target" {
	run env STEP=run PACKAGE_MANAGER=pnpm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	run _calls pnpm
	assert_output --partial "exec lhci autorun --upload.target=filesystem --upload.outputDir=${WORK_DIR}/out"
	assert_output --partial "--collect.url=http://localhost:3000"
	assert_equal "$(_calls bun)" ""
}

@test "run-lighthouse run: lhci on PATH is preferred over the package manager" {
	mock_command_record lhci
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	run _calls lhci
	assert_output --partial "autorun"
	assert_equal "$(_calls npx)" ""
}

@test "run-lighthouse run: empty PACKAGE_MANAGER fails before running anything" {
	run env STEP=run PACKAGE_MANAGER="" URL=http://localhost:3000 bash "$SCRIPT"
	assert_failure 2
	assert_equal "$(_calls bun)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-lighthouse run: finds the *.report.json that lhci's filesystem target writes" {
	cat >"${BATS_TEST_TMPDIR}/bin/lhci" <<'EOF'
#!/usr/bin/env bash
out=""
for a in "$@"; do case "$a" in --upload.outputDir=*) out="${a#--upload.outputDir=}" ;; esac; done
mkdir -p "$out"
echo '{"categories":{"performance":{"score":0.91}}}' > "$out/localhost-_-2026_10_06.report.json"
echo '[]' > "$out/manifest.json"
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/lhci"
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	assert_equal "$(grep '^results-path=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "${WORK_DIR}/out/localhost-_-2026_10_06.report.json"
}

@test "run-lighthouse parse: resolves a *.report.json under OUTPUT_DIR and scores it" {
	mkdir -p "${WORK_DIR}/out"
	echo '{"categories":{"performance":{"score":0.91},"accessibility":{"score":1},"best-practices":{"score":0.8},"seo":{"score":0.7}}}' \
		>"${WORK_DIR}/out/site.report.json"
	run env STEP=parse RESULTS_PATH="" OUTPUT_DIR="${WORK_DIR}/out" THRESHOLD_SEO=50 bash "$SCRIPT"
	assert_success
	refute_output --partial "No Lighthouse results found"
	assert_equal "$(grep '^performance=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "91"
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "true"
}

@test "run-lighthouse: no hard-coded bun, bunx, npx or pnpm invocation remains in the script" {
	run grep -nE '^\s*(bun|bunx|npx|pnpm) ' "$SCRIPT"
	assert_failure
	refute_output
}
