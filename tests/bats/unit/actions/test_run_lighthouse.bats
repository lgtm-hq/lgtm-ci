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

@test "run-lighthouse run: ignores a stale report left in OUTPUT_DIR by an earlier audit" {
	mkdir -p "${WORK_DIR}/out"
	echo '{"categories":{"performance":{"score":1}}}' >"${WORK_DIR}/out/aaa-old.report.json"
	touch -t 202001010000 "${WORK_DIR}/out/aaa-old.report.json"
	cat >"${BATS_TEST_TMPDIR}/bin/lhci" <<'EOF'
#!/usr/bin/env bash
out=""
for a in "$@"; do case "$a" in --upload.outputDir=*) out="${a#--upload.outputDir=}" ;; esac; done
echo '{"categories":{"performance":{"score":0.2}}}' > "$out/zzz-new.report.json"
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/lhci"
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	assert_equal "$(grep '^results-path=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "${WORK_DIR}/out/zzz-new.report.json"
}

@test "run-lighthouse run: no report written after the audit yields an empty results-path" {
	mkdir -p "${WORK_DIR}/out"
	echo '{}' >"${WORK_DIR}/out/stale.report.json"
	touch -t 202001010000 "${WORK_DIR}/out/stale.report.json"
	mock_command_record lhci
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	run grep '^results-path=' "$GITHUB_OUTPUT"
	assert_failure
}

@test "run-lighthouse parse: with RUN_MARKER a stale passing report does not count" {
	mkdir -p "${WORK_DIR}/out"
	echo '{"categories":{"performance":{"score":1},"accessibility":{"score":1},"best-practices":{"score":1},"seo":{"score":1}}}' \
		>"${WORK_DIR}/out/stale.report.json"
	touch -t 202001010000 "${WORK_DIR}/out/stale.report.json"
	marker="${BATS_TEST_TMPDIR}/marker"
	: >"$marker"
	run env STEP=parse RESULTS_PATH="" RUN_MARKER="$marker" OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_failure
	assert_output --partial "No Lighthouse results found"
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "false"
}

@test "run-lighthouse parse: a missing RUN_MARKER disables fallback discovery" {
	mkdir -p "${WORK_DIR}/out"
	echo '{"categories":{"performance":{"score":1}}}' >"${WORK_DIR}/out/stale.report.json"
	run env STEP=parse RESULTS_PATH="" RUN_MARKER="${BATS_TEST_TMPDIR}/gone" OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_failure
	assert_output --partial "Run marker not found"
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "false"
}

@test "run-lighthouse run: publishes the run marker for the parse step" {
	mock_command_record lhci
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	marker="$(grep '^run-marker=' "$GITHUB_OUTPUT" | cut -d= -f2-)"
	test -f "$marker"
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

# LHCI filesystem-upload layout (#1088): <slug>-<timestamp>.report.{json,html}
# per run plus a manifest.json whose entries carry absolute jsonPath/htmlPath,
# isRepresentativeRun and a 0-1 score summary. Shape copied from a real
# `lhci autorun --upload.target=filesystem` artifact.
# Usage: _lhci_report <dir> <name> <perf> <a11y> <bp> <seo>   (0-1 scores)
_lhci_report() {
	local dir="$1" name="$2"
	mkdir -p "$dir"
	jq -n --argjson p "$3" --argjson a "$4" --argjson b "$5" --argjson s "$6" \
		'{lighthouseVersion: "12.0.0", categories: {performance: {score: $p},
		accessibility: {score: $a}, "best-practices": {score: $b}, seo: {score: $s}}}' \
		>"$dir/$name.report.json"
	echo '<html></html>' >"$dir/$name.report.html"
}

# Usage: _lhci_manifest <dir> <representative-name> <name>...
_lhci_manifest() {
	local dir="$1" rep="$2" name
	shift 2
	for name in "$@"; do
		jq -n --arg d "$dir" --arg n "$name" --argjson r "$([[ "$name" == "$rep" ]] && echo true || echo false)" \
			'{url: "http://127.0.0.1:8080/", isRepresentativeRun: $r,
			htmlPath: "\($d)/\($n).report.html", jsonPath: "\($d)/\($n).report.json",
			summary: {performance: 1, accessibility: 1, "best-practices": 1, seo: 1}}'
	done | jq -s . >"$dir/manifest.json"
}

@test "run-lighthouse run: picks the manifest's representative run, not the newest report (#1088)" {
	cat >"${BATS_TEST_TMPDIR}/bin/lhci" <<EOF
#!/usr/bin/env bash
out=""
for a in "\$@"; do case "\$a" in --upload.outputDir=*) out="\${a#--upload.outputDir=}" ;; esac; done
source "${BATS_TEST_TMPDIR}/layout.sh"
_lhci_report "\$out" 127_0_0_1--2026_10_04_15_09_20 0.40 1 1 1
_lhci_report "\$out" 127_0_0_1--2026_10_04_15_09_24 0.86 1 0.96 1
_lhci_report "\$out" 127_0_0_1--2026_10_04_15_09_28 0.20 1 1 1
_lhci_manifest "\$out" 127_0_0_1--2026_10_04_15_09_24 \\
	127_0_0_1--2026_10_04_15_09_20 127_0_0_1--2026_10_04_15_09_24 127_0_0_1--2026_10_04_15_09_28
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/lhci"
	declare -f _lhci_report _lhci_manifest >"${BATS_TEST_TMPDIR}/layout.sh"
	run env STEP=run PACKAGE_MANAGER=npm URL=http://127.0.0.1:8080/ OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	assert_equal "$(grep '^results-path=' "$GITHUB_OUTPUT" | cut -d= -f2-)" \
		"${WORK_DIR}/out/127_0_0_1--2026_10_04_15_09_24.report.json"
}

