#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/wait-for-artifacts.sh (#803)
#
# The gh mock replays a scripted sequence: each listing call consumes the next
# line of LIST_SEQUENCE, each download call for an id consumes the next line of
# that id's download sequence. `sleep` is stubbed so the backoff is recorded,
# not waited on, and the budget is exhausted by the scheduled sum.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="scripts/ci/actions/wait-for-artifacts.sh"

setup() {
	setup_temp_dir
	save_path
	export GITHUB_REPOSITORY="lgtm-hq/py-lintro"
	export GITHUB_RUN_ID="30249542557"
	export GH_TOKEN="test-token"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	export SLEEP_CALLS="${BATS_TEST_TMPDIR}/sleep_calls"
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export MOCK_STATE="${BATS_TEST_TMPDIR}/mock_state"
	mkdir -p "$MOCK_STATE"
	: >"$SLEEP_CALLS"
	: >"$GH_CALLS"
	unset DOWNLOAD_DIR MATRIX_JSON MATRIX_KEY WAIT_BUDGET_SECONDS BACKOFF_SCHEDULE GH_CMD_TIMEOUT TIMEOUT_BIN
	_mock_sleep
	_mock_timeout_passthrough
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Record each sleep instead of waiting.
_mock_sleep() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/sleep" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${SLEEP_CALLS}'
EOF
	chmod +x "${mock_bin}/sleep"
	export PATH="${mock_bin}:$PATH"
}

# Portable stand-in for coreutils `timeout`: strips flags and the bound, runs
# the command. macOS ships no `timeout`, so the suite must not depend on it.
_mock_timeout_passthrough() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
shift # the bound
exec "$@"
EOF
	chmod +x "${mock_bin}/timeout"
	export PATH="${mock_bin}:$PATH"
}

# A `timeout` stand-in that reports the bound tripped (exit 124) for every
# wrapped command, without running it.
# `timeout` reports 124 when the command died on SIGTERM and 137 when it had
# to be SIGKILLed after --kill-after; the default here is 124.
_mock_timeout_trips() {
	local code="${1:-124}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/timeout" <<EOF
#!/usr/bin/env bash
exit ${code}
EOF
	chmod +x "${mock_bin}/timeout"
}

# JSON for one listing page (already in the `--slurp` array shape) holding the
# given "id:name" or "id:name:sha256hex" artifacts. Without a digest the
# entry has `"digest": null`, as pre-v4 artifacts do.
_listing() {
	local items=() entry id name digest
	for entry in "$@"; do
		id="${entry%%:*}"
		name="${entry#*:}"
		digest="null"
		if [[ "$name" == *:* ]]; then
			digest="\"sha256:${name#*:}\""
			name="${name%%:*}"
		fi
		items+=("{\"id\":${id},\"name\":\"${name}\",\"expired\":false,\"digest\":${digest}}")
	done
	local joined
	joined="$(
		IFS=,
		printf '%s' "${items[*]}"
	)"
	printf '[{"total_count":%d,"artifacts":[%s]}]' "$#" "$joined"
}

# Install the gh mock. Listing responses come from the file written by
# _list_sequence; download responses for id N from _download_sequence N.
# A response line of "404" makes the call fail like gh does on HTTP 404; "500"
# fails with a server error; anything else is the response body.
_mock_gh() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> '${GH_CALLS}'
state='${MOCK_STATE}'

# Pop the first line of a sequence file; the last line repeats once exhausted.
pop() {
	local file="\$1" line rest
	[[ -s "\$file" ]] || { echo "gh mock: no scripted response in \$file" >&2; exit 97; }
	line="\$(head -n 1 "\$file")"
	rest="\$(tail -n +2 "\$file")"
	if [[ -n "\$rest" ]]; then
		printf '%s\n' "\$rest" > "\$file"
	fi
	printf '%s' "\$line"
}

respond() {
	local line="\$1"
	case "\$line" in
	404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
	403) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
	500) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
	*) printf '%s' "\$line" ;;
	esac
}

