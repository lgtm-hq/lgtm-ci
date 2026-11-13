#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-bats-tests.sh (run-coverage)

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh"
	setup_temp_dir
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
	# Pin shard env so these tests stay valid when this file itself is
	# collected by a sharded kcov job (ci.yml coverage-shards: 8). Tests
	# that exercise sharding pass SHARD_* via env and override this.
	export SHARD_INDEX=0
	export SHARD_TOTAL=1
	# Pin the run identity shard manifests record and the aggregate checks
	# (#1531), so the real values of a CI run do not leak in.
	export GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=2 GITHUB_SHA=abc123

	mkdir -p "$BATS_TEST_TMPDIR/scripts/ci/lib"
	mkdir -p "$BATS_TEST_TMPDIR/tests"
	# Write fixture .bats via echo so the parent file's bats gather does not
	# treat embedded @test lines in a heredoc as real tests.
	{
		echo '#!/usr/bin/env bats'
		echo '@test "alpha" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/alpha.bats"
	{
		echo '#!/usr/bin/env bats'
		echo '@test "beta" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/beta.bats"

	local mock_bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$mock_bin"
	export PATH="${mock_bin}:${PATH}"
	export MOCK_BIN="$mock_bin"
	export BATS_CALLS="$BATS_TEST_TMPDIR/mock_calls_bats"
	: >"$BATS_CALLS"

	# kcov: skip options/outdir and exec the wrapped command (bats ...)
	cat >"${mock_bin}/kcov" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != "bats" ]]; do
	shift
done
if [[ $# -eq 0 ]]; then
	echo "mock kcov: expected bats command" >&2
	exit 1
fi
exec "$@"
EOF
	chmod +x "${mock_bin}/kcov"

	# timeout: honor --signal / --kill-after / duration; optional TIMEOUT_MOCK_EXIT=124
	export TIMEOUT_CALLS="$BATS_TEST_TMPDIR/mock_calls_timeout"
	: >"$TIMEOUT_CALLS"
	cat >"${mock_bin}/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TIMEOUT_CALLS}"
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	--signal|--kill-after)
		shift 2
		;;
	--signal=*|--kill-after=*)
		shift
		;;
	*)
		break
		;;
	esac
done
# duration (e.g. 40m)
shift
if [[ "\${TIMEOUT_MOCK_EXIT:-}" == "124" ]]; then
	exit 124
fi
exec "\$@"
EOF
	chmod +x "${mock_bin}/timeout"

	cat >"${mock_bin}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
echo "1..1"
echo "ok 1 mocked \$*"
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

@test "run-coverage: emits coverage-plan and suite timing lines" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	assert_output --partial "coverage-plan shard=0/1 file=tests/alpha.bats"
	assert_output --partial "coverage-plan shard=0/1 file=tests/beta.bats"
	assert_output --partial "coverage-start suite files=2"
	assert_output --partial "coverage-finish suite"
	assert_output --partial "elapsed="
}

@test "run-coverage: timeout path emits ::error:: for the suite" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		TIMEOUT_MOCK_EXIT=124 \
		KCOV_SUITE_TIMEOUT_MINUTES=3

	assert_failure 124
	assert_output --partial "::error::kcov/BATS timed out after 3m"
}

@test "run-coverage: passes --kill-after to timeout(1)" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	grep -q -- '--kill-after=30s' "$TIMEOUT_CALLS"
	grep -q -- '--signal=TERM' "$TIMEOUT_CALLS"
}

@test "run-coverage: serializes under kcov when PARALLEL > 1" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=4

	assert_success
	assert_output --partial "Serializing BATS under kcov (PARALLEL=4 ignored"
	# bats must not receive --jobs
	if grep -q -- '--jobs' "$BATS_CALLS"; then
		echo "unexpected --jobs in bats calls:" >&2
		cat "$BATS_CALLS" >&2
		return 1
	fi
	# both files still invoked in one bats call
	grep -q 'alpha.bats' "$BATS_CALLS"
	grep -q 'beta.bats' "$BATS_CALLS"
}

