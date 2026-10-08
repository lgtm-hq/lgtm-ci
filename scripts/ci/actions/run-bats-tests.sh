#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run BATS tests with optional coverage collection
#
# Environment variables:
#   STEP - Which step to run: install-bats, install-kcov, run-tests,
#          run-coverage, parse-results, parse-coverage, check-threshold,
#          aggregate-results, merge-coverage
#   BATS_VERSION - BATS version to install (for install-bats step; default
#              from scripts/ci/versions.env). Overriding it requires the
#              matching BATS_CORE_COMMIT, or LGTM_CI_ALLOW_UNVERIFIED=1.
#   KCOV_VERSION - kcov version to install (for install-kcov step; default
#              from scripts/ci/versions.env, same override rule with
#              KCOV_COMMIT)
#   TEST_PATH - Path to test files (for run-tests/run-coverage steps)
#   TEST_FILTER - Filter tests by name pattern (optional)
#   PARALLEL - Number of parallel jobs (optional, must be a positive integer).
#              Under run-coverage, PARALLEL > 1 is ignored (kcov + parallel BATS
#              is deadlock-prone); non-coverage runs still honor it.
#   SHARD_INDEX - Coverage shard index (run-coverage, default 0). Must satisfy
#              0 <= SHARD_INDEX < SHARD_TOTAL. Invalid values warn and fall
#              back to 0/1 (same style as PARALLEL).
#   SHARD_TOTAL - Coverage shard count (run-coverage, default 1). 1 is a
#              no-op filter so the kcov invocation matches today's behavior.
#   COVERAGE_DIR - Directory for coverage output (for run-coverage step)
#   KCOV_SUITE_TIMEOUT_MINUTES - Suite timeout for kcov/BATS under
#              run-coverage (default: 40). Uses timeout(1) with --kill-after;
#              exit 124 on expiry. Kept below the coverage-run step timeout (45).
#   SHARD_ARTIFACTS_DIR - Directory of downloaded shard TAP artifacts
#              (aggregate-results). Expected layout:
#              <artifact-prefix>-test-results-<comment-marker>-shard-*/bats-output.tap
#   EXPECTED_SHARDS - Optional positive integer (aggregate-results). When
#              set, fail unless that many bats-output.tap files were found.
#   SHARD_COVERAGE_DIR - Directory of downloaded shard coverage artifacts
#              (merge-coverage). Each shard dir contributes cov.xml or
#              cobertura.xml.
#   MERGED_COVERAGE_FILE - Destination for merge-coverage XML.
#   COVERAGE_PERCENT - Coverage percentage (for check-threshold step)
#   EXIT_CODE - bats exit code (parse-results / aggregate-results; feeds results.v1 status)
#   RESULTS_OUTPUT - results.v1 path (parse-results / aggregate-results;
#                    default results/bats/<MATRIX_VALUE|default>/results.json)
#   COVERAGE_THRESHOLD - Minimum coverage threshold (for check-threshold step)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

: "${STEP:=run-tests}"
: "${GITHUB_OUTPUT:=/dev/null}"
: "${GITHUB_STEP_SUMMARY:=/dev/null}"

# results.v1 contract (#1080): parse-results / aggregate-results write the
# document and derive their outputs from it.
_RUN_BATS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/testing/results.sh
source "$_RUN_BATS_SCRIPT_DIR/../lib/testing/results.sh"
# shellcheck source=../lib/testing/parse/tap.sh
source "$_RUN_BATS_SCRIPT_DIR/../lib/testing/parse/tap.sh"

# Wall-clock duration of a run, kept next to its TAP so the sharded
# aggregate can sum it (bats itself reports none in TAP).
write_bats_duration() {
	local start="$1" end="$2"
	printf '%s\n' "$(((end - start) * 1000))" >bats-duration-ms.txt
}

# Sum every bats-duration-ms.txt under a directory (0 when none).
sum_bats_durations() {
	find "$1" -type f -name 'bats-duration-ms.txt' -exec cat {} + 2>/dev/null |
		awk '{ s += $1 } END { printf "%d\n", s }'
}