case "\$*" in
	*runs/*/artifacts*)
		respond "\$(pop "\$state/list")"
		;;
	*actions/artifacts/*/zip*)
		args="\$*"
		id="\${args#*actions/artifacts/}"
		id="\${id%%/*}"
		line="\$(pop "\$state/download-\$id")"
		case "\$line" in
		404|403|500) respond "\$line" ;;
		zip:*) cat "\${line#zip:}" ;;
		*) printf '%s' "\$line" ;;
		esac
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

_list_sequence() {
	printf '%s\n' "$@" >"${MOCK_STATE}/list"
}

_download_sequence() {
	local id="$1"
	shift
	printf '%s\n' "$@" >"${MOCK_STATE}/download-${id}"
}

# The download tests build real archives with `zip` and the script extracts
# with `unzip`; skip rather than fail confusingly on a host without them.
# Called at the top of each test, not inside _zip_for: `skip` has no effect in
# a command-substitution subshell.
_require_zip_tools() {
	command -v zip >/dev/null 2>&1 || skip "zip command not available"
	command -v unzip >/dev/null 2>&1 || skip "unzip command not available"
}

# Build a real zip holding a results.v1 results.json (#1080) for the given
# leg (its name recorded as matrix.value), echo its path.
_zip_for() {
	local name="$1" dir zip
	dir="${BATS_TEST_TMPDIR}/zips/${name}"
	zip="${BATS_TEST_TMPDIR}/zips/${name}.zip"
	mkdir -p "$dir"
	printf '{"tool":"pytest","status":"passed","counts":{"passed":1,"failed":0,"skipped":0,"total":1},"duration_ms":1,"artifacts":[],"source":{"runner":"run-pytest","version":"t"},"matrix":{"key":"leg","value":"%s"}}\n' "$name" >"${dir}/results.json"
	(cd "$dir" && zip -q "$zip" results.json)
	printf '%s' "$zip"
}

_count_calls() {
	local file="$1" needle="$2"
	grep -c -- "$needle" "$file" || true
}

run_wait() {
	run bash "${PROJECT_ROOT}/${SCRIPT}" "$@"
}

# =============================================================================
# Argument and environment validation
# =============================================================================

@test "wait-for-artifacts: requires EXPECTED_COUNT and PATTERN" {
	_mock_gh
	run_wait
	assert_failure
	assert_output --partial "usage: wait-for-artifacts.sh EXPECTED_COUNT PATTERN"

	run_wait 2
	assert_failure
	assert_output --partial "usage: wait-for-artifacts.sh EXPECTED_COUNT PATTERN"
}

@test "wait-for-artifacts: rejects a non-positive EXPECTED_COUNT" {
	_mock_gh
	run_wait 0 'python-results-*'
	assert_failure
	assert_output --partial "EXPECTED_COUNT must be a positive integer"

	run_wait two 'python-results-*'
	assert_failure
	assert_output --partial "EXPECTED_COUNT must be a positive integer"
}

@test "wait-for-artifacts: requires GH_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID" {
	_mock_gh
	run env -u GH_TOKEN bash "${PROJECT_ROOT}/${SCRIPT}" 2 'python-results-*'
	assert_failure
	assert_output --partial "GH_TOKEN is required"

	run env -u GITHUB_REPOSITORY bash "${PROJECT_ROOT}/${SCRIPT}" 2 'python-results-*'
	assert_failure
	assert_output --partial "GITHUB_REPOSITORY is required"

	run env -u GITHUB_RUN_ID bash "${PROJECT_ROOT}/${SCRIPT}" 2 'python-results-*'
	assert_failure
	assert_output --partial "GITHUB_RUN_ID is required"
}

@test "wait-for-artifacts: rejects a malformed BACKOFF_SCHEDULE" {
	_mock_gh
	BACKOFF_SCHEDULE="2 fast" run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "BACKOFF_SCHEDULE entries must be positive integers"
}