@test "run-coverage: uses absolute COVERAGE_DIR for kcov outdir" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	run grep '^coverage-dir=' "$GITHUB_OUTPUT"
	assert_success
	[[ "$output" == coverage-dir=/* ]]
}

@test "run-coverage: wraps bats output in a stop-commands guard" {
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 fixture"
echo "::error::fake annotation from a passing test"
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	assert_output --partial "::stop-commands::lgtm-ci-bats-"
	assert_output --partial "::error::fake annotation from a passing test"
	# Resume token is `::<token>::` matching the stop-commands token.
	local token
	token="$(printf '%s\n' "$output" | sed -n 's/^::stop-commands::\(lgtm-ci-bats-[0-9][0-9]*\)$/\1/p' | head -n 1)"
	[ -n "$token" ]
	assert_output --partial "::${token}::"
	# Fixture command sits between the guard markers.
	local stop_line fake_line resume_line
	stop_line="$(printf '%s\n' "$output" | grep -nF "::stop-commands::${token}" | head -n 1 | cut -d: -f1)"
	fake_line="$(printf '%s\n' "$output" | grep -nF "::error::fake annotation from a passing test" | head -n 1 | cut -d: -f1)"
	resume_line="$(printf '%s\n' "$output" | grep -nF "::${token}::" | head -n 1 | cut -d: -f1)"
	[ "$stop_line" -lt "$fake_line" ]
	[ "$fake_line" -lt "$resume_line" ]
}

@test "run-coverage: timeout ::error:: is emitted after the output guard" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		TIMEOUT_MOCK_EXIT=124 \
		KCOV_SUITE_TIMEOUT_MINUTES=3

	assert_failure 124
	local token
	token="$(printf '%s\n' "$output" | sed -n 's/^::stop-commands::\(lgtm-ci-bats-[0-9][0-9]*\)$/\1/p' | head -n 1)"
	[ -n "$token" ]
	local resume_line error_line
	resume_line="$(printf '%s\n' "$output" | grep -nF "::${token}::" | head -n 1 | cut -d: -f1)"
	error_line="$(printf '%s\n' "$output" | grep -nF "::error::kcov/BATS timed out after 3m" | head -n 1 | cut -d: -f1)"
	[ "$resume_line" -lt "$error_line" ]
}

@test "run-coverage: filters cosmetic kcov LINENO errors and keeps real ones" {
	cat >"${MOCK_BIN}/kcov" <<'EOF'
#!/usr/bin/env bash
echo 'kcov: error: ${LINENO} is not an integer'
echo 'kcov: error: ${LINENO} is not an integer (with suffix)'
echo 'kcov: error: genuine parse failure'
while [[ $# -gt 0 && "$1" != "bats" ]]; do
	shift
done
exec "$@"
EOF
	chmod +x "${MOCK_BIN}/kcov"

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	refute_output --partial $'kcov: error: ${LINENO} is not an integer\n'
	assert_output --partial 'kcov: error: ${LINENO} is not an integer (with suffix)'
	assert_output --partial 'kcov: error: genuine parse failure'
}

@test "run-tests: wraps bats output in a stop-commands guard" {
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 fixture"
echo "::error::fake annotation from a passing test"
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests \
		PARALLEL=1

	assert_success
	assert_output --partial "::stop-commands::lgtm-ci-bats-"
	assert_output --partial "::error::fake annotation from a passing test"
	local token stop_line fake_line resume_line
	token="$(printf '%s\n' "$output" | sed -n 's/^::stop-commands::\(lgtm-ci-bats-[0-9][0-9]*\)$/\1/p' | head -n 1)"
	[ -n "$token" ]
	stop_line="$(printf '%s\n' "$output" | grep -nF "::stop-commands::${token}" | head -n 1 | cut -d: -f1)"
	fake_line="$(printf '%s\n' "$output" | grep -nF "::error::fake annotation from a passing test" | head -n 1 | cut -d: -f1)"
	resume_line="$(printf '%s\n' "$output" | grep -nF "::${token}::" | head -n 1 | cut -d: -f1)"
	[ "$stop_line" -lt "$fake_line" ]
	[ "$fake_line" -lt "$resume_line" ]
}

@test "run-tests: still honors PARALLEL --jobs when not under kcov" {
	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests \
		PARALLEL=4

	assert_success
	grep -q -- '--jobs 4' "$BATS_CALLS"
}

# =============================================================================
# Coverage sharding (#874)
# =============================================================================

_shard_of() {
	local test_file="$1"
	local total="$2"
	echo $(($(printf '%s' "$test_file" | cksum | cut -d' ' -f1) % total))
}

@test "run-coverage: SHARD_TOTAL=1 keeps both files and logs shard=0/1" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=0 \
		SHARD_TOTAL=1

	assert_success
	assert_output --partial "coverage-plan shard=0/1 file=tests/alpha.bats"
	assert_output --partial "coverage-plan shard=0/1 file=tests/beta.bats"
	grep -q 'alpha.bats' "$BATS_CALLS"
	grep -q 'beta.bats' "$BATS_CALLS"
}

@test "run-coverage: shard filter partitions files (union is all, disjoint)" {
	{
		echo '#!/usr/bin/env bats'
		echo '@test "gamma" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/gamma.bats"
	{
		echo '#!/usr/bin/env bats'
		echo '@test "delta" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/delta.bats"
	{
		echo '#!/usr/bin/env bats'
		echo '@test "epsilon" { true; }'
	} >"$BATS_TEST_TMPDIR/tests/epsilon.bats"

	local all_files="tests/alpha.bats tests/beta.bats tests/delta.bats tests/epsilon.bats tests/gamma.bats"
	local file shard0 shard1 shard2
	: >"$BATS_TEST_TMPDIR/seen0"
	: >"$BATS_TEST_TMPDIR/seen1"
	: >"$BATS_TEST_TMPDIR/seen2"

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=0 \
		SHARD_TOTAL=3
	assert_success
	printf '%s\n' "$output" | sed -n 's/^coverage-plan shard=0\/3 file=//p' | LC_ALL=C sort >"$BATS_TEST_TMPDIR/seen0"

	: >"$BATS_CALLS"
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=1 \
		SHARD_TOTAL=3
	assert_success
	printf '%s\n' "$output" | sed -n 's/^coverage-plan shard=1\/3 file=//p' | LC_ALL=C sort >"$BATS_TEST_TMPDIR/seen1"

	: >"$BATS_CALLS"
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=2 \
		SHARD_TOTAL=3
	assert_success
	printf '%s\n' "$output" | sed -n 's/^coverage-plan shard=2\/3 file=//p' | LC_ALL=C sort >"$BATS_TEST_TMPDIR/seen2"

	# Union of shards equals the full sorted file list.
	sort -u "$BATS_TEST_TMPDIR/seen0" "$BATS_TEST_TMPDIR/seen1" "$BATS_TEST_TMPDIR/seen2" >"$BATS_TEST_TMPDIR/union"
	printf '%s\n' $all_files | LC_ALL=C sort >"$BATS_TEST_TMPDIR/expected"
	diff -u "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/union"

	# Disjoint: no file in more than one shard.
	local overlap
	overlap="$(comm -12 "$BATS_TEST_TMPDIR/seen0" "$BATS_TEST_TMPDIR/seen1")"
	assert_equal "" "$overlap"
	overlap="$(comm -12 "$BATS_TEST_TMPDIR/seen0" "$BATS_TEST_TMPDIR/seen2")"
	assert_equal "" "$overlap"
	overlap="$(comm -12 "$BATS_TEST_TMPDIR/seen1" "$BATS_TEST_TMPDIR/seen2")"
	assert_equal "" "$overlap"

	# Matches cksum % 3.
	for file in $all_files; do
		local expected_shard
		expected_shard="$(_shard_of "$file" 3)"
		grep -qxF "$file" "$BATS_TEST_TMPDIR/seen${expected_shard}"
	done
}

@test "run-coverage: shard assignment is stable across two invocations" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=0 \
		SHARD_TOTAL=2
	assert_success
	local first
	first="$(printf '%s\n' "$output" | grep '^coverage-plan shard=')"

	: >"$BATS_CALLS"
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=0 \
		SHARD_TOTAL=2
	assert_success
	local second
	second="$(printf '%s\n' "$output" | grep '^coverage-plan shard=')"
	assert_equal "$first" "$second"
}

@test "run-coverage: invalid SHARD_INDEX/SHARD_TOTAL warn and fall back to 0/1" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX=9 \
		SHARD_TOTAL=2

	assert_success
	assert_output --partial "::warning::SHARD_INDEX='9' SHARD_TOTAL='2' is invalid"
	assert_output --partial "coverage-plan shard=0/1 file=tests/alpha.bats"
	assert_output --partial "coverage-plan shard=0/1 file=tests/beta.bats"
}

@test "run-coverage: empty shard exits 0 with a 1..0 TAP and marker and does not error" {
	local only="tests/alpha.bats"
	local other_index
	other_index=$((1 - $(_shard_of "$only" 2)))

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		SHARD_INDEX="$other_index" \
		SHARD_TOTAL=2

	assert_success
	assert_output --partial "coverage-plan shard=${other_index}/2 empty"
	refute_output --partial "No .bats files found"
	[[ -s "$BATS_TEST_TMPDIR/bats-output.tap" ]]
	run head -n 1 "$BATS_TEST_TMPDIR/bats-output.tap"
	assert_output "1..0"
	run grep -F "# shard ${other_index}/2: no test files assigned" "$BATS_TEST_TMPDIR/bats-output.tap"
	assert_success
	[[ -f "$BATS_TEST_TMPDIR/coverage-report/EMPTY_SHARD" ]]
	run cat "$BATS_TEST_TMPDIR/coverage-report/EMPTY_SHARD"
	assert_output "shard=${other_index}/2"
	# kcov/bats must not have been invoked
	[[ ! -s "$BATS_CALLS" ]]
}

# =============================================================================
# Empty suites (bats 1.14 exits 1 when no test is found)
# =============================================================================

# Mock bats whose --help advertises --allow-empty-suite, like bats >= 1.14.
_mock_bats_with_allow_empty_suite() {
	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--help" ]]; then
	echo "  --allow-empty-suite       Exit with code 0 when no tests are found."
	exit 0
fi
echo "1..1"
echo "ok 1 mocked \$*"
EOF
	chmod +x "${MOCK_BIN}/bats"
}

@test "run-tests: passes --allow-empty-suite when bats supports it" {
	_mock_bats_with_allow_empty_suite

	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests

	assert_success
	grep -q -- '--tap --allow-empty-suite tests$' "$BATS_CALLS"
}

@test "run-coverage: passes --allow-empty-suite when bats supports it" {
	_mock_bats_with_allow_empty_suite

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		TEST_FILTER=alpha

	assert_success
	grep -q -- '--tap --filter alpha --allow-empty-suite ' "$BATS_CALLS"
}

@test "run-tests/run-coverage: omit --allow-empty-suite when bats lacks it" {
	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests
	assert_success

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report
	assert_success

	run grep -c -- '--allow-empty-suite' "$BATS_CALLS"
	assert_output "0"
}

# Mock bats >= 1.14 with an empty suite: exit 1 unless --allow-empty-suite.
_mock_bats_empty_suite() {
	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--help" ]]; then
	echo "  --allow-empty-suite       Exit with code 0 when no tests are found."
	exit 0
fi
echo "1..0"
for arg in "\$@"; do
	[[ "\$arg" == "--allow-empty-suite" ]] && exit 0
done
echo "ERROR: Found no tests. (Try \\\`--allow-empty-suite\\\`?)" >&2
exit 1
EOF
	chmod +x "${MOCK_BIN}/bats"
}

@test "run-tests: a TEST_FILTER that matches no test still succeeds" {
	_mock_bats_empty_suite

	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests \
		TEST_FILTER=no-test-matches-this

	assert_success
	refute_output --partial "Found no tests"
	grep -qx 'exit-code=0' "$GITHUB_OUTPUT"
}

@test "run-coverage: a shard whose files match no TEST_FILTER test still succeeds" {
	_mock_bats_empty_suite

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		TEST_FILTER=no-test-matches-this

	assert_success
	refute_output --partial "Found no tests"
	grep -qx 'exit-code=0' "$GITHUB_OUTPUT"
}

@test "run-coverage: real bats passes when TEST_FILTER matches no test in its files" {
	# A sharded filtered run hands bats files with no matching test whenever
	# the matches hash to another shard. Use the installed bats; older bats
	# without the flag passed empty suites anyway, so it proves nothing there.
	rm "${MOCK_BIN}/bats"
	if ! bats --help 2>/dev/null | grep -q -- '--allow-empty-suite'; then
		skip "installed bats has no --allow-empty-suite"
	fi

	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		TEST_FILTER=no-test-matches-this

	assert_success
	grep -qx 'exit-code=0' "$GITHUB_OUTPUT"
}

@test "aggregate-results: sums ok/not ok across shard TAP files" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0"
	mkdir -p "$artifacts/shell-test-results-shard-1"
	cat >"$artifacts/shell-test-results-shard-0/bats-output.tap" <<'EOF'
1..3
ok 1 alpha
ok 2 beta
not ok 3 gamma
EOF
	cat >"$artifacts/shell-test-results-shard-1/bats-output.tap" <<'EOF'
1..2
ok 1 delta
ok 2 epsilon
EOF

	run run_coverage \
		STEP=aggregate-results \
		SHARD_ARTIFACTS_DIR="$artifacts"

	assert_success
	grep -qx 'tests-total=5' "$GITHUB_OUTPUT"
	grep -qx 'tests-passed=4' "$GITHUB_OUTPUT"
	grep -qx 'tests-failed=1' "$GITHUB_OUTPUT"
	grep -qx 'tests-ran=true' "$GITHUB_OUTPUT"
}

@test "aggregate-results: EXPECTED_SHARDS fails when a TAP file is missing" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0"
	cat >"$artifacts/shell-test-results-shard-0/bats-output.tap" <<'EOF'
1..1
ok 1 alpha
EOF

	run run_coverage \
		STEP=aggregate-results \
		SHARD_ARTIFACTS_DIR="$artifacts" \
		EXPECTED_SHARDS=2

	assert_failure
	assert_output --partial "Expected 2 shard TAP files, found 1"
}

@test "aggregate-results: empty shards report tests-ran=false" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0"
	: >"$artifacts/shell-test-results-shard-0/bats-output.tap"

	run run_coverage \
		STEP=aggregate-results \
		SHARD_ARTIFACTS_DIR="$artifacts"

	assert_success
	grep -qx 'tests-total=0' "$GITHUB_OUTPUT"
	grep -qx 'tests-passed=0' "$GITHUB_OUTPUT"
	grep -qx 'tests-failed=0' "$GITHUB_OUTPUT"
	grep -qx 'tests-ran=false' "$GITHUB_OUTPUT"
}

@test "aggregate-results: a 1..0 shard TAP counts as present with zero tests" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0" "$artifacts/shell-test-results-shard-1"
	cat >"$artifacts/shell-test-results-shard-0/bats-output.tap" <<'EOT'
1..2
ok 1 alpha
ok 2 beta
EOT
	printf '1..0\n# shard 1/2: no test files assigned\n' \
		>"$artifacts/shell-test-results-shard-1/bats-output.tap"

	run run_coverage \
		STEP=aggregate-results \
		SHARD_ARTIFACTS_DIR="$artifacts" \
		EXPECTED_SHARDS=2

	assert_success
	refute_output --partial "Expected 2 shard TAP files"
	grep -qx 'tests-total=2' "$GITHUB_OUTPUT"
	grep -qx 'tests-ran=true' "$GITHUB_OUTPUT"
}

@test "aggregate-results: every shard 1..0 reports tests-ran=false" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	local i
	for i in 0 1; do
		mkdir -p "$artifacts/shell-test-results-shard-${i}"
		printf '1..0\n# shard %s/2: no test files assigned\n' "$i" \
			>"$artifacts/shell-test-results-shard-${i}/bats-output.tap"
	done

	run run_coverage \
		STEP=aggregate-results \
		SHARD_ARTIFACTS_DIR="$artifacts" \
		EXPECTED_SHARDS=2

	assert_success
	grep -qx 'tests-total=0' "$GITHUB_OUTPUT"
	grep -qx 'tests-ran=false' "$GITHUB_OUTPUT"
}

_merge_fixture() {
	COV_DIR="$BATS_TEST_TMPDIR/shard-coverage"
	mkdir -p "$COV_DIR/cov-shard-0" "$COV_DIR/cov-shard-1"
	cat >"$COV_DIR/cov-shard-0/cov.xml" <<'EOT'
<?xml version="1.0" ?>
<coverage line-rate="1" lines-covered="1" lines-valid="1" version="1">
  <packages><package name="p" line-rate="1"><classes>
    <class name="a.sh" filename="a.sh" line-rate="1"><lines><line number="1" hits="1"/></lines></class>
  </classes></package></packages>
</coverage>
EOT
}

@test "merge-coverage: skips a shard with an EMPTY_SHARD marker with a notice" {
	_merge_fixture
	printf 'shard=1/2\n' >"$COV_DIR/cov-shard-1/EMPTY_SHARD"

	run run_coverage \
		STEP=merge-coverage \
		SHARD_COVERAGE_DIR="$COV_DIR" \
		MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"

	assert_success
	assert_output --partial "::notice::merge-coverage skipping empty shard cov-shard-1"
	assert_output --partial "merge-coverage input=${COV_DIR}/cov-shard-0/cov.xml"
	[[ -s "$BATS_TEST_TMPDIR/merged.xml" ]]
}

@test "merge-coverage: a shard with neither XML nor marker fails naming the shard" {
	_merge_fixture
	: >"$COV_DIR/cov-shard-1/stray.txt"

	run run_coverage \
		STEP=merge-coverage \
		SHARD_COVERAGE_DIR="$COV_DIR" \
		MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"

	assert_failure
	assert_output --partial "::error::Coverage shard cov-shard-1 has no cov.xml or cobertura.xml and no EMPTY_SHARD marker"
	[[ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]]
}

# =============================================================================
# #1531: shard completion manifests
# =============================================================================

# kcov mock that also writes a Cobertura report, as a finished kcov does.
_mock_kcov_with_report() {
	cat >"${MOCK_BIN}/kcov" <<'EOF'
#!/usr/bin/env bash
outdir=""
while [[ $# -gt 0 && "$1" != "bats" ]]; do
	[[ "$1" != --* ]] && outdir="$1"
	shift
done
mkdir -p "$outdir/kcov-merged"
printf '<coverage line-rate="0.5" lines-covered="1" lines-valid="2" version="1">\n</coverage>\n' \
	>"$outdir/kcov-merged/cov.xml"
exec "$@"
EOF
	chmod +x "${MOCK_BIN}/kcov"
}

@test "run-coverage: a finished shard writes shard-complete.json (#1531)" {
	_mock_kcov_with_report

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats \
		SHARD_INDEX=0 SHARD_TOTAL=1

	assert_success
	local manifest="$BATS_TEST_TMPDIR/coverage-report/shard-complete.json"
	assert [ -f "$manifest" ]
	run jq -c '[.shard_index, .shard_total, .plan, .counts.total, .lines_covered, .lines_valid]' "$manifest"
	assert_output '[0,1,1,1,1,2]'
}

@test "run-coverage: a cut-short TAP plan writes no manifest and warns (#1531)" {
	_mock_kcov_with_report
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..3"
echo "ok 1 first"
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats

	assert_success
	assert_output --partial "::warning::shard 0/1 did not finish; no completion manifest: TAP did not finish: 2 of 3 planned tests have no result (a setup_file/hook failure or an interruption)"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
}

@test "run-coverage: a timed-out shard writes no manifest (#1531)" {
	_mock_kcov_with_report

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats TIMEOUT_MOCK_EXIT=124

	assert_failure 124
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
}

@test "run-coverage: an empty shard writes an empty manifest (#1531)" {
	local index
	for index in 0 1 2 3 4 5 6 7; do
		rm -rf "$BATS_TEST_TMPDIR/coverage-report"
		run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats \
			SHARD_INDEX="$index" SHARD_TOTAL=8
		if [[ -f "$BATS_TEST_TMPDIR/coverage-report/EMPTY_SHARD" ]]; then
			break
		fi
	done
	assert [ -f "$BATS_TEST_TMPDIR/coverage-report/EMPTY_SHARD" ]
	run jq -c '[.empty, .plan, .shard_total]' "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json"
	assert_output '[true,0,8]'
}

# Lay out <total> shard TAP and coverage artifacts; the shards listed in
# SKIP_MANIFESTS (space separated) get no shard-complete.json and a
# cut-short TAP (1 of 2 planned tests).
_shard_artifacts() {
	local total="$1" index
	TAP_DIR="$BATS_TEST_TMPDIR/shard-taps"
	COV_DIR="$BATS_TEST_TMPDIR/shard-coverage"
	for ((index = 0; index < total; index++)); do
		mkdir -p "$TAP_DIR/t-shard-$index" "$COV_DIR/c-shard-$index"
		if [[ " ${SKIP_MANIFESTS:-} " == *" $index "* ]]; then
			printf '1..2\nok 1 t%s\n' "$index" >"$TAP_DIR/t-shard-$index/bats-output.tap"
		else
			printf '1..1\nok 1 t%s\n' "$index" >"$TAP_DIR/t-shard-$index/bats-output.tap"
		fi
		printf '<coverage lines-covered="%s" lines-valid="2">\n<class filename="a.sh"><lines><line number="%s" hits="1"/></lines></class>\n</coverage>\n' \
			1 $((index % 2 + 1)) >"$COV_DIR/c-shard-$index/cov.xml"
		if [[ " ${SKIP_MANIFESTS:-} " != *" $index "* ]]; then
			printf '{"schema":"lgtm-ci.shard-complete.v1","shard_index":%s,"shard_total":%s,"run_id":"%s","run_attempt":"%s","sha":"%s"}\n' \
				"$index" "$total" "${MANIFEST_RUN_ID:-42}" "${MANIFEST_RUN_ATTEMPT:-2}" "${MANIFEST_SHA:-abc123}" >"$COV_DIR/c-shard-$index/shard-complete.json"
		fi
	done
}

@test "aggregate-results: 2 of 8 shards without a manifest mark the document incomplete (#1531)" {
	SKIP_MANIFESTS="3 4" _shard_artifacts 8

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=8 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=1 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	assert_output --partial "::error::incomplete coverage: shard(s) 3, 4 did not finish: shard 3: 1 of 2 planned tests have no result (a setup_file/hook failure or an interruption); shard 4: 1 of 2 planned tests have no result (a setup_file/hook failure or an interruption)"
	run jq -c '[.status, .incomplete]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["error","incomplete coverage: shard(s) 3, 4 did not finish: shard 3: 1 of 2 planned tests have no result (a setup_file/hook failure or an interruption); shard 4: 1 of 2 planned tests have no result (a setup_file/hook failure or an interruption)"]'
	grep -qx 'status=error' "$GITHUB_OUTPUT"
}

@test "aggregate-results: every manifest present keeps the document complete (#1531)" {
	_shard_artifacts 8

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=8 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=0 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	refute_output --partial "incomplete"
	run jq -c '[.status, .counts.total, has("incomplete")]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["passed",8,false]'
}

@test "merge-coverage: 2 of 8 shards without a manifest merge nothing (#1531)" {
	SKIP_MANIFESTS="3 4" _shard_artifacts 8

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=8 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"

	assert_failure
	assert_output --partial "::error::incomplete coverage: shard(s) 3, 4 did not finish (no completion manifest: a setup_file/hook failure, an interruption or a lost upload)"
	refute_output --partial "merge-coverage input="
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
	run grep -c '^coverage-percent=' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "merge-coverage: every manifest present merges as before (#1531)" {
	_shard_artifacts 8

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=8 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"

	assert_success
	[[ -s "$BATS_TEST_TMPDIR/merged.xml" ]]
	grep -qx 'coverage-percent=100' "$GITHUB_OUTPUT"
}

@test "merge-coverage: manifests from another run ID or commit count as missing (#1531)" {
	MANIFEST_RUN_ID=41 _shard_artifacts 2
	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"
	assert_failure
	assert_output --partial "::error::incomplete coverage: shard(s) 0, 1 did not finish"

	rm -rf "$TAP_DIR" "$COV_DIR"
	MANIFEST_SHA=fff999 _shard_artifacts 2
	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"
	assert_failure
	assert_output --partial "::error::incomplete coverage: shard(s) 0, 1 did not finish"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "merge-coverage: a manifest from an earlier attempt of this run is accepted (#1531)" {
	MANIFEST_RUN_ATTEMPT=1 _shard_artifacts 2

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"

	assert_success
	[[ -s "$BATS_TEST_TMPDIR/merged.xml" ]]
}

@test "run-coverage: a setup_file failure is incomplete and writes no manifest (fail closed, #1531)" {
	_mock_kcov_with_report
	# Verbatim Bats 1.14 output for an uninterrupted setup_file failure. TAP
	# cannot tell it from a bats-exec-file killed by SIGTERM, so it fails
	# closed: no manifest, status error instead of failed.
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..3"
echo "not ok 1 setup_file failed"
echo "# (from function \`setup_file' in test file a.bats, line 2)"
echo "#   \`setup_file() { false; }' failed"
echo "ok 3 c"
echo "# bats warning: Executed 2 instead of expected 3 tests"
exit 1
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats

	assert_failure 1
	assert_output --partial "no completion manifest: TAP did not finish: 2 of 3 planned tests have no result (a setup_file/hook failure or an interruption)"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]

	run run_coverage STEP=parse-results EXIT_CODE=1 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"
	assert_success
	run jq -c '[.status, .incomplete]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["error","incomplete test results: bats-output.tap did not finish: 2 of 3 planned tests have no result (a setup_file/hook failure or an interruption)"]'
}

@test "run-coverage: SIGTERM to a bats-exec-file after a setup_file failure writes no manifest (#1531)" {
	_mock_kcov_with_report
	# Real Bats 1.14 output (Sol's case): no SIG marker, bats exits 1.
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..4"
echo "not ok 1 setup_file failed"
echo "# (from function \`setup_file' in test file a.bats, line 2)"
echo "ok 3 c"
echo "# bats warning: Executed 2 instead of expected 4 tests"
exit 1
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats

	assert_failure 1
	assert_output --partial "no completion manifest: TAP did not finish: 3 of 4 planned tests have no result (a setup_file/hook failure or an interruption)"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
}

@test "run-coverage: setup_file failure then SIGINT is incomplete and writes no manifest (#1531)" {
	_mock_kcov_with_report
	# Verbatim Bats 1.14 output (Sol's case): bats exits 1 after SIGINT.
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..4"
echo "not ok 1 setup_file failed"
echo "# (from function \`setup_file' in test file a.bats, line 2)"
echo "not ok 3 c"
echo "#   \`#!/usr/bin/env bats' failed with status 130"
echo ""
echo "# Received SIGINT, aborting ..."
echo ""
echo "# bats warning: Executed 2 instead of expected 4 tests"
exit 1
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats

	assert_failure 1
	assert_output --partial "no completion manifest: TAP did not finish: 1 of 4 planned tests have a result (interrupted)"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]

	run run_coverage STEP=parse-results EXIT_CODE=1 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"
	assert_success
	run jq -r '.status' "$BATS_TEST_TMPDIR/results.json"
	assert_output "error"
}

@test "parse-results: a cut-short plan (1..10, two ok, exit 124) shows partial counts (#1531)" {
	printf '1..10\nok 1 a\nok 2 b\n' >"$BATS_TEST_TMPDIR/bats-output.tap"

	run run_coverage STEP=parse-results EXIT_CODE=124 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json" \
		GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"

	assert_success
	run jq -r '.status' "$BATS_TEST_TMPDIR/results.json"
	assert_output "error"
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" \
		"> Incomplete run, partial counts only (not a full total): incomplete test results: bats-output.tap did not finish: 8 of 10 planned tests have no result (a setup_file/hook failure or an interruption)"
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" "| Total (partial) | 2 |"
	run grep -c '^| Total |' "$BATS_TEST_TMPDIR/summary.md"
	assert_output "0"
}

@test "aggregate-results: an incomplete sharded run uses the same partial warning (#1531)" {
	SKIP_MANIFESTS="1" _shard_artifacts 2

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=2 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=1 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"

	assert_success
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" \
		"> Incomplete run, partial counts only (not a full total): incomplete coverage: shard(s) 1 did not finish: shard 1: 1 of 2 planned tests have no result (a setup_file/hook failure or an interruption)"
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" "| Total (partial) | 2 |"
}

@test "install-kcov: installs the kcov build packages through the shared apt helper (#1432)" {
	# A failing helper stops the step before the kcov clone; its exit code
	# and annotation are the step's.
	cat >"${MOCK_BIN}/python3" <<'EOF2'
#!/usr/bin/env bash
echo "$@" >>"${BATS_TEST_TMPDIR}/mock_calls_python3"
echo "::error::apt could not reach a package mirror (DNS or network failure) after all retries"
exit 100
EOF2
	chmod +x "${MOCK_BIN}/python3"
	cat >"${MOCK_BIN}/git" <<'EOF2'
#!/usr/bin/env bash
echo "$@" >>"${BATS_TEST_TMPDIR}/mock_calls_git"
exit 1
EOF2
	chmod +x "${MOCK_BIN}/git"
	run env STEP=install-kcov bash "$SCRIPT"
	assert_failure 100
	assert_output --partial "::error::apt could not reach a package mirror (DNS or network failure) after all retries"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_python3"
	assert_output --regexp '^-I .*/scripts/ci/actions/\.\./lib/apt_helper\.py install binutils-dev libcurl4-openssl-dev libdw-dev libiberty-dev zlib1g-dev cmake$'
	assert [ ! -e "${BATS_TEST_TMPDIR}/mock_calls_git" ]
}
