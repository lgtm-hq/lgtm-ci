#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared setup, teardown and offline mocks for rerun-on-infra-failure suites

# shellcheck source=common.bash
load "${BASH_SOURCE[0]%/*}/common"
# shellcheck source=mocks.bash
load "${BASH_SOURCE[0]%/*}/mocks"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/rerun-on-infra-failure.sh"
	export GITHUB_REPOSITORY="lgtm-hq/Rustume"
	export GH_TOKEN="test-token"
	export RUN_ID="29252857248"
	export RUN_ATTEMPT="1"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	export RERUN_CALLS="${BATS_TEST_TMPDIR}/rerun_calls"
	export FETCH_CALLS="${BATS_TEST_TMPDIR}/fetch_calls"
	export SLEEP_CALLS="${BATS_TEST_TMPDIR}/sleep_calls"
	export API_CALLS="${BATS_TEST_TMPDIR}/api_calls"
	export JOBS_CALLS="${BATS_TEST_TMPDIR}/jobs_calls"
	export PROBE_DIR="${BATS_TEST_TMPDIR}/gh_probe"
	unset MAX_RERUNS SIGNATURES LOG_FETCH_ATTEMPTS LOG_FETCH_DELAY
	unset LOG_FETCH_DEADLINE GH_CMD_TIMEOUT TIMEOUT_BIN
	unset LOG_PROBE_MAX_JOBS LOG_PROBE_MAX_CALLS LOG_PROBE_CMD_TIMEOUT
	unset LOG_PROBE_TIME_BUDGET
	unset PROTECTED_WORKFLOWS PROTECTED_JOB_PATTERN ACQUISITION_MAX_JOBS
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Portable stand-in for coreutils `timeout` (#743). macOS ships no `timeout`, so
# depending on the real binary would make this suite pass on CI and fail
# locally; stubbing it unconditionally keeps both identical. It implements only
# the shape the script uses — flags, then "<seconds> cmd ..." — exits 124 when
# the bound trips, and blocks on a fifo rather than `sleep`, which this suite
# also stubs.
_mock_timeout() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${TIMEOUT_CALLS:-}" ]]; then
	echo "$*" >>"$TIMEOUT_CALLS"
fi
while [[ "$1" == -* ]]; do
	case "$1" in
	-k | -s) shift 2 ;;
	*) shift ;;
	esac
done
limit="$1"
shift

fifo="$(mktemp -u "${TMPDIR:-/tmp}/timeout-stub.XXXXXX")"
mkfifo "$fifo"
exec 9<>"$fifo"
rm -f "$fifo"

"$@" &
child=$!
(read -r -t "$limit" -u 9 _ || kill -TERM "$child" 2>/dev/null) &
watchdog=$!

status=0
wait "$child" || status=$?
printf 'done\n' >&9
wait "$watchdog" 2>/dev/null || true

# A command killed by the watchdog reports a signal status; report it the way
# coreutils timeout does.
if ((status > 128)); then
	exit 124
fi
exit "$status"
EOF
	chmod +x "${mock_bin}/timeout"
}

# Shell snippet for a gh mock that blocks for "$hang_for" seconds without
# sleeping, so the wrapping timeout is what ends it.
_gh_hang_snippet() {
	cat <<'EOF'
	hang_fifo="$(mktemp -u "${TMPDIR:-/tmp}/gh-hang.XXXXXX")"
	mkfifo "$hang_fifo"
	exec 8<>"$hang_fifo"
	rm -f "$hang_fifo"
	read -r -t "$hang_for" -u 8 _ || true
	exit 0
EOF
}

# Fixture store for the #794 ingestion probe: the attempt-jobs listing and the
# raw per-job logs the gh stub serves for `gh api`. Reset by every gh mock, so
# a test that says nothing about the probe still gets a well-defined, quiet
# stub (an empty listing) instead of an "unexpected gh call" error.
_init_probe_dir() {
	rm -rf "$PROBE_DIR"
	mkdir -p "$PROBE_DIR"
	: >"${PROBE_DIR}/listing"
	printf '0' >"${PROBE_DIR}/listing.status"
	: >"${PROBE_DIR}/joblog.default"
	printf '0' >"${PROBE_DIR}/joblog.default.status"
	: >"$API_CALLS"
	# #967 protection fixtures: an unprotected workflow, one eligible failed
	# job that ran its steps, and no annotations, so a test that says nothing
	# about protection re-runs as it always did.
	printf 'ci.yml\tCI' >"${PROBE_DIR}/run.meta"
	printf '0' >"${PROBE_DIR}/run.meta.status"
	printf '7\ttest\t3\n' >"${PROBE_DIR}/jobs.names"
	printf '0' >"${PROBE_DIR}/jobs.names.status"
	: >"${PROBE_DIR}/annotations.default"
	printf '0' >"${PROBE_DIR}/annotations.default.status"
	: >"$JOBS_CALLS"
}