@test "wait-for-artifacts: rejects non-integer WAIT_BUDGET_SECONDS and GH_CMD_TIMEOUT" {
	_mock_gh
	WAIT_BUDGET_SECONDS="ninety" run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "WAIT_BUDGET_SECONDS must be a non-negative integer"

	GH_CMD_TIMEOUT=0 run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "GH_CMD_TIMEOUT must be a positive integer"
}

@test "wait-for-artifacts: rejects a whitespace-only BACKOFF_SCHEDULE" {
	_mock_gh
	BACKOFF_SCHEDULE="   " run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "BACKOFF_SCHEDULE must list at least one delay"
}

@test "wait-for-artifacts: an explicit TIMEOUT_BIN that is not on PATH fails loudly" {
	_mock_gh
	TIMEOUT_BIN=/nonexistent/timeout run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "TIMEOUT_BIN '/nonexistent/timeout' not found on PATH"
}

@test "wait-for-artifacts: fails loudly when no timeout binary is available" {
	_mock_gh
	rm -f "${BATS_TEST_TMPDIR}/bin/timeout"
	# Hide any real coreutils timeout/gtimeout: the bound must never be
	# silently dropped (#743).
	run env PATH="${BATS_TEST_TMPDIR}/bin:/nonexistent" /bin/bash "${PROJECT_ROOT}/${SCRIPT}" 2 'python-results-*'
	assert_failure
	assert_output --partial "coreutils timeout is required to bound gh calls"
}

# =============================================================================
# Listing: happy path
# =============================================================================

@test "wait-for-artifacts: exact count on the first poll succeeds with no sleep" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts matching 'python-results-*' on poll 1"
	assert_output --partial "python-results-3.11, python-results-3.14"
	[[ ! -s "$SLEEP_CALLS" ]] || fail "happy path must not sleep: $(cat "$SLEEP_CALLS")"
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "1" ]]
	assert_file_contains "$GITHUB_OUTPUT" '^polls=1$'
	assert_file_contains "$GITHUB_OUTPUT" '^artifact-count=2$'
	assert_file_contains "$GITHUB_OUTPUT" '^elapsed-seconds=[0-9]+$'
}

@test "wait-for-artifacts: lists with an explicit GET, pagination and the per-run endpoint" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"

	run_wait 1 'python-results-*'
	assert_success
	run cat "$GH_CALLS"
	assert_output --partial "api -X GET --paginate --slurp repos/lgtm-hq/py-lintro/actions/runs/30249542557/artifacts?per_page=100"
}

@test "wait-for-artifacts: ignores artifacts that do not match the pattern" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-coverage-3.11 3:python-results-3.14 4:node-results-22)"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts matching 'python-results-*'"
	refute_output --partial "python-coverage"
	refute_output --partial "node-results"
}

@test "wait-for-artifacts: ignores expired artifacts" {
	_mock_gh
	printf '[{"total_count":3,"artifacts":[{"id":1,"name":"python-results-3.11","expired":false},{"id":2,"name":"python-results-3.14","expired":false},{"id":3,"name":"python-results-3.9","expired":true}]}]' \
		>"${MOCK_STATE}/list"

	run_wait 2 'python-results-*'
	assert_success
	refute_output --partial "python-results-3.9"
}

@test "wait-for-artifacts: folds paginated pages into one count" {
	_mock_gh
	printf '[{"total_count":2,"artifacts":[{"id":1,"name":"python-results-3.11","expired":false}]},{"total_count":2,"artifacts":[{"id":2,"name":"python-results-3.14","expired":false}]}]' \
		>"${MOCK_STATE}/list"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts"
}

# =============================================================================
# Listing: under-count (retried) and over-count (not retried)
# =============================================================================

