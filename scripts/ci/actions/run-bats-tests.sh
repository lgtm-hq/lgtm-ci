#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run BATS tests with optional coverage collection
#
# Environment variables:
#   STEP - Which step to run: install-bats, install-kcov, run-tests,
#          run-coverage, shard-manifest, parse-results, parse-coverage,
#          check-threshold, aggregate-results, merge-coverage
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
#              plus bats-report.tap (#1539), which is counted instead when present
#   EXPECTED_SHARDS - Optional positive integer (aggregate-results,
#              merge-coverage). aggregate-results fails unless that many
#              shard TAP directories were found; an empty shard's `1..0` TAP
#              counts as present with 0 tests. merge-coverage refuses to merge
#              unless every shard wrote a completion manifest (#1531).
#   SHARD_MANIFEST_DIR - Optional (aggregate-results, with EXPECTED_SHARDS):
#              directory of the downloaded shard coverage artifacts. A shard
#              with no shard-complete.json there marks the results document
#              incomplete (#1531).
#   SHARD_ARTIFACTS_DOWNLOAD_OUTCOME / SHARD_ARTIFACTS_PATTERN - Optional
#              (aggregate-results, #1562): final outcome of the shard TAP
#              download after its retries, and the pattern it fetched. Any
#              outcome but success fails the step as a download failure.
#   SHARD_COVERAGE_DOWNLOAD_OUTCOME / SHARD_COVERAGE_PATTERN - Optional
#              (aggregate-results, merge-coverage, #1562): the same for the
#              shard coverage download. A failure is reported as such instead
#              of as shards that did not finish.
#   SHARD_COVERAGE_DIR - Directory of downloaded shard coverage artifacts
#              (merge-coverage). Each shard dir contributes cov.xml or
#              cobertura.xml, or an EMPTY_SHARD marker (shard had no tests,
#              skipped). A shard dir with neither is an error naming the shard.
#
# shard-manifest (#1531) writes shard-complete.json into COVERAGE_DIR. The
# workflow runs it in its own step only when the run was not cancelled and
# the run-coverage step wrote an exit-code output other than 124: that
# output is written only at the end of run-coverage, after kcov returns, so
# a cancel or a job timeout leaves it unset. A step timeout signals the
# script while kcov may still return, so run-coverage also writes
# interrupted=true from an INT/TERM trap, and the step requires it unset.
# EXIT_CODE and INTERRUPTED are those outputs. An empty shard writes its
# manifest from run-coverage itself.
#   MERGED_COVERAGE_FILE - Destination for merge-coverage XML.
#   COVERAGE_INCLUDE_PATHS - Comma-separated repo-relative paths kcov
#              instruments (run-coverage; default scripts/ci/lib). Each entry
#              is joined into one --include-path and one --bash-parse-files-in-dir list.
#              Fails when none exists in the checkout.
#   COVERAGE_ON_EMPTY - Policy when the kcov report has zero instrumented
#              lines (run-coverage, parse-coverage): "fail" (default) keeps
#              the 0% result; "not-applicable" reports coverage-percent
#              "n/a" and check-threshold skips the gate.
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

# #1531: a shard proves it finished by writing shard-complete.json into its
# coverage directory; a cancelled or timed-out shard writes none. Never fails
# the step: the missing manifest is the signal the aggregate reads. The
# manifest records GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT and GITHUB_SHA.
# Usage: write_shard_manifest <kcov-exit-code>
write_shard_manifest() {
	python3 "$SCRIPT_DIR/shard-completion.py" write \
		--coverage-dir "$COVERAGE_DIR" \
		--shard-index "$SHARD_INDEX" --shard-total "$SHARD_TOTAL" \
		--exit-code "$1" --run-id "${GITHUB_RUN_ID:-}" \
		--run-attempt "${GITHUB_RUN_ATTEMPT:-}" --sha "${GITHUB_SHA:-}" || true
}

