#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-bats-tests.sh (run-coverage)

load "../../../helpers/common"

# #1531 guard: no test may touch the real coverage-report's manifest, neither
# the repository's nor the COVERAGE_DIR a sharded coverage job exports.
setup_file() {
	snapshot_real_manifests
}

teardown_file() {
	assert_real_manifests_untouched
}

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh"
	setup_temp_dir
	# This file runs inside a sharded kcov job (ci.yml coverage-shards: 8)
	# whose run-coverage step exports its real COVERAGE_DIR, SHARD_*,
	# GITHUB_* and more. Drop all of them, then pin what the script needs.
	# Tests that exercise sharding pass SHARD_* via env and override this.
	scrub_ci_step_env
	export COVERAGE_DIR="$BATS_TEST_TMPDIR/coverage-report"
	export SHARD_INDEX=0
	export SHARD_TOTAL=1
	# The run identity shard manifests record and the aggregate checks.
	export GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=2 GITHUB_SHA=abc123
	# install-kcov (#886): never the runner's real kcov stage or /usr/local.
	export KCOV_STAGE_DIR="$BATS_TEST_TMPDIR/kcov-stage/v43"
	export KCOV_INSTALL_PREFIX="$BATS_TEST_TMPDIR/kcov-prefix"
	export KCOV_SRC_DIR="$BATS_TEST_TMPDIR/kcov-src"
	export KCOV_CACHE_SUDO=""
	export OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
	printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$OS_RELEASE_FILE"
	export ImageOS=ubuntu24 RUNNER_ARCH=X64

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

@test "run-coverage: writes exit-code at its end and no manifest itself (#1531)" {
	_mock_kcov_with_report
	cat >"${MOCK_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
echo "1..2"
echo "ok 1 first"
echo "not ok 2 second"
exit 1
EOF
	chmod +x "${MOCK_BIN}/bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats

	assert_failure 1
	# exit-code is the step's last output, written after kcov returned (a
	# failing test included); the manifest is the next step's job.
	run tail -n 2 "$GITHUB_OUTPUT"
	assert_line --index 0 "exit-code=1"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
}

@test "run-coverage: a failure before kcov runs writes no exit-code (#1531)" {
	run run_coverage STEP=run-coverage TEST_PATH=tests/missing

	assert_failure
	run grep -c '^exit-code=' "$GITHUB_OUTPUT"
	assert_output "0"
}