@test "wait-for-artifacts: under-count then complete retries with backoff and succeeds" {
	_mock_gh
	_list_sequence \
		"$(_listing 1:python-results-3.11)" \
		"$(_listing 1:python-results-3.11)" \
		"$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_success
	# The "budget left" figure also counts wall-clock time, so it is not pinned.
	assert_output --partial "Poll 1: found 1/2 artifacts matching 'python-results-*' (python-results-3.11); listing may lag uploads, retrying in 2s"
	assert_output --partial "Poll 2: found 1/2 artifacts matching 'python-results-*' (python-results-3.11); listing may lag uploads, retrying in 4s"
	assert_output --partial "Found 2/2 artifacts matching 'python-results-*' on poll 3"
	run cat "$SLEEP_CALLS"
	assert_output "2
4"
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "3" ]]
	assert_file_contains "$GITHUB_OUTPUT" '^polls=3$'
}

@test "wait-for-artifacts: zero matches is an under-count and is retried" {
	_mock_gh
	_list_sequence \
		"$(_listing)" \
		"$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Poll 1: found 0/2 artifacts matching 'python-results-*' (none)"
	assert_output --partial "Found 2/2 artifacts matching 'python-results-*' on poll 2"
}

@test "wait-for-artifacts: permanent under-count fails after the budget, naming the missing artifact" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Expected 2 artifacts matching 'python-results-*', found 1 after 7 polls over 90s (missing: python-results-3.14; found: python-results-3.11)"
	# 2+4+8+16+30+30 = 90 s: seven polls fit the budget, an eighth would not.
	[[ "$(cat "$SLEEP_CALLS")" == $'2\n4\n8\n16\n30\n30' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "7" ]]
}

@test "wait-for-artifacts: permanent under-count without a matrix still reports the found set and window" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export WAIT_BUDGET_SECONDS=10

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "found 1 after 4 polls over 10s (found: python-results-3.11)"
	refute_output --partial "missing:"
	# 2+4 = 6 s, then the 8 s step is clamped to the 4 s left so the whole
	# budget is used; nothing remains for a fifth poll.
	[[ "$(cat "$SLEEP_CALLS")" == $'2\n4\n4' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
}

@test "wait-for-artifacts: a zero budget polls exactly once" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export WAIT_BUDGET_SECONDS=0

	run_wait 2 'python-results-*'
	assert_failure
	# Wall-clock time counts too, so the window is not pinned to 0 s here.
	assert_output --regexp "found 1 after 1 polls over [0-9]+s"
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: honours a custom backoff schedule, repeating its last step" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export BACKOFF_SCHEDULE="1 3"
	export WAIT_BUDGET_SECONDS=10

	run_wait 2 'python-results-*'
	assert_failure
	# 1+3+3+3 = 10 spends the budget exactly; no fifth sleep follows.
	[[ "$(cat "$SLEEP_CALLS")" == $'1\n3\n3\n3' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
}

@test "wait-for-artifacts: over-count fails immediately without retrying" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14 3:python-results-3.12)"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Found 3 artifacts matching 'python-results-*' but expected 2: python-results-3.11, python-results-3.14, python-results-3.12"
	assert_output --partial "artifact-prefix"
	assert_output --partial "Not retrying"
	[[ ! -s "$SLEEP_CALLS" ]] || fail "over-count must not retry: $(cat "$SLEEP_CALLS")"
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "1" ]]
}

@test "wait-for-artifacts: over-count on a later poll still fails immediately" {
	_mock_gh
	_list_sequence \
		"$(_listing 1:python-results-3.11)" \
		"$(_listing 1:python-results-3.11 2:python-results-3.14 3:python-results-3.12)"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "Found 3 artifacts matching 'python-results-*' but expected 2"
	run cat "$SLEEP_CALLS"
	assert_output "2"
}

# =============================================================================
# Listing: unrelated errors are not retried
# =============================================================================

@test "wait-for-artifacts: a listing error other than under-count fails immediately" {
	_mock_gh
	_list_sequence 500

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact listing failed (poll 1, exit 1): gh: Internal Server Error (HTTP 500)"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "1" ]]
}