# Set the run metadata the stub serves for `gh api .../actions/runs/<id>`:
# _run_meta <exit-code> <workflow path> <workflow name>.
_run_meta() {
	printf '%s' "$1" >"${PROBE_DIR}/run.meta.status"
	printf '%s\t%s' "$2" "$3" >"${PROBE_DIR}/run.meta"
}

# Set the failed-jobs listing the #967 guards read: "<exit-code>" then zero or
# more "<job-id>	<job name>	<steps that ran>" rows.
_failed_jobs() {
	local status="$1" row
	shift
	printf '%s' "$status" >"${PROBE_DIR}/jobs.names.status"
	: >"${PROBE_DIR}/jobs.names"
	for row in "$@"; do
		printf '%s\n' "$row" >>"${PROBE_DIR}/jobs.names"
	done
}

# Set the check-run annotation messages the stub serves for one job id (or
# "default"): _job_annotations <job-id|default> <exit-code> <messages>.
_job_annotations() {
	printf '%s' "$3" >"${PROBE_DIR}/annotations.${1}"
	printf '%s' "$2" >"${PROBE_DIR}/annotations.${1}.status"
}

# `gh api` branches for the #967 guards. Listed before the probe's cases: the
# guard's job listing hits the same attempt-jobs endpoint and is told apart by
# the `.name` in its jq filter, and the run-metadata pattern would otherwise
# swallow every /actions/runs/ URL.
_gh_guard_case() {
	cat <<EOF
	"api "*"/attempts/"*"/jobs"*".name"*)
		echo "\$*" >> '${JOBS_CALLS}'
		cat '${PROBE_DIR}/jobs.names'
		exit "\$(cat '${PROBE_DIR}/jobs.names.status')"
		;;
	"api "*"/check-runs/"*"/annotations"*)
		echo "\$*" >> '${JOBS_CALLS}'
		api_args="\$*"
		job_id="\${api_args##*/check-runs/}"
		job_id="\${job_id%%/annotations*}"
		ann_file='${PROBE_DIR}'"/annotations.\${job_id}"
		if [[ ! -f "\$ann_file" ]]; then
			ann_file='${PROBE_DIR}/annotations.default'
		fi
		cat "\$ann_file"
		exit "\$(cat "\${ann_file}.status")"
		;;
EOF
}

_gh_run_meta_case() {
	cat <<EOF
	"api "*"/actions/runs/"*".path"*)
		echo "\$*" >> '${JOBS_CALLS}'
		cat '${PROBE_DIR}/run.meta'
		exit "\$(cat '${PROBE_DIR}/run.meta.status')"
		;;
EOF
}

# Set the attempt-jobs listing the stub returns: "<exit-code>" then zero or more
# "<job-id>	<conclusion>	<completed-at>" rows.
_probe_listing() {
	local status="$1" row
	shift
	printf '%s' "$status" >"${PROBE_DIR}/listing.status"
	: >"${PROBE_DIR}/listing"
	for row in "$@"; do
		printf '%s\n' "$row" >>"${PROBE_DIR}/listing"
	done
}

# Set the raw log the stub serves for one job id (or "default" for all others):
# _probe_job_log <job-id|default> <exit-code> <payload>, or exit-code "hang"
# with the payload as a number of seconds to block for, so the probe's own
# timeout is what ends the call.
_probe_job_log() {
	local job_id="$1" status="$2" payload="$3"
	printf '%s' "$payload" >"${PROBE_DIR}/joblog.${job_id}"
	printf '%s' "$status" >"${PROBE_DIR}/joblog.${job_id}.status"
}

# `gh api` branches for the mock, serving the probe fixtures and recording every
# call so tests can assert on the flags used and on the call count.
_gh_api_case() {
	cat <<EOF
	"api "*"/attempts/"*"/jobs"*)
		echo "\$*" >> '${API_CALLS}'
		cat '${PROBE_DIR}/listing'
		exit "\$(cat '${PROBE_DIR}/listing.status')"
		;;
	"api "*"/actions/jobs/"*"/logs"*)
		echo "\$*" >> '${API_CALLS}'
		api_args="\$*"
		job_id="\${api_args##*/actions/jobs/}"
		job_id="\${job_id%%/logs*}"
		job_file='${PROBE_DIR}'"/joblog.\${job_id}"
		if [[ ! -f "\$job_file" ]]; then
			job_file='${PROBE_DIR}/joblog.default'
		fi
		job_status="\$(cat "\${job_file}.status")"
		if [[ "\$job_status" == "hang" ]]; then
			hang_for="\$(cat "\$job_file")"
$(_gh_hang_snippet)
		fi
		cat "\$job_file"
		exit "\$job_status"
		;;