@test "run-coverage: SIGINT then SIGTERM during kcov write interrupted=true even when kcov returns 0 (#1531)" {
	# A long kcov that ignores the signals sent to the script and still
	# returns 0, as on a GitHub step timeout (Sol's case).
	cat >"${MOCK_BIN}/kcov" <<EOF
#!/usr/bin/env bash
outdir=""
while [[ \$# -gt 0 && "\$1" != "bats" ]]; do
	[[ "\$1" != --* ]] && outdir="\$1"
	shift
done
mkdir -p "\$outdir/kcov-merged"
printf '<coverage lines-covered="1" lines-valid="2">\n</coverage>\n' >"\$outdir/kcov-merged/cov.xml"
echo "1..1"
: >"${BATS_TEST_TMPDIR}/kcov-started"
for _ in \$(seq 1 30); do sleep 0.1; done
echo "ok 1 slow"
exit 0
EOF
	chmod +x "${MOCK_BIN}/kcov"

	# Background jobs of a non-interactive shell start with SIGINT ignored,
	# and bash cannot trap a signal ignored on entry; perl restores the
	# default dispositions before exec, as the runner's step process has.
	(
		cd "$BATS_TEST_TMPDIR" || exit 1
		exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' \
			env STEP=run-coverage TEST_PATH=tests/alpha.bats bash "$SCRIPT"
	) >"$BATS_TEST_TMPDIR/run.log" 2>&1 &
	local pid=$! waited=0
	while [[ ! -e "$BATS_TEST_TMPDIR/kcov-started" && "$waited" -lt 100 ]]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	assert [ -e "$BATS_TEST_TMPDIR/kcov-started" ]
	kill -INT "$pid"
	sleep 0.2
	kill -TERM "$pid"
	local status=0
	wait "$pid" || status=$?

	assert_equal "$status" 0
	run cat "$BATS_TEST_TMPDIR/run.log"
	assert_output --partial "::warning::run-coverage received SIGINT"
	run grep -c '^interrupted=true$' "$GITHUB_OUTPUT"
	assert_output "1"
	grep -qx 'exit-code=0' "$GITHUB_OUTPUT"
	# The trap ran before the step's exit-code line.
	run grep -n -e '^interrupted=' -e '^exit-code=' "$GITHUB_OUTPUT"
	assert_line --index 0 --regexp '^[0-9]+:interrupted=true$'

	run run_coverage STEP=shard-manifest EXIT_CODE=0 INTERRUPTED=true
	assert_success
	assert_output --partial "interrupted 'true'"
	assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
}

@test "shard-manifest: exit 0 and exit 1 (failing tests) write the manifest (#1531)" {
	local code
	for code in 0 1; do
		rm -rf "$BATS_TEST_TMPDIR/coverage-report"
		mkdir -p "$BATS_TEST_TMPDIR/coverage-report/kcov-merged"
		printf '<coverage lines-covered="1" lines-valid="2">\n</coverage>\n' \
			>"$BATS_TEST_TMPDIR/coverage-report/kcov-merged/cov.xml"

		run run_coverage STEP=shard-manifest EXIT_CODE="$code" SHARD_INDEX=3 SHARD_TOTAL=8

		assert_success
		run jq -c '[.shard_index, .shard_total, .exit_code, .lines_covered, .run_id, .run_attempt, .sha]' \
			"$BATS_TEST_TMPDIR/coverage-report/shard-complete.json"
		assert_output "[3,8,${code},1,\"42\",\"2\",\"abc123\"]"
	done
}

@test "shard-manifest: an empty or 124 exit-code (cancel, timeout) writes no manifest (#1531)" {
	mkdir -p "$BATS_TEST_TMPDIR/coverage-report/kcov-merged"
	printf '<coverage lines-covered="1" lines-valid="2">\n</coverage>\n' \
		>"$BATS_TEST_TMPDIR/coverage-report/kcov-merged/cov.xml"
	local code
	for code in "" 124 143; do
		run run_coverage STEP=shard-manifest EXIT_CODE="$code" SHARD_INDEX=3 SHARD_TOTAL=8

		assert_success
		assert_output --partial "::warning::shard 3/8"
		assert [ ! -e "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json" ]
	done
}

@test "shard-manifest: no Cobertura report writes no manifest (#1531)" {
	mkdir -p "$BATS_TEST_TMPDIR/coverage-report"

	run run_coverage STEP=shard-manifest EXIT_CODE=0

	assert_success
	assert_output --partial "no Cobertura report"
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
	run jq -c '[.empty, .shard_total]' "$BATS_TEST_TMPDIR/coverage-report/shard-complete.json"
	assert_output '[true,8]'
}

# Lay out <total> shard TAP and coverage artifacts; the shards listed in
# SKIP_MANIFESTS (space separated) get no shard-complete.json.
_shard_artifacts() {
	local total="$1" index
	TAP_DIR="$BATS_TEST_TMPDIR/shard-taps"
	COV_DIR="$BATS_TEST_TMPDIR/shard-coverage"
	for ((index = 0; index < total; index++)); do
		mkdir -p "$TAP_DIR/t-shard-$index" "$COV_DIR/c-shard-$index"
		printf '1..1\nok 1 t%s\n' "$index" >"$TAP_DIR/t-shard-$index/bats-output.tap"
		printf '<coverage lines-covered="%s" lines-valid="2">\n<class filename="a.sh"><lines><line number="%s" hits="1"/></lines></class>\n</coverage>\n' \
			1 $((index % 2 + 1)) >"$COV_DIR/c-shard-$index/cov.xml"
		if [[ " ${SKIP_MANIFESTS:-} " != *" $index "* ]]; then
			printf '{"schema":"lgtm-ci.shard-complete.v1","shard_index":%s,"shard_total":%s,"run_id":"%s","run_attempt":"%s","sha":"%s"}\n' \
				"$index" "$total" "${MANIFEST_RUN_ID:-42}" "${MANIFEST_RUN_ATTEMPT:-2}" "${MANIFEST_SHA:-abc123}" >"$COV_DIR/c-shard-$index/shard-complete.json"
		fi
	done
}

SHARD_REASON_34="incomplete coverage: shard(s) 3, 4 did not finish (cancelled or timed out; no completion manifest)"

@test "aggregate-results: 2 of 8 shards without a manifest mark the document incomplete (#1531)" {
	SKIP_MANIFESTS="3 4" _shard_artifacts 8

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=8 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=1 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	assert_output --partial "::error::${SHARD_REASON_34}"
	run jq -c '[.status, .incomplete]' "$BATS_TEST_TMPDIR/results.json"
	assert_output "[\"error\",\"${SHARD_REASON_34}\"]"
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
	assert_output --partial "::error::${SHARD_REASON_34}"
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

# #1562: the download outcomes after the workflow's retries.
COV_PATTERN="p-coverage-m-shard-*"
DOWNLOAD_DETAIL="download outcome 'failure' after retries; the error is in the download step logs"
DOWNLOAD_REASON="incomplete coverage: artifact download failed for ${COV_PATTERN}"
DOWNLOAD_REASON+=" (${DOWNLOAD_DETAIL})"

@test "merge-coverage: a failed coverage download is not reported as unfinished shards (#1562)" {
	# Shard 2's artifact never arrived (ECONNRESET on every attempt).
	_shard_artifacts 4
	rm -rf "$COV_DIR/c-shard-2"

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=4 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml" \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME=failure SHARD_COVERAGE_PATTERN="$COV_PATTERN"

	assert_failure
	assert_output --partial "::error::${DOWNLOAD_REASON}; shard(s) 2 unverified"
	refute_output --partial "did not finish"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
	grep -qF "Coverage: incomplete, not merged (${DOWNLOAD_REASON}" "$GITHUB_STEP_SUMMARY"
}

@test "merge-coverage: a failed download fails closed even when every manifest arrived (#1562)" {
	_shard_artifacts 2

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml" \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME=failure SHARD_COVERAGE_PATTERN="$COV_PATTERN"

	assert_failure
	assert_output --partial "::error::${DOWNLOAD_REASON}"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "merge-coverage: a download that recovered on retry merges as before (#1562)" {
	_shard_artifacts 2

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml" \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME=success SHARD_COVERAGE_PATTERN="$COV_PATTERN"

	assert_success
	[[ -s "$BATS_TEST_TMPDIR/merged.xml" ]]
}

@test "merge-coverage: a successful download with a missing manifest still did not finish (#1562)" {
	SKIP_MANIFESTS="1" _shard_artifacts 2

	run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
		EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml" \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME=success SHARD_COVERAGE_PATTERN="$COV_PATTERN"

	assert_failure
	assert_output --partial "::error::incomplete coverage: shard(s) 1 did not finish"
	refute_output --partial "download failed"
}

@test "aggregate-results: a failed coverage download gives the download reason (#1562)" {
	_shard_artifacts 4
	rm -rf "$COV_DIR/c-shard-2"

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=4 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=0 \
		SHARD_ARTIFACTS_DOWNLOAD_OUTCOME=success \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME=failure SHARD_COVERAGE_PATTERN="$COV_PATTERN" \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	assert_output --partial "::error::${DOWNLOAD_REASON}; shard(s) 2 unverified"
	refute_output --partial "did not finish"
	run jq -r '.status' "$BATS_TEST_TMPDIR/results.json"
	assert_output "error"
}

@test "aggregate-results: a failed TAP download is reported as one, not as a TAP count (#1562)" {
	_shard_artifacts 4
	rm -rf "$TAP_DIR/t-shard-2"

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=4 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=0 \
		SHARD_ARTIFACTS_DOWNLOAD_OUTCOME=failure SHARD_ARTIFACTS_PATTERN="p-test-results-m-shard-*" \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_failure
	local target="p-test-results-m-shard-*"
	assert_output --partial "::error::artifact download failed for ${target} (${DOWNLOAD_DETAIL});"
	assert_output --partial "); found 3 of 4 shard TAP files"
	refute_output --partial "Expected 4 shard TAP files"
}

@test "parse-results: a cut-short plan (1..10, two ok, exit 124) keeps its status, with tap_plan and approximate totals (#1531, #1539)" {
	printf '1..10\nok 1 a\nok 2 b\n' >"$BATS_TEST_TMPDIR/bats-output.tap"

	run run_coverage STEP=parse-results EXIT_CODE=124 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json" \
		GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"

	assert_success
	run jq -c '[.status, .counts.total, has("incomplete"), .tap_plan]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["failed",2,false,{"planned":10,"reported":2}]'
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" "| Total (approximate) | 2 |"
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" \
		"Totals are approximate: 2 result lines against 10 planned tests."
	run grep -c 'Incomplete run' "$BATS_TEST_TMPDIR/summary.md"
	assert_output "0"
}

@test "aggregate-results: an incomplete sharded run uses the shared partial warning (#1531)" {
	SKIP_MANIFESTS="1" _shard_artifacts 2

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=2 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=1 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"

	assert_success
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" \
		"> Incomplete run, partial counts only (not a full total): incomplete coverage: shard(s) 1 did not finish (cancelled or timed out; no completion manifest)"
	assert_file_contains_literal "$BATS_TEST_TMPDIR/summary.md" "| Total (partial) | 2 |"
}

@test "aggregate-results: an incomplete run with no recorded results says so (#1531)" {
	SKIP_MANIFESTS="0 1" _shard_artifacts 2
	printf '1..1\n' >"$TAP_DIR/t-shard-0/bats-output.tap"
	printf '1..1\n' >"$TAP_DIR/t-shard-1/bats-output.tap"

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=2 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=1 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" \
		"No test results were recorded before the run stopped (incomplete coverage: shard(s) 0, 1 did not finish (cancelled or timed out; no completion manifest))"
	run grep -c 'Total' "$GITHUB_STEP_SUMMARY"
	assert_output "0"
}

@test "merge-coverage: no run ID or SHA fails closed as a checker usage error (#1531)" {
	_shard_artifacts 2
	local unset_var
	for unset_var in GITHUB_RUN_ID GITHUB_SHA; do
		run run_coverage -u "$unset_var" STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
			EXPECTED_SHARDS=2 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"
		assert_failure
		assert_output --partial "::error::incomplete coverage: shard completion check failed (exit 2)"
		assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
	done
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


# =============================================================================
# install-kcov: the kcov build cache (#886)
# =============================================================================

# Print the cache key install-kcov computes for the pinned kcov in this env.
_kcov_key() {
	bash -c 'source "$1/scripts/ci/versions.env"
		source "$1/scripts/ci/lib/testing/kcov_cache.sh"
		kcov_cache_key "$DEFAULT_KCOV_VERSION" "$DEFAULT_KCOV_COMMIT" \
			"$1/scripts/ci/patches/kcov-v43-ansi-c-quotes.patch" \
			"$(kcov_cache_recipe_digest "$1/scripts/ci/actions/run-bats-tests.sh")"' _ "$PROJECT_ROOT"
}

# Write an executable kcov at <path> that runs <body>.
_fake_kcov() {
	mkdir -p "$(dirname "$1")"
	printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
	chmod +x "$1"
}

# Fill <tree> with what kcov v43's make install puts down; its kcov runs
# <body> (default: print "kcov v43").
_fill_kcov_tree() {
	local tree="$1" body="${2:-echo kcov v43}"
	_fake_kcov "$tree/bin/kcov" "$body"
	_fake_kcov "$tree/bin/kcov-system-daemon" "exit 0"
	mkdir -p "$tree/share/doc/kcov" "$tree/share/man/man1"
	echo changelog >"$tree/share/doc/kcov/ChangeLog"
	echo copying >"$tree/share/doc/kcov/COPYING"
	echo externals >"$tree/share/doc/kcov/COPYING.externals"
	echo manpage >"$tree/share/man/man1/kcov.1"
}

# Stage a kcov tree whose kcov runs <body>, stamped with <key> (default: the
# current key).
_stage_kcov() {
	local body="${1:-echo kcov v43}" key="${2-$(_kcov_key)}"
	_fill_kcov_tree "$KCOV_STAGE_DIR/tree" "$body"
	printf '%s\n' "$key" >"$KCOV_STAGE_DIR/cache-key"
}

# Record every apt helper, git, cmake and make call; the apt helper fails with
# exit 100 so a step that falls through to the source build stops there.
_kcov_build_recorders() {
	local tool
	for tool in python3 git cmake make; do
		cat >"${MOCK_BIN}/${tool}" <<EOF2
#!/usr/bin/env bash
echo "\$*" >>"${BATS_TEST_TMPDIR}/mock_calls_${tool}"
[[ "${tool}" == python3 ]] && { echo "::error::apt could not reach a package mirror"; exit 100; }
exit 1
EOF2
		chmod +x "${MOCK_BIN}/${tool}"
	done
}

# ldd mock. <mode>: ok (every library resolves), missing <lib>, fail (exit 2)
# or timeout (exit 124, what timeout(1) returns when it kills ldd).
_fake_ldd() {
	local mode="${1:-ok}" lib="${2:-}"
	{
		echo '#!/usr/bin/env bash'
		echo 'echo "	libc.so.6 => /lib/libc.so.6 (0x1)"'
		case "$mode" in
		missing) echo "echo \"	${lib} => not found\"" ;;
		fail) echo 'echo "ldd: exited unexpectedly" >&2; exit 2' ;;
		timeout) echo 'exit 124' ;;
		esac
	} >"${MOCK_BIN}/ldd"
	chmod +x "${MOCK_BIN}/ldd"
}

# Assert the step fell through to the source build without touching the prefix.
_assert_fell_through() {
	assert_failure 100
	assert [ -e "${BATS_TEST_TMPDIR}/mock_calls_python3" ]
	assert [ ! -e "$KCOV_INSTALL_PREFIX/bin/kcov" ]
}

@test "kcov-cache-key: prints the exact key and the stage directory (#886)" {
	run run_coverage STEP=kcov-cache-key GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
	assert_success
	run cat "$BATS_TEST_TMPDIR/out"
	assert_line "cache-key=$(_kcov_key)"
	assert_line "stage-dir=$KCOV_STAGE_DIR"
	assert_line --regexp '^cache-key=lgtm-kcov-v43-a39874f938ce13f7a65f253120d1ec946b349ffe-[0-9a-f]{64}-r[0-9a-f]{64}-ubuntu24-ubuntu24\.04-x64$'
}

@test "kcov-cache-key: an unchecked version override or an unknown OS keys nothing (#886)" {
	run run_coverage STEP=kcov-cache-key GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" KCOV_VERSION=v44
	assert_success
	assert_output --partial "the cache is skipped"
	run grep -Fx "cache-key=" "$BATS_TEST_TMPDIR/out"
	assert_success

	: >"$BATS_TEST_TMPDIR/out"
	run run_coverage STEP=kcov-cache-key GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" \
		OS_RELEASE_FILE="$BATS_TEST_TMPDIR/missing"
	assert_success
	assert_output --partial "the cache is skipped"
	run grep -Fx "cache-key=" "$BATS_TEST_TMPDIR/out"
	assert_success
}

@test "kcov-cache-key: the recipe digest follows kcov_cache.sh and the install-kcov block only (#886)" {
	local copy="$BATS_TEST_TMPDIR/recipe"
	mkdir -p "$copy"
	cp "$PROJECT_ROOT/scripts/ci/lib/testing/kcov_cache.sh" "$copy/kcov_cache.sh"
	cp "$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh" "$copy/run.sh"
	_digest() { bash -c 'source "$1/kcov_cache.sh"; kcov_cache_recipe_digest "$1/run.sh"' _ "$copy"; }

	local base
	base="$(_digest)"
	assert [ "${#base}" -eq 64 ]
	run bash -c 'source "$1/scripts/ci/lib/testing/kcov_cache.sh"; kcov_cache_recipe_digest "$1/scripts/ci/actions/run-bats-tests.sh"' _ "$PROJECT_ROOT"
	assert_output "$base"

	# Outside the block: same recipe.
	printf '# unrelated\n' >>"$copy/run.sh"
	run _digest
	assert_output "$base"
	# Inside the block: a new recipe.
	sed -i.bak 's/^	make -j"\$(nproc)"$/	make -j1/' "$copy/run.sh"
	run _digest
	refute_output "$base"
	cp "$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh" "$copy/run.sh"
	# The library: a new recipe.
	printf '# tweak\n' >>"$copy/kcov_cache.sh"
	run _digest
	refute_output "$base"
	# No markers: no digest, so no key.
	grep -v 'kcov-recipe:end' "$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh" >"$copy/run.sh"
	run _digest
	assert_output ""
}

@test "install-kcov: a stage that passes every check installs without apt, clone or build (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov
	run env STEP=install-kcov bash "$SCRIPT"
	assert_success
	assert_output --partial "::notice title=kcov cache::kcov v43 restored from cache ($(_kcov_key))"
	refute_output --partial "::warning"
	run "$KCOV_INSTALL_PREFIX/bin/kcov" --version
	assert_output "kcov v43"
	run ls -l "$KCOV_INSTALL_PREFIX/bin/kcov" "$KCOV_INSTALL_PREFIX/share/man/man1/kcov.1"
	assert_line --regexp '^-rwxr-xr-x.*/bin/kcov$'
	assert_line --regexp '^-rw-r--r--.*/share/man/man1/kcov\.1$'
	run find "$KCOV_INSTALL_PREFIX" -type f
	assert_equal "$(printf '%s\n' "${lines[@]}" | wc -l | tr -d ' ')" 6
	local tool
	for tool in python3 git cmake make; do
		assert [ ! -e "${BATS_TEST_TMPDIR}/mock_calls_${tool}" ]
	done
}

@test "install-kcov: a stage reporting another version falls through to the source build (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov 'echo kcov v42'
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial '::warning title=kcov cache unusable::'
	assert_output --partial '--version reported "kcov v42", expected exactly "kcov v43"; building from source'
}