@test "wait-for-artifacts: a 403 on the listing names the actions: read grant and does not retry" {
	_mock_gh
	_list_sequence 403

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact listing was forbidden (poll 1)"
	assert_output --partial "HTTP 403"
	assert_output --partial "must grant 'actions: read'"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "1" ]]
}

@test "wait-for-artifacts: a listing that trips the timeout bound fails immediately" {
	_mock_gh
	_mock_timeout_trips
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact listing timed out after 30s (poll 1, exit 124); not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: every gh call runs under the timeout bound" {
	_require_zip_tools
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
	: >"$TIMEOUT_CALLS"
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TIMEOUT_CALLS"
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
shift
exec "$@"
EOF
	chmod +x "${mock_bin}/timeout"
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/results"
	export GH_CMD_TIMEOUT=7

	run_wait 1 'python-results-*'
	assert_success
	run cat "$TIMEOUT_CALLS"
	assert_line --index 0 --partial "--kill-after=10s 7 gh api -X GET --paginate --slurp repos/"
	assert_line --index 1 --partial "--kill-after=10s 7 gh api -X GET repos/lgtm-hq/py-lintro/actions/artifacts/1/zip"
	[[ "$(_count_calls "$TIMEOUT_CALLS" " gh ")" == "$(wc -l <"$GH_CALLS" | tr -d ' ')" ]]
}

# =============================================================================
# Download
# =============================================================================

@test "wait-for-artifacts: without DOWNLOAD_DIR only the listing is awaited" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_success
	[[ "$(_count_calls "$GH_CALLS" "/zip")" == "0" ]]
	refute_output --partial "Downloaded"
}

@test "wait-for-artifacts: downloads each listed artifact into DOWNLOAD_DIR/<name>/" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 2 "zip:$(_zip_for python-results-3.14)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Downloaded 2 artifact(s) to ${DOWNLOAD_DIR} in 2 request(s)"
	[[ -f "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
	[[ -f "${DOWNLOAD_DIR}/python-results-3.14/results.json" ]]
	run jq -r .matrix.value "${DOWNLOAD_DIR}/python-results-3.14/results.json"
	assert_output 'python-results-3.14'
	run cat "$GH_CALLS"
	assert_output --partial "api -X GET repos/lgtm-hq/py-lintro/actions/artifacts/1/zip"
	assert_output --partial "api -X GET repos/lgtm-hq/py-lintro/actions/artifacts/2/zip"
}

@test "wait-for-artifacts: downloaded layout aggregates with aggregate-results.sh" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 2 "zip:$(_zip_for python-results-3.14)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 2 'python-results-*'
	assert_success
	# The download tree must be exactly what aggregate-results.sh globs: one
	# results.json per leg, two legs for a two-entry matrix.
	run env RESULTS_DIR="$DOWNLOAD_DIR" \
		MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}' \
		bash "${PROJECT_ROOT}/scripts/ci/actions/aggregate-results.sh"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" '^passed=true$'
}

@test "wait-for-artifacts: 404 then 200 on download retries that artifact and succeeds" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 8646450086:python-results-3.11 8646450237:python-results-3.14)"
	_download_sequence 8646450086 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 8646450237 404 "zip:$(_zip_for python-results-3.14)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Artifact python-results-3.14 (id 8646450237) is listed but not yet downloadable (HTTP 404); retrying in 2s"
	assert_output --partial "Downloaded 2 artifact(s) to ${DOWNLOAD_DIR} in 3 request(s)"
	[[ -f "${DOWNLOAD_DIR}/python-results-3.14/results.json" ]]
	run cat "$SLEEP_CALLS"
	assert_output "2"
	[[ "$(_count_calls "$GH_CALLS" "artifacts/8646450237/zip")" == "2" ]]
	[[ "$(_count_calls "$GH_CALLS" "artifacts/8646450086/zip")" == "1" ]]
}

