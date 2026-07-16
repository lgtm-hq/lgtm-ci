#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-bats-tests.sh (run-coverage)

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/run-bats-tests.sh"
	setup_temp_dir
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"

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

	# kcov: skip options/outdir and exec the wrapped command (bash DRIVER ...)
	cat >"${mock_bin}/kcov" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != "bash" ]]; do
	shift
done
if [[ $# -eq 0 ]]; then
	echo "mock kcov: expected bash command" >&2
	exit 1
fi
exec "$@"
EOF
	chmod +x "${mock_bin}/kcov"

	# timeout: honor --signal / duration; optional TIMEOUT_MOCK_EXIT=124
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
	case "$1" in
	--signal)
		shift 2
		;;
	--signal=*)
		shift
		;;
	*)
		break
		;;
	esac
done
# duration (e.g. 5m)
shift
if [[ "${TIMEOUT_MOCK_EXIT:-}" == "124" ]]; then
	exit 124
fi
exec "$@"
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

@test "run-coverage: emits per-file coverage-start and coverage-finish timing lines" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1

	assert_success
	assert_output --partial "coverage-start file=tests/alpha.bats"
	assert_output --partial "coverage-finish file=tests/alpha.bats"
	assert_output --partial "coverage-start file=tests/beta.bats"
	assert_output --partial "coverage-finish file=tests/beta.bats"
	assert_output --partial "elapsed="
}

@test "run-coverage: timeout path emits ::error:: naming the file" {
	run run_coverage \
		STEP=run-coverage \
		TEST_PATH=tests/alpha.bats \
		COVERAGE_DIR=coverage-report \
		PARALLEL=1 \
		TIMEOUT_MOCK_EXIT=124 \
		KCOV_FILE_TIMEOUT_MINUTES=3

	assert_failure 124
	assert_output --partial "::error::kcov/BATS timed out after 3m for file: tests/alpha.bats"
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
	# both files still invoked
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
	# kcov mock records nothing; driver success + github output path is absolute
	run grep '^coverage-dir=' "$GITHUB_OUTPUT"
	assert_success
	[[ "$output" == coverage-dir=/* ]]
}

@test "run-tests: still honors PARALLEL --jobs when not under kcov" {
	run run_coverage \
		STEP=run-tests \
		TEST_PATH=tests \
		PARALLEL=4

	assert_success
	grep -q -- '--jobs 4' "$BATS_CALLS"
}