# Write the results.v1 document for a TAP set and publish the public
# outputs from it. Usage: write_bats_results <output-path> <tap-file>...
write_bats_results() {
	local output="$1"
	shift
	mkdir -p "$(dirname "$output")"
	RESULTS_TOOL=bats RESULTS_RUNNER=run-bats-tests tap_results_v1 "$@" >"$output"
	results_v1_validate "$output"
	results_v1_github_outputs "$output"
	echo "results-json=$output" >>"$GITHUB_OUTPUT"
}

# #856 Part 3: fixture `::error::` / `::warning::` / `::notice::` lines must
# not become real job annotations. Wrap BATS stdout/stderr in a
# stop-commands region. Real annotations from this script (timeout, missing
# path, coverage threshold) are emitted outside the guarded region.
bats_stop_token="lgtm-ci-bats-${RANDOM}${RANDOM}"

begin_bats_output_guard() {
	printf '::stop-commands::%s\n' "$bats_stop_token"
}

end_bats_output_guard() {
	printf '::%s::\n' "$bats_stop_token"
}

# #856 Part 4: kcov's bash engine finds `kcov@` anywhere in a line. A nested
# shell traces the unexpanded `PS4='kcov@${BASH_SOURCE}@${LINENO}@'`
# assignment, and the parser then errors on the literal `${LINENO}`. Cosmetic
# only — coverage output is unaffected. Drop that one message; keep others.
filter_kcov_console() {
	# grep -v exits 1 when every line matches; `set +e` callers tolerate it.
	# The ${LINENO} is kcov's literal error text, not a shell expansion (#856).
	# -x keeps other kcov errors that merely contain this diagnostic.
	local filter_status=0
	# shellcheck disable=SC2016
	grep -vFx 'kcov: error: ${LINENO} is not an integer' || filter_status=$?
	if [[ "$filter_status" -eq 0 || "$filter_status" -eq 1 ]]; then
		return 0
	fi
	return "$filter_status"
}

# =============================================================================
# Step: install-bats - Install BATS core and helper libraries
# =============================================================================
if [[ "$STEP" == "install-bats" ]]; then
	# shellcheck source=../lib/supply_chain.sh
	source "$SCRIPT_DIR/../lib/supply_chain.sh"
	# shellcheck source=../versions.env
	source "$SCRIPT_DIR/../versions.env"
	BATS_VERSION="${BATS_VERSION:-$DEFAULT_BATS_CORE_VERSION}"
	# Normalize BATS_VERSION to avoid double "v" (strip leading "v" if present)
	BATS_VERSION="${BATS_VERSION#v}"
	BATS_SUPPORT_VERSION="${BATS_SUPPORT_VERSION:-$DEFAULT_BATS_SUPPORT_VERSION}"
	BATS_ASSERT_VERSION="${BATS_ASSERT_VERSION:-$DEFAULT_BATS_ASSERT_VERSION}"
	BATS_FILE_VERSION="${BATS_FILE_VERSION:-$DEFAULT_BATS_FILE_VERSION}"
	BATS_SRC="${BATS_INSTALL_SRC:-/tmp}"
	BATS_PREFIX="${BATS_INSTALL_PREFIX:-/usr/local}"
	BATS_LIB_PREFIX="${BATS_LIB_INSTALL_PREFIX:-/usr/lib}"
	SUDO="sudo"
	if [[ "${BATS_INSTALL_NO_SUDO:-}" == "1" ]]; then
		SUDO=""
	fi

	# Install BATS core from source at the specified tag. The content pin is
	# the tag's commit from versions.env (#1096): a moved tag fails here.
	git clone --depth 1 --branch "v${BATS_VERSION}" \
		https://github.com/bats-core/bats-core.git "${BATS_SRC}/bats-core"
	supply_chain_verify_commit "${BATS_SRC}/bats-core" BATS_CORE_COMMIT \
		"$BATS_VERSION" "$DEFAULT_BATS_CORE_VERSION"
	$SUDO "${BATS_SRC}/bats-core/install.sh" "$BATS_PREFIX"

	# Install bats helper libraries (pinned to tags, verified by commit)
	for lib in bats-support bats-assert bats-file; do
		case "$lib" in
		bats-support) version="$BATS_SUPPORT_VERSION" default_version="$DEFAULT_BATS_SUPPORT_VERSION" ;;
		bats-assert) version="$BATS_ASSERT_VERSION" default_version="$DEFAULT_BATS_ASSERT_VERSION" ;;
		bats-file) version="$BATS_FILE_VERSION" default_version="$DEFAULT_BATS_FILE_VERSION" ;;
		*) version="" default_version="" ;;
		esac

		if [[ -z "$version" ]]; then
			echo "::error::Missing version for ${lib}"
			exit 1
		fi

		git clone --depth 1 --branch "$version" "https://github.com/bats-core/${lib}.git" "${BATS_SRC}/${lib}"

		# Verify tag matches expected version
		if ! git -C "${BATS_SRC}/${lib}" describe --tags --exact-match "$version" >/dev/null 2>&1; then
			echo "::error::Tag mismatch for ${lib}: expected $version"
			exit 1
		fi

		# The committed commit for the tag is the content pin; no tag-signature
		# check (runner keyrings never carry the upstream keys, #1096).
		supply_chain_verify_commit "${BATS_SRC}/${lib}" \
			"$(supply_chain_var_suffix "$lib")_COMMIT" "$version" "$default_version"

		$SUDO mkdir -p "${BATS_LIB_PREFIX}/${lib}/src"
		$SUDO cp -r "${BATS_SRC}/${lib}/src/"* "${BATS_LIB_PREFIX}/${lib}/src/"
		$SUDO cp "${BATS_SRC}/${lib}/load.bash" "${BATS_LIB_PREFIX}/${lib}/"
	done

	# Verify installation
	bats --version
	exit 0