@test "install-kcov: extra --version output is a mismatch, not a match (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov 'echo kcov v43; echo "warning: something odd"'
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial '--version reported "kcov v43 (and 1 more line(s))"'
}

@test "install-kcov: a stage built for another key falls through to the source build (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov 'echo kcov v43' 'lgtm-kcov-v43-other'
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "was built for 'lgtm-kcov-v43-other', not '$(_kcov_key)'; building from source"
}

@test "install-kcov: a broken, non-executable or missing staged binary falls through (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov 'echo "kcov: error while loading shared libraries: libdw.so.1" >&2; exit 127'
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial '--version reported "exit 127: kcov: error while loading shared libraries: libdw.so.1"'

	rm -f "${BATS_TEST_TMPDIR}/mock_calls_python3"
	_stage_kcov
	chmod -x "$KCOV_STAGE_DIR/tree/bin/kcov"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree/bin/kcov is not executable; building from source"

	rm -f "${BATS_TEST_TMPDIR}/mock_calls_python3" "$KCOV_STAGE_DIR/tree/bin/kcov"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "::warning title=kcov cache unusable::$KCOV_STAGE_DIR/tree misses bin/kcov"
}

@test "install-kcov: an unresolved library, an ldd error, an ldd timeout or no ldd all fall through (#886)" {
	_kcov_build_recorders
	_stage_kcov
	# The staged kcov runs fine here: ldd, not the image, has to vouch for it.
	_fake_ldd missing libdw.so.1
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "needs shared libraries ldd cannot resolve: libdw.so.1; building from source"

	rm -f "${BATS_TEST_TMPDIR}/mock_calls_python3"
	_fake_ldd fail
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "failed (exit 2): ldd: exited unexpectedly; building from source"

	rm -f "${BATS_TEST_TMPDIR}/mock_calls_python3"
	: >"$TIMEOUT_CALLS"
	_fake_ldd timeout
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree/bin/kcov timed out after 10s; building from source"
	run cat "$TIMEOUT_CALLS"
	assert_line --regexp '^--kill-after=2s 10s ldd .*/tree/bin/kcov$'

	rm -f "${BATS_TEST_TMPDIR}/mock_calls_python3"
	run env STEP=install-kcov KCOV_CACHE_LDD=no-such-ldd bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "no-such-ldd is not on PATH, so the shared libraries of"
}