@test "run-lighthouse parse: scores the representative report of an LHCI filesystem layout (#1088)" {
	out="${WORK_DIR}/lighthouse-reports"
	_lhci_report "$out" 127_0_0_1--2026_10_04_15_09_20 0.40 1 1 1
	_lhci_report "$out" 127_0_0_1--2026_10_04_15_09_24 0.86 1 0.96 1
	_lhci_manifest "$out" 127_0_0_1--2026_10_04_15_09_24 \
		127_0_0_1--2026_10_04_15_09_20 127_0_0_1--2026_10_04_15_09_24
	touch "$out/127_0_0_1--2026_10_04_15_09_20.report.json"
	run env STEP=parse RESULTS_PATH="" OUTPUT_DIR="$out" \
		THRESHOLD_PERFORMANCE=50 THRESHOLD_ACCESSIBILITY=50 THRESHOLD_BEST_PRACTICES=50 THRESHOLD_SEO=50 \
		bash "$SCRIPT"
	assert_success
	assert_equal "$(grep '^performance=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "86"
	assert_equal "$(grep '^best-practices=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "96"
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "true"
}

@test "run-lighthouse parse: a manifest moved with its reports resolves jsonPath by name (#1088)" {
	out="${WORK_DIR}/downloaded"
	_lhci_report "$out" 127_0_0_1--2026_10_04_15_09_24 0.86 1 0.96 1
	# Written on the runner, then downloaded elsewhere: jsonPath no longer exists.
	_lhci_manifest "$out" 127_0_0_1--2026_10_04_15_09_24 127_0_0_1--2026_10_04_15_09_24
	jq '.[].jsonPath |= sub("^.*/"; "/home/runner/work/x/x/lighthouse-reports/")' \
		"$out/manifest.json" >"$out/manifest.tmp" && mv "$out/manifest.tmp" "$out/manifest.json"
	run env STEP=parse RESULTS_PATH="" OUTPUT_DIR="$out" THRESHOLD_SEO=50 bash "$SCRIPT"
	assert_success
	assert_equal "$(grep '^performance=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "86"
}

@test "run-lighthouse parse: a manifest older than RUN_MARKER is ignored (#1088)" {
	out="${WORK_DIR}/out"
	_lhci_report "$out" old 1 1 1 1
	_lhci_manifest "$out" old old
	touch -t 202001010000 "$out/manifest.json" "$out/old.report.json"
	marker="${BATS_TEST_TMPDIR}/marker"
	: >"$marker"
	run env STEP=parse RESULTS_PATH="" RUN_MARKER="$marker" OUTPUT_DIR="$out" bash "$SCRIPT"
	assert_failure
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "false"
}

@test "run-lighthouse parse: no report fails with an annotation instead of zero scores (#1088)" {
	mkdir -p "${WORK_DIR}/out"
	run env STEP=parse RESULTS_PATH="" OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error title=No Lighthouse report::"
	assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "false"
}

@test "run-lighthouse parse: passed=false always names the failed categories (#1088)" {
	out="${WORK_DIR}/out"
	local scores
	for scores in "0.1 1 1 1" "1 0.1 1 1" "1 1 0.1 1" "1 1 1 0.1" "0 0 0 0"; do
		rm -rf "$out"
		: >"$GITHUB_OUTPUT"
		# shellcheck disable=SC2086 # four scores, split on purpose
		_lhci_report "$out" site $scores
		_lhci_manifest "$out" site site
		run env STEP=parse RESULTS_PATH="" OUTPUT_DIR="$out" bash "$SCRIPT"
		assert_success
		assert_equal "$(grep '^passed=' "$GITHUB_OUTPUT" | cut -d= -f2-)" "false"
		[[ -n "$(grep '^failed-categories=' "$GITHUB_OUTPUT" | cut -d= -f2-)" ]] ||
			fail "passed=false without failed-categories for scores: $scores"
	done
}

@test "run-lighthouse action: Check result still runs after a failed parse" {
	run sed -n '/name: Check result/,/shell: bash/p' "${PROJECT_ROOT}/.github/actions/run-lighthouse/action.yml"
	assert_output --partial '!cancelled()'
}

@test "run-lighthouse: no hard-coded bun, bunx, npx or pnpm invocation remains in the script" {
	run grep -nE '^\s*(bun|bunx|npx|pnpm) ' "$SCRIPT"
	assert_failure
	refute_output
}