@test "wait-for-artifacts: download 404 retries share the wait budget and give up when it is spent" {
	_require_zip_tools
	_mock_gh
	_list_sequence \
		"$(_listing 1:python-results-3.11)" \
		"$(_listing 1:python-results-3.11 2:python-results-3.14)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 2 404
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"
	export WAIT_BUDGET_SECONDS=10

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "Artifact python-results-3.14 (id 2) still returned HTTP 404 after 4 download attempts over 10s; giving up"
	# 2 s spent on the listing retry leaves 8 s: the download's own backoff
	# restarts at 2, then 4, then the 8 s step is clamped to the 2 s left.
	[[ "$(cat "$SLEEP_CALLS")" == $'2\n2\n4\n2' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
	[[ "$(_count_calls "$GH_CALLS" "artifacts/2/zip")" == "4" ]]
}

@test "wait-for-artifacts: a non-404 download error fails immediately" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 2 500
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Download of artifact python-results-3.14 (id 2) failed (exit 1): gh: Internal Server Error (HTTP 500)"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "artifacts/2/zip")" == "1" ]]
}

@test "wait-for-artifacts: a download that trips the timeout bound fails immediately" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
shift
case "$*" in
*/zip*) exit 124 ;;
*) exec "$@" ;;
esac
EOF
	chmod +x "${mock_bin}/timeout"
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "Download of artifact python-results-3.11 (id 1) timed out after 30s (exit 124); not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: a corrupt archive is an integrity failure, not retried" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	_download_sequence 1 "this is not a zip"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact python-results-3.11 (id 1) downloaded but is not a valid zip; not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "artifacts/1/zip")" == "1" ]]
	[[ ! -f "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
}

# =============================================================================
# Name-based check when the matrix is known
# =============================================================================

@test "wait-for-artifacts: a sibling artifact standing in for a missing leg fails immediately when the matrix is known" {
	_mock_gh
	# Count matches (2 of 2) but 3.12 is not a leg of this matrix: a sibling
	# call's upload must not be aggregated in place of the missing 3.14.
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.12)"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "Artifacts outside the matrix (python-results-3.12)"
	assert_output --partial "artifact-prefix"
	assert_output --partial "Not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "runs/${GITHUB_RUN_ID}/artifacts")" == "1" ]]
}

@test "wait-for-artifacts: with the matrix known, the expected set passes regardless of listing order" {
	_mock_gh
	_list_sequence "$(_listing 2:python-results-3.14 1:python-results-3.11)"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts"
}

@test "wait-for-artifacts: fails when EXPECTED_COUNT and the matrix disagree" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 3 'python-results-*'
	assert_failure
	assert_output --partial "EXPECTED_COUNT is 3 but MATRIX_JSON names 2 legs"
	[[ ! -s "$GH_CALLS" ]]
}

@test "wait-for-artifacts: a MATRIX_KEY that names no include entry fails instead of silently losing the by-name check" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	export MATRIX_JSON='{"include":[{"node-version":"22"},{"node-version":"24"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "MATRIX_KEY 'python-version' matches no include entry of MATRIX_JSON"
	[[ ! -s "$GH_CALLS" ]]
}

@test "wait-for-artifacts: an empty include list with MATRIX_KEY set falls back to the count check" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	export MATRIX_JSON='{"include":[]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_success
}

@test "wait-for-artifacts: refuses an artifact name that is not a safe directory name" {
	_mock_gh
	printf '[{"total_count":2,"artifacts":[{"id":1,"name":"python-results-3.11","expired":false},{"id":2,"name":"python-results-../../etc","expired":false}]}]' \
		>"${MOCK_STATE}/list"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "is not a safe directory name; refusing to download"
	[[ "$(_count_calls "$GH_CALLS" "/zip")" == "0" ]]
}