@test "install-kcov: a symlink, an extra file or a missing allowlisted file rejects the stage (#886)" {
	_kcov_build_recorders
	_fake_ldd
	_stage_kcov
	ln -s /bin/sh "$KCOV_STAGE_DIR/tree/share/doc/kcov/link"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree holds a symlink: share/doc/kcov/link; building from source"

	rm -rf "$KCOV_STAGE_DIR" "${BATS_TEST_TMPDIR}/mock_calls_python3"
	_stage_kcov
	_fake_kcov "$KCOV_STAGE_DIR/tree/bin/git" "exit 0"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree holds a file outside the kcov allowlist: bin/git; building from source"
	assert [ ! -e "$KCOV_INSTALL_PREFIX/bin/git" ]

	rm -rf "$KCOV_STAGE_DIR" "${BATS_TEST_TMPDIR}/mock_calls_python3"
	_stage_kcov
	rm "$KCOV_STAGE_DIR/tree/share/man/man1/kcov.1"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree misses share/man/man1/kcov.1; building from source"

	# A stage whose kcov binary is itself a symlink is rejected too.
	rm -rf "$KCOV_STAGE_DIR" "${BATS_TEST_TMPDIR}/mock_calls_python3"
	_stage_kcov
	mv "$KCOV_STAGE_DIR/tree/bin/kcov" "$BATS_TEST_TMPDIR/real-kcov"
	ln -s "$BATS_TEST_TMPDIR/real-kcov" "$KCOV_STAGE_DIR/tree/bin/kcov"
	run env STEP=install-kcov bash "$SCRIPT"
	_assert_fell_through
	assert_output --partial "/tree holds a symlink: bin/kcov"
}