fi

# =============================================================================
# Step: install-kcov - Install kcov for coverage collection
# =============================================================================
if [[ "$STEP" == "install-kcov" ]]; then
	# Install kcov dependencies
	sudo apt-get update -qq
	sudo apt-get install -y -qq \
		binutils-dev \
		libcurl4-openssl-dev \
		libdw-dev \
		libiberty-dev \
		zlib1g-dev \
		cmake

	# Install kcov from source. The content pin is the tag's commit from
	# scripts/ci/versions.env (#1096); the release publishes no assets.
	# shellcheck source=../lib/supply_chain.sh
	source "$SCRIPT_DIR/../lib/supply_chain.sh"
	# shellcheck source=../versions.env
	source "$SCRIPT_DIR/../versions.env"
	KCOV_VERSION="${KCOV_VERSION:-$DEFAULT_KCOV_VERSION}"

	git clone --depth 1 --branch "$KCOV_VERSION" \
		https://github.com/SimonKagstrom/kcov.git /tmp/kcov-src
	# The committed commit for the tag is the content pin; no tag-signature
	# check (runner keyrings never carry the upstream keys).
	supply_chain_verify_commit /tmp/kcov-src KCOV_COMMIT "$KCOV_VERSION" "$DEFAULT_KCOV_VERSION"
	cd /tmp/kcov-src

	# Verify we're on the expected tag
	CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
	if [[ "$CURRENT_TAG" != "$KCOV_VERSION" ]]; then
		echo "::error::Tag mismatch: expected $KCOV_VERSION, got $CURRENT_TAG"
		exit 1
	fi

	# Build and install (mkdir -p for idempotency)
	mkdir -p build
	cd build
	cmake ..
	make -j"$(nproc)"
	sudo make install
	cd -

	# Verify installation
	kcov --version
	exit 0
fi

# =============================================================================
# Step: run-tests - Run BATS tests
# =============================================================================
if [[ "$STEP" == "run-tests" ]]; then
	set +e

	: "${TEST_PATH:=tests/bats}"
	FILTER="${TEST_FILTER:-}"
	PARALLEL="${PARALLEL:-1}"

	# Validate PARALLEL is a positive integer
	if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
		echo "::warning::PARALLEL='$PARALLEL' is not a valid positive integer, defaulting to 1"
		PARALLEL=1
	fi

	# Build bats command
	BATS_ARGS=("--recursive" "--tap")

	if [[ -n "$FILTER" ]]; then
		BATS_ARGS+=("--filter" "$FILTER")
	fi

	if [[ "$PARALLEL" -gt 1 ]]; then
		BATS_ARGS+=("--jobs" "$PARALLEL")
	fi

	# Run tests
	echo "Running: bats ${BATS_ARGS[*]} $TEST_PATH"
	run_start_ts="$(date +%s)"
	begin_bats_output_guard
	bats "${BATS_ARGS[@]}" "$TEST_PATH" 2>&1 | tee bats-output.tap
	TEST_EXIT_CODE=${PIPESTATUS[0]}
	end_bats_output_guard
	write_bats_duration "$run_start_ts" "$(date +%s)"

	# Store raw output for parsing
	echo "exit-code=$TEST_EXIT_CODE" >>"$GITHUB_OUTPUT"

	exit "$TEST_EXIT_CODE"
