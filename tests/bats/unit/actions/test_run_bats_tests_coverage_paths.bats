#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for run-bats-tests.sh kcov include paths and the
#          coverage-on-empty policy (#1373)

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh"
	setup_temp_dir
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_summary"
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
	export SHARD_INDEX=0
	export SHARD_TOTAL=1
	# kcov sees the physical cwd, which can differ from BATS_TEST_TMPDIR (a "//").
	REPO="$(cd "$BATS_TEST_TMPDIR" && pwd)"

	mkdir -p "$BATS_TEST_TMPDIR/scripts/ci/lib" "$BATS_TEST_TMPDIR/tests"
	{
		echo '#!/usr/bin/env bats'
		echo '@test "alpha" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/alpha.bats"

	local mock_bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$mock_bin"
	export PATH="${mock_bin}:${PATH}"
	export KCOV_CALLS="$BATS_TEST_TMPDIR/mock_calls_kcov"
	: >"$KCOV_CALLS"

	# kcov: record argv, write a Cobertura report with MOCK_LINES_VALID
	# lines (when set) into the outdir, then run the wrapped bats command.
	cat >"${mock_bin}/kcov" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${KCOV_CALLS}"
outdir=""
while [[ \$# -gt 0 && "\$1" != "bats" ]]; do
	outdir="\$1"
	shift
done
if [[ -n "\${MOCK_LINES_VALID:-}" ]]; then
	mkdir -p "\$outdir"
	printf '<coverage line-rate="0" lines-covered="0" lines-valid="%s" version="1"></coverage>\n' \
		"\$MOCK_LINES_VALID" >"\$outdir/cov.xml"
fi
exec "\$@"
EOF
	chmod +x "${mock_bin}/kcov"

	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
	case "$1" in
	--signal | --kill-after) shift 2 ;;
	--signal=* | --kill-after=*) shift ;;
	*) break ;;
	esac
done
shift
exec "$@"
EOF
	chmod +x "${mock_bin}/timeout"

	cat >"${mock_bin}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 mocked"
EOF
	chmod +x "${mock_bin}/bats"
}

teardown() {
	teardown_temp_dir
}

run_coverage() {
	(
		cd "$BATS_TEST_TMPDIR" || exit 1
		env "$@" bash "$SCRIPT"
	)
}

@test "run-coverage: default include path is scripts/ci/lib" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run cat "$KCOV_CALLS"
	assert_output --partial "--include-path=${REPO}/scripts/ci/lib "
	assert_output --partial "--bash-parse-files-in-dir=${REPO}/scripts/ci/lib "
}

@test "run-coverage: joins comma-separated paths into one include and one parse list" {
	# kcov keeps only the last --include-path it is given, so several paths
	# must travel as one comma-separated value per option (#1450).
	mkdir -p "$BATS_TEST_TMPDIR/src/shell" "$BATS_TEST_TMPDIR/bin-lib"

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		"COVERAGE_INCLUDE_PATHS=src/shell, ./bin-lib/ ,scripts/ci/lib"

	assert_success
	run cat "$KCOV_CALLS"
	local list="${REPO}/src/shell,${REPO}/bin-lib,${REPO}/scripts/ci/lib"
	assert_output --partial "--include-path=${list} "
	assert_output --partial "--bash-parse-files-in-dir=${list} "
	run grep -o -- "--include-path=" "$KCOV_CALLS"
	assert_output "--include-path="
}

@test "run-coverage: warns on a missing entry when another exists" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		"COVERAGE_INCLUDE_PATHS=nope/lib,scripts/ci/lib"

	assert_success
	assert_output --partial "::warning::coverage-include-path entry not found in the checkout, skipped: nope/lib"
	run cat "$KCOV_CALLS"
	refute_output --partial "nope/lib"
}

@test "run-coverage: fails with ::error:: naming the paths when none exists" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		"COVERAGE_INCLUDE_PATHS=nope/lib,other/lib"

	assert_failure
	assert_output --partial "::error::None of the coverage-include-path entries exist in the checkout (nope/lib other/lib)"
	assert_output --partial "coverage-include-path input"
	[[ ! -s "$KCOV_CALLS" ]]
}

