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
	# collected by a sharded kcov job (ci.yml coverage-shards: 4). Tests
	# that exercise sharding pass SHARD_* via env and override this.
	export SHARD_INDEX=0
	export SHARD_TOTAL=1

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

@test "run-coverage: empty shard exits 0 with empty TAP and does not error" {
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
	[[ -f "$BATS_TEST_TMPDIR/bats-output.tap" ]]
	[[ ! -s "$BATS_TEST_TMPDIR/bats-output.tap" ]]
	# kcov/bats must not have been invoked
	[[ ! -s "$BATS_CALLS" ]]
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