@test "install-kcov: no stage builds from source quietly (#886)" {
	_kcov_build_recorders
	run env STEP=install-kcov bash "$SCRIPT"
	assert_failure 100
	assert_output --partial "kcov cache: no staged build at $KCOV_STAGE_DIR; building kcov v43 from source"
	refute_output --partial "::warning"
}

# A source build that succeeds: apt, clone (at the pinned commit and tag),
# patch, cmake and make all succeed. `make install` writes CMake's
# install_manifest.txt into the build directory (failing when it cannot) and
# puts down kcov v43's files under DESTDIR; the kcov reports MOCK_KCOV_REPORT
# (default "kcov v43"). sudo runs its command, then makes that manifest
# read-only, as a root-owned one is to the unprivileged runner. make and sudo
# log to one ordered file.
_kcov_build_succeeds() {
	export CALL_ORDER="$BATS_TEST_TMPDIR/mock_calls_order"
	cat >"${MOCK_BIN}/python3" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >>"${BATS_TEST_TMPDIR}/mock_calls_python3"
EOF2
	cat >"${MOCK_BIN}/git" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >>"${BATS_TEST_TMPDIR}/mock_calls_git"
[[ "$1" == -C ]] && shift 2
case "$1" in
clone) mkdir -p "${@: -1}" ;;
rev-parse) echo a39874f938ce13f7a65f253120d1ec946b349ffe ;;
describe) echo v43 ;;
esac
exit 0
EOF2
	cat >"${MOCK_BIN}/make" <<'EOF2'
#!/usr/bin/env bash
echo "make $*" >>"$CALL_ORDER"
destdir=""
for arg in "$@"; do
	case "$arg" in DESTDIR=*) destdir="${arg#DESTDIR=}" ;; esac
done
[[ " $* " == *" install "* ]] || exit 0
if [[ -e install_manifest.txt && ! -w install_manifest.txt ]]; then
	echo "file failed to open for writing (Permission denied): $PWD/install_manifest.txt" >&2
	exit 2
fi
root="${destdir}${KCOV_INSTALL_PREFIX}"
mkdir -p "$root/bin" "$root/share/doc/kcov" "$root/share/man/man1"
printf '#!/usr/bin/env bash\necho "%s"\n' "${MOCK_KCOV_REPORT:-kcov v43}" >"$root/bin/kcov"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/kcov-system-daemon"
chmod +x "$root/bin/kcov" "$root/bin/kcov-system-daemon"
for f in ChangeLog COPYING COPYING.externals; do echo "$f" >"$root/share/doc/kcov/$f"; done
echo man >"$root/share/man/man1/kcov.1"
echo "$root/bin/kcov" >install_manifest.txt
EOF2
	cat >"${MOCK_BIN}/sudo" <<'EOF2'
#!/usr/bin/env bash
echo "sudo $*" >>"$CALL_ORDER"
"$@"
rc=$?
manifest="$KCOV_SRC_DIR/build/install_manifest.txt"
[[ -e "$manifest" ]] && chmod 0444 "$manifest"
exit "$rc"
EOF2
	printf '#!/usr/bin/env bash\necho "$*" >>"%s/mock_calls_cmake"\n' "$BATS_TEST_TMPDIR" >"${MOCK_BIN}/cmake"
	printf '#!/usr/bin/env bash\necho 2\n' >"${MOCK_BIN}/nproc"
	chmod +x "${MOCK_BIN}/python3" "${MOCK_BIN}/git" "${MOCK_BIN}/make" \
		"${MOCK_BIN}/cmake" "${MOCK_BIN}/sudo" "${MOCK_BIN}/nproc"
	_fake_ldd
	# The final `kcov --version` finds the installed kcov, not the run-coverage mock.
	export PATH="$KCOV_INSTALL_PREFIX/bin:$PATH"
	# Privileged writes go through the sudo mock, as on a runner.
	export KCOV_CACHE_SUDO=sudo
}

@test "install-kcov: a source build stages once, unprivileged, before any sudo, then installs from the stage (#886)" {
	_kcov_build_succeeds
	run env STEP=install-kcov GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash "$SCRIPT"
	assert_success
	assert_output --partial "kcov cache: staged kcov v43 at $KCOV_STAGE_DIR ($(_kcov_key))"
	refute_output --partial "::warning"
	run cat "$BATS_TEST_TMPDIR/out"
	assert_line "stage-ready=true"
	run cat "$KCOV_STAGE_DIR/cache-key"
	assert_output "$(_kcov_key)"
	run "$KCOV_STAGE_DIR/tree/bin/kcov" --version
	assert_output "kcov v43"
	run "$KCOV_INSTALL_PREFIX/bin/kcov" --version
	assert_output "kcov v43"
	assert [ ! -e "$KCOV_STAGE_DIR.partial" ]

	# One make install, into the DESTDIR, before any sudo; sudo never runs make.
	run grep -n '' "$CALL_ORDER"
	assert_line --regexp '^2:make install DESTDIR=.*/kcov-stage/v43\.partial/destdir$'
	run grep -c '^make .*install' "$CALL_ORDER"
	assert_output "1"
	run grep -c '^sudo make' "$CALL_ORDER"
	assert_output "0"
	run grep -c '^sudo install -m 0755 .*/kcov-stage/v43/tree/bin/kcov ' "$CALL_ORDER"
	assert_output "1"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_cmake"
	assert_output "-DCMAKE_INSTALL_PREFIX=$KCOV_INSTALL_PREFIX .."
	run grep -c '^apply ' "${BATS_TEST_TMPDIR}/mock_calls_git"
	assert_output "1"

	# The next run restores that stage without apt, clone or build.
	rm -f "${BATS_TEST_TMPDIR}"/mock_calls_* "$KCOV_INSTALL_PREFIX/bin/kcov"
	_kcov_build_recorders
	run env STEP=install-kcov bash "$SCRIPT"
	assert_success
	assert_output --partial "kcov v43 restored from cache"
	assert [ ! -e "${BATS_TEST_TMPDIR}/mock_calls_python3" ]
	assert [ ! -e "${BATS_TEST_TMPDIR}/mock_calls_git" ]
}