fi

# =============================================================================
# Step: run-coverage - Run tests with kcov coverage
# =============================================================================
if [[ "$STEP" == "run-coverage" ]]; then
	set +e

	: "${TEST_PATH:=tests/bats}"
	FILTER="${TEST_FILTER:-}"
	PARALLEL="${PARALLEL:-1}"
	COVERAGE_DIR="${COVERAGE_DIR:-coverage-report}"
	# Suite-level timeout (minutes). Must stay below the coverage-run step
	# timeout (45) so timeout(1) fails the step with logs instead of a bare
	# job/step cancellation. See #556.
	SUITE_TIMEOUT_MINUTES="${KCOV_SUITE_TIMEOUT_MINUTES:-40}"

	# Validate PARALLEL is a positive integer
	if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
		echo "::warning::PARALLEL='$PARALLEL' is not a valid positive integer, defaulting to 1"
		PARALLEL=1
	fi

	SHARD_INDEX="${SHARD_INDEX:-0}"
	SHARD_TOTAL="${SHARD_TOTAL:-1}"
	if ! [[ "$SHARD_TOTAL" =~ ^[1-9][0-9]*$ ]] ||
		! [[ "$SHARD_INDEX" =~ ^(0|[1-9][0-9]*)$ ]] ||
		[[ "$SHARD_INDEX" -ge "$SHARD_TOTAL" ]]; then
		echo "::warning::SHARD_INDEX='${SHARD_INDEX}' SHARD_TOTAL='${SHARD_TOTAL}' is invalid (need integers 0 <= SHARD_INDEX < SHARD_TOTAL), defaulting to 0/1"
		SHARD_INDEX=0
		SHARD_TOTAL=1
	fi

	# Validate suite timeout is a positive integer (minutes)
	if ! [[ "$SUITE_TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
		echo "::warning::KCOV_SUITE_TIMEOUT_MINUTES='$SUITE_TIMEOUT_MINUTES' is not a valid positive integer, defaulting to 40"
		SUITE_TIMEOUT_MINUTES=40
	fi

	# kcov instruments via PS4/DEBUG trap; parallel BATS under kcov is a known
	# deadlock-prone combination. Always serialize coverage runs.
	if [[ "$PARALLEL" -gt 1 ]]; then
		echo "::notice::Serializing BATS under kcov (PARALLEL=$PARALLEL ignored; kcov+parallel is deadlock-prone)"
		PARALLEL=1
	fi

	if ! command -v timeout >/dev/null 2>&1; then
		echo "::error::timeout(1) is required for run-coverage (install coreutils)"
		exit 1
	fi

	mkdir -p "$COVERAGE_DIR"
	# kcov sets LD_PRELOAD to <outdir>/libkcov_sowrapper.so. Use an absolute
	# outdir so chdir inside tests does not break preload resolution (stderr
	# noise fails refute_output / exact-output assertions).
	COVERAGE_DIR="$(cd "$COVERAGE_DIR" && pwd)"

	# Resolve .bats files for diagnostics. Coverage itself must be a single
	# kcov→bats process: per-file kcov invocations do not merge bash coverage
	# with kcov v43 (empty cov.xml / 0% line-rate).
	TEST_FILES=()
	if [[ -f "$TEST_PATH" ]]; then
		TEST_FILES=("$TEST_PATH")
	elif [[ -d "$TEST_PATH" ]]; then
		while IFS= read -r test_file; do
			TEST_FILES+=("$test_file")
		done < <(find "$TEST_PATH" -type f -name '*.bats' | LC_ALL=C sort)
	else
		echo "::error::TEST_PATH not found: $TEST_PATH"
		exit 1
	fi

	if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
		echo "::error::No .bats files found under $TEST_PATH"
		exit 1
	fi

	# cksum(path) % N assignment. SHARD_TOTAL=1 skips filtering so the bats
	# argv stays byte-for-byte today's list (#874).
	if [[ "$SHARD_TOTAL" -gt 1 ]]; then
		filtered_files=()
		for test_file in "${TEST_FILES[@]}"; do
			shard=$(($(printf '%s' "$test_file" | cksum | cut -d' ' -f1) % SHARD_TOTAL))
			if [[ "$shard" -eq "$SHARD_INDEX" ]]; then
				filtered_files+=("$test_file")
			fi
		done
		if [[ ${#filtered_files[@]} -gt 0 ]]; then
			TEST_FILES=("${filtered_files[@]}")
		else
			# Bash 3.2 + set -u errors on "${arr[@]}" when arr is empty.
			TEST_FILES=()
		fi
	fi

	# Empty shard (every file hashed elsewhere) is success with 0 tests — do
	# not reuse the "No .bats files found" error.
	if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
		echo "coverage-plan shard=${SHARD_INDEX}/${SHARD_TOTAL} empty"
		: >bats-output.tap
		echo "exit-code=0" >>"$GITHUB_OUTPUT"
		echo "coverage-dir=$COVERAGE_DIR" >>"$GITHUB_OUTPUT"
		exit 0
	fi

	for test_file in "${TEST_FILES[@]}"; do
		echo "coverage-plan shard=${SHARD_INDEX}/${SHARD_TOTAL} file=${test_file}"
	done

	BATS_ARGS=(--tap)
	if [[ -n "$FILTER" ]]; then
		BATS_ARGS+=(--filter "$FILTER")
	fi
	# Never pass --jobs under kcov (serialized above).

	REPO_ROOT="$(pwd)"
	echo "coverage-start suite files=${#TEST_FILES[@]} timeout=${SUITE_TIMEOUT_MINUTES}m"
	start_ts="$(date +%s)"

	# Note: kcov instruments bash scripts via PS4/DEBUG trap
	# --bash-parse-files-in-dir: Pre-parse bash files for coverage mapping
	# --include-path: Only report coverage for library files
	# --exclude-pattern: Skip test infrastructure files
	# --kill-after: if bats/kcov ignore SIGTERM, SIGKILL after grace so timeout(1)
	# itself cannot hang waiting on an uninterruptible child (#556 / Greptile).
	begin_bats_output_guard
	timeout --signal=TERM --kill-after=30s "${SUITE_TIMEOUT_MINUTES}m" \
		kcov \
		--cobertura \
		--bash-parse-files-in-dir="${REPO_ROOT}/scripts/ci/lib" \
		--include-path="${REPO_ROOT}/scripts/ci/lib" \
		--exclude-pattern="/tests/,/tmp/,/bats-" \
		"$COVERAGE_DIR" \
		bats "${BATS_ARGS[@]}" "${TEST_FILES[@]}" 2>&1 |
		filter_kcov_console |
		tee bats-output.tap
	PIPE_STATUS=("${PIPESTATUS[@]}")
	KCOV_EXIT=${PIPE_STATUS[0]:-0}
	FILTER_EXIT=${PIPE_STATUS[1]:-0}
	TEE_EXIT=${PIPE_STATUS[2]:-0}
	end_bats_output_guard

	end_ts="$(date +%s)"
	elapsed=$((end_ts - start_ts))
	echo "coverage-finish suite elapsed=${elapsed}s exit=${KCOV_EXIT}"
	write_bats_duration "$start_ts" "$end_ts"

	# GNU timeout exits 124 when the command times out.
	if [[ "$KCOV_EXIT" -eq 124 ]]; then
		echo "::error::kcov/BATS timed out after ${SUITE_TIMEOUT_MINUTES}m (see last TAP lines / coverage-plan order for the hanging file)"
		EXIT_CODE=124
	elif [[ "$KCOV_EXIT" -ne 0 ]]; then
		EXIT_CODE="$KCOV_EXIT"
	elif [[ "$FILTER_EXIT" -ne 0 ]]; then
		EXIT_CODE="$FILTER_EXIT"
	else
		EXIT_CODE="$TEE_EXIT"
	fi

	echo "exit-code=$EXIT_CODE" >>"$GITHUB_OUTPUT"
	echo "coverage-dir=$COVERAGE_DIR" >>"$GITHUB_OUTPUT"
	exit "$EXIT_CODE"
fi

# =============================================================================
# Step: parse-results - Parse TAP output from test run
# =============================================================================
if [[ "$STEP" == "parse-results" ]]; then
	# TAP -> results.v1 (#1080); the outputs below come from the document.
	# A "# skip" directive counts as skipped (bats prints it as ok), so
	# tests-passed excludes skipped tests and tests-skipped reports them.
	: "${RESULTS_OUTPUT:=$(results_v1_path bats "${MATRIX_VALUE:-default}")}"
	TESTS_RAN="false"
	# The run step wrote this next to the TAP; never scan the tree for it.
	TESTS_DURATION_MS=0
	if [[ -f bats-duration-ms.txt ]]; then
		TESTS_DURATION_MS="$(tr -dc '0-9' <bats-duration-ms.txt)"
		: "${TESTS_DURATION_MS:=0}"
	fi
	if [[ -f bats-output.tap ]]; then
		RESULTS_ARTIFACTS=$'tap=bats-output.tap\n' \
			EXIT_CODE="${EXIT_CODE:-}" TESTS_DURATION_MS="$TESTS_DURATION_MS" \
			write_bats_results "$RESULTS_OUTPUT" bats-output.tap
	else
		EXIT_CODE="${EXIT_CODE:-}" write_bats_results "$RESULTS_OUTPUT"
	fi
	IFS=$'\t' read -r TOTAL PASSED FAILED < <(
		jq -r '[.counts.total, .counts.passed, .counts.failed] | @tsv' "$RESULTS_OUTPUT"
	)
	if [[ "$TOTAL" -gt 0 ]]; then
		TESTS_RAN="true"
	fi
	echo "tests-ran=$TESTS_RAN" >>"$GITHUB_OUTPUT"

	{
		echo "### Test Results"
		echo ""
		echo "| Metric | Count |"
		echo "|--------|-------|"
		echo "| Total | $TOTAL |"
		echo "| Passed | $PASSED |"
		echo "| Failed | $FAILED |"
	} >>"$GITHUB_STEP_SUMMARY"
	exit 0
fi

# =============================================================================
# Step: parse-coverage - Parse coverage results from kcov
# =============================================================================
if [[ "$STEP" == "parse-coverage" ]]; then
	COVERAGE_DIR="${COVERAGE_DIR:-coverage-report}"
	COVERAGE_PERCENT=""

	# Try to extract coverage from kcov output
	if [[ -d "$COVERAGE_DIR" ]]; then
		# Prefer index.html (legacy/default kcov output) when available.
		# Use POSIX-compatible sed (gawk's match with third arg is not portable)
		if [[ -f "$COVERAGE_DIR/index.html" ]]; then
			COVERAGE_PERCENT=$(sed -n 's/.*covered">\([0-9.]*\).*/\1/p' \
				"$COVERAGE_DIR/index.html" 2>/dev/null | head -n1)
		fi

		# Fall back to Cobertura-style XML (kcov may emit cov.xml)
		# Use POSIX-compatible sed (gawk's match with third arg is not portable)
		if [[ -z "$COVERAGE_PERCENT" ]] && [[ -f "$COVERAGE_DIR/cov.xml" ]]; then
			LINE_RATE=$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' \
				"$COVERAGE_DIR/cov.xml" 2>/dev/null | head -n1)
			if [[ -n "$LINE_RATE" ]]; then
				# Convert from decimal to percentage with proper rounding (using awk, no bc dependency)
				COVERAGE_PERCENT=$(echo "$LINE_RATE" | awk '{printf "%.0f", $1 * 100}' 2>/dev/null || echo "")
			fi
		fi

		# Fall back to cobertura.xml if cov.xml didn't yield a value
		# Use POSIX-compatible sed (gawk's match with third arg is not portable)
		if [[ -z "$COVERAGE_PERCENT" ]] && [[ -f "$COVERAGE_DIR/cobertura.xml" ]]; then
			LINE_RATE=$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' \
				"$COVERAGE_DIR/cobertura.xml" 2>/dev/null | head -n1)
			if [[ -n "$LINE_RATE" ]]; then
				# Convert from decimal to percentage with proper rounding (using awk, no bc dependency)
				COVERAGE_PERCENT=$(echo "$LINE_RATE" | awk '{printf "%.0f", $1 * 100}' 2>/dev/null || echo "")
			fi
		fi
	fi

	# Mark as N/A if no coverage data found (avoid false 0%)
	if [[ -z "$COVERAGE_PERCENT" ]]; then
		echo "::warning::Coverage data not found in ${COVERAGE_DIR}"
		COVERAGE_PERCENT="N/A"
	fi

	echo "coverage-percent=$COVERAGE_PERCENT" >>"$GITHUB_OUTPUT"

	{
		echo ""
		echo "### Coverage"
		echo ""
		if [[ "$COVERAGE_PERCENT" == "N/A" ]]; then
			echo "Coverage: N/A"
		else
			echo "Coverage: ${COVERAGE_PERCENT}%"
		fi
	} >>"$GITHUB_STEP_SUMMARY"
	exit 0
fi

# =============================================================================
# Step: check-threshold - Check if coverage meets threshold
# =============================================================================
if [[ "$STEP" == "check-threshold" ]]; then
	COVERAGE="${COVERAGE_PERCENT:-0}"
	THRESHOLD="${COVERAGE_THRESHOLD:-0}"

	if [[ -z "$COVERAGE" || "$COVERAGE" == "N/A" ]]; then
		echo "::error::Coverage data not found (kcov output missing)."
		exit 1
	fi

	# Strip trailing '%' if present and validate numeric format
	COVERAGE="${COVERAGE%\%}"
	THRESHOLD="${THRESHOLD%\%}"

	# Validate COVERAGE is numeric (integer or decimal)
	if ! [[ "$COVERAGE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		echo "::error::Invalid COVERAGE value: '$COVERAGE' (expected numeric)"
		exit 1
	fi

	# Validate THRESHOLD is numeric (integer or decimal)
	if ! [[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		echo "::error::Invalid COVERAGE_THRESHOLD value: '$THRESHOLD' (expected numeric)"
		exit 1
	fi

	echo "Coverage: ${COVERAGE}%"
	echo "Threshold: ${THRESHOLD}%"

	# Use awk for float comparison (POSIX-compatible, no bc dependency)
	# awk exits 1 if coverage is below threshold, 0 otherwise
	if ! awk -v cov="$COVERAGE" -v thresh="$THRESHOLD" 'BEGIN { exit (cov < thresh) }'; then
		echo "::error::Coverage ${COVERAGE}% is below threshold ${THRESHOLD}%"
		exit 1
	fi

	echo "Coverage ${COVERAGE}% meets threshold ${THRESHOLD}%"
	exit 0
fi

# =============================================================================
# Step: aggregate-results - Sum TAP totals across coverage shards
# =============================================================================
if [[ "$STEP" == "aggregate-results" ]]; then
	: "${SHARD_ARTIFACTS_DIR:?SHARD_ARTIFACTS_DIR is required}"

	if [[ ! -d "$SHARD_ARTIFACTS_DIR" ]]; then
		echo "::warning::SHARD_ARTIFACTS_DIR is missing: ${SHARD_ARTIFACTS_DIR}"
		mkdir -p "$SHARD_ARTIFACTS_DIR"
	fi

	TESTS_RAN="false"
	TAP_COUNT=0
	TAP_FILES=()

	while IFS= read -r tap_file; do
		TAP_COUNT=$((TAP_COUNT + 1))
		TAP_FILES+=("$tap_file")
		parse_tap_file "$tap_file" || true
		echo "aggregate-tap file=${tap_file} total=${TESTS_TOTAL} passed=${TESTS_PASSED} failed=${TESTS_FAILED} skipped=${TESTS_SKIPPED}"
	done < <(find "$SHARD_ARTIFACTS_DIR" -type f -name 'bats-output.tap' | LC_ALL=C sort)

	if [[ -n "${EXPECTED_SHARDS:-}" ]]; then
		if ! [[ "$EXPECTED_SHARDS" =~ ^[1-9][0-9]*$ ]]; then
			echo "::error::EXPECTED_SHARDS must be a positive integer, got: ${EXPECTED_SHARDS}"
			exit 1
		fi
		if [[ "$TAP_COUNT" -ne "$EXPECTED_SHARDS" ]]; then
			echo "::error::Expected ${EXPECTED_SHARDS} shard TAP files, found ${TAP_COUNT}"
			exit 1
		fi
	fi

	# Shard TAPs -> one results.v1 document (#1080); outputs come from it.
	: "${RESULTS_OUTPUT:=$(results_v1_path bats "${MATRIX_VALUE:-default}")}"
	TESTS_DURATION_MS="$(sum_bats_durations "$SHARD_ARTIFACTS_DIR")"
	if [[ "${#TAP_FILES[@]}" -gt 0 ]]; then
		RESULTS_ARTIFACTS="$(printf 'tap=%s\n' "${TAP_FILES[@]}")" \
		EXIT_CODE="${EXIT_CODE:-}" TESTS_DURATION_MS="$TESTS_DURATION_MS" \
			write_bats_results "$RESULTS_OUTPUT" "${TAP_FILES[@]}"
	else
		EXIT_CODE="${EXIT_CODE:-}" write_bats_results "$RESULTS_OUTPUT"
	fi
	IFS=$'\t' read -r TOTAL PASSED FAILED < <(
		jq -r '[.counts.total, .counts.passed, .counts.failed] | @tsv' "$RESULTS_OUTPUT"
	)
	if [[ "$TOTAL" -gt 0 ]]; then
		TESTS_RAN="true"
	fi
	echo "tests-ran=$TESTS_RAN" >>"$GITHUB_OUTPUT"

	{
		echo "### Test Results"
		echo ""
		echo "| Metric | Count |"
		echo "|--------|-------|"
		echo "| Total | $TOTAL |"
		echo "| Passed | $PASSED |"
		echo "| Failed | $FAILED |"
	} >>"$GITHUB_STEP_SUMMARY"
	exit 0
fi

# =============================================================================
# Step: merge-coverage - Merge per-shard Cobertura XML via merge-cobertura.py
# =============================================================================
if [[ "$STEP" == "merge-coverage" ]]; then
	: "${SHARD_COVERAGE_DIR:?SHARD_COVERAGE_DIR is required}"
	MERGED_COVERAGE_FILE="${MERGED_COVERAGE_FILE:-merged-cobertura.xml}"

	if [[ ! -d "$SHARD_COVERAGE_DIR" ]]; then
		echo "::error::SHARD_COVERAGE_DIR is not a directory: ${SHARD_COVERAGE_DIR}"
		exit 1
	fi

	xml_files=()
	shopt -s nullglob
	for shard_dir in "$SHARD_COVERAGE_DIR"/*; do
		if [[ ! -d "$shard_dir" ]]; then
			continue
		fi
		xml=""
		if [[ -f "$shard_dir/cov.xml" ]]; then
			xml="$shard_dir/cov.xml"
		elif [[ -f "$shard_dir/kcov-merged/cov.xml" ]]; then
			xml="$shard_dir/kcov-merged/cov.xml"
		elif [[ -f "$shard_dir/cobertura.xml" ]]; then
			xml="$shard_dir/cobertura.xml"
		else
			xml="$(find "$shard_dir" -type f -name 'cov.xml' | LC_ALL=C sort | head -n 1 || true)"
			if [[ -z "$xml" ]]; then
				xml="$(find "$shard_dir" -type f -name 'cobertura.xml' | LC_ALL=C sort | head -n 1 || true)"
			fi
		fi
		if [[ -n "$xml" ]]; then
			xml_files+=("$xml")
			echo "merge-coverage input=${xml}"
		fi
	done
	shopt -u nullglob

	if [[ ${#xml_files[@]} -eq 0 ]]; then
		echo "::error::No cov.xml or cobertura.xml found under ${SHARD_COVERAGE_DIR}"
		exit 1
	fi

	python3 "${SCRIPT_DIR}/merge-cobertura.py" \
		--output "$MERGED_COVERAGE_FILE" \
		"${xml_files[@]}"
	exit $?
fi

# Unknown step
echo "::error::Unknown STEP: $STEP"
echo "Valid steps: install-bats, install-kcov, run-tests, run-coverage, parse-results, parse-coverage, check-threshold, aggregate-results, merge-coverage"
exit 1