# Print the incomplete reason when a shard of <expected> has no manifest
# under <dir>; print nothing when every shard finished. A manifest from
# another run ID or commit counts as missing; an earlier attempt of this
# run is accepted ("Re-run failed jobs" reuses its finished shards' artifacts
# on purpose, and they are true coverage for this commit).
# <download-outcome> and <pattern> (#1562) are the final outcome of the
# workflow's download of <dir> (after its retries) and the artifact pattern
# it fetched; a failed download is reported as such, not as unfinished shards.
# Usage: shard_incomplete_reason <dir> <expected> [<download-outcome> [<pattern>]]
# Fails closed: only exit 0 means every shard finished. Exit 1 prints the
# reason; a checker that crashes (a traceback also exits 1, with no reason),
# hits a usage error or cannot run is reported as incomplete too.
shard_incomplete_reason() {
	local reason rc=0
	reason="$(python3 "$SCRIPT_DIR/shard-completion.py" check --dir "$1" --expected "$2" \
		--run-id "${GITHUB_RUN_ID:-}" --sha "${GITHUB_SHA:-}" \
		--download-outcome "${3:-}" --artifact-pattern "${4:-}")" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		return 0
	fi
	if [[ "$rc" -eq 1 && -n "$reason" ]]; then
		printf '%s\n' "$reason"
		return 0
	fi
	echo "incomplete coverage: shard completion check failed (exit ${rc})"
}

# Trap handler for run-coverage (#1531): mark the step's outputs interrupted.
# Usage: mark_coverage_interrupted <signal-name>
mark_coverage_interrupted() {
	if [[ -z "${COVERAGE_INTERRUPTED:-}" ]]; then
		echo "interrupted=true" >>"$GITHUB_OUTPUT"
	fi
	COVERAGE_INTERRUPTED="$1"
	echo "::warning::run-coverage received SIG$1; this shard records no completion manifest" >&2
}