@test "install-kcov: the mocks reproduce the root-owned manifest of the old sudo-first order (#886)" {
	_kcov_build_succeeds
	mkdir -p "$KCOV_SRC_DIR/build"
	# sudo make install first (the order before the fix) ...
	run bash -c 'cd "$1" && sudo make install' _ "$KCOV_SRC_DIR/build"
	assert_success
	# ... leaves a manifest the unprivileged DESTDIR install cannot rewrite.
	if [[ "$(id -u)" != 0 ]]; then
		run bash -c 'cd "$1" && make install DESTDIR="$2"' _ "$KCOV_SRC_DIR/build" "$BATS_TEST_TMPDIR/d"
		assert_failure 2
		assert_output --partial "install_manifest.txt"
	fi
}

@test "install-kcov: a build that fails the stage checks is not staged, and the step still passes (#886)" {
	_kcov_build_succeeds
	: >"$BATS_TEST_TMPDIR/out"
	run env STEP=install-kcov MOCK_KCOV_REPORT="kcov v42" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=kcov cache not populated::"
	assert [ ! -e "$KCOV_STAGE_DIR" ]
	assert [ ! -e "$KCOV_STAGE_DIR.partial" ]
	run grep -c "stage-ready" "$BATS_TEST_TMPDIR/out"
	assert_output "0"
	run "$KCOV_INSTALL_PREFIX/bin/kcov" --version
	assert_output "kcov v42"
}

# A checker that crashes, hits a usage error or cannot run must not read as
# "every shard finished" (#1531 review): python3 is shadowed for
# shard-completion.py only.
_broken_shard_checker() {
	local real
	real="$(command -v python3)"
	cat >"${MOCK_BIN}/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
*shard-completion.py*) echo "Traceback (most recent call last): boom" >&2; exit $1 ;;
esac
exec "$real" "\$@"
EOF
	chmod +x "${MOCK_BIN}/python3"
}

@test "merge-coverage: a crashing or misused completion checker merges nothing (#1531)" {
	local rc
	for rc in 1 2 127; do
		_shard_artifacts 8
		_broken_shard_checker "$rc"
		run run_coverage STEP=merge-coverage SHARD_COVERAGE_DIR="$COV_DIR" \
			EXPECTED_SHARDS=8 MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml"
		assert_failure
		assert_output --partial "::error::incomplete coverage: shard completion check failed (exit ${rc})"
		assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
	done
}

@test "aggregate-results: a crashing completion checker marks the document incomplete (#1531)" {
	_shard_artifacts 8
	_broken_shard_checker 1

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$TAP_DIR" \
		EXPECTED_SHARDS=8 SHARD_MANIFEST_DIR="$COV_DIR" EXIT_CODE=0 \
		RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	run jq -c '[.status, .incomplete]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["error","incomplete coverage: shard completion check failed (exit 1)"]'
}

# =============================================================================
# Bats' own report file (#1539)
# =============================================================================

# A console TAP polluted the way kcov's 2>&1 xtrace pollutes it: a traced
# assertion prints captured mock TAP (a fake "not ok 2"), and trace bytes split
# the real "ok 3" line. Usage: _polluted_console_tap <file>
_polluted_console_tap() {
	{
		echo "1..3"
		echo "ok 1 alpha"
		echo "not ok 2 second == *--allow-empty-suite* ]]"
		echo "ok 2 beta"
		echo "ok 3api.github.com:443"
	} >"$1"
}

