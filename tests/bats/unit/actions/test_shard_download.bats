#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/shard-download.sh (#1562)
#
# The pinned actions/download-artifact extracts into DIR/<name> when several
# artifacts match but straight into DIR when one does. These tests replay that
# layout by hand (no network) and feed the result to run-bats-tests.sh's
# merge-coverage step, the consumer that only visits subdirectories.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="scripts/ci/actions/shard-download.sh"
RUN_BATS="scripts/ci/actions/run-bats-tests.sh"
PATTERN="p-coverage-m-shard-*"

setup() {
	setup_temp_dir
	save_path
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/step_summary"
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
	export GITHUB_RUN_ID="42"
	export GITHUB_SHA="abc123"
	unset DOWNLOAD_OUTCOME DOWNLOAD_RETRY_1_OUTCOME DOWNLOAD_RETRY_2_OUTCOME
	DIR="${BATS_TEST_TMPDIR}/shard-coverage"
	SLEEP_CALLS="${BATS_TEST_TMPDIR}/sleep_calls"
	: >"$SLEEP_CALLS"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '#!/usr/bin/env bash\necho "$@" >>%q\n' "$SLEEP_CALLS" >"${mock_bin}/sleep"
	chmod +x "${mock_bin}/sleep"
	export PATH="${mock_bin}:$PATH"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Extract shard <index> of <total> into <dest> the way the action does: <dest>
# is DIR/<artifact-name> for a multi-match, DIR itself for a single match.
# Shard 0 covers both lines of a.sh; shard 1 covers neither line of b.sh, so
# the true merged coverage of a 2-shard run is 50%.
_extract_shard() {
	local dest="$1" index="$2" total="$3" file hits
	mkdir -p "$dest"
	if [[ "$index" -eq 0 ]]; then file="a.sh" hits=1; else file="b.sh" hits=0; fi
	printf '<coverage lines-valid="2"><class filename="%s"><lines>' "$file" >"$dest/cov.xml"
	printf '<line number="1" hits="%s"/><line number="2" hits="%s"/>' "$hits" "$hits" >>"$dest/cov.xml"
	printf '</lines></class></coverage>\n' >>"$dest/cov.xml"
	printf '{"schema":"lgtm-ci.shard-complete.v1","shard_index":%s,"shard_total":%s,' \
		"$index" "$total" >"$dest/shard-complete.json"
	printf '"run_id":"42","run_attempt":"1","sha":"abc123"}\n' >>"$dest/shard-complete.json"
}

_finalize() {
	run env DOWNLOAD_OUTCOME="${1:-}" DOWNLOAD_RETRY_1_OUTCOME="${2:-}" \
		DOWNLOAD_RETRY_2_OUTCOME="${3:-}" bash "$SCRIPT" finalize "$DIR"
}

_merge() {
	run env STEP=merge-coverage SHARD_COVERAGE_DIR="$DIR" EXPECTED_SHARDS="$1" \
		MERGED_COVERAGE_FILE="$BATS_TEST_TMPDIR/merged.xml" \
		SHARD_COVERAGE_DOWNLOAD_OUTCOME="$2" SHARD_COVERAGE_PATTERN="$PATTERN" \
		bash "$RUN_BATS"
}

_final_outcome() {
	sed -n 's/^outcome=//p' "$GITHUB_OUTPUT" | tail -n 1
}

# --- Sol's trace ----------------------------------------------------------

@test "without the reset, Sol's trace silently drops shard B's coverage (the hazard)" {
	# Attempt 1: both match, A lands in DIR/A, B fails. Attempt 2: only B
	# matches and lands at the root. The completion check passes; the merge
	# never sees B and reports 100% instead of 50%.
	_extract_shard "$DIR/p-coverage-m-shard-0" 0 2
	_extract_shard "$DIR" 1 2

	_merge 2 success

	assert_success
	assert_output --partial "merged coverage: 100%"
	refute_output --partial "/shard-coverage/cov.xml"
}

@test "reset before the retry, then finalize: Sol's trace fails closed, never 100% (#1562)" {
	_extract_shard "$DIR/p-coverage-m-shard-0" 0 2 # attempt 1, partial

	run bash "$SCRIPT" reset "$DIR" 15
	assert_success
	assert [ -d "$DIR" ]
	run find "$DIR" -mindepth 1
	assert_output ""
	run cat "$SLEEP_CALLS"
	assert_output "15"

	_extract_shard "$DIR" 1 2 # attempt 2 matched only B: root extraction
	_finalize failure success
	assert_success
	assert [ "$(_final_outcome)" = "success" ]
	assert [ -f "$DIR/single-artifact/cov.xml" ]
	assert [ ! -e "$DIR/cov.xml" ]

	_merge 2 "$(_final_outcome)"
	assert_failure
	assert_output --partial "shard(s) 0 did not finish"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "finalize relocates a root extraction, dotfiles included (#1562)" {
	_extract_shard "$DIR" 1 2
	: >"$DIR/.hidden"

	_finalize success
	assert_success
	assert_output --partial "moved the single artifact"

	run find "$DIR" -mindepth 1 -maxdepth 1
	assert_output "$DIR/single-artifact"
	grep -q 'b.sh' "$DIR/single-artifact/cov.xml"
	assert [ -f "$DIR/single-artifact/.hidden" ]
}

@test "finalize fails closed on a mixed layout (an attempt that was not cleared) (#1562)" {
	_extract_shard "$DIR/p-coverage-m-shard-0" 0 2
	_extract_shard "$DIR" 1 2

	_finalize failure success
	assert_success
	assert_output --partial "has a shard-complete.json at its root and"
	assert_output --partial "at p-coverage-m-shard-0/shard-complete.json"
	assert [ "$(_final_outcome)" = "failure" ]
	assert [ -f "$DIR/cov.xml" ]

	_merge 2 "$(_final_outcome)"
	assert_failure
	assert_output --partial "artifact download failed for ${PATTERN}"
	refute_output --partial "merged coverage"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "finalize fails closed on a manifest nested deeper than one level (#1562)" {
	# Sol: shard 0 at the root, shard 1 under x/y/. Wrapping both into
	# single-artifact/ let merge read one report and claim 100%.
	_extract_shard "$DIR" 0 2
	_extract_shard "$DIR/x/y" 1 2

	_finalize success
	assert_success
	assert_output --partial "at x/y/shard-complete.json"
	assert [ "$(_final_outcome)" = "failure" ]
	assert [ ! -e "$DIR/single-artifact" ]

	_merge 2 "$(_final_outcome)"
	assert_failure
	refute_output --partial "merged coverage"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "finalize fails closed when a root file blocks single-artifact/ (#1562)" {
	# Errexit is off inside a function called in a condition; the failed
	# mkdir must still fail the outcome, never report success.
	_extract_shard "$DIR" 1 2
	: >"$DIR/single-artifact"

	_finalize success
	assert_success
	assert_output --partial "cannot create"
	refute_output --partial "moved the single artifact"
	assert [ "$(_final_outcome)" = "failure" ]

	_merge 1 "$(_final_outcome)"
	assert_failure
	refute_output --partial "merged coverage"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "finalize fails closed when the download directory is not writable (#1562)" {
	if [[ "$(id -u)" -eq 0 ]]; then
		skip "root ignores directory permissions"
	fi
	_extract_shard "$DIR" 1 2
	chmod 555 "$DIR"

	_finalize success
	chmod 755 "$DIR"
	assert_success
	assert_output --partial "cannot create"
	refute_output --partial "moved the single artifact"
	assert [ "$(_final_outcome)" = "failure" ]
	assert [ -f "$DIR/cov.xml" ]

	_merge 1 "$(_final_outcome)"
	assert_failure
	refute_output --partial "merged coverage"
	assert [ ! -e "$BATS_TEST_TMPDIR/merged.xml" ]
}

# --- normal layouts keep working -------------------------------------------

@test "finalize leaves a multi-artifact layout alone and it merges at 50% (#1562)" {
	_extract_shard "$DIR/p-coverage-m-shard-0" 0 2
	_extract_shard "$DIR/p-coverage-m-shard-1" 1 2

	_finalize success
	assert_success
	assert [ "$(_final_outcome)" = "success" ]
	assert [ ! -e "$DIR/single-artifact" ]

	_merge 2 success
	assert_success
	assert_output --partial "merged coverage: 50%"
}

@test "finalize decides by content: a brace pattern's two artifact dirs stay put (#1562)" {
	# minimatch expands p-coverage-{m,n}-shard-*; a bash glob does not, so
	# name-based detection wrapped both dirs into single-artifact/ and the
	# merge picked one report (100%). No root manifest: layout untouched.
	PATTERN="p-coverage-{m,n}-shard-*"
	_extract_shard "$DIR/p-coverage-m-shard-0" 0 2
	_extract_shard "$DIR/p-coverage-n-shard-1" 1 2

	_finalize success
	assert_success
	assert [ "$(_final_outcome)" = "success" ]
	assert [ ! -e "$DIR/single-artifact" ]
	assert [ -f "$DIR/p-coverage-m-shard-0/cov.xml" ]
	assert [ -f "$DIR/p-coverage-n-shard-1/cov.xml" ]

	_merge 2 success
	assert_success
	assert_output --partial "merged coverage: 50%"
}

@test "finalize leaves a root without a manifest alone (#1562)" {
	mkdir -p "$DIR/p-coverage-m-shard-0"
	: >"$DIR/stray.txt"

	_finalize success
	assert_success
	assert [ "$(_final_outcome)" = "success" ]
	assert [ ! -e "$DIR/single-artifact" ]
	assert [ -f "$DIR/stray.txt" ]
}

@test "single shard (count 1): a root extraction on the first try still merges (#1562)" {
	_extract_shard "$DIR" 0 1

	_finalize success
	assert_success
	assert [ "$(_final_outcome)" = "success" ]
	assert [ -f "$DIR/single-artifact/shard-complete.json" ]

	_merge 1 success
	assert_success
	assert_output --partial "merged coverage: 100%"
	assert [ -s "$BATS_TEST_TMPDIR/merged.xml" ]
}

@test "finalize on a missing directory keeps the folded outcome" {
	_finalize failure failure failure
	assert_success
	assert [ "$(_final_outcome)" = "failure" ]
}

# --- outcome folding ---------------------------------------------------------

@test "finalize folds the attempts: any success wins, else the last attempt" {
	local case expected
	for case in "success,,:success" "failure,success,:success" \
		"failure,failure,success:success" "failure,failure,failure:failure" \
		"cancelled,,:failure" "failure,failure,cancelled:cancelled"; do
		expected="${case##*:}"
		IFS=, read -r first retry_1 retry_2 <<<"${case%:*}"
		: >"$GITHUB_OUTPUT"
		_finalize "$first" "$retry_1" "$retry_2"
		assert_success
		assert [ "$(_final_outcome)" = "$expected" ]
	done
}

# --- argument handling -------------------------------------------------------

@test "reset without seconds clears without sleeping" {
	mkdir -p "$DIR/stale"
	run bash "$SCRIPT" reset "$DIR"
	assert_success
	assert [ ! -e "$DIR/stale" ]
	run cat "$SLEEP_CALLS"
	assert_output ""
}

@test "reset refuses an unsafe directory or a bad delay" {
	run bash "$SCRIPT" reset /
	assert_failure 2
	run bash "$SCRIPT" reset ""
	assert_failure 2
	run bash "$SCRIPT" reset "$DIR" soon
	assert_failure 2
}

@test "usage errors exit 2" {
	run bash "$SCRIPT"
	assert_failure 2
	run bash "$SCRIPT" finalize
	assert_failure 2
	run bash "$SCRIPT" finalize "$DIR" "$PATTERN"
	assert_failure 2
	run bash "$SCRIPT" bogus "$DIR"
	assert_failure 2
}