EOF
}

# Mock gh: serve the given failed-job logs for `run view --log-failed` and
# record `run rerun` invocations. Optional arguments make `run rerun` block for
# that many seconds, and exit with that status.
_mock_gh() {
	local logs="$1" rerun_hang="${2:-0}" rerun_status="${3:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local logs_file="${mock_bin}/.failed_logs"
	printf '%s\n' "$logs" >"$logs_file"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		cat '${logs_file}'
		;;
$(_gh_guard_case)
$(_gh_api_case)
$(_gh_run_meta_case)
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		hang_for='${rerun_hang}'
		if [[ "\$hang_for" != "0" ]]; then
$(_gh_hang_snippet)
		fi
		exit '${rerun_status}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	_mock_timeout
	export PATH="${mock_bin}:$PATH"
}

# Mock gh with a per-attempt failed-log script (#716 ingestion race). Each
# argument describes one `run view --log-failed` attempt as
# "<exit-code>:<payload>", or as "hang:<seconds>" to make that attempt block
# until the wrapping timeout kills it (#743); attempts past the last spec repeat
# it. `run rerun` invocations are recorded as with _mock_gh.
_mock_gh_attempts() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local spec_dir="${BATS_TEST_TMPDIR}/gh_attempts"
	mkdir -p "$mock_bin" "$spec_dir"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

	local count=0 spec
	for spec in "$@"; do
		count=$((count + 1))
		printf '%s' "${spec#*:}" >"${spec_dir}/${count}.log"
		printf '%s' "${spec%%:*}" >"${spec_dir}/${count}.status"
	done
	printf '%s' "$count" >"${spec_dir}/count"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
spec_dir='${spec_dir}'
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		attempt=\$(grep -c '' '${FETCH_CALLS}')
		count=\$(cat "\${spec_dir}/count")
		if [[ "\$attempt" -gt "\$count" ]]; then
			attempt="\$count"
		fi
		status="\$(cat "\${spec_dir}/\${attempt}.status")"
		if [[ "\$status" == "hang" ]]; then
			hang_for="\$(cat "\${spec_dir}/\${attempt}.log")"
$(_gh_hang_snippet)
		fi
		cat "\${spec_dir}/\${attempt}.log"
		exit "\$status"
		;;
$(_gh_guard_case)
$(_gh_api_case)
$(_gh_run_meta_case)
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		;;
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	_mock_timeout
	export PATH="${mock_bin}:$PATH"
}

# Stub sleep so retry-loop tests record the backoff instead of waiting on it.
_mock_sleep() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$SLEEP_CALLS"

	cat >"${mock_bin}/sleep" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${SLEEP_CALLS}'
EOF
	chmod +x "${mock_bin}/sleep"
	export PATH="${mock_bin}:$PATH"
}

# Count lines in a recording file, tolerating a missing/empty file.
_call_count() {
	local file="$1"
	if [[ ! -s "$file" ]]; then
		echo 0
		return 0
	fi
	grep -c '' "$file"
}

# A PATH holding only what the script needs, so `timeout` can be made genuinely
# absent. Restricting PATH is the only way to test the fallback on a Linux
# runner, where /usr/bin/timeout cannot be hidden any other way.
_minimal_path_dir() {
	local dir="${BATS_TEST_TMPDIR}/sysbin" tool src
	mkdir -p "$dir"
	for tool in bash env cat chmod dirname grep kill mkfifo mktemp rm sleep; do
		src="$(command -v "$tool" 2>/dev/null)" || continue
		ln -sf "$src" "${dir}/${tool}"
	done
	printf '%s\n' "$dir"
}

# =============================================================================
# Silent-hang regression and the script-level watchdog (#776)
# =============================================================================

# Mock gh serving a large, whitespace-dense failed-job payload followed by a
# transient signature. Whitespace density is the point: the #776 hang was
# `${logs//[[:space:]]/}`, whose cost is O(length x matches), so it is the
# proportion of whitespace — not the size alone — that made a real failed-job
# log take minutes to classify.
_mock_gh_large_log() {
	local bytes="$1" trailer="$2"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$RERUN_CALLS"
	: >"$FETCH_CALLS"
	_init_probe_dir

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	run\ view\ *--log-failed*)
		echo "\$*" >> '${FETCH_CALLS}'
		yes '	shell-tests	2026-07-26T12:45:31.1234567Z ok 1 a test name with spaces' | head -c '${bytes}'
		printf '\n%s\n' '${trailer}'
		;;
	run\ rerun\ *)
		echo "\$*" >> '${RERUN_CALLS}'
		;;
$(_gh_guard_case)
	*)
		echo "unexpected gh call: \$*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "${mock_bin}/gh"
	_mock_timeout
	export PATH="${mock_bin}:$PATH"
}