@test "wait-for-artifacts: the reusable-workflow shape (matrix + download) succeeds end to end" {
	_require_zip_tools
	_mock_gh
	_list_sequence \
		"$(_listing 1:python-results-3.11)" \
		"$(_listing 1:python-results-3.11 2:python-results-3.14)"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 2 404 "zip:$(_zip_for python-results-3.14)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts matching 'python-results-*' on poll 2"
	assert_output --partial "Downloaded 2 artifact(s)"
	[[ -f "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
	[[ -f "${DOWNLOAD_DIR}/python-results-3.14/results.json" ]]
	[[ "$(cat "$SLEEP_CALLS")" == $'2\n2' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
}

# The run-level listing spans every attempt: after `Re-run failed jobs` the
# re-run leg's new upload sits next to the earlier attempt's copy of the same
# name. Dedupe by name, newest id wins — a rerun is not sibling contamination.
@test "wait-for-artifacts: a rerun's duplicate names collapse to the newest id instead of over-counting" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 10:python-results-3.11 11:python-results-3.14 42:python-results-3.14)"
	_download_sequence 10 "zip:$(_zip_for python-results-3.11)"
	_download_sequence 42 "zip:$(_zip_for python-results-3.14)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_success
	assert_output --partial "Found 2/2 artifacts"
	[[ "$(_count_calls "$GH_CALLS" "artifacts/42/zip")" == "1" ]]
	[[ "$(_count_calls "$GH_CALLS" "artifacts/11/zip")" == "0" ]]
}

@test "wait-for-artifacts: a MATRIX_JSON that does not parse fails instead of weakening the check" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	export MATRIX_JSON='{"include":['
	export MATRIX_KEY="python-version"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Expected artifact names could not be derived from MATRIX_JSON, MATRIX_KEY and PATTERN"
	[[ ! -s "$GH_CALLS" ]]
}

@test "wait-for-artifacts: a matrix include entry that is not an object fails instead of passing a partial name list" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	# jq would emit "python-results-3.11" and then fail on the number; a partial
	# list of one name must not satisfy EXPECTED_COUNT=1.
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},0]}'
	export MATRIX_KEY="python-version"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Expected artifact names could not be derived from MATRIX_JSON, MATRIX_KEY and PATTERN"
	[[ ! -s "$GH_CALLS" ]]
}

@test "wait-for-artifacts: a malformed MATRIX_JSON with EXPECTED_COUNT=1 does not pass via the diagnostic line" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export MATRIX_JSON='not json'
	export MATRIX_KEY="python-version"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Expected artifact names could not be derived from MATRIX_JSON, MATRIX_KEY and PATTERN"
}

@test "wait-for-artifacts: the final sleep is clamped to the remaining budget" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export BACKOFF_SCHEDULE="3"
	export WAIT_BUDGET_SECONDS=5

	run_wait 2 'python-results-*'
	assert_failure
	# 3 s, then 2 s of budget left: sleep exactly that, then fail at 5 s —
	# not at 3 s with budget unused.
	[[ "$(cat "$SLEEP_CALLS")" == $'3\n2' ]] || fail "unexpected backoff: $(cat "$SLEEP_CALLS")"
	assert_output --partial "after 3 polls over 5s"
}

# =============================================================================
# Digest verification
# =============================================================================

_sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

