#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run BATS tests with optional coverage collection
#
# Environment variables:
#   STEP - Which step to run: install-bats, install-kcov, run-tests,
#          run-coverage, parse-results, parse-coverage, check-threshold
#   BATS_VERSION - BATS version to install (for install-bats step)
#   KCOV_VERSION - kcov version to install (for install-kcov step, default: v43)
#   TEST_PATH - Path to test files (for run-tests/run-coverage steps)
#   TEST_FILTER - Filter tests by name pattern (optional)
#   PARALLEL - Number of parallel jobs (optional, must be a positive integer)
#   COVERAGE_DIR - Directory for coverage output (for run-coverage step)
#   COVERAGE_PERCENT - Coverage percentage (for check-threshold step)
#   COVERAGE_THRESHOLD - Minimum coverage threshold (for check-threshold step)

set -euo pipefail

: "${STEP:=run-tests}"
: "${GITHUB_OUTPUT:=/dev/null}"
: "${GITHUB_STEP_SUMMARY:=/dev/null}"

# =============================================================================
# Step: install-bats - Install BATS core and helper libraries
# =============================================================================
if [[ "$STEP" == "install-bats" ]]; then
	: "${BATS_VERSION:=1.10.0}"
	# Normalize BATS_VERSION to avoid double "v" (strip leading "v" if present)
	BATS_VERSION="${BATS_VERSION#v}"
	: "${BATS_SUPPORT_VERSION:=v0.3.0}"
	: "${BATS_ASSERT_VERSION:=v2.2.4}"
	: "${BATS_FILE_VERSION:=v0.4.0}"

	# Install BATS core from source at specified version
	git clone --depth 1 --branch "v${BATS_VERSION}" \
		https://github.com/bats-core/bats-core.git /tmp/bats-core
	sudo /tmp/bats-core/install.sh /usr/local

	# Install bats helper libraries (pinned to tags)
	for lib in bats-support bats-assert bats-file; do
		case "$lib" in
		bats-support) version="$BATS_SUPPORT_VERSION" ;;
		bats-assert) version="$BATS_ASSERT_VERSION" ;;
		bats-file) version="$BATS_FILE_VERSION" ;;
		*) version="" ;;
		esac

		if [[ -z "$version" ]]; then
			echo "::error::Missing version for ${lib}"
			exit 1
		fi

		git clone --branch "$version" "https://github.com/bats-core/${lib}.git" "/tmp/${lib}"

		# Verify tag matches expected version
		if ! git -C "/tmp/${lib}" describe --tags --exact-match "$version" >/dev/null 2>&1; then
			echo "::error::Tag mismatch for ${lib}: expected $version"
			exit 1
		fi

		# Verify tag signature if GPG key is available
		if git -C "/tmp/${lib}" verify-tag "$version" 2>/dev/null; then
			echo "::notice::Tag $version signature verified for ${lib}"
		else
			echo "::warning::Could not verify tag signature for $version (GPG key not available)"
		fi

		sudo mkdir -p "/usr/lib/${lib}/src"
		sudo cp -r "/tmp/${lib}/src/"* "/usr/lib/${lib}/src/"
		sudo cp "/tmp/${lib}/load.bash" "/usr/lib/${lib}/"
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

	# Install kcov from source with integrity verification
	# KCOV_VERSION can be overridden via environment variable
	: "${KCOV_VERSION:=v43}"

	# Clone repo (need full history for tag verification)
	git clone --branch "$KCOV_VERSION" \
		https://github.com/SimonKagstrom/kcov.git /tmp/kcov-src
	cd /tmp/kcov-src

	# Verify we're on the expected tag
	CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
	if [[ "$CURRENT_TAG" != "$KCOV_VERSION" ]]; then
		echo "::error::Tag mismatch: expected $KCOV_VERSION, got $CURRENT_TAG"
		exit 1
	fi

	# Verify tag signature if GPG key is available
	if git verify-tag "$KCOV_VERSION" 2>/dev/null; then
		echo "::notice::Tag $KCOV_VERSION signature verified"
	else
		echo "::warning::Could not verify tag signature for $KCOV_VERSION (GPG key not available)"
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
	bats "${BATS_ARGS[@]}" "$TEST_PATH" 2>&1 | tee bats-output.tap

	TEST_EXIT_CODE=${PIPESTATUS[0]}

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

	# Validate PARALLEL is a positive integer
	if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
		echo "::warning::PARALLEL='$PARALLEL' is not a valid positive integer, defaulting to 1"
		PARALLEL=1
	fi

	mkdir -p "$COVERAGE_DIR"

	# Build bats command with same flags as main test step
	# Include --tap so parse-results can read bats-output.tap
	BATS_ARGS=("--recursive" "--tap")

	if [[ -n "$FILTER" ]]; then
		BATS_ARGS+=("--filter" "$FILTER")
	fi

	if [[ "$PARALLEL" -gt 1 ]]; then
		BATS_ARGS+=("--jobs" "$PARALLEL")
	fi

	# Run kcov with bats
	# Note: kcov instruments bash scripts via PS4/DEBUG trap
	# --bash-parse-files-in-dir: Pre-parse bash files for coverage mapping
	# --include-path: Only report coverage for library files
	# --exclude-pattern: Skip test infrastructure files
	echo "Running coverage: kcov ... bats ${BATS_ARGS[*]} $TEST_PATH"
	kcov \
		--cobertura \
		--bash-parse-files-in-dir="$(pwd)/scripts/ci/lib" \
		--include-path="$(pwd)/scripts/ci/lib" \
		--exclude-pattern="/tests/,/tmp/,/bats-" \
		"$COVERAGE_DIR" \
		bats "${BATS_ARGS[@]}" "$TEST_PATH" 2>&1 | tee bats-output.tap
	# Capture exit codes from both sides of the pipe
	PIPE_STATUS=("${PIPESTATUS[@]}")
	KCOV_EXIT=${PIPE_STATUS[0]}
	TEE_EXIT=${PIPE_STATUS[1]}
	# Use first non-zero exit code (prefer kcov/bats failure over tee)
	if [[ "$KCOV_EXIT" -ne 0 ]]; then
		EXIT_CODE="$KCOV_EXIT"
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
	# Parse TAP output
	TESTS_RAN="false"
	TOTAL=0
	PASSED=0
	FAILED=0

	if [[ -f bats-output.tap ]]; then
		# Use -E for extended regex (POSIX-compatible)
		# Assign separately to avoid || echo writing to GITHUB_OUTPUT
		TOTAL=$(grep -Ec "^(ok|not ok)" bats-output.tap 2>/dev/null) || TOTAL=0
		PASSED=$(grep -c "^ok " bats-output.tap 2>/dev/null) || PASSED=0
		FAILED=$(grep -c "^not ok" bats-output.tap 2>/dev/null) || FAILED=0
		# Mark tests as ran if TAP file exists and has content
		if [[ "$TOTAL" -gt 0 ]]; then
			TESTS_RAN="true"
		fi
	fi

	{
		echo "tests-total=$TOTAL"
		echo "tests-passed=$PASSED"
		echo "tests-failed=$FAILED"
		echo "tests-ran=$TESTS_RAN"
	} >>"$GITHUB_OUTPUT"

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

# Unknown step
echo "::error::Unknown STEP: $STEP"
echo "Valid steps: install-bats, install-kcov, run-tests, run-coverage, parse-results, parse-coverage, check-threshold"
exit 1