# Mock bats >= 1.14 whose --help advertises --report-formatter. It prints the
# polluted console TAP and writes a clean report.tap into its --output dir.
_mock_bats_with_report() {
	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--help" ]]; then
	echo "  --report-formatter <type> Switch between reporters (same options as --formatter)"
	exit 0
fi
out=""
while [[ \$# -gt 0 ]]; do
	[[ "\$1" == "--output" ]] && out="\$2"
	shift
done
printf '1..3\nok 1 alpha\nnot ok 2 second == *--allow-empty-suite* ]]\nok 2 beta\nok 3api.github.com:443\n'
if [[ -n "\$out" ]]; then
	printf '1..3\nok 1 alpha\nok 2 beta\nok 3 gamma\n' >"\$out/report.tap"
fi
EOF
	chmod +x "${MOCK_BIN}/bats"
}

@test "aggregate-results: counts a shard's clean bats-report.tap, not its polluted console TAP (#1539)" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0" "$artifacts/shell-test-results-shard-1"
	_polluted_console_tap "$artifacts/shell-test-results-shard-0/bats-output.tap"
	printf '1..3\nok 1 alpha\nok 2 beta\nok 3 gamma\n' >"$artifacts/shell-test-results-shard-0/bats-report.tap"
	printf '1..0\n# shard 1/2: no test files assigned\n' >"$artifacts/shell-test-results-shard-1/bats-output.tap"
	printf '1..0\n' >"$artifacts/shell-test-results-shard-1/bats-report.tap"

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$artifacts" \
		EXPECTED_SHARDS=2 EXIT_CODE=0 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	refute_output --partial "Expected 2 shard TAP files"
	run jq -c '[.status, .counts, has("tap_plan"), [.artifacts[].path | split("/") | last]]' \
		"$BATS_TEST_TMPDIR/results.json"
	assert_output '["passed",{"passed":3,"failed":0,"skipped":0,"total":3},false,["bats-report.tap","bats-report.tap"]]'
	grep -qx 'tests-failed=0' "$GITHUB_OUTPUT"
	grep -qx 'status=passed' "$GITHUB_OUTPUT"
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| Total | 3 |"
	run grep -c 'approximate' "$GITHUB_STEP_SUMMARY"
	assert_output "0"
}

@test "aggregate-results: a shard without bats-report.tap falls back to its console TAP (#1539)" {
	local artifacts="$BATS_TEST_TMPDIR/shard-taps"
	mkdir -p "$artifacts/shell-test-results-shard-0" "$artifacts/shell-test-results-shard-1"
	printf '1..2\nok 1 alpha\nok 2 beta\n' >"$artifacts/shell-test-results-shard-0/bats-output.tap"
	printf '1..2\nok 1 alpha\nok 2 beta\n' >"$artifacts/shell-test-results-shard-0/bats-report.tap"
	_polluted_console_tap "$artifacts/shell-test-results-shard-1/bats-output.tap"

	run run_coverage STEP=aggregate-results SHARD_ARTIFACTS_DIR="$artifacts" \
		EXPECTED_SHARDS=2 EXIT_CODE=0 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"

	assert_success
	assert_output --partial "aggregate-tap file=${artifacts}/shell-test-results-shard-0/bats-report.tap total=2"
	assert_output --partial "aggregate-tap file=${artifacts}/shell-test-results-shard-1/bats-output.tap total=4"
	# Console counts as before (one leaked failure), labelled approximate.
	run jq -c '[.counts.total, .counts.failed, .tap_plan]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '[6,1,{"planned":5,"reported":6}]'
	assert_file_contains_literal "$GITHUB_STEP_SUMMARY" "| Total (approximate) | 6 |"
}

@test "parse-results: counts bats-report.tap when present, else bats-output.tap (#1539)" {
	_polluted_console_tap "$BATS_TEST_TMPDIR/bats-output.tap"
	printf '1..3\nok 1 alpha\nok 2 beta\nok 3 gamma\n' >"$BATS_TEST_TMPDIR/bats-report.tap"

	run run_coverage STEP=parse-results EXIT_CODE=0 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"
	assert_success
	run jq -c '[.status, .counts.total, .counts.failed, .artifacts[0].path]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '["passed",3,0,"bats-report.tap"]'

	rm "$BATS_TEST_TMPDIR/bats-report.tap"
	run run_coverage STEP=parse-results EXIT_CODE=0 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"
	assert_success
	run jq -c '[.counts.total, .counts.failed, .artifacts[0].path]' "$BATS_TEST_TMPDIR/results.json"
	assert_output '[4,1,"bats-output.tap"]'
}

@test "run-tests: writes bats-report.tap from bats' report file when bats supports it (#1539)" {
	_mock_bats_with_report

	run run_coverage STEP=run-tests TEST_PATH=tests

	assert_success
	grep -q -- '--tap --report-formatter tap --output .* tests$' "$BATS_CALLS"
	run cat "$BATS_TEST_TMPDIR/bats-report.tap"
	assert_output $'1..3\nok 1 alpha\nok 2 beta\nok 3 gamma'
	# The console log is kept as it was.
	assert_file_contains_literal "$BATS_TEST_TMPDIR/bats-output.tap" "ok 3api.github.com:443"
}

@test "run-coverage: passes the report arguments to bats under kcov and saves bats-report.tap (#1539)" {
	_mock_bats_with_report

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run grep -- '--report-formatter tap --output ' "$BATS_CALLS"
	assert_success
	assert_output --partial "tests/alpha.bats tests/beta.bats"
	run head -n 1 "$BATS_TEST_TMPDIR/bats-report.tap"
	assert_output "1..3"
}

@test "run-tests/run-coverage: no report arguments or bats-report.tap when bats lacks --report-formatter (#1539)" {
	printf 'stale\n' >"$BATS_TEST_TMPDIR/bats-report.tap"

	run run_coverage STEP=run-tests TEST_PATH=tests
	assert_success
	[[ ! -e "$BATS_TEST_TMPDIR/bats-report.tap" ]]

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report
	assert_success
	[[ ! -e "$BATS_TEST_TMPDIR/bats-report.tap" ]]

	run grep -c -- '--report-formatter' "$BATS_CALLS"
	assert_output "0"
}

@test "run-coverage: an empty shard also writes a 1..0 bats-report.tap (#1539)" {
	local other_index
	other_index=$((1 - $(_shard_of "tests/alpha.bats" 2)))

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats COVERAGE_DIR=coverage-report \
		SHARD_INDEX="$other_index" SHARD_TOTAL=2

	assert_success
	run cat "$BATS_TEST_TMPDIR/bats-report.tap"
	assert_output "1..0"
}

@test "run-tests: bats runs without PARALLEL in its environment when --jobs is used" {
	# GNU parallel (bats --jobs) reads $PARALLEL as its own options, so the
	# step's PARALLEL=4 must not reach bats; --jobs carries the count.
	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf 'args=%s PARALLEL=%s\n' "\$*" "\${PARALLEL-unset}" >>"${BATS_CALLS}"
echo "1..1"
echo "ok 1 mocked"
EOF
	chmod +x "${MOCK_BIN}/bats"

	run bash -c 'cd "$1" && STEP=run-tests TEST_PATH=tests PARALLEL=4 bash "$2"' _ \
		"$BATS_TEST_TMPDIR" "$SCRIPT"

	assert_success
	run cat "$BATS_CALLS"
	assert_output --partial "--jobs 4"
	assert_output --partial "PARALLEL=unset"
}

# =============================================================================
# Per-file durations (#1422): --timing and the run-ordered file list
# =============================================================================

# Mock bats whose --help advertises --timing, like bats >= 1.2.
_mock_bats_with_timing() {
	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--help" ]]; then
	echo "  -T, --timing              Add timing information to tests"
	exit 0
fi
echo "1..1"
echo "ok 1 mocked # in 5 ms"
EOF
	chmod +x "${MOCK_BIN}/bats"
}

@test "run-coverage: passes --timing when bats supports it, run-tests does not (#1422)" {
	_mock_bats_with_timing

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report
	assert_success
	run grep -c -- '--tap --timing tests/alpha.bats tests/beta.bats$' "$BATS_CALLS"
	assert_output "1"

	: >"$BATS_CALLS"
	run run_coverage STEP=run-tests TEST_PATH=tests
	assert_success
	run grep -c -- '--timing' "$BATS_CALLS"
	assert_output "0"
}

@test "run-coverage: probes bats --help once per run (#1422)" {
	_mock_bats_with_timing

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run grep -cx -- '--help' "$BATS_CALLS"
	assert_output "1"
}

@test "run-coverage: omits --timing when bats lacks it (#1422)" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run grep -c -- '--timing' "$BATS_CALLS"
	assert_output "0"
}

@test "run-coverage: writes bats-files.txt in the order bats runs the files (#1422)" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run cat "$BATS_TEST_TMPDIR/bats-files.txt"
	assert_output $'tests/alpha.bats\ntests/beta.bats'
}