@test "wait-for-artifacts: a download matching the listed digest is accepted and reported as verified" {
	_require_zip_tools
	_mock_gh
	local zip
	zip="$(_zip_for python-results-3.11)"
	_list_sequence "$(_listing "1:python-results-3.11:$(_sha256_of "$zip")")"
	_download_sequence 1 "zip:${zip}"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_success
	assert_output --partial "Downloaded python-results-3.11 (id 1) to ${DOWNLOAD_DIR}/python-results-3.11 (digest verified)"
	[[ -f "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
}

@test "wait-for-artifacts: a download whose digest differs from the listing is an integrity failure, not retried" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing "1:python-results-3.11:$(printf 'a%.0s' {1..64})")"
	_download_sequence 1 "zip:$(_zip_for python-results-3.11)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact python-results-3.11 (id 1) digest mismatch: listing says sha256:aaaa"
	assert_output --partial "not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
	[[ "$(_count_calls "$GH_CALLS" "artifacts/1/zip")" == "1" ]]
	[[ ! -e "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
}

@test "wait-for-artifacts: scratch files are removed on every exit path" {
	_require_zip_tools
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	_download_sequence 1 "this is not a zip"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"
	export TMPDIR="${BATS_TEST_TMPDIR}/scratch"
	mkdir -p "$TMPDIR"

	run_wait 1 'python-results-*'
	assert_failure
	[[ -z "$(ls -A "$TMPDIR")" ]] || fail "scratch left behind: $(ls -A "$TMPDIR")"
}

@test "wait-for-artifacts: an archive whose entries escape the destination is refused" {
	_require_zip_tools
	command -v python3 >/dev/null 2>&1 || skip "python3 not available"
	_mock_gh
	# `zip` normalises away `..`, so craft the archive with Python's zipfile.
	local evil="${BATS_TEST_TMPDIR}/evil.zip"
	python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../escape.json", "{}")
    z.writestr("results.json", "{}")' "$evil"
	_list_sequence "$(_listing 1:python-results-3.11)"
	_download_sequence 1 "zip:${evil}"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact python-results-3.11 (id 1) contains entries that escape the destination directory; not retrying"
	# `../escape.json` relative to DOWNLOAD_DIR/python-results-3.11 lands in
	# DOWNLOAD_DIR itself; nothing may have been extracted at all.
	[[ ! -e "${DOWNLOAD_DIR}/escape.json" ]]
	[[ ! -e "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: a multi-wildcard PATTERN with the matrix set is rejected, not checked by count" {
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"
	export MATRIX_JSON='{"include":[{"python-version":"3.11"},{"python-version":"3.14"}]}'
	export MATRIX_KEY="python-version"

	run_wait 2 '*-results-*'
	assert_failure
	assert_output --partial "PATTERN '*-results-*' must contain exactly one '*' for MATRIX_KEY to fill"
	[[ ! -s "$GH_CALLS" ]]
}

@test "wait-for-artifacts: a listing killed after --kill-after (exit 137) is reported as a timeout" {
	_mock_gh
	_mock_timeout_trips 137
	_list_sequence "$(_listing 1:python-results-3.11 2:python-results-3.14)"

	run_wait 2 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact listing timed out after 30s (poll 1, exit 137); not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: a download killed after --kill-after (exit 137) is reported as a timeout" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
shift
case "$*" in
*/zip*) exit 137 ;;
*) exec "$@" ;;
esac
EOF
	chmod +x "${mock_bin}/timeout"
	_mock_gh
	_list_sequence "$(_listing 1:python-results-3.11)"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "Download of artifact python-results-3.11 (id 1) timed out after 30s (exit 137); not retrying"
	[[ ! -s "$SLEEP_CALLS" ]]
}

@test "wait-for-artifacts: an archive containing a symlink entry is refused" {
	_require_zip_tools
	_mock_gh
	local dir="${BATS_TEST_TMPDIR}/symlinked" zip="${BATS_TEST_TMPDIR}/symlinked.zip"
	mkdir -p "$dir"
	ln -s /etc/passwd "${dir}/link"
	printf '{}' >"${dir}/results.json"
	(cd "$dir" && zip -qy "$zip" link results.json)
	_list_sequence "$(_listing 1:python-results-3.11)"
	_download_sequence 1 "zip:${zip}"
	export DOWNLOAD_DIR="${BATS_TEST_TMPDIR}/python-results"

	run_wait 1 'python-results-*'
	assert_failure
	assert_output --partial "::error::Artifact python-results-3.11 (id 1) contains symlink entries; not retrying"
	[[ ! -e "${DOWNLOAD_DIR}/python-results-3.11/results.json" ]]
	[[ ! -s "$SLEEP_CALLS" ]]
}