# Step summary table for a bats results.v1 document. Only the sharded
# aggregate can mark a document incomplete (#1531: a shard with no completion
# manifest); it then gets the partial-counts warning and partial row labels.
# Single-job documents never carry "incomplete" and render as before.
# A document with "tap_plan" (#1539: counted results differ from the summed
# 1..N plans) labels its totals approximate; the status is unchanged.
# Usage: write_bats_step_summary <results-file>
write_bats_step_summary() {
	local file="$1" total passed failed has_plan incomplete label=""
	IFS=$'\t' read -r total passed failed has_plan < <(
		jq -r '[.counts.total, .counts.passed, .counts.failed, has("tap_plan")] | @tsv' "$file"
	)
	if [[ "$has_plan" == "true" ]]; then
		label=" (approximate)"
	fi
	incomplete="$(results_v1_incomplete_reason "$file")"
	{
		echo "### Test Results"
		echo ""
		if [[ -n "$incomplete" && "$total" -eq 0 ]]; then
			echo "No test results were recorded before the run stopped (${incomplete})"
		else
			if [[ -n "$incomplete" ]]; then
				results_v1_partial_notice "$incomplete"
				echo ""
				label=" (partial)"
			fi
			echo "| Metric | Count |"
			echo "|--------|-------|"
			echo "| Total${label} | $total |"
			echo "| Passed${label} | $passed |"
			echo "| Failed${label} | $failed |"
			if [[ "$has_plan" == "true" && -z "$incomplete" ]]; then
				echo ""
				jq -r '"Totals are approximate: \(.tap_plan.reported) result lines against \(.tap_plan.planned) planned tests."' "$file"
			fi
		fi
	} >>"$GITHUB_STEP_SUMMARY"
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

# Bats 1.14 exits 1 when no test is found: a TEST_FILTER that matches nothing,
# or a coverage shard whose files hold no matching test while another shard
# runs them. Older bats passed with 0 tests; keep that result for callers.
# Probed, because a BATS_VERSION override may install a bats without the flag.
bats_supports_allow_empty_suite() {
	local help
	help="$(bats --help 2>/dev/null || true)"
	[[ "$help" == *--allow-empty-suite* ]]
}

# #1539: the console TAP (bats-output.tap) is the run's log. Under kcov it also
# carries xtrace output through 2>&1, which can split real result lines and
# print captured mock TAP as fake ones. Bats' own report file gets only its
# event stream, so the counts come from it when bats can write one. Probed
# like --allow-empty-suite; without it the console TAP is counted as before.
BATS_REPORT_FILE="bats-report.tap"

bats_supports_report_formatter() {
	local help
	help="$(bats --help 2>/dev/null || true)"
	[[ "$help" == *--report-formatter* ]]
}

# Add the report-file arguments to BATS_ARGS when bats supports them, and
# set BATS_REPORT_DIR to the directory bats writes report.tap into (empty
# otherwise). A stale report from an earlier run is removed first.
add_bats_report_args() {
	rm -f "$BATS_REPORT_FILE"
	BATS_REPORT_DIR=""
	if bats_supports_report_formatter; then
		BATS_REPORT_DIR="$(mktemp -d)"
		BATS_ARGS+=(--report-formatter tap --output "$BATS_REPORT_DIR")
	fi
}

# Move bats' report.tap to bats-report.tap next to the console TAP.
save_bats_report() {
	[[ -n "${BATS_REPORT_DIR:-}" ]] || return 0
	if [[ -f "$BATS_REPORT_DIR/report.tap" ]]; then
		mv "$BATS_REPORT_DIR/report.tap" "$BATS_REPORT_FILE"
	else
		echo "::warning::bats wrote no report file; test counts come from the console TAP"
	fi
	rm -rf "$BATS_REPORT_DIR"
}

# Print the TAP file to count in <dir>: bats-report.tap when present, else
# bats-output.tap, else nothing. Prints the bare name for ".".
# Usage: bats_result_tap <dir>
bats_result_tap() {
	local dir="$1" name
	for name in "$BATS_REPORT_FILE" bats-output.tap; do
		if [[ -f "$dir/$name" ]]; then
			if [[ "$dir" == "." ]]; then
				printf '%s\n' "$name"
			else
				printf '%s\n' "$dir/$name"
			fi
			return 0
		fi
	done
	return 0
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
# Helpers: kcov include paths and the empty-coverage policy (#1373)
# =============================================================================
# Print lines-valid of the first Cobertura report under $1, or nothing.
cobertura_lines_valid() {
	local dir="$1" xml=""
	if [[ -f "$dir/cov.xml" ]]; then
		xml="$dir/cov.xml"
	elif [[ -f "$dir/cobertura.xml" ]]; then
		xml="$dir/cobertura.xml"
	elif [[ -d "$dir" ]]; then
		xml="$(find "$dir" -type f \( -name 'cov.xml' -o -name 'cobertura.xml' \) | LC_ALL=C sort | head -n 1 || true)"
	fi
	if [[ -n "$xml" ]]; then
		sed -n 's/.*lines-valid="\([0-9]*\)".*/\1/p' "$xml" 2>/dev/null | head -n 1
	fi
	return 0
}

# Succeed when the report exists, has zero instrumented lines, and the
# COVERAGE_ON_EMPTY policy is "not-applicable".
coverage_not_applicable() {
	[[ "${COVERAGE_ON_EMPTY:-fail}" == "not-applicable" ]] || return 1
	[[ "$(cobertura_lines_valid "$1")" == "0" ]]
}

# =============================================================================
# Step: install-kcov - Install kcov for coverage collection
# =============================================================================
if [[ "$STEP" == "install-kcov" ]]; then
	# Install kcov dependencies through the shared apt helper: bounded
	# timeouts and retries, third-party sources left out (#1432).
	python3 -I "$SCRIPT_DIR/../lib/apt_helper.py" install \
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

	# Backport kcov#501 until a release includes it. Bash 5.3 traces Bats
	# 1.14's saved traps with ANSI-C quotes; v43 misreads escaped apostrophes
	# as multiline strings and silently drops subsequent coverage events.
	# Apply only to v43, after verifying its source commit; overrides of newer
	# releases must not receive a patch they may already contain.
	if [[ "$KCOV_VERSION" == "v43" ]]; then
		git apply "$SCRIPT_DIR/../patches/kcov-v43-ansi-c-quotes.patch"
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

	if bats_supports_allow_empty_suite; then
		BATS_ARGS+=("--allow-empty-suite")
	fi
	add_bats_report_args

	# Run tests
	echo "Running: bats ${BATS_ARGS[*]} $TEST_PATH"
	run_start_ts="$(date +%s)"
	begin_bats_output_guard
	# GNU parallel, which `bats --jobs` runs, reads $PARALLEL as its own
	# options: the step's PARALLEL=4 made it run "4" as a command and execute
	# no test ("Executed 0 instead of expected N"). The job count travels as
	# --jobs above, so bats never needs the variable.
	env -u PARALLEL bats "${BATS_ARGS[@]}" "$TEST_PATH" 2>&1 | tee bats-output.tap
	TEST_EXIT_CODE=${PIPESTATUS[0]}
	end_bats_output_guard
	write_bats_duration "$run_start_ts" "$(date +%s)"
	save_bats_report

	# Store raw output for parsing
	echo "exit-code=$TEST_EXIT_CODE" >>"$GITHUB_OUTPUT"

	exit "$TEST_EXIT_CODE"
fi

# =============================================================================
# Step: run-coverage - Run tests with kcov coverage
# =============================================================================
if [[ "$STEP" == "run-coverage" ]]; then
	set +e

	# #1531: a step timeout or a cancel signals this script, yet kcov can still
	# return (even exit 0) and let the step write exit-code. Record the signal
	# as interrupted=true so "Record shard completion" refuses the shard. Bash
	# runs the trap as soon as the foreground kcov pipeline returns, before
	# the exit-code line below, and never later than the step's next command,
	# so kcov returning cannot hide it. Nothing is forwarded to kcov (GNU
	# timeout runs it in its own process group, so it may not get the
	# signal); the gate does not depend on how it ends. exit-code is unchanged.
	COVERAGE_INTERRUPTED=""
	trap 'mark_coverage_interrupted INT' INT
	trap 'mark_coverage_interrupted TERM' TERM

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
		# A valid zero-test TAP plus a marker keep the shard's artifacts
		# present: the aggregate and merge steps treat a missing artifact
		# as a lost shard, so an empty one must still upload both.
		printf '1..0\n# shard %s/%s: no test files assigned\n' \
			"$SHARD_INDEX" "$SHARD_TOTAL" >bats-output.tap
		printf '1..0\n' >"$BATS_REPORT_FILE"
		write_bats_duration 0 0
		printf 'shard=%s/%s\n' "$SHARD_INDEX" "$SHARD_TOTAL" >"$COVERAGE_DIR/EMPTY_SHARD"
		[[ -z "$COVERAGE_INTERRUPTED" ]] && write_shard_manifest 0
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
	if bats_supports_allow_empty_suite; then
		BATS_ARGS+=(--allow-empty-suite)
	fi
	# kcov stops reading its own options at the command, so these reach bats.
	add_bats_report_args
	# Never pass --jobs under kcov (serialized above).

	REPO_ROOT="$(pwd)"

	# #1373: every existing COVERAGE_INCLUDE_PATHS entry is instrumented. kcov
	# keeps only the last --include-path / --bash-parse-files-in-dir it is
	# given, so the entries go in one comma-separated list per option (#1450).
	COVERAGE_ON_EMPTY="${COVERAGE_ON_EMPTY:-fail}"
	if [[ "$COVERAGE_ON_EMPTY" != "fail" && "$COVERAGE_ON_EMPTY" != "not-applicable" ]]; then
		echo "::error::coverage-on-empty must be 'fail' or 'not-applicable', got: ${COVERAGE_ON_EMPTY}"
		exit 1
	fi
	KCOV_PATH_ARGS=()
	KCOV_DIRS=()
	REQUESTED_PATHS=()
	IFS=',' read -r -a _include_entries <<<"${COVERAGE_INCLUDE_PATHS:-scripts/ci/lib}"
	for _entry in "${_include_entries[@]}"; do
		_entry="${_entry#"${_entry%%[![:space:]]*}"}"
		_entry="${_entry%"${_entry##*[![:space:]]}"}"
		_entry="${_entry#./}"
		_entry="${_entry%/}"
		[[ -n "$_entry" ]] || continue
		# Reject absolute paths and '..' as a whole path segment only, so names
		# that merely contain two dots (lib/foo..bar) stay valid.
		if [[ "$_entry" == /* || "$_entry" == .. || "$_entry" == ../* || "$_entry" == */../* || "$_entry" == */.. ]]; then
			echo "::error::coverage-include-path entries must be repo-relative paths without '..' segments, got: ${_entry}"
			exit 1
		fi
		REQUESTED_PATHS+=("$_entry")
		if [[ -e "${REPO_ROOT}/${_entry}" ]]; then
			KCOV_DIRS+=("${REPO_ROOT}/${_entry}")
		else
			echo "::warning::coverage-include-path entry not found in the checkout, skipped: ${_entry}"
		fi
	done
	if [[ ${#KCOV_DIRS[@]} -gt 0 ]]; then
		_kcov_list="$(
			IFS=,
			echo "${KCOV_DIRS[*]}"
		)"
		KCOV_PATH_ARGS=(
			"--bash-parse-files-in-dir=${_kcov_list}"
			"--include-path=${_kcov_list}"
		)
	fi
	if [[ ${#KCOV_PATH_ARGS[@]} -eq 0 ]]; then
		echo "::error::None of the coverage-include-path entries exist in the checkout (${REQUESTED_PATHS[*]:-none}); set the coverage-include-path input to your library path (COVERAGE_INCLUDE_PATHS)"
		exit 1
	fi

	echo "coverage-start suite files=${#TEST_FILES[@]} timeout=${SUITE_TIMEOUT_MINUTES}m"
	start_ts="$(date +%s)"

	# Note: kcov instruments bash scripts via PS4/DEBUG trap
	# --bash-parse-files-in-dir / --include-path: each takes the comma list of
	# COVERAGE_INCLUDE_PATHS entries (pre-parse and restrict the report)
	# --exclude-pattern: Skip test infrastructure files
	# --kill-after: if bats/kcov ignore SIGTERM, SIGKILL after grace so timeout(1)
	# itself cannot hang waiting on an uninterruptible child (#556 / Greptile).
	begin_bats_output_guard
	timeout --signal=TERM --kill-after=30s "${SUITE_TIMEOUT_MINUTES}m" \
		kcov \
		--cobertura \
		"${KCOV_PATH_ARGS[@]}" \
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
	save_bats_report

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

	# #1373: nothing instrumented. "fail" keeps the 0% result for the gate.
	if coverage_not_applicable "$COVERAGE_DIR"; then
		echo "::notice::Coverage not applicable: kcov instrumented 0 lines under ${REQUESTED_PATHS[*]} (coverage-on-empty=not-applicable)"
		echo "coverage-percent=n/a" >>"$GITHUB_OUTPUT"
	fi

	echo "exit-code=$EXIT_CODE" >>"$GITHUB_OUTPUT"
	echo "coverage-dir=$COVERAGE_DIR" >>"$GITHUB_OUTPUT"
	exit "$EXIT_CODE"
fi

# =============================================================================
# Step: shard-manifest - Record a finished coverage shard (#1531)
# =============================================================================
if [[ "$STEP" == "shard-manifest" ]]; then
	COVERAGE_DIR="${COVERAGE_DIR:-coverage-report}"
	SHARD_INDEX="${SHARD_INDEX:-0}"
	SHARD_TOTAL="${SHARD_TOTAL:-1}"
	# The workflow's step condition is the gate; this repeats it so a direct
	# call cannot record a run whose coverage step never reported an exit or
	# was signalled (INTERRUPTED is run-coverage's interrupted output).
	if [[ ! "${EXIT_CODE:-}" =~ ^[0-9]+$ || "${EXIT_CODE}" == "124" || "${INTERRUPTED:-}" == "true" ]]; then
		echo "::warning::shard ${SHARD_INDEX}/${SHARD_TOTAL} did not finish (exit-code '${EXIT_CODE:-}', interrupted '${INTERRUPTED:-}'); no completion manifest"
		exit 0
	fi
	write_shard_manifest "$EXIT_CODE"
	exit 0
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
	TAP_FILE="$(bats_result_tap .)"
	if [[ -n "$TAP_FILE" ]]; then
		RESULTS_ARTIFACTS="tap=${TAP_FILE}"$'\n' \
			EXIT_CODE="${EXIT_CODE:-}" TESTS_DURATION_MS="$TESTS_DURATION_MS" \
			write_bats_results "$RESULTS_OUTPUT" "$TAP_FILE"
	else
		EXIT_CODE="${EXIT_CODE:-}" write_bats_results "$RESULTS_OUTPUT"
	fi
	TOTAL="$(jq -r '.counts.total' "$RESULTS_OUTPUT")"
	if [[ "$TOTAL" -gt 0 ]]; then
		TESTS_RAN="true"
	fi
	echo "tests-ran=$TESTS_RAN" >>"$GITHUB_OUTPUT"
	write_bats_step_summary "$RESULTS_OUTPUT"
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

	# #1373: zero instrumented lines under coverage-on-empty=not-applicable
	if coverage_not_applicable "$COVERAGE_DIR"; then
		COVERAGE_PERCENT="n/a"
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
		if [[ "$COVERAGE_PERCENT" == "n/a" ]]; then
			echo "Coverage: n/a (no instrumented lines)"
		elif [[ "$COVERAGE_PERCENT" == "N/A" ]]; then
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

	if [[ "$COVERAGE" == "n/a" ]]; then
		echo "::notice::Coverage threshold skipped: not applicable (no instrumented lines, coverage-on-empty=not-applicable)"
		exit 0
	fi

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

	# One TAP per shard directory (#1539): its bats-report.tap when present,
	# else its bats-output.tap, so a shard is never counted from both.
	while IFS= read -r shard_dir; do
		tap_file="$(bats_result_tap "$shard_dir")"
		TAP_COUNT=$((TAP_COUNT + 1))
		TAP_FILES+=("$tap_file")
		parse_tap_file "$tap_file" || true
		echo "aggregate-tap file=${tap_file} total=${TESTS_TOTAL} passed=${TESTS_PASSED} failed=${TESTS_FAILED} skipped=${TESTS_SKIPPED}"
	done < <(find "$SHARD_ARTIFACTS_DIR" -type f \( -name 'bats-output.tap' -o -name "$BATS_REPORT_FILE" \) |
		sed 's|/[^/]*$||' | LC_ALL=C sort -u)

	if [[ -n "${EXPECTED_SHARDS:-}" ]]; then
		if ! [[ "$EXPECTED_SHARDS" =~ ^[1-9][0-9]*$ ]]; then
			echo "::error::EXPECTED_SHARDS must be a positive integer, got: ${EXPECTED_SHARDS}"
			exit 1
		fi
		# #1562: a failed download (after the workflow's retries) explains a
		# missing TAP better than the count does, and a partial download is
		# never aggregated even when the count happens to match.
		tap_outcome="${SHARD_ARTIFACTS_DOWNLOAD_OUTCOME:-}"
		if [[ -n "$tap_outcome" && "$tap_outcome" != "success" ]]; then
			tap_target="${SHARD_ARTIFACTS_PATTERN:-the shard TAP artifacts}"
			tap_detail="download outcome '${tap_outcome}' after retries"
			tap_detail+="; the error is in the download step logs"
			echo "::error::artifact download failed for ${tap_target} (${tap_detail});" \
				"found ${TAP_COUNT} of ${EXPECTED_SHARDS} shard TAP files"
			exit 1
		fi
		if [[ "$TAP_COUNT" -ne "$EXPECTED_SHARDS" ]]; then
			echo "::error::Expected ${EXPECTED_SHARDS} shard TAP files, found ${TAP_COUNT}"
			exit 1
		fi
	fi

	# #1531: a shard without a completion manifest (from this run and commit)
	# did not finish, so its TAP counts only part of its tests. The document still records
	# the partial counts, marked incomplete (status error), for diagnosis.
	RESULTS_INCOMPLETE=""
	if [[ -n "${SHARD_MANIFEST_DIR:-}" && -n "${EXPECTED_SHARDS:-}" ]]; then
		RESULTS_INCOMPLETE="$(shard_incomplete_reason "$SHARD_MANIFEST_DIR" "$EXPECTED_SHARDS" \
			"${SHARD_COVERAGE_DOWNLOAD_OUTCOME:-}" "${SHARD_COVERAGE_PATTERN:-}")"
		if [[ -n "$RESULTS_INCOMPLETE" ]]; then
			echo "::error::${RESULTS_INCOMPLETE}"
		fi
	fi
	export RESULTS_INCOMPLETE

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
	TOTAL="$(jq -r '.counts.total' "$RESULTS_OUTPUT")"
	if [[ "$TOTAL" -gt 0 ]]; then
		TESTS_RAN="true"
	fi
	echo "tests-ran=$TESTS_RAN" >>"$GITHUB_OUTPUT"
	write_bats_step_summary "$RESULTS_OUTPUT"
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

	# #1531: merging an unfinished shard's partial report publishes a
	# percentage for a run that never finished. Without every manifest, merge nothing;
	# the shard artifacts stay uploaded for diagnosis.
	if [[ -n "${EXPECTED_SHARDS:-}" ]]; then
		if ! [[ "$EXPECTED_SHARDS" =~ ^[1-9][0-9]*$ ]]; then
			echo "::error::EXPECTED_SHARDS must be a positive integer, got: ${EXPECTED_SHARDS}"
			exit 1
		fi
		incomplete="$(shard_incomplete_reason "$SHARD_COVERAGE_DIR" "$EXPECTED_SHARDS" \
			"${SHARD_COVERAGE_DOWNLOAD_OUTCOME:-}" "${SHARD_COVERAGE_PATTERN:-}")"
		if [[ -n "$incomplete" ]]; then
			echo "::error::${incomplete}"
			{
				echo ""
				echo "### Coverage"
				echo ""
				echo "Coverage: incomplete, not merged (${incomplete})"
			} >>"$GITHUB_STEP_SUMMARY"
			exit 1
		fi
	fi

	xml_files=()
	missing_shards=0
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
		elif [[ -n "$(find "$shard_dir" -type f -name 'EMPTY_SHARD' | head -n 1)" ]]; then
			echo "::notice::merge-coverage skipping empty shard $(basename "$shard_dir") (EMPTY_SHARD marker)"
		else
			echo "::error::Coverage shard $(basename "$shard_dir") has no cov.xml or cobertura.xml and no EMPTY_SHARD marker"
			missing_shards=$((missing_shards + 1))
		fi
	done
	shopt -u nullglob

	if [[ "$missing_shards" -gt 0 ]]; then
		exit 1
	fi

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
echo "Valid steps: install-bats, install-kcov, run-tests, run-coverage, shard-manifest, parse-results, parse-coverage, check-threshold, aggregate-results, merge-coverage"
exit 1