@test "run-coverage: bats-files.txt holds only this shard's files (#1422)" {
	local index
	index="$(_shard_of tests/alpha.bats 2)"

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		SHARD_INDEX="$index" SHARD_TOTAL=2

	assert_success
	run cat "$BATS_TEST_TMPDIR/bats-files.txt"
	if [[ "$(_shard_of tests/beta.bats 2)" == "$index" ]]; then
		assert_output $'tests/alpha.bats\ntests/beta.bats'
	else
		assert_output "tests/alpha.bats"
	fi
}

@test "run-coverage: an empty shard writes an empty bats-files.txt (#1422)" {
	local other_index
	other_index=$((1 - $(_shard_of tests/alpha.bats 2)))

	run run_coverage STEP=run-coverage TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report SHARD_INDEX="$other_index" SHARD_TOTAL=2

	assert_success
	[[ -f "$BATS_TEST_TMPDIR/bats-files.txt" ]]
	[[ ! -s "$BATS_TEST_TMPDIR/bats-files.txt" ]]
}

@test "run-coverage: a run that never starts leaves no stale bats-files.txt (#1422)" {
	printf 'tests/stale.bats\n' >"$BATS_TEST_TMPDIR/bats-files.txt"

	run run_coverage STEP=run-coverage TEST_PATH=tests/absent COVERAGE_DIR=coverage-report

	assert_failure
	[[ ! -e "$BATS_TEST_TMPDIR/bats-files.txt" ]]
}

@test "run-coverage: real bats --timing keeps the counts and feeds bats-durations.py (#1422)" {
	rm "${MOCK_BIN}/bats"
	if ! bats --help 2>/dev/null | grep -q -- '--timing'; then
		skip "installed bats has no --timing"
	fi
	if ! bats --help 2>/dev/null | grep -q -- '--report-formatter'; then
		skip "installed bats has no --report-formatter"
	fi
	{
		echo '#!/usr/bin/env bats'
		echo '@test "gamma skipped" { skip "not here"; }'
		echo '@test "gamma fails" { false; }'
	} >"$BATS_TEST_TMPDIR/tests/gamma.bats"

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report
	assert_failure
	run grep -cE '^ok [0-9]+ .* # in [0-9]+ ms$' "$BATS_TEST_TMPDIR/bats-report.tap"
	assert_output "2"

	run run_coverage STEP=parse-results EXIT_CODE=1 RESULTS_OUTPUT="$BATS_TEST_TMPDIR/results.json"
	assert_success
	run jq -c '[.counts.total, .counts.passed, .counts.failed, .counts.skipped]' \
		"$BATS_TEST_TMPDIR/results.json"
	assert_output '[4,2,1,1]'

	run cat "$BATS_TEST_TMPDIR/bats-version.txt"
	assert_output --regexp '^[0-9]+\.[0-9]+'
	[[ ! -e "$BATS_TEST_TMPDIR/bats-filter-used.txt" ]]

	# bats-files.txt is relative to the run's working directory. The script
	# counts tests statically and starts no process.
	cd "$BATS_TEST_TMPDIR" || return 1
	run python3 "$PROJECT_ROOT/scripts/ci/actions/bats-durations.py" shard \
		--tap bats-report.tap --files bats-files.txt --output durations.json \
		--shard-index 0 --shard-total 1 --sha abc123 --run-id 42 --run-attempt 2
	assert_success
	run jq -c '.durations | keys' "$BATS_TEST_TMPDIR/durations.json"
	assert_output '["tests/alpha.bats","tests/beta.bats","tests/gamma.bats"]'
	run jq -c '[.missing, (.durations | map(type) | unique), .test_counts]' "$BATS_TEST_TMPDIR/durations.json"
	assert_output '[[],["number"],{"tests/alpha.bats":1,"tests/beta.bats":1,"tests/gamma.bats":2}]'
	run jq -c '[.run_id, .run_attempt, (.wall_seconds | type), (.bats_version | type)]' \
		"$BATS_TEST_TMPDIR/durations.json"
	assert_output '[42,2,"number","string"]'
}

@test "run-coverage: a test filter leaves the marker that stops durations (#1422)" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report \
		TEST_FILTER=alpha

	assert_success
	run cat "$BATS_TEST_TMPDIR/bats-filter-used.txt"
	assert_output "test-filter"
	run grep -c -- '--filter alpha' "$BATS_CALLS"
	assert_output "1"
}

@test "run-coverage: an unfiltered run removes an earlier filter marker (#1422)" {
	printf 'test-filter\n' >"$BATS_TEST_TMPDIR/bats-filter-used.txt"

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	[[ ! -e "$BATS_TEST_TMPDIR/bats-filter-used.txt" ]]
}

@test "run-coverage: records the bats version only when bats reports one (#1422)" {
	printf '0.0.1\n' >"$BATS_TEST_TMPDIR/bats-version.txt"

	# The default mock answers --version with TAP, not "Bats <version>".
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report
	assert_success
	[[ ! -e "$BATS_TEST_TMPDIR/bats-version.txt" ]]

	cat >"${MOCK_BIN}/bats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--version" ]]; then
	echo "Bats 1.14.0"
	exit 0
fi
echo "1..1"
echo "ok 1 mocked"
EOF
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report
	assert_success
	run cat "$BATS_TEST_TMPDIR/bats-version.txt"
	assert_output "1.14.0"
}

@test "run-coverage: bounds bats --version with a short timeout (#1594)" {
	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	run grep -cx -- '--signal=TERM --kill-after=5s 10s bats --version' "$TIMEOUT_CALLS"
	assert_output "1"
}

@test "run-coverage: a bats --version that times out records no version (#1594)" {
	printf '0.0.1\n' >"$BATS_TEST_TMPDIR/bats-version.txt"
	# timeout(1) gives up on the version probe only (exit 124, no output);
	# the suite itself runs as usual.
	cat >"${MOCK_BIN}/timeout" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TIMEOUT_CALLS}"
if [[ "\$*" == *"bats --version" ]]; then
	exit 124
fi
while [[ "\${1:-}" == --* ]]; do
	shift
done
shift
exec "\$@"
EOF2
	cat >"${MOCK_BIN}/bats" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_CALLS}"
if [[ "\${1:-}" == "--version" ]]; then
	echo "Bats 1.14.0"
	exit 0
fi
echo "1..1"
echo "ok 1 mocked"
EOF2

	run run_coverage STEP=run-coverage TEST_PATH=tests COVERAGE_DIR=coverage-report

	assert_success
	[[ ! -e "$BATS_TEST_TMPDIR/bats-version.txt" ]]
	run grep -c -- '--version' "$BATS_CALLS"
	assert_output "0"
}