@test "run-coverage: rejects a '..' path segment but accepts names that contain two dots" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		COVERAGE_INCLUDE_PATHS="scripts/ci/lib,../outside"
	assert_failure
	assert_output --partial "without '..' segments, got: ../outside"

	# A name that merely contains two dots passes the traversal check; it then
	# falls through to the existence check like any other missing path.
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		COVERAGE_INCLUDE_PATHS="lib/foo..bar"
	refute_output --partial "without '..' segments"
	assert_output --partial "entry not found in the checkout, skipped: lib/foo..bar"
}

@test "run-coverage: rejects an invalid COVERAGE_ON_EMPTY" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		COVERAGE_ON_EMPTY=ignore

	assert_failure
	assert_output --partial "::error::coverage-on-empty must be 'fail' or 'not-applicable'"
}

@test "run-coverage: zero instrumented lines under fail keeps today's behaviour" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		MOCK_LINES_VALID=0

	assert_success
	refute_output --partial "::notice::Coverage not applicable"
	run grep -c '^coverage-percent=' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "run-coverage: zero instrumented lines under not-applicable writes n/a and a notice" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		MOCK_LINES_VALID=0 COVERAGE_ON_EMPTY=not-applicable

	assert_success
	assert_output --partial "::notice::Coverage not applicable"
	grep -qx 'coverage-percent=n/a' "$GITHUB_OUTPUT"
}

@test "run-coverage: instrumented lines under not-applicable are left alone" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		MOCK_LINES_VALID=12 COVERAGE_ON_EMPTY=not-applicable

	assert_success
	refute_output --partial "Coverage not applicable"
	run grep -c '^coverage-percent=' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "parse-coverage: zero lines gives 0 under fail and n/a under not-applicable" {
	mkdir -p "$BATS_TEST_TMPDIR/coverage-report"
	printf '<coverage line-rate="0" lines-valid="0"></coverage>\n' \
		>"$BATS_TEST_TMPDIR/coverage-report/cov.xml"

	run run_coverage STEP=parse-coverage COVERAGE_DIR=coverage-report
	assert_success
	grep -qx 'coverage-percent=0' "$GITHUB_OUTPUT"

	: >"$GITHUB_OUTPUT"
	run run_coverage STEP=parse-coverage COVERAGE_DIR=coverage-report COVERAGE_ON_EMPTY=not-applicable
	assert_success
	grep -qx 'coverage-percent=n/a' "$GITHUB_OUTPUT"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "Coverage: n/a (no instrumented lines)"
	refute_output --partial "n/a%"
}

@test "check-threshold: n/a skips the gate with a notice" {
	run run_coverage STEP=check-threshold COVERAGE_PERCENT=n/a COVERAGE_THRESHOLD=80

	assert_success
	assert_output --partial "::notice::Coverage threshold skipped: not applicable"
	refute_output --partial "below threshold"
}

@test "check-threshold: N/A (report missing) still fails" {
	run run_coverage STEP=check-threshold COVERAGE_PERCENT=N/A COVERAGE_THRESHOLD=80

	assert_failure
	assert_output --partial "Coverage data not found"
}

@test "check-threshold: numeric coverage below threshold still fails" {
	run run_coverage STEP=check-threshold COVERAGE_PERCENT=10 COVERAGE_THRESHOLD=80

	assert_failure
	assert_output --partial "below threshold"
}

@test "generate-test-summary: n/a renders without percent sign or threshold verdict" {
	run env \
		TESTS_PASSED="3" \
		TESTS_FAILED="0" \
		TESTS_TOTAL="3" \
		COVERAGE_ENABLED="true" \
		COVERAGE_PERCENT="n/a" \
		COVERAGE_THRESHOLD="80" \
		JOB_RESULT="success" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/generate-test-summary.sh"

	assert_success
	assert_output --partial "n/a"
	assert_output --partial "Not applicable: no instrumented lines"
	refute_output --partial "n/a%"
	refute_output --partial "Below target"
	refute_output --partial "Target met"
	refute_output --partial "Unable to retrieve coverage"
}
