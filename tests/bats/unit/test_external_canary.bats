#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Runner expressions and Markdown assertions intentionally use literal quotes.
# shellcheck disable=SC2016
# Purpose: Unit tests for scripts/ci/actions/external-canary.sh (#1074)
#
# `gh` is mocked: every call is appended to $MOCK_CALLS; GET responses come
# from a fake fixture checkout and a sequence of run-list snapshots so the
# poll loop can be driven through in-progress -> completed, failure and
# timeout without touching the network.

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/fake_timeout"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/external-canary.sh"
CANDIDATE="1111111111111111111111111111111111111111"
OLD_PIN="f29da756f9f1673d6d10c5b956480807e5dc8a9b"

# Runner *file* for calling functions of the script. Under kcov (CI
# coverage) `bash -c "source ..."` leaves BASH_SOURCE unbound and the
# script's `set -u` aborts; a script file keeps it bound (see
# test_egress_presets_rendered.bats). Usage: bash "$CANARY_EVAL" '<cmd>'
_write_canary_eval() {
	export CANARY_EVAL="${BATS_TEST_TMPDIR}/canary-eval.sh"
	printf '%s\n' '# shellcheck disable=SC1090' 'source "$SCRIPT"' 'eval "$1"' >"$CANARY_EVAL"
}

# Print infra_canary_signatures from a script file, not `bash -c`, for the
# kcov reason above: the library sets -u and kcov's trace reads BASH_SOURCE.
_canary_signatures() {
	local runner="${BATS_TEST_TMPDIR}/signatures.sh"
	printf '%s\n' '# shellcheck disable=SC1090' \
		"source '${PROJECT_ROOT}/scripts/ci/lib/infra-signatures.sh'" \
		'infra_canary_signatures' >"$runner"
	bash "$runner"
}

setup() {
	setup_temp_dir
	save_path
	export SCRIPT CANDIDATE OLD_PIN
	export GITHUB_RUN_ID=12345 GITHUB_RUN_ATTEMPT=1
	export CANARY_TEST_BRANCH="canary/${CANDIDATE}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
	export GH_TOKEN=fixture-token
	export LGTM_CI_TOKEN=lgtm-ci-token
	export FIXTURE_REPO=owner/fixture
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export CANARY_POLL_SECONDS=0
	export CANARY_WRITE_RETRY_SECONDS=0
	export CANARY_TIMEOUT_SECONDS=60
	export CANARY_CLEANUP_POLL_SECONDS=0
	export CANARY_QUEUE_TIMEOUT_SECONDS=60
	export CANARY_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	# The fake fixture exposes one gate; the default expected-gate list would
	# report every other gate as not_dispatchable.
	export CANARY_EXPECTED_GATES="python"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output.txt"
	: >"$GITHUB_STEP_SUMMARY"
	: >"$GITHUB_OUTPUT"

	# Fake fixture: a gate, an informational negative, a manual release path,
	# and one push-only workflow.
	export MOCK_FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixture"
	mkdir -p "$MOCK_FIXTURE_DIR"
	cat >"$MOCK_FIXTURE_DIR/python.yml" <<EOF
name: fixture-python
"on":
  workflow_dispatch:
  push:
    branches: [main]
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@${OLD_PIN}
  direct:
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@${OLD_PIN}
      - uses: actions/checkout@${OLD_PIN}
EOF
	cat >"$MOCK_FIXTURE_DIR/verify-negative.yml" <<EOF
name: fixture-verify-negative
"on":
  workflow_dispatch:
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@${OLD_PIN}
EOF
	cat >"$MOCK_FIXTURE_DIR/release-version-pr.yml" <<EOF
name: fixture-release-version-pr
"on":
  workflow_dispatch:
jobs:
  pr:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@${OLD_PIN}
EOF
	cat >"$MOCK_FIXTURE_DIR/starter-python.yml" <<EOF
name: CI
"on":
  push:
    branches: [main]
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@${OLD_PIN}
EOF

	export MOCK_RUNS_DIR="${BATS_TEST_TMPDIR}/runs"
	mkdir -p "$MOCK_RUNS_DIR"
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/gh-calls.log"
	export MOCK_POSTED_TREE="${BATS_TEST_TMPDIR}/posted-tree.json"
	export MOCK_ABSENT="${BATS_TEST_TMPDIR}/absent.txt"
	export MOCK_REUSABLES="${BATS_TEST_TMPDIR}/reusables"
	export MOCK_MERGE_BASE="2222222222222222222222222222222222222222"
	: >"$MOCK_ABSENT"
	: >"$MOCK_CALLS"
	install_mock_gh
	_write_canary_eval
}

teardown() {
	restore_path
	teardown_temp_dir
}

# gh mock: dispatches on the argument string. Run-list snapshots are served
# in order from $MOCK_RUNS_DIR/runs.<n>; the last one repeats. Failure
# injection: MOCK_PR_FILES_FAIL, MOCK_TREE_FAIL_FIRST, MOCK_TREE_FAIL_ALWAYS,
# MOCK_REF_FAIL, MOCK_DISPATCH_FAIL=<file>, MOCK_RUNS_FAIL_AT=<n>,
# MOCK_DELETE_FAIL, MOCK_CONTENTS_FAIL, MOCK_COMPARE_FAIL. A compare without
# --jq serves $MOCK_COMPARE_JSON (default: one changed docs file).
# lgtm-ci contents lookups answer 404 for every "<ref> <path>" line of
# $MOCK_ABSENT and 200 otherwise; the compare API answers $MOCK_MERGE_BASE.
# Raw reusable reads serve $MOCK_REUSABLES/<ref>/<file>, else
# $MOCK_REUSABLES/default/<file>, else a reusable with no inputs;
# MOCK_RAW_FAIL injects an HTTP 502.
install_mock_gh() {
	local bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$bin"
	cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK_CALLS"
args="$*"
case "$args" in
*"Accept: application/vnd.github.raw+json repos/lgtm-hq/lgtm-ci/contents/"*"?ref="*)
	if [[ "${MOCK_RAW_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 502" >&2
		exit 1
	fi
	path="${args##*/contents/}"
	ref="${path#*\?ref=}"
	ref="${ref%% *}"
	path="${path%%\?*}"
	if grep -qxF "${ref} ${path}" "$MOCK_ABSENT" 2>/dev/null; then
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
	fi
	for dir in "$MOCK_REUSABLES/$ref" "$MOCK_REUSABLES/default"; do
		if [[ -f "$dir/$(basename "$path")" ]]; then
			cat "$dir/$(basename "$path")"
			exit 0
		fi
	done
	printf 'on:\n  workflow_call:\n    secrets:\n      GH_TOKEN:\n        required: true\n'
	;;
*"repos/lgtm-hq/lgtm-ci/contents/"*"?ref="*" --silent")
	if [[ "${MOCK_CONTENTS_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 502" >&2
		exit 1
	fi
	path="${args##*/contents/}"
	ref="${path#*\?ref=}"
	ref="${ref%% *}"
	path="${path%%\?*}"
	if grep -qxF "${ref} ${path}" "$MOCK_ABSENT" 2>/dev/null; then
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
	fi
	;;
*"repos/lgtm-hq/lgtm-ci/compare/main..."*" --jq .merge_base_commit.sha")
	if [[ "${MOCK_COMPARE_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 500" >&2
		exit 1
	fi
	echo "$MOCK_MERGE_BASE"
	;;
*"repos/lgtm-hq/lgtm-ci/compare/main..."*)
	# The whole compare response (#1670): $MOCK_COMPARE_JSON, else a
	# candidate that changed one docs file. MOCK_COMPARE_FAIL injects an error.
	if [[ "${MOCK_COMPARE_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 500" >&2
		exit 1
	fi
	if [[ -n "${MOCK_COMPARE_JSON:-}" ]]; then cat "$MOCK_COMPARE_JSON"
	else printf '{"merge_base_commit":{"sha":"%s"},"total_commits":1,"files":[{"filename":"docs/README.md","status":"modified"}]}\n' "$MOCK_MERGE_BASE"; fi
	;;
*"repos/lgtm-hq/lgtm-ci/commits/"*)
	echo "$CANDIDATE"
	;;
*"repos/lgtm-hq/lgtm-ci/pulls/"*"/files?per_page=100 --paginate --jq .[].filename")
	if [[ "${MOCK_PR_FILES_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 502" >&2
		exit 1
	fi
	cat "${MOCK_PR_FILES:-/dev/null}"
	;;
*"repos/lgtm-hq/lgtm-ci/pulls/"*" --jq "*)
	if [[ "${MOCK_PR_STATE_FAIL:-}" == 1 ]] || [[ -f "$MOCK_RUNS_DIR/.count" && "${MOCK_PR_FINAL_FAIL:-}" == 1 ]]; then exit 1; fi
	if [[ -f "$MOCK_RUNS_DIR/.count" && -n "${MOCK_PR_FINAL_STATE:-}" ]]; then
		echo "$MOCK_PR_FINAL_STATE"
	else
		echo "${MOCK_PR_STATE:-open}"
	fi
	;;
*"git/ref/heads/main --jq .object.sha")
	echo "basebasebasebasebasebasebasebasebasebase"
	;;
*"git/commits/basebase"*"--jq .tree.sha")
	echo "treetreetreetreetreetreetreetreetreetree"
	;;
*"git/trees/treetree"*"recursive=1"*)
	# The script applies its own --jq on the real API; the mock answers what
	# that jq yields for a flat workflows directory. The main test asserts
	# the jq restricts the listing to direct .yml children.
	for f in "$MOCK_FIXTURE_DIR"/*.yml; do echo ".github/workflows/$(basename "$f")"; done
	;;
*"/contents/.github/workflows/"*)
	path="${args##*/contents/}"
	path="${path%%\?*}"
	cat "$MOCK_FIXTURE_DIR/$(basename "$path")"
	;;
*"-X POST repos/owner/fixture/git/trees --input "*" --jq .sha")
	tree_calls="$MOCK_RUNS_DIR/.tree-calls"
	t=$(( $(cat "$tree_calls" 2>/dev/null || echo 0) + 1 ))
	echo "$t" >"$tree_calls"
	if [[ "${MOCK_TREE_FAIL_ALWAYS:-}" == "1" ]] || [[ "${MOCK_TREE_FAIL_FIRST:-}" == "1" && "$t" -eq 1 ]]; then
		echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2
		exit 1
	fi
	payload="${args##*--input }"
	payload="${payload%% *}"
	cp "$payload" "$MOCK_POSTED_TREE"
	echo "newtreenewtreenewtreenewtreenewtreenewtr"
	;;
*"-X POST repos/owner/fixture/git/commits --input "*" --jq .sha")
	echo "cafecafecafecafecafecafecafecafecafecafe"
	;;
*"-X POST repos/owner/fixture/git/refs -f ref="*)
	if [[ "${MOCK_REF_FAIL:-}" == "1" ]]; then
		echo "gh: Reference already exists (HTTP 422)" >&2
		exit 1
	fi
	ref="${args##*ref=}"
	ref="${ref%% *}"
	if [[ "${MOCK_REF_REJECT_DUPLICATE:-}" == 1 ]]; then
		if grep -qxF "$ref" "$MOCK_RUNS_DIR/refs" 2>/dev/null; then exit 1; fi
		printf '%s\n' "$ref" >>"$MOCK_RUNS_DIR/refs"
	fi
	echo "$ref"
	;;
*"/actions/workflows/"*"/runs?branch="*)
	file="${args#*/actions/workflows/}"; file="${file%%/runs?*}"
	count_file="$MOCK_RUNS_DIR/.reconcile-$file"
	n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$count_file"
	[[ "${MOCK_RECONCILE_FAIL:-}" != 1 && "${MOCK_RECONCILE_FAIL_AT:-}" != "$n" ]] || exit 1
	page="${args##*page=}"; page="${page%% *}"
	if [[ -f "$MOCK_RUNS_DIR/page.$page.json" ]]; then
		cat "$MOCK_RUNS_DIR/page.$page.json"
		exit 0
	fi
	while [[ $n -gt 1 && ! -f "$MOCK_RUNS_DIR/observed.$n.json" ]]; do n=$((n - 1)); done
	if [[ -f "$MOCK_RUNS_DIR/observed.$n.json" ]]; then
		stamp=$(cat "$MOCK_RUNS_DIR/dispatch-$file.at")
		jq --arg stamp "$stamp" '.workflow_runs |= map(if .created_at == "dispatch" then .created_at = $stamp else . end)' "$MOCK_RUNS_DIR/observed.$n.json"
	else
		echo '{"total_count":0,"workflow_runs":[]}'
	fi
	;;
*"/actions/workflows/"*"/dispatches -f ref="*)
	file="${args#*/actions/workflows/}"; file="${file%%/dispatches*}"
	date -u +%Y-%m-%dT%H:%M:%SZ >"$MOCK_RUNS_DIR/dispatch-$file.at"
	if [[ -n "${MOCK_DISPATCH_FAIL:-}" && "$args" == *"/actions/workflows/${MOCK_DISPATCH_FAIL}/dispatches"* ]]; then
		echo "gh: HTTP 422" >&2
		exit 1
	fi
	;;
*"git/matching-refs/heads/canary/ "*)
	# The cross-SHA sweep's listing (#1652): $MOCK_RUNS_DIR/sweep-refs.
	[[ "${MOCK_SWEEP_REFS_FAIL:-}" != 1 ]] || exit 1
	[[ ! -f "$MOCK_RUNS_DIR/sweep-refs" ]] || cat "$MOCK_RUNS_DIR/sweep-refs"
	;;
*"git/matching-refs/heads/canary/"*)
	;;
*"repos/lgtm-hq/lgtm-ci/actions/runs/"*"/attempts/"*)
	# Owning attempt of a stale ref: status and completion epoch.
	[[ "${MOCK_OWNER_FAIL:-}" != 1 ]] || exit 1
	# A slow or hung owner read (#1656): real seconds.
	if [[ -n "${MOCK_OWNER_SLEEP:-}" ]]; then sleep "$MOCK_OWNER_SLEEP"; fi
	printf '%s\t\n' "${MOCK_OWNER_STATUS:-completed}"
	;;
*"/actions/runs/"*"/jobs?"*)
	if [[ "${MOCK_JOBS_FAIL:-}" == 1 ]]; then exit 1; fi
	if [[ "$args" == *"jobs?per_page=1 --jq .total_count"* ]]; then
		# run_job_count (#1601): jobs created for the run, whatever their status.
		echo "${MOCK_JOBS_TOTAL:-1}"
	elif [[ "$args" != *--jq* ]]; then
		# Optional per-run jobs (#1616): $MOCK_JOBS_DIR/<run id>.json wins.
		run_id="${args#*/actions/runs/}"; run_id="${run_id%%/*}"
		if [[ -n "${MOCK_JOBS_DIR:-}" && -f "${MOCK_JOBS_DIR}/${run_id}.json" ]]; then cat "${MOCK_JOBS_DIR}/${run_id}.json"
		elif [[ -n "${MOCK_JOBS_JSON:-}" ]]; then cat "$MOCK_JOBS_JSON"; else echo '{"jobs":[]}'; fi
	elif [[ "${MOCK_JOBS_QUEUED:-}" != 1 ]]; then date +%s; fi
	;;
*"/check-runs/"*"/annotations"*)
	# Check-run annotations (#1475): $MOCK_ANNOTATIONS/<job id>.json, else a read error.
	[[ "${MOCK_ANNOTATIONS_FAIL:-}" != 1 ]] || exit 1
	job="${args#*/check-runs/}"; job="${job%%/annotations*}"
	cat "${MOCK_ANNOTATIONS:-/nonexistent}/${job}.json"
	;;
*"/actions/runs/"*"/cancel"*)
	;;
*"/actions/runs?branch="*"&event=workflow_dispatch&per_page=100"*)
	if [[ "${MOCK_CLEANUP_FAIL:-}" == 1 ]]; then exit 1; fi
	if [[ -f "$MOCK_RUNS_DIR/cleanup" ]]; then
		cat "$MOCK_RUNS_DIR/cleanup"
	else
		# Cleanup observes the latest fixture state without advancing polling.
		n="$(cat "$MOCK_RUNS_DIR/.count" 2>/dev/null || echo 1)"
		while [[ $n -gt 1 && ! -f "$MOCK_RUNS_DIR/runs.$n" ]]; do n=$((n - 1)); done
		if [[ -f "$MOCK_RUNS_DIR/runs.$n" ]]; then cat "$MOCK_RUNS_DIR/runs.$n"; fi
	fi
	;;
*"/actions/runs?branch="*)
	count_file="$MOCK_RUNS_DIR/.count"
	n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$count_file"
	if [[ "${MOCK_RUNS_FAIL_AT:-}" == "$n" ]]; then
		echo "gh: HTTP 500" >&2
		exit 1
	fi
	while [[ $n -gt 1 && ! -f "$MOCK_RUNS_DIR/runs.$n" ]]; do n=$((n - 1)); done
	[[ -f "$MOCK_RUNS_DIR/runs.$n" ]] && cat "$MOCK_RUNS_DIR/runs.$n"
	exit 0
	;;
*"-X DELETE repos/owner/fixture/git/refs/heads/canary/"*)
	if [[ "${MOCK_DELETE_FAIL:-}" == "1" ]]; then
		echo "gh: HTTP 422" >&2
		exit 1
	fi
	;;
*)
	echo "unexpected gh call: $args" >&2
	exit 99
	;;
esac
exit 0
EOF
	chmod +x "$bin/gh"
	# The stale-ref sweep bounds its calls with a deterministic GNU-like timeout.
	install_fake_timeout "$bin/gnutimeout" gnu
	export PATH="$bin:$PATH"
}

# One TSV row of a run-list snapshot.
run_row() {
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "https://github.com/owner/fixture/actions/runs/${4:-1}" "fixture-${1%.yml}"
}

# Gate green, informational negative red as expected.
all_green_snapshot() {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.1"
}

# Call one function of the script with the environment of this test.
call_fn() {
	bash "$CANARY_EVAL" "$*"
}

@test "external-canary: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

# --- classification -------------------------------------------------------

@test "external-canary: push-path fixture workflows are gates expecting success" {
	local wf
	for wf in python.yml node-bun.yml node-npm.yml node-pnpm.yml rust.yml siblings.yml retry.yml \
		egress.yml perms.yml actions-direct.yml coverage-lcov.yml playwright.yml \
		build-python-direct.yml vuln-suppression.yml rust-build-siblings.yml \
		python-private-dep.yml verify-fresh-install.yml rust-release-build.yml readonly-node.yml readonly-shell.yml \
		readonly-rust.yml readonly-docker.yml docker-publish.yml docker-facade-validate.yml \
		docker-orchestrator.yml recover.yml docker-scan-failure-probe.yml; do
		run call_fn classify_workflow "$wf"
		assert_success
		assert_output "$(printf 'gate\tsuccess')"
	done
}

@test "external-canary: the default expected-gate list names every gate exactly once" {
	run env -u CANARY_EXPECTED_GATES bash "$CANARY_EVAL" "printf '%s\n' \$CANARY_EXPECTED_GATES | sort | uniq -d"
	assert_output ""
	run env -u CANARY_EXPECTED_GATES bash "$CANARY_EVAL" "for g in \$CANARY_EXPECTED_GATES; do classify_workflow \"\$g.yml\" | cut -f1; done | sort -u"
	assert_output "gate"
	run env -u CANARY_EXPECTED_GATES bash "$CANARY_EVAL" "printf '%s\n' \$CANARY_EXPECTED_GATES | wc -l | tr -d ' '"
	assert_output "28"
}

@test "external-canary: App-token, SBOM and negative-probe paths are informational expecting success" {
	local wf
	for wf in app-token-probe.yml sbom-release-upload.yml tooling-app.yml perms-negative-probe.yml \
		playwright-negative-probe.yml verify-negative-probe.yml tooling-app-negative-probe.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tsuccess')"
	done
}

@test "external-canary: negative-by-design workflows are informational expecting failure" {
	local wf
	for wf in verify-negative.yml playwright-negative.yml docker-scan-failure.yml tooling-app-negative.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tfailure')"
	done
	for wf in perms-negative.yml perms-negative-node.yml perms-negative-shell.yml perms-negative-rust.yml \
		perms-negative-docker.yml perms-negative-recover.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tstartup_failure')"
	done
}

@test "external-canary: version-PR callers are manual and not dispatched by default" {
	local wf
	for wf in release-version-pr.yml release-benign-hook.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'manual\tsuccess')"
		run call_fn should_dispatch "$wf"
		assert_failure
		run env CANARY_INCLUDE_MANUAL=true bash "$CANARY_EVAL" "should_dispatch '$wf'"
		assert_success
	done
	run call_fn classify_workflow release-tamper-hook.yml
	assert_output "$(printf 'manual\tfailure')"
	run call_fn should_dispatch python.yml
	assert_success
	run call_fn should_dispatch verify-negative.yml
	assert_success
}

@test "external-canary: an unknown workflow is a gate (fail closed)" {
	run call_fn classify_workflow brand-new-probe.yml
	assert_output "$(printf 'gate\tsuccess')"
	run call_fn classify_workflow .github/workflows/release-version-pr.yml
	assert_output "$(printf 'manual\tsuccess')"
}

# --- pin rewriting and discovery -----------------------------------------

@test "external-canary: rewrite_pins rewrites workflow and action pins only" {
	cp "$MOCK_FIXTURE_DIR/python.yml" "$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_success
	run grep -c "@${CANDIDATE}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_output "2"
	run grep -F "actions/checkout@${OLD_PIN}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
	run grep -F "lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@${CANDIDATE}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
	run grep -F "lgtm-hq/lgtm-ci/.github/actions/run-pytest@${CANDIDATE}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
}

@test "external-canary: rewrite_pins rewrites refs tagged lgtm-ci-pin, like the fixture's pin.sh" {
	printf 'jobs:\n  a:\n    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-recover-plan.yml@%s\n    with:\n      tooling-ref: %s # lgtm-ci-pin\n      other-ref: %s\n' \
		"$OLD_PIN" "$OLD_PIN" "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_success
	run grep -F "tooling-ref: ${CANDIDATE} # lgtm-ci-pin" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
	# An untagged 40-hex value is not an lgtm-ci pin and stays as it is.
	run grep -F "other-ref: ${OLD_PIN}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
}

@test "external-canary: rewrite_pins accepts any spacing before lgtm-ci-pin" {
	printf 'with:\n  tooling-ref: %s  # lgtm-ci-pin\n  ref: %s\t# lgtm-ci-pin\n' "$OLD_PIN" "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_success
	run grep -c "${CANDIDATE}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_output "2"
}

@test "external-canary: rewrite_pins refuses an lgtm-ci-pin it could not rewrite" {
	printf 'with:\n  tooling-ref: v0.76.2 # lgtm-ci-pin\n' >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_failure
	assert_output --partial "lgtm-ci-pin ref not pinned to the candidate: "
}

@test "external-canary: rewrite_pins ignores comment lines that mention lgtm-ci-pin" {
	printf '# the `# lgtm-ci-pin` marker lets scripts/pin.sh rewrite it\njobs:\n  a:\n    with:\n      tooling-ref: %s # lgtm-ci-pin\n' "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_success
	run grep -F "tooling-ref: ${CANDIDATE} # lgtm-ci-pin" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
}

@test "external-canary: rewrite_pins rejects a short SHA" {
	cp "$MOCK_FIXTURE_DIR/python.yml" "$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" abc123
	assert_failure
	assert_output --partial "not a full SHA"
}

@test "external-canary: rewrite_pins refuses an lgtm-ci reference pinned to a tag or branch" {
	printf 'jobs:\n  a:\n    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@v0.75.3\n  b:\n    uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@%s\n' "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_failure
	assert_output --partial "wf.yml: lgtm-ci reference not pinned to the candidate: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@v0.75.3"
}

@test "external-canary: rewrite_pins ignores lgtm-ci references quoted in comments" {
	printf '# Calls `uses: lgtm-hq/lgtm-ci/.github/actions/build-python-package@<sha>` with\n# Re-pin with: scripts/pin.sh <sha>\njobs:\n  a:\n    steps:\n      - uses: lgtm-hq/lgtm-ci/.github/actions/build-python-package@%s\n' "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" "$CANDIDATE"
	assert_success
	run grep -c "@${CANDIDATE}" "$BATS_TEST_TMPDIR/wf.yml"
	assert_output "1"
	run grep -F "build-python-package@<sha>" "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
}

@test "external-canary: discover_dispatchable finds block, list and inline workflow_dispatch forms only" {
	printf 'name: list\n"on":\n  - push\n  - workflow_dispatch\n' >"$MOCK_FIXTURE_DIR/list-form.yml"
	printf 'name: inline\non: [push, workflow_dispatch]\n' >"$MOCK_FIXTURE_DIR/inline-form.yml"
	printf 'name: inline-push\non: [push, pull_request]\n' >"$MOCK_FIXTURE_DIR/inline-push.yml"
	run call_fn discover_dispatchable "$MOCK_FIXTURE_DIR"
	assert_success
	assert_line "python.yml"
	assert_line "verify-negative.yml"
	assert_line "release-version-pr.yml"
	assert_line "list-form.yml"
	assert_line "inline-form.yml"
	refute_line "starter-python.yml"
	refute_line "inline-push.yml"
}

@test "external-canary: build_tree_payload emits one blob entry per workflow under .github/workflows" {
	run bash "$CANARY_EVAL" "build_tree_payload treesha '$MOCK_FIXTURE_DIR' | jq -r '.base_tree, (.tree | length), (.tree[] | \"\\(.mode) \\(.type) \\(.path)\")'"
	assert_success
	assert_line --index 0 "treesha"
	assert_line --index 1 "4"
	assert_line "100644 blob .github/workflows/python.yml"
	assert_line "100644 blob .github/workflows/starter-python.yml"
}

@test "external-canary: resolve_candidate_sha returns a full SHA without calling gh" {
	run call_fn resolve_candidate_sha "$CANDIDATE"
	assert_success
	assert_output "$CANDIDATE"
	run cat "$MOCK_CALLS"
	assert_output ""
}

@test "external-canary: resolve_candidate_sha resolves a ref on the lgtm-ci repository" {
	run call_fn resolve_candidate_sha main
	assert_success
	assert_output "$CANDIDATE"
	run grep -F "repos/lgtm-hq/lgtm-ci/commits/main --jq .sha" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: since_timestamp is ISO-8601 UTC and lies in the past by the slack" {
	run env CANARY_SINCE_SLACK_SECONDS=3600 bash "$CANARY_EVAL" "since_timestamp"
	assert_success
	assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	[[ "$output" < "$now" ]]
}

@test "external-canary: branch helpers refuse anything outside canary/" {
	run call_fn delete_canary_branch main
	assert_failure
	assert_output --partial "refusing to delete"
	run call_fn canary_branch_name "$CANDIDATE"
	assert_output "$CANARY_TEST_BRANCH"
}

# --- dispatch arg building ------------------------------------------------

@test "external-canary: main creates a run-specific canary ref from base and dispatches every gate and informational workflow on it" {
	all_green_snapshot
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success

	# Branch created from the base branch's commit and tree, never on main.
	run grep -F "git/ref/heads/main --jq .object.sha" "$MOCK_CALLS"
	assert_success
	run grep -F -- "-X POST repos/owner/fixture/git/refs -f ref=refs/heads/${CANARY_TEST_BRANCH} -f sha=cafecafe" "$MOCK_CALLS"
	assert_success
	run grep -E -- "-X (POST|PATCH|PUT|DELETE) [^ ]*(heads/main|git/refs/heads/main)" "$MOCK_CALLS"
	refute_output

	# The tree listing selects direct .yml children of .github/workflows only.
	run grep -F 'workflows/[^/]+' "$MOCK_CALLS"
	assert_success

	# The posted tree carries the re-pinned files (candidate in, old pin out).
	run jq -r '.base_tree' "$MOCK_POSTED_TREE"
	assert_output "treetreetreetreetreetreetreetreetreetree"
	run bash -c "jq -r '.tree[].content' '$MOCK_POSTED_TREE' | grep -c '@${CANDIDATE}'"
	assert_output "5"
	run bash -c "jq -r '.tree[].content' '$MOCK_POSTED_TREE' | grep -c 'lgtm-hq/lgtm-ci/[^ ]*@${OLD_PIN}'"
	assert_output "0"

	# One dispatch per gate/informational workflow; manual and push-only not dispatched.
	run grep -c -- "/actions/workflows/[a-z-]*.yml/dispatches -f ref=${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_output "2"
	run grep -F "actions/workflows/python.yml/dispatches -f ref=${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_success
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	assert_success
	run grep -E "actions/workflows/(starter-python|release-version-pr).yml/dispatches" "$MOCK_CALLS"
	refute_output

	# Poll filters to the branch, the dispatch event, and runs created since dispatch.
	run grep -E "actions/runs\?branch=${CANARY_TEST_BRANCH}&event=workflow_dispatch&created=%3E%3D[0-9T:Z-]+&per_page=100" "$MOCK_CALLS"
	assert_success

	# Branch deleted at the end, successfully; the manual row is listed.
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_success
	# This second independent invocation owns a separate dispatch journal.
	run env CANARY_STATE_DIR="${BATS_TEST_TMPDIR}/second-state" bash "$SCRIPT" "$CANDIDATE"
	assert_output --partial "dispatched python.yml on ${CANARY_TEST_BRANCH}"
	assert_output --partial "| \`release-version-pr.yml\` | manual | \`success\` | \`not_dispatched\` | ➖ not dispatched | — |"
	assert_output --partial "deleted owner/fixture@${CANARY_TEST_BRANCH}"
	refute_output --partial "could not delete"
}

@test "external-canary: CANARY_INCLUDE_MANUAL=true also dispatches the manual release workflows" {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed failure 12
		run_row release-version-pr.yml completed success 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_INCLUDE_MANUAL=true bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -c -- "/dispatches -f ref=${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_output "3"
	run grep -F "| \`release-version-pr.yml\` | manual | \`success\` | \`success\` | ✅ pass |" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "external-canary: an absent failed dispatch stays blocking at the queue bound" {
	run_row verify-negative.yml completed failure 12 >"$MOCK_RUNS_DIR/runs.1"
	# Freeze admission, then expire only after the failed POST was attempted.
	# A real one-second clock can expire before dispatch under parallel coverage.
	export MOCK_REAL_DATE
	MOCK_REAL_DATE="$(command -v date)"
	cat >"${BATS_TEST_TMPDIR}/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
	if [[ -s "$MOCK_RUNS_DIR/dispatch-python.yml.at" ]]; then
		printf '102\n'
	else
		printf '100\n'
	fi
else
	exec "$MOCK_REAL_DATE" "$@"
fi
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/date"
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 CANARY_TIMEOUT_SECONDS=600 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "dispatch python.yml failed on owner/fixture"
	assert_output --partial "| \`python.yml\` | gate | \`success\` | \`dispatch_failed\` | ❌ **gate failed** | — |"
	assert_output --partial "::error title=external canary::gate python.yml concluded 'dispatch_failed'"
	# Missing execution is reconciled within the existing queue bound.
	[[ -s "$MOCK_RUNS_DIR/.count" ]]
	run grep -c '/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: an expected gate the fixture no longer exposes is reported not_dispatchable and fails" {
	all_green_snapshot
	run env CANARY_EXPECTED_GATES="python rust" bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "| \`rust.yml\` | gate | \`success\` | \`not_dispatchable\` | ❌ **gate failed** | — |"
	assert_output --partial "gate rust.yml concluded 'not_dispatchable'"
	run grep -F "actions/workflows/rust.yml/dispatches" "$MOCK_CALLS"
	refute_output
}

# --- poll termination -----------------------------------------------------

@test "external-canary: poll_runs keeps polling while a run is queued and stops when all completed" {
	run_row python.yml in_progress "" 11 >"$MOCK_RUNS_DIR/runs.1"
	{
		run_row python.yml in_progress "" 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.2"
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.3"
	run call_fn poll_runs "$CANARY_TEST_BRANCH" 2026-10-08T00:00:00Z python.yml verify-negative.yml
	assert_success
	assert_line "$(printf 'python.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	assert_line "$(printf 'verify-negative.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/12\tfixture-verify-negative')"
	run cat "$MOCK_RUNS_DIR/.count"
	assert_output "3"
}

@test "external-canary: poll_runs terminates on a failed run" {
	run_row python.yml completed failure 11 >"$MOCK_RUNS_DIR/runs.1"
	run call_fn poll_runs "$CANARY_TEST_BRANCH" 2026-10-08T00:00:00Z python.yml
	assert_success
	assert_output "$(printf 'python.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	run cat "$MOCK_RUNS_DIR/.count"
	assert_output "1"
}

@test "external-canary: poll_runs terminates at the bounds with execution timeout and undiscovered queue timeout" {
	run_row python.yml in_progress "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_TIMEOUT_SECONDS=0 CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" "poll_runs $CANARY_TEST_BRANCH 2026-10-08T00:00:00Z python.yml rust.yml"
	assert_success
	assert_line "$(printf 'python.yml\ttimeout\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	assert_line "$(printf 'rust.yml\tqueued-timeout\t\t')"
}

@test "external-canary: poll_runs uses the latest run when a workflow has several" {
	{
		run_row python.yml completed success 22
		run_row python.yml completed failure 11
	} >"$MOCK_RUNS_DIR/runs.1"
	run call_fn poll_runs "$CANARY_TEST_BRANCH" 2026-10-08T00:00:00Z python.yml
	assert_output --partial "runs/22"
	refute_output --partial "runs/11"
}

@test "external-canary: poll_runs keeps the previous snapshot when a list fetch fails" {
	run_row python.yml in_progress "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.2"
	# Call 2 fails; call 3 serves the completed snapshot.
	run env MOCK_RUNS_FAIL_AT=2 bash "$CANARY_EVAL" "poll_runs $CANARY_TEST_BRANCH 2026-10-08T00:00:00Z python.yml"
	assert_success
	assert_output --partial "run list fetch failed; keeping the previous snapshot"
	assert_line "$(printf 'python.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	# A failure on the final poll at the bound still reports the last good rows.
	rm -f "$MOCK_RUNS_DIR/.count" "$MOCK_RUNS_DIR/runs.2"
	run env MOCK_RUNS_FAIL_AT=2 CANARY_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" "poll_runs $CANARY_TEST_BRANCH 2026-10-08T00:00:00Z python.yml"
	assert_success
	assert_line "$(printf 'python.yml\ttimeout\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
}

# --- summary rendering and gate evaluation --------------------------------

@test "external-canary: render_summary writes a table with role, expected, conclusion, verdict and run link" {
	local rows
	rows="$(
		printf 'python.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python\n'
		printf 'verify-negative.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/12\tfixture-verify-negative\n'
		printf 'app-token-probe.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/13\tfixture-app-token-probe\n'
		printf 'release-version-pr.yml\tnot_dispatched\t\t\n'
		printf 'rust.yml\tmissing\t\t\n'
	)"
	ROWS="$rows" run bash "$CANARY_EVAL" "render_summary '$CANDIDATE' '$CANARY_TEST_BRANCH' <<<\"\$ROWS\""
	assert_success
	assert_line "## External consumer canary"
	assert_line "| Workflow | Role | Expected | Conclusion | Verdict | Run |"
	assert_line "| \`python.yml\` | gate | \`success\` | \`success\` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/11) |"
	assert_line "| \`verify-negative.yml\` | informational | \`failure\` | \`failure\` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/12) |"
	assert_line "| \`app-token-probe.yml\` | informational | \`success\` | \`failure\` | ⚠️ unexpected | [run](https://github.com/owner/fixture/actions/runs/13) |"
	assert_line "| \`release-version-pr.yml\` | manual | \`success\` | \`not_dispatched\` | ➖ not dispatched | — |"
	assert_line "| \`rust.yml\` | gate | \`success\` | \`missing\` | ❌ **gate failed** | — |"
	assert_output --partial "pinned to \`${CANDIDATE}\`"
}

@test "external-canary: failed_gates lists gate mismatches only" {
	local rows
	rows="$(printf 'python.yml\tfailure\tu\tn\nrust.yml\tsuccess\tu\tn\nverify-negative.yml\tsuccess\tu\tn\nperms-negative.yml\tstartup_failure\tu\tn\nrelease-version-pr.yml\tnot_dispatched\t\t\n')"
	ROWS="$rows" run bash "$CANARY_EVAL" "failed_gates <<<\"\$ROWS\""
	assert_success
	assert_output "$(printf 'python.yml\tfailure')"
}

@test "external-canary: main exits non-zero when a gate fails and writes summary and outputs" {
	{
		run_row python.yml completed failure 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "::error title=external canary::gate python.yml concluded 'failure'"
	run grep -F "| \`python.yml\` | gate | \`success\` | \`failure\` | ❌ **gate failed** |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "gate-failures=1" "$GITHUB_OUTPUT"
	assert_success
	run grep -F "branch=${CANARY_TEST_BRANCH}" "$GITHUB_OUTPUT"
	assert_success
	# Branch is still cleaned up on failure.
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: informational workflows never fail the canary" {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed success 12 # unexpected green: a finding, not a gate failure
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "| \`verify-negative.yml\` | informational | \`failure\` | \`success\` | ⚠️ unexpected |"
	run grep -F "gate-failures=0" "$GITHUB_OUTPUT"
	assert_success
}

@test "external-canary: a gate that never completes fails the canary as timeout" {
	{
		run_row python.yml in_progress "" 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_TIMEOUT_SECONDS=0 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'timeout'"
}

@test "external-canary: CANARY_KEEP_BRANCH=true leaves the canary branch in place" {
	all_green_snapshot
	run env CANARY_KEEP_BRANCH=true bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F -- "-X DELETE" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: main requires a ref and the fixture token" {
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "usage:"
	run env -u GH_TOKEN bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "GH_TOKEN is required"
}

# --- run/skip decision (always-run, fast-skip) ----------------------------

@test "external-canary: workflow_dispatch always runs the full set without listing files" {
	run env EVENT_NAME=workflow_dispatch bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_line --index 0 --partial "$(printf 'full\t')"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a pull request touching an adoption-relevant path runs the full set" {
	local path
	for path in .github/workflows/reusable-test-python.yml .github/actions/run-pytest/action.yml \
		scripts/ci/actions/run-pytest.sh schemas/renovate.json examples/ci-python.yml; do
		: >"$MOCK_CALLS"
		printf 'README.md\n%s\ndocs/x.md\n' "$path" >"$BATS_TEST_TMPDIR/files.txt"
		run env EVENT_NAME=pull_request EVENT_ACTION=synchronize PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
			bash "$CANARY_EVAL" "decide_run_mode"
		assert_success
		assert_output "$(printf 'full\tpull request touches %s' "$path")"
		run grep -F "repos/lgtm-hq/lgtm-ci/pulls/42/files?per_page=100 --paginate" "$MOCK_CALLS"
		assert_success
	done
}

@test "external-canary: a pull request with no adoption-relevant change skips" {
	printf 'README.md\ndocs/workflow-contract.md\ntests/bats/unit/x.bats\nscripts/other.sh\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
		bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output --partial "$(printf 'skip\tno adoption-relevant changes')"
}

@test "external-canary: a failed file listing fails the decision instead of skipping (fail closed)" {
	run env EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER=42 MOCK_PR_FILES_FAIL=1 \
		bash "$CANARY_EVAL" "decide_run_mode"
	assert_failure
	assert_output --partial "cannot list the files of pull request #42; refusing to skip"
	refute_output --partial "$(printf 'skip\t')"
	run env -u GH_TOKEN EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER=42 MOCK_PR_FILES_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	refute_output --partial "::notice"
	run grep -F "mode=skipped" "$GITHUB_OUTPUT"
	refute_output
	# A missing PR number is the same kind of failure.
	run env EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER= bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "PR_NUMBER is required"
}

@test "external-canary: the needs-external-canary label forces a full run without listing files" {
	run env EVENT_NAME=pull_request EVENT_ACTION=synchronize PR_NUMBER=42 PR_LABELS="docs, needs-external-canary" \
		bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output "$(printf 'full\tlabel needs-external-canary forces a full run')"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a fork pull request skips, even with the force label" {
	run env EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER=42 PR_HEAD_REPO_FORK=true \
		bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output --partial "$(printf 'skip\tfork pull request')"
	run env EVENT_NAME=pull_request EVENT_ACTION=labeled EVENT_LABEL=needs-external-canary PR_NUMBER=42 \
		PR_HEAD_REPO_FORK=true PR_LABELS=needs-external-canary bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output --partial "$(printf 'skip\tfork pull request')"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a labeled event for an unrelated label skips without re-running the set" {
	printf '.github/workflows/x.yml\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env EVENT_NAME=pull_request EVENT_ACTION=labeled EVENT_LABEL=documentation PR_NUMBER=42 \
		PR_LABELS="documentation" MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output "$(printf "skip\tlabel 'documentation' is not a canary label; this head was already decided on push")"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: labeled events for the force and override labels run the full set" {
	run env EVENT_NAME=pull_request EVENT_ACTION=labeled EVENT_LABEL=needs-external-canary PR_NUMBER=42 \
		PR_LABELS="needs-external-canary" bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output "$(printf 'full\tlabel needs-external-canary forces a full run')"
	printf '.github/workflows/x.yml\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env EVENT_NAME=pull_request EVENT_ACTION=labeled EVENT_LABEL=canary-informational PR_NUMBER=42 \
		PR_LABELS="canary-informational" MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" bash "$CANARY_EVAL" "decide_run_mode"
	assert_success
	assert_output "$(printf 'full\tpull request touches .github/workflows/x.yml')"
}

@test "external-canary: main on a skipped PR exits 0, writes the skipped summary and touches no fixture" {
	printf 'README.md\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env -u GH_TOKEN EVENT_NAME=pull_request EVENT_ACTION=opened PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
		bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "::notice title=external canary::skipped: no adoption-relevant changes"
	run grep -F "Skipped: no adoption-relevant changes" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "mode=skipped" "$GITHUB_OUTPUT"
	assert_success
	run grep -F "owner/fixture" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: the canary-informational label turns a gate failure into a warning" {
	{
		run_row python.yml completed failure 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.1"
	run env EVENT_NAME=pull_request EVENT_ACTION=synchronize PR_NUMBER=42 PR_LABELS="needs-external-canary,canary-informational" \
		bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "::warning title=external canary::gate python.yml concluded 'failure' (reported as success: label canary-informational)"
	refute_output --partial "::error"
	run grep -F "reported as success because the pull request carries the owner-only label \`canary-informational\`" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "gate-failures=1" "$GITHUB_OUTPUT"
	assert_success
}

@test "external-canary: the override label does nothing when every gate passes" {
	all_green_snapshot
	run env EVENT_NAME=pull_request EVENT_ACTION=synchronize PR_NUMBER=42 PR_LABELS="needs-external-canary,canary-informational" \
		bash "$SCRIPT" "$CANDIDATE"
	assert_success
	refute_output --partial "::warning"
}

# --- write retry and cleanup ownership -------------------------------------

@test "external-canary: a transient failure on a fixture write is retried once" {
	all_green_snapshot
	run env MOCK_TREE_FAIL_FIRST=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "create tree: gh: Resource not accessible by personal access token (HTTP 403) ; retrying in 0s"
	run cat "$MOCK_RUNS_DIR/.tree-calls"
	assert_output "2"
}

@test "external-canary: a persistent write failure names the step and does not delete a branch it never created" {
	all_green_snapshot
	run env MOCK_TREE_FAIL_ALWAYS=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "create tree failed on owner/fixture: gh: Resource not accessible by personal access token (HTTP 403)"
	assert_output --partial "cannot create the canary tree (the token needs Contents and Workflows read/write on owner/fixture)"
	run grep -c -- "/dispatches" "$MOCK_CALLS"
	assert_output "0"
	run grep -F -- "-X DELETE" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a branch that already exists is left untouched" {
	all_green_snapshot
	run env MOCK_REF_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "this run's ref may already exist; it is left untouched"
	run grep -F -- "-X DELETE" "$MOCK_CALLS"
	refute_output
	run grep -c -- "/dispatches" "$MOCK_CALLS"
	assert_output "0"
}

@test "external-canary: retained refs allow a new attempt and another run of the same SHA" {
	all_green_snapshot
	run env CANARY_KEEP_BRANCH=true MOCK_REF_REJECT_DUPLICATE=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run env CANARY_KEEP_BRANCH=true MOCK_REF_REJECT_DUPLICATE=1 GITHUB_RUN_ATTEMPT=2 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run env CANARY_KEEP_BRANCH=true MOCK_REF_REJECT_DUPLICATE=1 GITHUB_RUN_ID=67890 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run cat "$MOCK_RUNS_DIR/refs"
	assert_output "$(printf 'refs/heads/canary/%s-%s\n' "$CANDIDATE" 12345-1 "$CANDIDATE" 12345-2 "$CANDIDATE" 67890-1)"
	run grep -F -- '-X DELETE' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: monitoring failure fails gates but remains informational for informational workflows" {
	run bash "$CANARY_EVAL" '
		printf "python.yml\tmonitoring_failed\t\t\nverify-negative.yml\tmonitoring_failed\t\t\n" | failed_gates
	'
	assert_success
	assert_output "$(printf 'python.yml\tmonitoring_failed')"
}

@test "external-canary: a failed branch deletion is a warning, not a failure" {
	all_green_snapshot
	run env MOCK_DELETE_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "could not delete owner/fixture@${CANARY_TEST_BRANCH}"
}

# --- negative probes ---------------------------------------------------------

# Adds verify-negative-probe.yml (no lgtm-ci reference) to the fake fixture.
_add_probe() {
	cat >"$MOCK_FIXTURE_DIR/verify-negative-probe.yml" <<EOF
name: fixture-verify-negative-probe
"on":
  workflow_dispatch:
jobs:
  probe:
    uses: ./.github/workflows/negative-probe.yml
EOF
}

@test "external-canary: a negative with a probe is reached only through the probe" {
	_add_probe
	{
		run_row python.yml completed success 11
		run_row verify-negative-probe.yml completed success 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F "actions/workflows/verify-negative-probe.yml/dispatches" "$MOCK_CALLS"
	assert_success
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	refute_output
	run grep -F "| \`verify-negative.yml\` | informational | \`failure\` | \`via_probe\` | ↪ via \`verify-negative-probe.yml\` | — |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "| \`verify-negative-probe.yml\` | informational | \`success\` | \`success\` | ✅ pass |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "gate-failures=0" "$GITHUB_OUTPUT"
	assert_success
}

@test "external-canary: a red probe (negative passed unexpectedly) is reported, not a gate failure" {
	_add_probe
	{
		run_row python.yml completed success 11
		run_row verify-negative-probe.yml completed failure 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "| \`verify-negative-probe.yml\` | informational | \`success\` | \`failure\` | ⚠️ unexpected |"
}

@test "external-canary: a negative without a probe is still dispatched directly" {
	all_green_snapshot
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	assert_success
	run grep -F "via_probe" "$GITHUB_STEP_SUMMARY"
	refute_output
}

@test "external-canary: a negative whose probe is not dispatched is dispatched directly" {
	# The probe references an lgtm-ci path that landed after the candidate.
	_add_probe
	printf '      - uses: lgtm-hq/lgtm-ci/.github/actions/brand-new@%s\n' "$OLD_PIN" >>"$MOCK_FIXTURE_DIR/verify-negative-probe.yml"
	printf '%s .github/actions/brand-new\n%s .github/actions/brand-new\n' "$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	all_green_snapshot
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	assert_success
	run grep -F "actions/workflows/verify-negative-probe.yml/dispatches" "$MOCK_CALLS"
	refute_output
	run grep -F "| \`verify-negative.yml\` | informational | \`failure\` | \`failure\` | ✅ pass |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "| \`verify-negative-probe.yml\` | informational | \`success\` | \`not_applicable\` |" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "external-canary: a run that dispatches nothing warns instead of passing silently" {
	printf '%s .github/actions/run-pytest\n%s .github/actions/run-pytest\n%s .github/workflows/reusable-rust-test.yml\n%s .github/workflows/reusable-rust-test.yml\n' \
		"$CANDIDATE" "$MOCK_MERGE_BASE" "$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "::warning title=external canary::no fixture workflow was dispatched against ${CANDIDATE}"
	run grep -c -- "/dispatches" "$MOCK_CALLS"
	assert_output "0"
	run grep -F "nothing was exercised" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "external-canary: presence is decided by HTTP status, so action directories count as present" {
	run call_fn "lgtm_ci_path_state .github/actions/run-pytest '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "present"
	run grep -F "contents/.github/actions/run-pytest?ref=${CANDIDATE} --silent" "$MOCK_CALLS"
	assert_success
	run grep -F -- "--jq" "$MOCK_CALLS"
	refute_output
}

# --- reference check against the candidate (#1128) --------------------------

@test "external-canary: lgtm_ci_references lists distinct workflow and action paths from uses: lines" {
	printf '# uses: lgtm-hq/lgtm-ci/.github/workflows/commented.yml@%s\njobs:\n  a:\n    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@%s\n  b:\n    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@%s\n  c:\n    steps:\n      - uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@%s\n      - uses: actions/checkout@%s\n' \
		"$CANDIDATE" "$CANDIDATE" "$CANDIDATE" "$CANDIDATE" "$OLD_PIN" >"$BATS_TEST_TMPDIR/wf.yml"
	run call_fn lgtm_ci_references "$BATS_TEST_TMPDIR/wf.yml"
	assert_success
	assert_output "$(printf '.github/actions/run-pytest\n.github/workflows/reusable-test-python.yml')"
	printf 'jobs:\n  a:\n    runs-on: ubuntu-24.04\n' >"$BATS_TEST_TMPDIR/none.yml"
	run call_fn lgtm_ci_references "$BATS_TEST_TMPDIR/none.yml"
	assert_success
	assert_output ""
}

@test "external-canary: reference_verdict dispatches when every reference exists at the candidate, without a compare" {
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/python.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "dispatch"
	run grep -F "/compare/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a reusable that landed on main after the candidate branched is not_applicable" {
	printf '%s .github/workflows/reusable-rust-test.yml\n%s .github/workflows/reusable-rust-test.yml\n' \
		"$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/verify-negative.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "$(printf 'not_applicable\t.github/workflows/reusable-rust-test.yml')"
	run grep -F "repos/lgtm-hq/lgtm-ci/compare/main...${CANDIDATE} --jq .merge_base_commit.sha" "$MOCK_CALLS"
	assert_success
	run grep -F "contents/.github/workflows/reusable-rust-test.yml?ref=main" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: a reusable present at the merge base but gone at the candidate is removed_by_candidate" {
	printf '%s .github/actions/run-pytest\n' "$CANDIDATE" >"$MOCK_ABSENT"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/python.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "$(printf 'removed_by_candidate\t.github/actions/run-pytest')"
	# main is not consulted: the merge base already proves the removal.
	run grep -F "contents/.github/actions/run-pytest?ref=main" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a reference missing everywhere is dispatched so the run reports it" {
	printf '%s .github/workflows/reusable-rust-test.yml\n%s .github/workflows/reusable-rust-test.yml\nmain .github/workflows/reusable-rust-test.yml\n' \
		"$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/verify-negative.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "dispatch"
}

@test "external-canary: reference lookups fail closed" {
	run env MOCK_CONTENTS_FAIL=1 bash "$CANARY_EVAL" "reference_verdict '$MOCK_FIXTURE_DIR/python.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "cannot read lgtm-hq/lgtm-ci/.github/"
	printf '%s .github/actions/run-pytest\n' "$CANDIDATE" >"$MOCK_ABSENT"
	run env MOCK_COMPARE_FAIL=1 bash "$CANARY_EVAL" "reference_verdict '$MOCK_FIXTURE_DIR/python.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "cannot compare main...${CANDIDATE}"
	run env MOCK_MERGE_BASE=null bash "$CANARY_EVAL" "reference_verdict '$MOCK_FIXTURE_DIR/python.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "not a full SHA"
	# In main: no dispatch at all, and the branch it created is cleaned up.
	run env MOCK_CONTENTS_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "cannot check the lgtm-ci references of"
	run grep -c -- "/dispatches" "$MOCK_CALLS"
	assert_output "0"
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/${CANARY_TEST_BRANCH}" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: main lists a not_applicable gate without dispatching it or failing" {
	printf '%s .github/actions/run-pytest\n%s .github/actions/run-pytest\n' "$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	run_row verify-negative.yml completed failure 12 >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F "actions/workflows/python.yml/dispatches" "$MOCK_CALLS"
	refute_output
	run grep -F "| \`python.yml\` | gate | \`success\` | \`not_applicable\` | ➖ not applicable | — |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "references \`.github/actions/run-pytest\`, which landed on lgtm-ci \`main\` after this candidate branched" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "Rebase onto \`main\`" "$GITHUB_STEP_SUMMARY"
	assert_success
	# Not reported not_dispatchable either: the fixture still exposes it.
	run grep -F "not_dispatchable" "$GITHUB_STEP_SUMMARY"
	refute_output
	run grep -F "gate-failures=0" "$GITHUB_OUTPUT"
	assert_success
}

@test "external-canary: main fails when the candidate removes a reusable, whatever the workflow's role" {
	# verify-negative.yml is informational; removing its reusable still fails.
	printf '%s .github/workflows/reusable-rust-test.yml\n' "$CANDIDATE" >"$MOCK_ABSENT"
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "::error title=external canary::informational verify-negative.yml concluded 'removed_by_candidate'"
	assert_output --partial "| \`verify-negative.yml\` | informational | \`failure\` | \`removed_by_candidate\` | ❌ **removed by candidate** | — |"
	assert_output --partial "this change deletes or renames a public interface"
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	refute_output
	run grep -F "gate-failures=1" "$GITHUB_OUTPUT"
	assert_success
	# The override label still applies.
	: >"$GITHUB_OUTPUT"
	run env EVENT_NAME=pull_request EVENT_ACTION=synchronize PR_NUMBER=42 PR_LABELS="needs-external-canary,canary-informational" \
		bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "::warning title=external canary::informational verify-negative.yml concluded 'removed_by_candidate'"
}

@test "external-canary: a probe inherits the not_applicable verdict of the negative it dispatches" {
	_add_probe
	printf '%s .github/workflows/reusable-rust-test.yml\n%s .github/workflows/reusable-rust-test.yml\n' \
		"$CANDIDATE" "$MOCK_MERGE_BASE" >"$MOCK_ABSENT"
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -E "actions/workflows/verify-negative(-probe)?.yml/dispatches" "$MOCK_CALLS"
	refute_output
	run grep -F "| \`verify-negative-probe.yml\` | informational | \`success\` | \`not_applicable\` | ➖ not applicable | — |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "| \`verify-negative.yml\` | informational | \`failure\` | \`not_applicable\` | ➖ not applicable | — |" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "external-canary: failed_gates counts removed_by_candidate for any role and skips not_applicable gates" {
	local rows
	rows="$(printf 'python.yml\tnot_applicable\t\tp\nverify-negative.yml\tremoved_by_candidate\t\tp\nrelease-version-pr.yml\tremoved_by_candidate\t\tp\nverify-negative.yml\tvia_probe\t\tq\n')"
	ROWS="$rows" run bash "$CANARY_EVAL" "failed_gates <<<\"\$ROWS\""
	assert_success
	assert_output "$(printf 'verify-negative.yml\tremoved_by_candidate\nrelease-version-pr.yml\tremoved_by_candidate')"
}

# --- passed inputs against the candidate (#1134) -----------------------------

# A fixture job passing `concurrency-scope` to the vuln-suppression reusable.
_add_scoped_caller() {
	cat >"$MOCK_FIXTURE_DIR/vuln-suppression.yml" <<EOF
name: fixture-vuln-suppression
"on":
  workflow_dispatch:
jobs:
  check:
    # yamllint disable-line rule:line-length
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@${OLD_PIN}
    permissions:
      contents: write
    with:
      job-name: "Vuln"
      # Per canary ref, so concurrent canaries never supersede each other.
      concurrency-scope: \${{ github.ref }}
    secrets:
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF
}

# Write the vuln-suppression reusable at <ref> declaring the given inputs.
_reusable_at() {
	local ref="$1" name
	shift
	mkdir -p "$MOCK_REUSABLES/$ref"
	{
		printf 'on:\n  workflow_call:\n    inputs:\n'
		for name in "$@"; do printf '      %s:\n        type: string\n' "$name"; done
		printf '    secrets:\n      GH_TOKEN:\n        required: true\n'
	} >"$MOCK_REUSABLES/$ref/reusable-vuln-suppression-check.yml"
}

@test "external-canary: lgtm_ci_passed_inputs lists with: keys of lgtm-ci reusable calls only" {
	_add_scoped_caller
	cat >>"$MOCK_FIXTURE_DIR/vuln-suppression.yml" <<EOF
  local:
    uses: ./.github/workflows/negative-probe.yml
    with:
      negative: x.yml
  steps-job:
    runs-on: ubuntu-24.04
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@${OLD_PIN}
        with:
          python-version: "3.12"
EOF
	run call_fn lgtm_ci_passed_inputs "$MOCK_FIXTURE_DIR/vuln-suppression.yml"
	assert_success
	assert_output "$(printf '.github/workflows/reusable-vuln-suppression-check.yml#concurrency-scope\n.github/workflows/reusable-vuln-suppression-check.yml#job-name')"
}

@test "external-canary: inputs the candidate declares are dispatched without a compare" {
	_add_scoped_caller
	_reusable_at default job-name concurrency-scope
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "dispatch"
	run grep -F "/compare/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: an input that landed on main after the candidate branched is not_applicable" {
	_add_scoped_caller
	_reusable_at "$CANDIDATE" job-name
	_reusable_at "$MOCK_MERGE_BASE" job-name
	_reusable_at main job-name concurrency-scope
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "$(printf 'not_applicable\t.github/workflows/reusable-vuln-suppression-check.yml#concurrency-scope')"
	# In main: listed, not dispatched, rebase suggested.
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row verify-negative.yml completed failure 12 >>"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_EXPECTED_GATES="python vuln-suppression" bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "| \`vuln-suppression.yml\` | gate | \`success\` | \`not_applicable\` | ➖ not applicable | — |"
	assert_output --partial "references \`.github/workflows/reusable-vuln-suppression-check.yml#concurrency-scope\`, which landed on lgtm-ci \`main\`"
	run grep -F "actions/workflows/vuln-suppression.yml/dispatches" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: an input the candidate removes fails the canary as removed_by_candidate" {
	_add_scoped_caller
	_reusable_at "$CANDIDATE" concurrency-scope
	_reusable_at "$MOCK_MERGE_BASE" job-name concurrency-scope
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "$(printf 'removed_by_candidate\t.github/workflows/reusable-vuln-suppression-check.yml#job-name')"
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row verify-negative.yml completed failure 12 >>"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_EXPECTED_GATES="python vuln-suppression" bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "::error title=external canary::gate vuln-suppression.yml concluded 'removed_by_candidate'"
}

@test "external-canary: an input passed to a reusable missing everywhere is dispatched so the run reports it" {
	_add_scoped_caller
	_reusable_at default job-name
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "dispatch"
}

@test "external-canary: a failed reusable read fails closed" {
	_add_scoped_caller
	run env MOCK_RAW_FAIL=1 bash "$CANARY_EVAL" "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "cannot read lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml at ${CANDIDATE}: gh: HTTP 502"
}

@test "external-canary: lgtm_ci_passed_inputs tolerates comments and either key order" {
	cat >"$MOCK_FIXTURE_DIR/vuln-suppression.yml" <<EOF
"on":
  workflow_dispatch:
    inputs:
      not-a-call-input:
        type: string
jobs:
  with-first: # inputs before uses
    with: # ref scope
      concurrency-scope: \${{ github.ref }} # per canary ref
      # a comment line
      job-name: >-
        Vuln
        check:
          not-a-key
    uses: "lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@${OLD_PIN}" # pinned
  local: # no lgtm-ci reusable
    uses: ./.github/workflows/negative-probe.yml
    with:
      negative: x.yml
EOF
	run call_fn lgtm_ci_passed_inputs "$MOCK_FIXTURE_DIR/vuln-suppression.yml"
	assert_success
	assert_output "$(printf '.github/workflows/reusable-vuln-suppression-check.yml#concurrency-scope\n.github/workflows/reusable-vuln-suppression-check.yml#job-name')"
}

@test "external-canary: reusable inputs come from on.workflow_call only and tolerate comments" {
	mkdir -p "$MOCK_REUSABLES/default"
	cat >"$MOCK_REUSABLES/default/reusable-vuln-suppression-check.yml" <<'EOF'
---
name: x
on: # triggers
  workflow_dispatch:
    inputs:
      dispatch-only:
        type: string
  workflow_call: # the interface
    inputs: # reusable inputs
      # a comment
      job-name:
        description: "has: a colon"
        type: string
    outputs:
      out-only:
        value: x
    secrets:
      GH_TOKEN:
        required: true
jobs:
  inputs:
    runs-on: ubuntu-24.04
EOF
	run call_fn "lgtm_ci_reusable_inputs .github/workflows/reusable-vuln-suppression-check.yml '$CANDIDATE'; echo \"[\$REPLY]\""
	assert_success
	assert_output "[ job-name ]"
}

@test "external-canary: a reusable without a readable on.workflow_call fails closed" {
	_add_scoped_caller
	mkdir -p "$MOCK_REUSABLES/default"
	printf 'on: {workflow_call: {inputs: {job-name: {type: string}}}}\n' \
		>"$MOCK_REUSABLES/default/reusable-vuln-suppression-check.yml"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "cannot read block-style on.workflow_call inputs in lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml at ${CANDIDATE}"
}

@test "external-canary: quoted keys are read on both sides" {
	cat >"$MOCK_FIXTURE_DIR/vuln-suppression.yml" <<EOF
"on":
  workflow_dispatch:
"jobs":
  check:
    "uses": 'lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@${OLD_PIN}'
    "with":
      "job-name": test
EOF
	run call_fn lgtm_ci_passed_inputs "$MOCK_FIXTURE_DIR/vuln-suppression.yml"
	assert_output ".github/workflows/reusable-vuln-suppression-check.yml#job-name"
	mkdir -p "$MOCK_REUSABLES/default"
	printf '"on":\n  "workflow_call":\n    "inputs":\n      "job-name":\n        type: string\n' \
		>"$MOCK_REUSABLES/default/reusable-vuln-suppression-check.yml"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'; echo \"\$REPLY\""
	assert_success
	assert_output "dispatch"
}

@test "external-canary: flow-style with: or inputs: fails closed instead of reading as empty" {
	cat >"$MOCK_FIXTURE_DIR/vuln-suppression.yml" <<EOF
"on":
  workflow_dispatch:
jobs:
  check:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@${OLD_PIN}
    with: {job-name: test}
EOF
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "vuln-suppression.yml: flow-style with: on the call to .github/workflows/reusable-vuln-suppression-check.yml cannot be checked"
	_add_scoped_caller
	mkdir -p "$MOCK_REUSABLES/default"
	printf 'on:\n  workflow_call:\n    inputs: {job-name: {type: string}}\n' \
		>"$MOCK_REUSABLES/default/reusable-vuln-suppression-check.yml"
	run call_fn "reference_verdict '$MOCK_FIXTURE_DIR/vuln-suppression.yml' '$CANDIDATE'"
	assert_failure
	assert_output --partial "cannot read block-style on.workflow_call inputs in"
}

@test "external-canary: informational queue expiry retains its non-blocking verdict" {
	run call_fn verdict_for verify-negative.yml queued-timeout
	assert_success
	assert_output queued-timeout
}

@test "external-canary: queue expiry blocks gates as inconclusive" {
	run_row python.yml queued "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run env MOCK_JOBS_QUEUED=1 CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" \
		"poll_runs $CANARY_TEST_BRANCH 2026-10-08T00:00:00Z python.yml rust.yml"
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	assert_line "$(printf 'rust.yml\tqueued-timeout\t\t')"
	ROWS="$output" run bash "$CANARY_EVAL" 'failed_gates <<<"$ROWS"'
	assert_success
	assert_output "$(printf 'python.yml	queued-timeout\nrust.yml	queued-timeout')"
	run bash "$CANARY_EVAL" "printf 'python.yml	queued-timeout		\n' | render_summary '$CANDIDATE'"
	assert_output --partial '⚠️ inconclusive'
}

@test "external-canary: queue budget covers admission and prevents dispatch after expiry" {
	run env CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'result is inconclusive'
	refute_output --partial 'no gate failures'
	assert_output --partial 'queued-timeout'
	run grep '/dispatches' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: job start gets its full execution budget after the queue budget expires" {
	# Both clocks are deterministic: queue deadline 101, first job starts at
	# 100, next poll at 102. Execution budget is still available at that point.
	run bash "$CANARY_EVAL" '
		clock="$CANARY_STATE_DIR.clock"; echo 99 >"$clock"
		date() { local n; n=$(cat "$clock"); echo $((n + 1)) >"$clock"; echo "$n"; }
		first_job_start() { echo 100; }
		list_canary_runs() {
			if (($(cat "$clock") < 104)); then
				printf "python.yml\tin_progress\t\thttps://example/runs/11\tpython\n"
			else
				printf "python.yml\tcompleted\tsuccess\thttps://example/runs/11\tpython\n"
			fi
		}
		CANARY_QUEUE_TIMEOUT_SECONDS=2 CANARY_TIMEOUT_SECONDS=20 poll_runs canary/test since python.yml
	'
	assert_success
	assert_line "$(printf 'python.yml\tsuccess\thttps://example/runs/11\tpython')"
	refute_output --partial queued-timeout
	refute_output --partial "python.yml$(printf '\t')timeout"
}

@test "external-canary: rolling admission never exceeds the configured in-flight bound" {
	run bash "$CANARY_EVAL" '
		CANARY_STATE_DIR=""
		state="$MOCK_RUNS_DIR/scheduler"; mkdir -p "$state"
		dispatch_workflow() {
			local active; active=$(find "$state" -name "*.active" | wc -l)
			((active < CANARY_MAX_IN_FLIGHT)) || exit 91
			touch "$state/$1.active"
			echo "dispatch $1"
		}
		list_canary_runs() {
			local path file
			for path in "$state"/*.active; do
				file=${path##*/}; file=${file%.active}
				# Free one slot per snapshot; other workflows stay queued.
				if [[ ! -f "$state/freed" ]]; then
					mv "$path" "$state/$file.done"; touch "$state/freed"
				fi
				break
			done
			for path in "$state"/*.done; do
				[[ -f "$path" ]] || continue
				file=${path##*/}; file=${file%.done}
				printf "%s\tcompleted\tsuccess\thttps://example/runs/11\tname\n" "$file"
			done
			for path in "$state"/*.active; do
				[[ -f "$path" ]] || continue
				file=${path##*/}; file=${file%.active}
				printf "%s\tqueued\t\thttps://example/runs/11\tname\n" "$file"
			done
			rm -f "$state/freed"
		}
		first_job_start() { :; }
		CANARY_MAX_IN_FLIGHT=2 CANARY_DISPATCH=true poll_runs canary/test since one.yml two.yml three.yml four.yml
	'
	assert_success
	assert_line 'dispatch four.yml'
	assert_line "$(printf 'four.yml\tsuccess\thttps://example/runs/11\tname')"
}

@test "external-canary: failed job lookup cannot be reclassified as queue pressure" {
	run_row python.yml queued "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run env MOCK_JOBS_FAIL=1 CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" \
		"poll_runs $CANARY_TEST_BRANCH since python.yml"
	assert_success
	assert_line "$(printf 'python.yml\tmonitoring_failed\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
}

_prepare_cleanup() {
	mkdir -p "$CANARY_STATE_DIR"
	printf '%s\n' "$CANARY_TEST_BRANCH" >"$CANARY_STATE_DIR/branch"
	printf 'python.yml\n' >"$CANARY_STATE_DIR/attempted"
}

@test "external-canary: always-run cleanup cancels queued runs and probe children and retains unsettled ref" {
	_prepare_cleanup
	{
		run_row python.yml queued "" 11
		run_row verify-negative.yml in_progress "" 12
		run_row rust.yml completed success 13
	} >"$MOCK_RUNS_DIR/cleanup"
	run bash "$SCRIPT" --cleanup
	assert_success
	assert_output --partial "retained owner/fixture@$CANARY_TEST_BRANCH"
	run grep -F 'actions/runs/11/cancel' "$MOCK_CALLS"
	assert_success
	run grep -F 'actions/runs/12/cancel' "$MOCK_CALLS"
	assert_success
	run grep -E 'actions/runs/13/cancel|-X DELETE' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: cleanup retains ref when a dispatch is not yet visible or run listing fails" {
	_prepare_cleanup
	: >"$MOCK_RUNS_DIR/cleanup"
	run bash "$SCRIPT" --cleanup
	assert_success
	assert_output --partial 'retained owner/fixture@'
	run env MOCK_CLEANUP_FAIL=1 bash "$SCRIPT" --cleanup
	assert_success
	assert_output --partial 'cannot verify fixture runs'
	run grep -F -- '-X DELETE' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: cleanup deletes ref only after cancellation is observed complete" {
	_prepare_cleanup
	all_green_snapshot
	run bash "$SCRIPT" --cleanup
	assert_success
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/$CANARY_TEST_BRANCH" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: cleanup without ownership journal touches no fixture runs" {
	run bash "$SCRIPT" --cleanup
	assert_success
	run cat "$MOCK_CALLS"
	assert_output ""
}

# A settled stale ref of another candidate SHA, for the sweep (#1652).
SWEEP_STALE="canary/3333333333333333333333333333333333333333-100-1"

# Fresh state for a second full run in one test, as each Actions run has its
# own runner.temp; the fixture snapshots and sweep refs stay.
_reset_canary_run() {
	rm -rf "$CANARY_STATE_DIR"
	rm -f "$MOCK_RUNS_DIR"/.count "$MOCK_RUNS_DIR"/.reconcile-* "$MOCK_RUNS_DIR"/dispatch-*.at
	: >"$GITHUB_STEP_SUMMARY"
	: >"$GITHUB_OUTPUT"
	: >"$MOCK_CALLS"
}

@test "external-canary: a full run sweeps stale refs of other candidates after its own ref, reported in the summary" {
	all_green_snapshot
	printf 'refs/heads/%s\n' "$SWEEP_STALE" 'canary/3333333333333333333333333333333333333333' >"$MOCK_RUNS_DIR/sweep-refs"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run grep -F -- '-X DELETE repos/owner/fixture/git/refs/heads/' "$MOCK_CALLS"
	assert_output "$(printf 'api -X DELETE repos/owner/fixture/git/refs/heads/%s\n' "$CANARY_TEST_BRANCH" "$SWEEP_STALE")"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "- Removed 1: \`${SWEEP_STALE}\`"
	assert_output --partial "- Left 1 alone, name is not"
	assert_output --partial '(CANARY_SWEEP_MAX_REFS=20)'
	# The always-run cleanup step finds the journal gone and does nothing more.
	: >"$MOCK_CALLS"
	run bash "$SCRIPT" --cleanup
	assert_success
	run cat "$MOCK_CALLS"
	assert_output ""
}

@test "external-canary: a sweep API error never changes the canary result" {
	all_green_snapshot
	run env MOCK_SWEEP_REFS_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'cannot list canary refs for the stale ref sweep'
	run grep -F 'gate-failures=0' "$GITHUB_OUTPUT"
	assert_success
	_reset_canary_run
	printf 'refs/heads/%s\n' "$SWEEP_STALE" >"$MOCK_RUNS_DIR/sweep-refs"
	run env MOCK_OWNER_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "cannot verify owner of ${SWEEP_STALE}"
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/${SWEEP_STALE}" "$MOCK_CALLS"
	refute_output
	# A failing gate still fails, with or without a sweep error.
	_reset_canary_run
	run_row python.yml completed failure 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row verify-negative.yml completed failure 12 >>"$MOCK_RUNS_DIR/runs.1"
	run env MOCK_SWEEP_REFS_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure 1
	assert_output --partial "concluded 'failure'"
}

# Two settled stale refs of another candidate for the time-bound cases (#1656).
_two_sweep_refs() {
	printf 'refs/heads/%s\n' "$SWEEP_STALE" 'canary/3333333333333333333333333333333333333333-101-1' >"$MOCK_RUNS_DIR/sweep-refs"
}

@test "external-canary: a slow API stops the sweep at its budget and the verdict stands" {
	all_green_snapshot
	_two_sweep_refs
	local start=$SECONDS
	# The first owner read takes 3s against a 2s budget: cut at the deadline.
	run env CANARY_SWEEP_BUDGET_SECONDS=2 MOCK_OWNER_SLEEP=3 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "cannot verify owner of ${SWEEP_STALE}"
	assert_output --partial 'budget exhausted (CANARY_SWEEP_BUDGET_SECONDS=2), 1 ref(s) left for the next run'
	((SECONDS - start < 15))
	run grep -F 'gate-failures=0' "$GITHUB_OUTPUT"
	assert_success
	run grep -c '/attempts/' "$MOCK_CALLS"
	assert_output 1
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial '- Budget exhausted (CANARY_SWEEP_BUDGET_SECONDS=2), 1 ref(s) left for the next run.'
	assert_output --partial "- Kept 1, API error or timeout: \`${SWEEP_STALE}\`"
}

@test "external-canary: a hung sweep call is killed by the per-call timeout and the verdict stands" {
	all_green_snapshot
	_two_sweep_refs
	local start=$SECONDS
	run env CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_OWNER_SLEEP=60 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'all applicable gates passed'
	# Two owner reads, each cut after 1s; nothing waits for the 60s.
	((SECONDS - start < 20))
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "- Kept 2, API error or timeout: \`${SWEEP_STALE}\`"
	# A failing gate still fails with a hung sweep call.
	_reset_canary_run
	run_row python.yml completed failure 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row verify-negative.yml completed failure 12 >>"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_SWEEP_CALL_TIMEOUT_SECONDS=1 MOCK_OWNER_SLEEP=60 bash "$SCRIPT" "$CANDIDATE"
	assert_failure 1
	assert_output --partial "concluded 'failure'"
}

@test "external-canary: a full run records its start for the sweep's job-time check" {
	all_green_snapshot
	local before
	before="$(date +%s)"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	run cat "$CANARY_STATE_DIR/started"
	assert_output --regexp '^[0-9]+$'
	((output >= before && output <= $(date +%s)))
}

@test "external-canary: dispatch writes are not retried after an ambiguous failure" {
	_pin_failed_dispatch_clock
	all_green_snapshot
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	run grep -c '/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: rejects an invalid in-flight limit before creating a ref" {
	run env CANARY_MAX_IN_FLIGHT=0 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'CANARY_MAX_IN_FLIGHT must be a positive integer'
	run grep -F 'git/refs' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: execution clock uses earliest started job across pages and ignores queued or skipped jobs" {
	run bash "$CANARY_EVAL" '
		fixture_api() {
			local filter="${@: -1}"
			printf "%s\n" \
				'"'"'{"jobs":[{"status":"queued","started_at":"2026-01-01T00:00:00Z"},{"status":"completed","conclusion":"skipped","started_at":"2026-01-01T00:00:01Z"},{"status":"in_progress","started_at":"2026-01-01T00:00:20Z"}]}'"'"' \
				'"'"'{"jobs":[{"status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:10Z"}]}'"'"' | jq -r "$filter"
		}
		first_job_start 11
	'
	assert_success
	assert_output "$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-01-01T00:00:10Z' +%s 2>/dev/null || date -u -d '2026-01-01T00:00:10Z' +%s)"
}

@test "external-canary: a run-list outage is not reported as queue pressure" {
	run env CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" '
		list_canary_runs() { return 1; }
		poll_runs canary/test since python.yml
	'
	assert_success
	assert_line "$(printf 'python.yml\tmonitoring_failed\t\t')"
}

# Keep these short-budget failed-POST controls on the intended API path even
# under coverage. Expire only after POST (or the requested reconciliation),
# while the matched admission control advances before the first POST instead.
_pin_failed_dispatch_clock() {
	export MOCK_DISPATCH_REAL_DATE MOCK_RECONCILE_BEFORE_EXPIRY="${1:-0}"
	MOCK_DISPATCH_REAL_DATE="${MOCK_DISPATCH_REAL_DATE:-$(command -v date)}"
	# Repeated scenarios in one test each own a fresh dispatch/read receipt.
	rm -f "$MOCK_RUNS_DIR/dispatch-python.yml.at" "$MOCK_RUNS_DIR/.reconcile-python.yml" "$MOCK_RUNS_DIR/clock-count"
	: >"$MOCK_CALLS"
	cat >"${BATS_TEST_TMPDIR}/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
	if [[ "${MOCK_EXPIRE_BEFORE_DISPATCH:-0}" == 1 ]]; then
		n=$(cat "$MOCK_RUNS_DIR/clock-count" 2>/dev/null || echo 0)
		echo $((n + 1)) >"$MOCK_RUNS_DIR/clock-count"
		# since_timestamp, then poll_runs establishes its admission deadline.
		if ((n < 2)); then echo 1767225600; else echo 1767225602; fi
	elif [[ -s "$MOCK_RUNS_DIR/dispatch-python.yml.at" ]] &&
		(($(cat "$MOCK_RUNS_DIR/.reconcile-python.yml" 2>/dev/null || echo 0) >= MOCK_RECONCILE_BEFORE_EXPIRY)); then
		echo 1767225602
	else
		echo 1767225600
	fi
elif [[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then
	printf '2026-01-01T00:00:00Z\n'
else
	exec "$MOCK_DISPATCH_REAL_DATE" "$@"
fi
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/date"
}

_assert_single_failed_dispatch() {
	run grep -c '/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

_assert_dispatch_pages() {
	_assert_single_failed_dispatch
	local page
	for page in 1 2; do
		run grep -Fc "/workflows/python.yml/runs?branch=${CANARY_TEST_BRANCH}&event=workflow_dispatch&per_page=100&page=${page}" "$MOCK_CALLS"
		assert_output 1
	done
	run cat "$MOCK_RUNS_DIR/.reconcile-python.yml"
	assert_output 2
}

# Complete workflow-run API evidence for ambiguous POST regressions. The gh
# process substitutes the actual pre-POST timestamp for the dispatch marker.
observed_run() {
	jq -n --arg file "${1:-python.yml}" --arg branch "$CANARY_TEST_BRANCH" \
		--arg conclusion "${2:-success}" '{total_count:1, workflow_runs:[{
		id:11, path:(".github/workflows/" + $file), head_branch:$branch,
		head_sha:"cafecafecafecafecafecafecafecafecafecafe", event:"workflow_dispatch",
		created_at:"dispatch", status:"completed", conclusion:$conclusion,
		html_url:"https://github.com/owner/fixture/actions/runs/11", name:"fixture",
		repository:{full_name:"owner/fixture"}, head_repository:{full_name:"owner/fixture"}
	}]}'
}

@test "external-canary: ambiguous POST adopts a late unique required success and preserves diagnostic" {
	all_green_snapshot
	printf '{"total_count":0,"workflow_runs":[]}' >"$MOCK_RUNS_DIR/observed.1.json"
	observed_run >"$MOCK_RUNS_DIR/observed.2.json"
	run env MOCK_DISPATCH_FAIL=python.yml bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '| `python.yml` | gate | `success` | `success` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/11) |'
	assert_output --partial 'gh: HTTP 422'
	run grep -F 'gh: HTTP 422' "$GITHUB_STEP_SUMMARY"
	assert_success
	run cat "$MOCK_RUNS_DIR/.reconcile-python.yml"
	assert_output 2
	run grep -c '/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
	run cat "$CANARY_STATE_DIR/attempted"
	assert_line python.yml
}

@test "external-canary: ambiguous POST preserves real required failure and expected negative conclusion" {
	all_green_snapshot
	observed_run python.yml failure >"$MOCK_RUNS_DIR/observed.1.json"
	run env MOCK_DISPATCH_FAIL=python.yml bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'failure'"
	assert_output --partial '[run](https://github.com/owner/fixture/actions/runs/11)'
	cp "$MOCK_FIXTURE_DIR/verify-negative.yml" "$MOCK_FIXTURE_DIR/perms-negative-docker.yml"
	rm -f "$MOCK_RUNS_DIR/observed.1.json"
	observed_run perms-negative-docker.yml startup_failure >"$MOCK_RUNS_DIR/observed.1.json"
	run env MOCK_DISPATCH_FAIL=perms-negative-docker.yml bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '| `perms-negative-docker.yml` | informational | `startup_failure` | `startup_failure` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/11) |'
}

@test "external-canary: ambiguous POST rejects foreign stale malformed conflicting and incomplete evidence" {
	local change
	all_green_snapshot
	for change in \
		'.workflow_runs[0].head_branch = "canary/foreign"' \
		'.workflow_runs[0].head_sha = "1111111111111111111111111111111111111111"' \
		'.workflow_runs[0].event = "push"' \
		'.workflow_runs[0].path = ".github/workflows/rust.yml"' \
		'.workflow_runs[0].repository.full_name = "foreign/repo"' \
		'.workflow_runs[0].html_url = "https://example.com/runs/11"' \
		'.workflow_runs[0].created_at = "2000-01-01T00:00:00Z"' \
		'.workflow_runs[0].created_at = "2099-01-01T00:00:00Z"' \
		'.workflow_runs[0].conclusion = null' \
		'.workflow_runs += .workflow_runs | .total_count = 2' \
		'.total_count = 2' \
		'del(.total_count)' \
		'.total_count = 1001'; do
		observed_run | jq "$change" >"$MOCK_RUNS_DIR/observed.1.json"
		rm -f "$MOCK_RUNS_DIR/.reconcile-python.yml"
		_pin_failed_dispatch_clock
		run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial "gate python.yml concluded 'dispatch_failed'"
		refute_output --partial '| `python.yml` | gate | `success` | `success` |'
		_assert_single_failed_dispatch
	done
}

@test "external-canary: ambiguous POST read errors and missing runs cannot be waived by override" {
	_pin_failed_dispatch_clock
	all_green_snapshot
	observed_run >"$MOCK_RUNS_DIR/observed.1.json"
	run env MOCK_DISPATCH_FAIL=python.yml MOCK_RECONCILE_FAIL=1 CANARY_QUEUE_TIMEOUT_SECONDS=1 \
		PR_LABELS=canary-informational bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'dispatch_failed'"
	_assert_single_failed_dispatch
	rm -f "$MOCK_RUNS_DIR/observed.1.json"
	_pin_failed_dispatch_clock
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 PR_LABELS=canary-informational bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'dispatch_failed'"
	_assert_single_failed_dispatch
}

@test "external-canary: ambiguous POST without state or trusted head remains blocking" {
	_pin_failed_dispatch_clock
	all_green_snapshot
	observed_run >"$MOCK_RUNS_DIR/observed.1.json"
	run bash "$CANARY_EVAL" '
		CANARY_STATE_DIR=""
		CANARY_DISPATCH=true CANARY_QUEUE_TIMEOUT_SECONDS=1 MOCK_DISPATCH_FAIL=python.yml poll_runs "$CANARY_TEST_BRANCH" since python.yml
	'
	assert_success
	assert_output --partial "$(printf 'python.yml\tdispatch_failed')"
	run grep -c '/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: ambiguous POST cannot switch run identity between snapshots" {
	_pin_failed_dispatch_clock 2
	all_green_snapshot
	observed_run | jq '.workflow_runs[0] |= (.status="queued" | .conclusion=null)' >"$MOCK_RUNS_DIR/observed.1.json"
	observed_run | jq '.workflow_runs[0] |= (.id=22 | .html_url="https://github.com/owner/fixture/actions/runs/22")' >"$MOCK_RUNS_DIR/observed.2.json"
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=2 MOCK_JOBS_QUEUED=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'dispatch_failed'"
	_assert_single_failed_dispatch
	run cat "$MOCK_RUNS_DIR/.reconcile-python.yml"
	assert_output 2
}

@test "external-canary: ambiguous POST consumes complete pages and rejects later conflicts" {
	_pin_failed_dispatch_clock
	all_green_snapshot
	observed_run | jq '.total_count=101 | .workflow_runs = [range(100) as $n | .workflow_runs[0] | .id += $n]' >"$MOCK_RUNS_DIR/page.1.json"
	observed_run | jq '.total_count=101' >"$MOCK_RUNS_DIR/page.2.json"
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'dispatch_failed'"
	run grep -F 'per_page=100&page=2' "$MOCK_CALLS"
	assert_success
	_assert_dispatch_pages
	# A second-page outage cannot make the first page sufficient evidence.
	_pin_failed_dispatch_clock
	printf 'not-json' >"$MOCK_RUNS_DIR/page.2.json"
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "gate python.yml concluded 'dispatch_failed'"
	_assert_dispatch_pages
}

@test "external-canary: pagination fixture admission expiry is inconclusive before POST" {
	_pin_failed_dispatch_clock
	all_green_snapshot
	observed_run | jq '.total_count=101 | .workflow_runs = [range(100) as $n | .workflow_runs[0] | .id += $n]' >"$MOCK_RUNS_DIR/page.1.json"
	observed_run | jq '.total_count=101' >"$MOCK_RUNS_DIR/page.2.json"
	run env MOCK_EXPIRE_BEFORE_DISPATCH=1 MOCK_DISPATCH_FAIL=python.yml CANARY_QUEUE_TIMEOUT_SECONDS=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `python.yml` | gate | `success` | `queued-timeout` | ⚠️ inconclusive |'
	assert_output --partial 'result is inconclusive'
	refute_output --partial 'dispatch python.yml failed'
	run grep -E '/workflows/python.yml/(dispatches|runs\?)' "$MOCK_CALLS"
	refute_output
	[[ ! -e "$MOCK_RUNS_DIR/dispatch-python.yml.at" ]]
	[[ ! -e "$MOCK_RUNS_DIR/.reconcile-python.yml" ]]
}

@test "external-canary: closed candidate PR exits with a notice before fixture writes" {
	run env EVENT_NAME=pull_request PR_NUMBER=1222 MOCK_PR_STATE=closed bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '::notice::candidate pull request #1222 is closed or merged'
	run grep 'repos/owner/fixture' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: merged candidate PR exits with a notice" {
	run env EVENT_NAME=pull_request PR_NUMBER=1222 MOCK_PR_STATE=merged bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '::notice::candidate pull request #1222 is closed or merged'
}

@test "external-canary: PR state API error fails closed" {
	run env EVENT_NAME=pull_request PR_NUMBER=1222 MOCK_PR_STATE_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'cannot read candidate pull request state'
	refute_output --partial '::notice::'
}

@test "external-canary: PR merged while polling overrides a real gate failure" {
	retry_snapshots failure failure
	setup_failure_jobs 'Run tests'
	run env EVENT_NAME=pull_request PR_NUMBER=1222 PR_LABELS=needs-external-canary MOCK_PR_FINAL_STATE=merged bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '::notice::candidate pull request #1222 is closed or merged'
	refute_output --partial '::error'
}

@test "external-canary: PR state error after polling cannot turn a pass green" {
	all_green_snapshot
	run env EVENT_NAME=pull_request PR_NUMBER=1222 PR_LABELS=needs-external-canary MOCK_PR_FINAL_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'cannot read candidate pull request state'
	refute_output --partial '::notice::'
}

@test "external-canary: unknown PR state fails closed" {
	run env EVENT_NAME=pull_request PR_NUMBER=1222 MOCK_PR_STATE=null bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	refute_output --partial '::notice::'
}

@test "external-canary: closed candidate after polling exits with a notice" {
	all_green_snapshot
	run env EVENT_NAME=pull_request PR_NUMBER=1222 PR_LABELS=needs-external-canary MOCK_PR_FINAL_STATE=closed bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '::notice::candidate pull request #1222 is closed or merged'
}

@test "external-canary: inconclusive cannot be overridden by the informational label" {
	run env PR_LABELS=canary-informational CANARY_QUEUE_TIMEOUT_SECONDS=0 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'result is inconclusive'
	refute_output --partial 'reported as success'
}

# Eval prelude: python.yml's first dispatch succeeds and its retry POST fails.
# The unmatched retry stays ambiguous until the queue budget expires, so the
# clock jumps past the deadline once the retry was attempted.
RETRY_REJECTED_STUBS='
	dispatch_workflow() {
		[[ "$1" != python.yml ]] && return 0
		printf "%s\n" "$1" >>"$MOCK_RUNS_DIR/dispatches"
		[[ $(wc -l <"$MOCK_RUNS_DIR/dispatches") -eq 1 ]]
	}
	date() {
		[[ "$*" == +%s ]] || { command date "$@"; return; }
		if [[ -f "$MOCK_RUNS_DIR/dispatches" ]] && (($(wc -l <"$MOCK_RUNS_DIR/dispatches") >= 2)); then
			echo 1767229200
		else
			echo 1767225600
		fi
	}
'

@test "external-canary: failed retry dispatch is blocking inconclusive in main" {
	retry_snapshots startup_failure success
	run bash "$CANARY_EVAL" "${RETRY_REJECTED_STUBS}"'
		main "$CANDIDATE"
	'
	assert_failure
	assert_output --partial 'retry dispatch failed'
	assert_output --partial 'result is inconclusive'
}

# A terminal setup failure, one stale snapshot after re-dispatch, then the
# newer run followed by the original. Exercise retry polling through gh stubs.
retry_snapshots() {
	run_row python.yml completed "$1" 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row verify-negative.yml completed failure 12 >>"$MOCK_RUNS_DIR/runs.1"
	cp "$MOCK_RUNS_DIR/runs.1" "$MOCK_RUNS_DIR/runs.2"
	cp "$MOCK_RUNS_DIR/runs.1" "$MOCK_RUNS_DIR/runs.3"
	{
		run_row python.yml completed "$2" 21
		run_row python.yml completed "$1" 11
		run_row verify-negative.yml completed failure 12
	} >"$MOCK_RUNS_DIR/runs.4"
}

setup_failure_jobs() {
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json"
	jq -n --arg step "${1:-Harden runner}" --arg later "${2:-skipped}" \
		'{jobs: [{conclusion: "failure", steps: [
		{name: "Set up job", conclusion: "success"},
		{name: $step, conclusion: "failure"},
		{name: "Run tests", conclusion: $later}]}]}' >"$MOCK_JOBS_JSON"
}

@test "external-canary: startup failure retries once with the second verdict and first run note" {
	retry_snapshots startup_failure success
	run bash "$CANARY_EVAL" '
		mkdir -p "$CANARY_STATE_DIR"
		CANARY_DISPATCH=true poll_runs "$CANARY_TEST_BRANCH" since python.yml >"$MOCK_RUNS_DIR/results"
		render_summary "$CANDIDATE" <"$MOCK_RUNS_DIR/results"
	'
	assert_success
	assert_output --partial '| `success` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial 'retried once (startup_failure); first run: https://github.com/owner/fixture/actions/runs/11'
	run cat "$CANARY_STATE_DIR/attempted"
	assert_output "$(printf 'python.yml\npython.yml')"
	run grep 'created=' "$MOCK_CALLS"
	assert_output --partial "created=%3E%3D$(date -u +%Y-%m-%d)"
}

@test "external-canary: jobs-proven Harden runner failure retries and main renders the sidecar" {
	retry_snapshots failure success
	setup_failure_jobs
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'retried once (infra); first run: https://github.com/owner/fixture/actions/runs/11'
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial '| `success` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/21)'
	run grep '/runs/11/jobs?' "$MOCK_CALLS"
	assert_output --partial '--paginate'
}

@test "external-canary: failure in Run tests never retries" {
	retry_snapshots failure success
	setup_failure_jobs 'Run tests'
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	refute_output --partial 'retried once'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: informational startup failures and gate probes never retry" {
	run bash "$CANARY_EVAL" '
		for file in sbom-release-upload.yml app-token-probe.yml verify-negative.yml release-version-pr.yml docker-scan-failure-probe.yml unknown-probe.yml; do
			if retry_eligible "$file" startup_failure https://example/runs/11; then exit 91; fi
		done
	'
	assert_success
	run cat "$MOCK_CALLS"
	assert_output ''
}

@test "external-canary: retried startup failure is blocking inconclusive" {
	retry_snapshots startup_failure startup_failure
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `startup_failure` | ⚠️ inconclusive |'
	assert_output --partial 'result is inconclusive'
	refute_output --partial 'gate failed'
}

@test "external-canary: retried proven setup failure is blocking inconclusive" {
	retry_snapshots failure failure
	setup_failure_jobs
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ⚠️ inconclusive |'
	assert_output --partial 'result is inconclusive'
	refute_output --partial 'gate failed'
}

@test "external-canary: second failure is a gate failure without a third dispatch" {
	retry_snapshots startup_failure failure
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial 'retried once (startup_failure); first run: https://github.com/owner/fixture/actions/runs/11'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: CANARY_RETRY_INFRA=false never re-dispatches" {
	retry_snapshots startup_failure success
	run env CANARY_RETRY_INFRA=false bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	refute_output --partial 'retried once'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: jobs API error makes failure ineligible" {
	retry_snapshots failure success
	export MOCK_JOBS_FAIL=1
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	refute_output --partial 'retried once'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: all setup step names accept only skipped or null later steps" {
	local step
	for step in 'Set up job' 'Pre Harden runner' 'Harden runner' 'Checkout sources' 'Prepare Python Matrix'; do
		setup_failure_jobs "$step"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_success
		assert_output infra
	done
	setup_failure_jobs 'Harden runner' success
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	setup_failure_jobs 'Harden runner'
	jq '.jobs[0].steps[2].conclusion = null' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
}

@test "external-canary: every failed job across all pages must prove setup failure" {
	setup_failure_jobs
	cp "$MOCK_JOBS_JSON" "$MOCK_JOBS_JSON.page1"
	setup_failure_jobs 'Run tests'
	cat "$MOCK_JOBS_JSON.page1" >>"$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	setup_failure_jobs
	cat "$MOCK_JOBS_JSON" "$MOCK_JOBS_JSON.page1" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra
}

@test "external-canary: missing failure evidence and unrelated conclusions never retry" {
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json"
	local jobs conclusion
	for jobs in '{"jobs":[]}' '{"jobs":[{"conclusion":"failure","steps":[]}]}' '{"jobs":[{"conclusion":"failure"}]}' 'invalid'; do
		printf '%s\n' "$jobs" >"$MOCK_JOBS_JSON"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
	for conclusion in timeout queued-timeout dispatch_failed missing via_probe monitoring_failed; do
		run call_fn retry_eligible python.yml "$conclusion" https://example/runs/11
		assert_failure
	done
}

@test "external-canary: failed retry dispatch preserves the first result and reports the failure" {
	retry_snapshots startup_failure success
	run bash "$CANARY_EVAL" "${RETRY_REJECTED_STUBS}"'
		mkdir -p "$CANARY_STATE_DIR"
		CANARY_DISPATCH=true poll_runs "$CANARY_TEST_BRANCH" since python.yml >"$MOCK_RUNS_DIR/results"
		render_summary "$CANDIDATE" <"$MOCK_RUNS_DIR/results"
	'
	assert_success
	assert_output --partial '| `startup_failure` | ⚠️ inconclusive | [run](https://github.com/owner/fixture/actions/runs/11)'
	assert_output --partial 'retry dispatch failed'
	refute_output --partial 'retried once'
}

@test "external-canary: retry admission shares the queue deadline" {
	run bash "$CANARY_EVAL" '
		CANARY_STATE_DIR=""
		date() { echo 100; }
		list_canary_runs() { printf "python.yml\tcompleted\tstartup_failure\thttps://example/runs/11\tname\n"; }
		dispatch_workflow() { exit 91; }
		CANARY_QUEUE_TIMEOUT_SECONDS=0 poll_runs canary/test since python.yml
	'
	assert_success
	assert_line "$(printf 'python.yml\tstartup_failure\thttps://example/runs/11\tname\t\tstartup_failure')"
}

@test "external-canary: retry shares in-flight slots with queued first attempts" {
	run bash "$CANARY_EVAL" '
		mkdir -p "$CANARY_STATE_DIR"
		state="$MOCK_RUNS_DIR/scheduler"; mkdir -p "$state"
		dispatch_workflow() {
			local active; active=$(find "$state" -name "*.active" | wc -l)
			((active < CANARY_MAX_IN_FLIGHT)) || return 91
			touch "$state/$1.active"
			printf "%s\n" "$1" >>"$state/dispatches"
		}
		list_canary_runs() {
			local file id result
			for file in "$state"/*.active; do
				[[ -f "$file" ]] || continue
				file=${file##*/}; file=${file%.active}
				id=12; result=success
				if [[ "$file" == one.yml ]]; then
					id=11
					if [[ ! -f "$state/failed" ]]; then
						touch "$state/failed"; result=startup_failure
					else id=21; fi
				fi
				mv "$state/$file.active" "$state/$file.done"
				printf "%s\tcompleted\t%s\thttps://example/runs/%s\tname\n" "$file" "$result" "$id" >"$state/$file.row"
				# Free just one slot per fetch; queued workflows still use slots.
				break
			done
			cat "$state"/*.row
			for file in "$state"/*.active; do
				[[ -f "$file" ]] || continue
				file=${file##*/}; file=${file%.active}
				printf "%s\tqueued\t\thttps://example/runs/12\tname\n" "$file"
			done
		}
		first_job_start() { :; }
		CANARY_MAX_IN_FLIGHT=2 CANARY_DISPATCH=true poll_runs canary/test since one.yml two.yml
		cat "$state/dispatches"
	'
	assert_success
	assert_line "$(printf 'one.yml\tsuccess\thttps://example/runs/21\tname\t\t\tstartup_failure\tdispatched\thttps://example/runs/11')"
	assert_line "$(printf 'two.yml\tsuccess\thttps://example/runs/12\tname')"
	assert_output --partial "$(printf 'one.yml\ntwo.yml\none.yml')"
}

@test "external-canary: cleanup retains ref until both journaled attempts are visible" {
	mkdir -p "$CANARY_STATE_DIR"
	printf '%s\n' "$CANARY_TEST_BRANCH" >"$CANARY_STATE_DIR/branch"
	printf 'python.yml\npython.yml\n' >"$CANARY_STATE_DIR/attempted"
	run_row python.yml completed startup_failure 11 >"$MOCK_RUNS_DIR/cleanup"
	run call_fn cleanup_fixture_runs
	assert_success
	assert_output --partial 'retained owner/fixture@'
	assert_file_exists "$CANARY_STATE_DIR/branch"
	run grep -- '-X DELETE' "$MOCK_CALLS"
	assert_failure
}

@test "external-canary: informational startup failure stays informational without a second dispatch" {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed startup_failure 12
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial '| `verify-negative.yml` | informational | `failure` | `startup_failure` | ⚠️ unexpected |'
	refute_output --partial 'retried once'
	run grep -c '/actions/workflows/verify-negative.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
}

@test "external-canary: partial jobs evidence followed by an API error cannot trigger retry" {
	run bash "$CANARY_EVAL" '
		fixture_api() {
			printf "%s\n" '\''{"jobs":[{"conclusion":"failure","steps":[{"name":"Harden runner","conclusion":"failure"}]}]}'\''
			return 1
		}
		retry_eligible python.yml failure https://example/runs/11
	'
	assert_failure
	assert_output ''
}

@test "external-canary: polling-only mode never dispatches an eligible startup failure" {
	retry_snapshots startup_failure success
	run call_fn poll_runs "$CANARY_TEST_BRANCH" since python.yml
	assert_success
	assert_output "$(printf 'python.yml\tstartup_failure\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python\t\tstartup_failure')"
	run grep '/dispatches' "$MOCK_CALLS"
	assert_failure
}

# PR #1222 review: an infrastructure verdict never depends on CANARY_STATE_DIR.
@test "external-canary: gate startup_failure is inconclusive without a state directory" {
	run bash "$CANARY_EVAL" '
		CANARY_STATE_DIR=""
		verdict_for python.yml startup_failure
		verdict_for verify-negative.yml startup_failure
		printf "python.yml\tstartup_failure\thttps://example/runs/11\tname\n" | inconclusive_gates
	'
	assert_success
	assert_output "$(printf 'inconclusive\nfail\npython.yml\tstartup_failure')"
}

@test "external-canary: proven setup failure evidence travels in the row without a state directory" {
	retry_snapshots failure failure
	setup_failure_jobs
	run bash "$CANARY_EVAL" '
		CANARY_STATE_DIR=""
		CANARY_DISPATCH=true poll_runs "$CANARY_TEST_BRANCH" since python.yml >"$MOCK_RUNS_DIR/results"
		render_summary "$CANDIDATE" <"$MOCK_RUNS_DIR/results"
		echo "inconclusive: $(inconclusive_gates <"$MOCK_RUNS_DIR/results")"
		echo "failed: $(failed_gates <"$MOCK_RUNS_DIR/results")"
	'
	assert_success
	assert_output --partial '| `failure` | ⚠️ inconclusive | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial 'retried once (infra); first run: https://github.com/owner/fixture/actions/runs/11'
	assert_output --partial "$(printf 'inconclusive: python.yml\tfailure')"
	assert_output --partial "$(printf 'failed: python.yml\tfailure')"
	refute_output --partial 'gate failed'
}

@test "external-canary: rejected retry dispatch keeps inconclusive evidence without a state directory" {
	retry_snapshots failure success
	setup_failure_jobs
	run bash "$CANARY_EVAL" "${RETRY_REJECTED_STUBS}"'
		CANARY_STATE_DIR=""
		CANARY_DISPATCH=true poll_runs "$CANARY_TEST_BRANCH" since python.yml >"$MOCK_RUNS_DIR/results"
		cat "$MOCK_RUNS_DIR/results"
		render_summary "$CANDIDATE" <"$MOCK_RUNS_DIR/results"
		echo "inconclusive: $(inconclusive_gates <"$MOCK_RUNS_DIR/results")"
	'
	assert_success
	assert_line "$(printf 'python.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python\tdispatch response failed\tinfra\tinfra\tfailed\thttps://github.com/owner/fixture/actions/runs/11')"
	assert_output --partial '| `failure` | ⚠️ inconclusive | [run](https://github.com/owner/fixture/actions/runs/11)'
	assert_output --partial 'retry dispatch failed; first run: https://github.com/owner/fixture/actions/runs/11'
	assert_output --partial "$(printf 'inconclusive: python.yml\tfailure')"
	refute_output --partial 'gate failed'
}

@test "external-canary: override label cannot waive a rejected retry dispatch" {
	retry_snapshots failure success
	setup_failure_jobs
	run bash "$CANARY_EVAL" "${RETRY_REJECTED_STUBS}"'
		PR_LABELS=canary-informational main "$CANDIDATE"
	'
	assert_failure
	assert_output --partial "result is inconclusive: python.yml concluded 'failure'"
	refute_output --partial 'reported as success'
}

@test "external-canary: ambiguous retry POST reconciles only a run other than the first" {
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	observed_run | jq --arg now "$now" '
		.workflow_runs[0].created_at = $now
		| .workflow_runs += [.workflow_runs[0] | .id = 21 | .html_url = "https://github.com/owner/fixture/actions/runs/21"]
		| .total_count = 2' >"$MOCK_RUNS_DIR/both.json"
	run bash "$CANARY_EVAL" '
		fixture_api() { cat "$MOCK_RUNS_DIR/both.json"; }
		head=cafecafecafecafecafecafecafecafecafecafe
		since=$(($(date +%s) - 60))
		if observed_dispatch_run "$CANARY_TEST_BRANCH" python.yml "$head" "$since"; then exit 91; fi
		observed_dispatch_run "$CANARY_TEST_BRANCH" python.yml "$head" "$since" https://github.com/owner/fixture/actions/runs/11
	'
	assert_success
	assert_output "$(printf 'python.yml\tcompleted\tsuccess\thttps://github.com/owner/fixture/actions/runs/21\tfixture')"
}

@test "external-canary: mixed inconclusive and failed gates annotate every row" {
	all_green_snapshot
	run bash "$CANARY_EVAL" '
		poll_runs() {
			printf "python.yml\tstartup_failure\thttps://example/runs/11\tname\n"
			printf "rust.yml\tfailure\thttps://example/runs/12\tname\n"
		}
		PR_LABELS=canary-informational main "$CANDIDATE"
	'
	assert_failure
	assert_output --partial "::error title=external canary::result is inconclusive: python.yml concluded 'startup_failure' (not a pass or product failure)"
	assert_output --partial "::error title=external canary::gate rust.yml concluded 'failure'"
	refute_output --partial 'reported as success'
}

# --- infrastructure annotation signatures (#1475) --------------------------

# Check-run annotations shaped like the real fixture ones: fixture run
# 43070043408, job 130695209599 (docker readiness), and job 130586824518 of
# run 43039395926 (apt DNS failure: apt's `E:` line is plain output, so only
# the exit code is annotated).
ANN_EXIT_1='{"path":".github","start_line":12,"end_line":12,"annotation_level":"failure","title":"","message":"Process completed with exit code 1.","raw_details":""}'
ANN_EXIT_100='{"path":".github","start_line":90,"end_line":90,"annotation_level":"failure","title":"","message":"Process completed with exit code 100.","raw_details":""}'
ANN_DOCKER='{"path":".github","start_line":11,"end_line":11,"annotation_level":"failure","title":"","message":"Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace)","raw_details":""}'
ANN_TEST='{"path":"tests/test_app.py","start_line":4,"end_line":4,"annotation_level":"failure","title":"test_add","message":"assert 3 == 4","raw_details":""}'
ANN_EGRESS='{"path":".github","start_line":7,"end_line":7,"annotation_level":"failure","title":"","message":"Error: connect ECONNREFUSED 54.185.253.63:443","raw_details":""}'
ANN_WARNING='{"path":".github","start_line":3,"end_line":3,"annotation_level":"warning","title":"","message":"Node.js 20 actions are deprecated.","raw_details":""}'

# Jobs JSON with one failed job (id $1) whose only failed step is $2, and that
# job's check-run annotations: the remaining arguments, one annotation object
# each, written as $MOCK_ANNOTATIONS/<id>.json.
signature_job() {
	local job="$1" step="$2"
	shift 2
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	jq -n --arg step "$step" --argjson job "$job" '{jobs: [{id: $job, conclusion: "failure", steps: [
		{name: "Set up job", conclusion: "success"},
		{name: "Harden runner", conclusion: "success"},
		{name: $step, conclusion: "failure"},
		{name: "Upload results", conclusion: "skipped"}]}]}' >"$MOCK_JOBS_JSON"
	jq -s . <<<"$*" >"$MOCK_ANNOTATIONS/${job}.json"
}

docker_readiness_job() {
	signature_job 501 "Wait for hardener Docker readiness" "$ANN_EXIT_1" "$ANN_DOCKER" "$ANN_WARNING"
}

# Reset the run snapshots between scenarios of one test.
_reset_retry_scenario() {
	rm -rf "$MOCK_RUNS_DIR" "$CANARY_STATE_DIR"
	mkdir -p "$MOCK_RUNS_DIR"
	: >"$MOCK_CALLS"
	: >"$GITHUB_STEP_SUMMARY"
}

@test "external-canary: the docker readiness annotation makes a failed gate eligible" {
	docker_readiness_job
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:docker-readiness
	run grep -c 'check-runs/501/annotations' "$MOCK_CALLS"
	assert_output 1
	# The canary never reads job logs, whose host is outside its egress preset.
	run grep -c '/logs' "$MOCK_CALLS"
	assert_output 0
}

@test "external-canary: the docker readiness annotation triggers exactly one retry that can pass" {
	retry_snapshots failure success
	docker_readiness_job
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "retried once (infra:docker-readiness); first run: https://github.com/owner/fixture/actions/runs/11"
	assert_output --partial '| `success` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/21)'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: an apt DNS failure is not retried and needs the manual re-run" {
	# Fixture run 43039395926: apt's DNS error is plain output, not an annotation.
	retry_snapshots failure success
	signature_job 501 "Install musl toolchain" "$ANN_EXIT_100"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/11)'
	refute_output --partial 'retried once'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 1
	run _canary_signatures
	refute_output --partial apt-dns
}

@test "external-canary: a product failure without a signature is not retried" {
	local case step ann
	for case in "Run tests|ANN_TEST" "Setup Bun|ANN_EGRESS"; do
		IFS='|' read -r step ann <<<"$case"
		_reset_retry_scenario
		retry_snapshots failure success
		signature_job 501 "$step" "$ANN_EXIT_1" "${!ann}"
		run bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/11)'
		assert_output --partial "::error title=external canary::gate python.yml concluded 'failure'"
		refute_output --partial 'retried once'
		refute_output --partial 'result is inconclusive'
		refute_output --partial 'run rerun'
		run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
		assert_output 1
	done
}

@test "external-canary: the signature counts only as the readiness step's own error" {
	# The signature annotation on a job whose failed step is not the readiness step.
	signature_job 501 "Run tests" "$ANN_EXIT_1" "$ANN_DOCKER"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Another failure annotation beside the signature (some other step's error).
	signature_job 501 "Wait for hardener Docker readiness" "$ANN_EXIT_1" "$ANN_DOCKER" "$ANN_TEST"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A second exit code annotation means a second failing step.
	signature_job 501 "Wait for hardener Docker readiness" "$ANN_EXIT_1" "$ANN_EXIT_100" "$ANN_DOCKER"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Only the exact message: the 60s harden-runner wait is a different error.
	signature_job 501 "Wait for hardener Docker readiness" "$ANN_EXIT_1" \
		"$(jq -c '.message = "Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace) extra"' <<<"$ANN_DOCKER")"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# No annotations at all.
	signature_job 501 "Wait for hardener Docker readiness"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a second infrastructure failure is blocking inconclusive with the re-run instruction" {
	retry_snapshots failure failure
	docker_readiness_job
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ⚠️ inconclusive | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial 'retried once (infra:docker-readiness); first run: https://github.com/owner/fixture/actions/runs/11'
	assert_output --partial "::error title=external canary::result is inconclusive: python.yml concluded 'failure' (not a pass or product failure). Not a product failure"
	assert_output --partial 'Re-run this canary with `gh run rerun 12345 --repo lgtm-hq/lgtm-ci --failed`, which replaces this attempt'
	refute_output --partial 'gate failed'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial '> ⚠️ **Blocking inconclusive.** Not a product failure'
	assert_output --partial 'gh run rerun 12345 --repo lgtm-hq/lgtm-ci --failed'
}

@test "external-canary: a retry that then fails without a signature is a product failure" {
	retry_snapshots failure failure
	docker_readiness_job
	# The retry (run 21) failed in a test step: its jobs carry no signature.
	run bash "$CANARY_EVAL" '
		fixture_api() {
			if [[ "$*" == *"/runs/21/jobs?"* ]]; then
				jq ".jobs[0].steps[2].name = \"Run tests\"" "$MOCK_JOBS_JSON"
				return 0
			fi
			gh api "$@"
		}
		main "$CANDIDATE"
	'
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial 'retried once (infra:docker-readiness)'
	refute_output --partial 'result is inconclusive'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: every failed job must carry a signature or be a downstream report" {
	docker_readiness_job
	# The docker-publish shape (fixture run 43070043408): a publish leg plus the
	# check job reporting it.
	jq '.jobs += [{id: 502, name: "check", conclusion: "failure", steps: [
		{name: "Set up job", conclusion: "success"},
		{name: "Assert the published index lists both platforms", conclusion: "failure"}]}]' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_success
	assert_output infra:docker-readiness
	# A second job failing in a test step keeps the run a product failure.
	jq '.jobs += [{id: 503, conclusion: "failure", steps: [{name: "Run tests", conclusion: "failure"}]}]' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/503.json"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
	# A downstream report alone is not evidence.
	jq '.jobs |= map(select(.id == 502))' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: signature evidence fails closed on annotation API errors and ambiguous steps" {
	docker_readiness_job
	run env MOCK_ANNOTATIONS_FAIL=1 bash "$CANARY_EVAL" 'retry_eligible python.yml failure https://example/runs/11'
	assert_failure
	# A full run with the annotation API down: one dispatch, a product failure.
	retry_snapshots failure success
	run env MOCK_ANNOTATIONS_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/11)'
	refute_output --partial 'retried once'
	# Malformed annotations.
	echo '{"message": "not a list"}' >"$MOCK_ANNOTATIONS/501.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Two failed steps in one job.
	docker_readiness_job
	jq '.jobs[0].steps[1].conclusion = "failure"' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Signatures never make informational workflows or probes eligible.
	docker_readiness_job
	run call_fn retry_eligible verify-negative.yml failure https://example/runs/11
	assert_failure
	run call_fn retry_eligible docker-scan-failure-probe.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: every canary signature names its step and the run it was seen in" {
	local sigs
	sigs="$(_canary_signatures)"
	assert_equal "$(cut -f1 <<<"$sigs" | sort -u | tr '\n' ' ')" \
		"apt-mirror docker-readiness playwright-download "
	assert_equal "$(grep '^playwright-download' <<<"$sigs" | cut -f2)" "Install Playwright browsers"
	assert_equal "$(grep '^docker-readiness' <<<"$sigs" | cut -f2)" "Wait for hardener Docker readiness"
	# The message is the one wait-for-harden-runner.sh emits with ::error::.
	run grep -F '::error::Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace)"' \
		"${PROJECT_ROOT}/scripts/ci/docker/wait-for-harden-runner.sh"
	assert_success
	run awk '/^infra_canary_signatures\(\)/,/^}/' "${PROJECT_ROOT}/scripts/ci/lib/infra-signatures.sh"
	assert_output --partial 'Fixture run 43070043408'
	assert_output --partial '#1432'
	assert_output --partial '43039395926'
}

# Sol review of #1494: the downstream exception and unfinished jobs.
_readiness_plus() {
	docker_readiness_job
	jq --argjson job "$1" '.jobs += [$job]' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
}

@test "external-canary: a timed-out or cancelled job next to a readiness failure is not retried" {
	local conclusion
	# JSON values: three strings and a real null (an unfinished job).
	for conclusion in '"timed_out"' '"cancelled"' '"action_required"' null; do
		_readiness_plus "{\"id\": 504, \"name\": \"tests\", \"conclusion\": ${conclusion}, \"steps\": [{\"name\": \"Run tests\", \"conclusion\": null}]}"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
}

@test "external-canary: the downstream step name counts only in its own workflow and job" {
	local check='{"id": 502, "name": "check", "conclusion": "failure", "steps": [{"name": "Assert the published index lists both platforms", "conclusion": "failure"}]}'
	_readiness_plus "$check"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
	# Same job and step in another workflow: not the known report.
	run call_fn retry_eligible another-gate.yml failure https://example/runs/11
	assert_failure
	# Same step in another job of the right workflow: not the known report.
	_readiness_plus "${check/\"check\"/\"assert-index\"}"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a downstream report with its own error annotation is not retried" {
	_readiness_plus '{"id": 502, "name": "check", "conclusion": "failure", "steps": [{"name": "Assert the published index lists both platforms", "conclusion": "failure"}]}'
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a setup failure next to a timed-out job is not retried" {
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	jq -n '{jobs: [
		{id: 601, name: "build", conclusion: "failure", steps: [
			{name: "Set up job", conclusion: "failure"}, {name: "Run", conclusion: null}]},
		{id: 602, name: "tests", conclusion: "timed_out", steps: [
			{name: "Run tests", conclusion: "cancelled"}]}]}' >"$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Without the timed-out job, the setup failure alone is still retried.
	jq '.jobs |= map(select(.id == 601))' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra
}

@test "external-canary: downstream annotation reads count toward the five-read budget" {
	local id
	docker_readiness_job
	for id in 511 512 513 514; do
		jq --argjson id "$id" '.jobs += [.jobs[0] | .id = $id]' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
		mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
		cp "$MOCK_ANNOTATIONS/501.json" "$MOCK_ANNOTATIONS/${id}.json"
	done
	# Five signature jobs: exactly the budget.
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_success
	# A sixth read, for the downstream check job, exceeds it.
	_readiness_plus_keep() {
		jq --argjson job "$1" '.jobs += [$job]' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
		mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	}
	_readiness_plus_keep '{"id": 502, "name": "check", "conclusion": "failure", "steps": [{"name": "Assert the published index lists both platforms", "conclusion": "failure"}]}'
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
}

# #1503: every Docker gate fixture's report job is a downstream entry.
_docker_check() {
	_readiness_plus "{\"id\": 502, \"name\": \"check\", \"conclusion\": \"failure\", \"steps\": [{\"name\": \"$1\", \"conclusion\": \"failure\"}]}"
}

@test "external-canary: each Docker gate's check job reporting a readiness failure is retried once" {
	local entry file step
	for entry in \
		$'readonly-docker.yml\tAssert the build passed and both SARIF artifacts exist' \
		$'docker-facade-validate.yml\tAssert the facade validated and uploaded both SARIF categories' \
		$'docker-orchestrator.yml\tAssert the split path ran through the facade' \
		$'docker-publish.yml\tAssert the published index lists both platforms'; do
		IFS=$'\t' read -r file step <<<"$entry"
		_docker_check "$step"
		jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
		run call_fn retry_eligible "$file" failure https://example/runs/11
		assert_success
		assert_output infra:docker-readiness
	done
}

@test "external-canary: a Docker gate's check step with its own error is not retried" {
	_docker_check "Assert the build passed and both SARIF artifacts exist"
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible readonly-docker.yml failure https://example/runs/11
	assert_failure
	# A step of one fixture is not excused in another.
	_docker_check "Assert the build passed and both SARIF artifacts exist"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
	run call_fn retry_eligible docker-orchestrator.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a check job failing silently while its Docker reusable succeeded is not retried" {
	# The real readonly-docker and facade-validate check steps also assert
	# artifacts and SARIF categories, and those fail with a bare exit 1 (no
	# ::error::) only after the reusable succeeded. With no failed job proving a
	# signature, the excused report alone must never earn a retry (#1503).
	local entry file step
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	for entry in \
		$'readonly-docker.yml\tAssert the build passed and both SARIF artifacts exist' \
		$'docker-facade-validate.yml\tAssert the facade validated and uploaded both SARIF categories'; do
		IFS=$'\t' read -r file step <<<"$entry"
		jq -n --arg step "$step" '{jobs: [
			{id: 501, name: "validate / Docker build per platform (linux/amd64)", conclusion: "success",
				steps: [{name: "Wait for hardener Docker readiness", conclusion: "success"}]},
			{id: 502, name: "check", conclusion: "failure",
				steps: [{name: $step, conclusion: "failure"}]}]}' >"$MOCK_JOBS_JSON"
		jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/502.json"
		run call_fn retry_eligible "$file" failure https://example/runs/11
		assert_failure
	done
}

# The e2e-matrix fixture (run 43020328220): a shard dies on apt in Run
# Playwright, the reusable's always() merge job then fails on the missing
# shard report, and the fixture's check job fails on the reusable's result.
# ANN_APT is defined below; bats sets file-level variables before any test.
_e2e_matrix_apt_run() {
	signature_job 501 "Run Playwright" "$ANN_EXIT_1" "$ANN_APT"
	jq '.jobs[0].name = "e2e-matrix / E2E tests (smoke, chromium, 1)"
		| .jobs += [
			{id: 502, name: "e2e-matrix / Merge Reports", conclusion: "failure", steps: [
				{name: "Download shard reports", conclusion: "success"},
				{name: "Merge reports", conclusion: "failure"},
				{name: "Upload merged report", conclusion: "skipped"}]},
			{id: 503, name: "check", conclusion: "failure", steps: [
				{name: "Require the e2e-matrix job to succeed", conclusion: "failure"}]}]' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	jq -s . <<<"$1" >"$MOCK_ANNOTATIONS/502.json"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/503.json"
}

@test "external-canary: an e2e-matrix shard apt failure with its merge and check jobs is retried once" {
	# The merge warns per missing shard after a failed test job, so its only
	# failure annotation is the exit code.
	_e2e_matrix_apt_run "$ANN_EXIT_1 $ANN_WARNING"
	run call_fn retry_eligible e2e-matrix.yml failure https://example/runs/11
	assert_success
	assert_output infra:apt-mirror
	run grep -c 'check-runs/50[123]/annotations' "$MOCK_CALLS"
	assert_output 3
}

@test "external-canary: an e2e-matrix merge job with its own error is not retried" {
	local merge_error='{"path":".github","start_line":1,"end_line":1,"annotation_level":"failure","title":"Playwright merge","message":"shard playwright-smoke-chromium-1: expected 1 results file, found 0","raw_details":""}'
	_e2e_matrix_apt_run "$ANN_EXIT_1 $merge_error"
	run call_fn retry_eligible e2e-matrix.yml failure https://example/runs/11
	assert_failure
	# The same jobs in another workflow are not excused.
	_e2e_matrix_apt_run "$ANN_EXIT_1"
	run call_fn retry_eligible docker-publish.yml failure https://example/runs/11
	assert_failure
}

# #1432 follow-up: the apt helper's final network error is an infrastructure signature.
ANN_APT='{"path":".github","start_line":5,"end_line":5,"annotation_level":"failure","title":"","message":"apt could not reach a package mirror (DNS or network failure) after all retries","raw_details":""}'

@test "external-canary: the apt-mirror pattern matches the helper's exact message" {
	local msg pattern
	msg="$(grep -A2 '^NETWORK_ERROR_MESSAGE = (' "${PROJECT_ROOT}/scripts/ci/lib/apt_helper.py" |
		sed -n 's/^ *"\(.*\)"$/\1/p')"
	assert [ -n "$msg" ]
	pattern="$(_canary_signatures | awk -F'\t' '$1 == "apt-mirror" { print $3; exit }')"
	run bash -c '[[ "$1" =~ $2 ]]' _ "$msg" "$pattern"
	assert_success
	# Each lgtm-ci step listed runs the helper.
	local step
	while IFS=$'\t' read -r _ step _; do
		[[ "$step" == "run-playwright (direct)" ]] && continue
		run grep -rqF -- "- name: ${step}" "${PROJECT_ROOT}/.github/workflows"
		assert_success
	done < <(_canary_signatures | awk -F'\t' '$1 == "apt-mirror"')
}

@test "external-canary: an apt-mirror failure in each helper step is retried once" {
	local step
	for step in 'Install musl toolchain' 'Install Playwright browsers' 'Install kcov for coverage' \
		'run-playwright (direct)' 'Run Playwright'; do
		signature_job 501 "$step" "$ANN_EXIT_1" "$ANN_APT"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_success
		assert_output infra:apt-mirror
	done
}

@test "external-canary: the apt message in a step that does not run the helper is not retried" {
	signature_job 501 "Run tests" "$ANN_EXIT_1" "$ANN_APT"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

# #1563: both bounded Playwright download attempts timing out is a signature.
ANN_PW_TIMEOUT='{"path":".github","start_line":5,"end_line":5,"annotation_level":"failure","title":"","message":"Playwright browser install timed out twice (300s per attempt)","raw_details":""}'
ANN_PW_ERROR='{"path":".github","start_line":5,"end_line":5,"annotation_level":"failure","title":"","message":"Playwright browser install failed twice (timeout or error)","raw_details":""}'

@test "external-canary: the playwright-download pattern matches the library's message" {
	local pattern lib="${PROJECT_ROOT}/scripts/ci/lib/testing/playwright_runner.sh"
	local timed_out="Playwright browser install timed out twice"
	pattern="$(_canary_signatures | awk -F'\t' '$1 == "playwright-download" { print $3; exit }')"
	assert [ -n "$pattern" ]
	# shellcheck disable=SC2016 # the literal source line, not an expansion
	run grep -F "echo \"::error::${timed_out}"' (${seconds}s per attempt)"' "$lib"
	assert_success
	run bash -c '[[ "$1" =~ $2 ]]' _ "${timed_out} (300s per attempt)" "$pattern"
	assert_success
	run bash -c '[[ "$1" =~ $2 ]]' _ \
		"Playwright browser install failed twice (timeout or error)" "$pattern"
	assert_failure
	run grep -rqF -- "- name: Install Playwright browsers" "${PROJECT_ROOT}/.github/workflows"
	assert_success
}

@test "external-canary: a double Playwright download timeout is retried once" {
	signature_job 501 'Install Playwright browsers' "$ANN_EXIT_1" "$ANN_PW_TIMEOUT"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:playwright-download
}

@test "external-canary: a Playwright install error, or the timeout elsewhere, is not retried" {
	signature_job 501 'Install Playwright browsers' "$ANN_EXIT_1" "$ANN_PW_ERROR"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	signature_job 501 'Run Playwright' "$ANN_EXIT_1" "$ANN_PW_TIMEOUT"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

# --- never-started fixture runs (#1601) ------------------------------------

# Eval prelude for poll_runs with a fake clock: it starts at 1000 and every
# poll interval (sleep) adds 100s, so the queue deadline is 2500 and the
# 300s threshold is reached on the fourth poll. Each test defines
#   main_rows <clock>   rows of the main run list (since "since")
#   retry_rows <clock>  rows created after a second dispatch
# and seeds $MOCK_RUNS_DIR/started.<id> (first job start) and jobs.<id> (job
# count, default 0). Calls are recorded in dispatches, job-counts and api.
STUCK_STUBS='
	CANARY_STATE_DIR=""
	clock="$MOCK_RUNS_DIR/clock"; echo 1000 >"$clock"
	sleep() { echo $(($(cat "$clock") + 100)) >"$clock"; }
	date() { if [[ "$*" == +%s ]]; then cat "$clock"; else command date "$@"; fi; }
	dispatch_workflow() {
		printf "%s\n" "$1" >>"$MOCK_RUNS_DIR/dispatches"
		[[ "${STUCK_DISPATCH_FAIL_AT:-}" != "$(wc -l <"$MOCK_RUNS_DIR/dispatches" | tr -d " ")" ]] || {
			echo "gh: HTTP 502" >&2
			return 1
		}
	}
	first_job_start() { cat "$MOCK_RUNS_DIR/started.$1" 2>/dev/null || true; }
	run_job_count() { printf "%s\n" "$1" >>"$MOCK_RUNS_DIR/job-counts"; cat "$MOCK_RUNS_DIR/jobs.$1" 2>/dev/null || echo 0; }
	# Every write and read of the fixture lands here; cancel answers 409.
	fixture_api() {
		printf "%s\n" "$*" >>"$MOCK_RUNS_DIR/api"
		[[ "$*" != *"/cancel"* ]] || { echo "gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 409)" >&2; return 1; }
	}
	list_canary_runs() {
		if [[ "$2" == since ]]; then main_rows "$(cat "$clock")"; else retry_rows "$(cat "$clock")"; fi
	}
	retry_rows() { :; }
'

# Run poll_runs for the given files after the test's own definitions ($1),
# then print the results and render the summary.
_poll_stuck() {
	local defs="$1"
	shift
	run env CANARY_QUEUE_TIMEOUT_SECONDS=1500 CANARY_TIMEOUT_SECONDS=1500 \
		CANARY_REDISPATCH_AFTER_SECONDS="${STUCK_AFTER:-300}" CANARY_MAX_REDISPATCHES="${STUCK_CAP:-3}" \
		STUCK_DISPATCH_FAIL_AT="${STUCK_DISPATCH_FAIL_AT:-}" bash "$CANARY_EVAL" "${STUCK_STUBS}${defs}"'
		CANARY_DISPATCH=true poll_runs canary/test since '"$*"' >"$MOCK_RUNS_DIR/results"
		cat "$MOCK_RUNS_DIR/results"
		render_summary "$CANDIDATE" canary/test <"$MOCK_RUNS_DIR/results"
	'
}

_stuck_row() {
	printf '%s\t%s\t%s\thttps://example/runs/%s\tname\n' "$1" "$2" "${3:-}" "$4"
}

@test "external-canary: a run that never starts is dispatched again and the green second run decides" {
	_poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
		retry_rows() {
			if (($1 < 1600)); then printf "python.yml\tqueued\t\thttps://example/runs/21\tname\n"
			else printf "python.yml\tcompleted\tsuccess\thttps://example/runs/21\tname\n"; fi
		}
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tsuccess\thttps://example/runs/21\tname\t\t\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial 're-dispatching python.yml: run https://example/runs/11 is still queued with no jobs 300s after dispatch (extra dispatch 1 of 3); the new run decides'
	assert_output --partial 'fixture run 11 (python.yml) was not cancelled (gh: Cannot cancel a workflow run that has not been queued yet. (HTTP 409)); GitHub refuses that'
	assert_output --partial '| `success` | ✅ pass | [run](https://example/runs/21) · [first run, not started in time](https://example/runs/11) |'
	assert_output --partial '> `python.yml`: dispatched twice: the first run never started (queued with no job), so the second run decides; first run: https://example/runs/11'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
	# Jobs are counted once, for the stuck run only.
	run cat "$MOCK_RUNS_DIR/job-counts"
	assert_output 11
	run grep -c 'actions/runs/11/cancel' "$MOCK_RUNS_DIR/api"
	assert_output 1
}

@test "external-canary: a fixture whose second run never starts either stays inconclusive" {
	_poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
		retry_rows() { printf "python.yml\tqueued\t\thttps://example/runs/21\tname\n"; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/21\tname\t\t\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial '| `queued-timeout` | ⚠️ inconclusive | [run](https://example/runs/21) · [first run, not started in time](https://example/runs/11) |'
	# No third dispatch and no job count for the second run.
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
	run cat "$MOCK_RUNS_DIR/job-counts"
	assert_output 11
	ROWS="$(sed -n 1p "$MOCK_RUNS_DIR/results")" run bash "$CANARY_EVAL" 'inconclusive_gates <<<"$ROWS"'
	assert_output "$(printf 'python.yml\tqueued-timeout')"
}

@test "external-canary: a run that started and failed is a product failure and never dispatched again" {
	echo 1000 >"$MOCK_RUNS_DIR/started.11"
	_poll_stuck '
		main_rows() {
			if (($1 < 1500)); then printf "python.yml\tin_progress\t\thttps://example/runs/11\tname\n"
			else printf "python.yml\tcompleted\tfailure\thttps://example/runs/11\tname\n"; fi
		}
		retry_eligible() { return 1; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tfailure\thttps://example/runs/11\tname')"
	assert_output --partial '❌ **gate failed**'
	refute_output --partial 're-dispatching'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output python.yml
	assert_file_not_exists "$MOCK_RUNS_DIR/job-counts"
}

@test "external-canary: a queued run that has jobs waits for the queue budget without a second dispatch" {
	echo 2 >"$MOCK_RUNS_DIR/jobs.11"
	_poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/11\tname')"
	refute_output --partial 're-dispatching'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output python.yml
	# One job count in all: a run with jobs is never counted again.
	run cat "$MOCK_RUNS_DIR/job-counts"
	assert_output 11
}

@test "external-canary: a never-started run is not dispatched again before the threshold" {
	STUCK_AFTER=2000 _poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/11\tname')"
	assert_file_not_exists "$MOCK_RUNS_DIR/job-counts"
}

@test "external-canary: the per-canary cap stops further second dispatches" {
	_poll_stuck_cap() {
		STUCK_CAP="$1" _poll_stuck '
			main_rows() {
				printf "one.yml\tqueued\t\thttps://example/runs/11\tname\n"
				printf "two.yml\tqueued\t\thttps://example/runs/12\tname\n"
			}
			retry_rows() { printf "one.yml\tcompleted\tsuccess\thttps://example/runs/21\tname\n"; }
		' one.yml two.yml
	}
	_poll_stuck_cap 1
	assert_success
	assert_line "$(printf 'one.yml\tsuccess\thttps://example/runs/21\tname\t\t\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_line "$(printf 'two.yml\tqueued-timeout\thttps://example/runs/12\tname')"
	assert_output --partial 'not re-dispatching two.yml: run https://example/runs/12 never started, but this canary already used its 1 extra dispatch(es) (CANARY_MAX_REDISPATCHES)'
	run grep -c 'not re-dispatching' <<<"$output"
	assert_output 1
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'one.yml\ntwo.yml\none.yml')"
	# The refused run is counted once, not on every poll.
	run grep -c '^12$' "$MOCK_RUNS_DIR/job-counts"
	assert_output 1
	# A cap of zero turns the second dispatch off.
	rm -f "$MOCK_RUNS_DIR/dispatches" "$MOCK_RUNS_DIR/job-counts"
	_poll_stuck_cap 0
	assert_line "$(printf 'one.yml\tqueued-timeout\thttps://example/runs/11\tname')"
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'one.yml\ntwo.yml')"
	# With the feature off no job is counted at all.
	assert_file_not_exists "$MOCK_RUNS_DIR/job-counts"
}

@test "external-canary: a first run that starts late and fails anyway decides over a green second run" {
	_poll_stuck '
		main_rows() {
			if (($1 < 1500)); then printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"
			elif (($1 < 1700)); then printf "python.yml\tin_progress\t\thttps://example/runs/11\tname\n"
			else printf "python.yml\tcompleted\tfailure\thttps://example/runs/11\tname\n"; fi
		}
		retry_rows() {
			if (($1 < 1800)); then printf "python.yml\tin_progress\t\thttps://example/runs/21\tname\n"
			else printf "python.yml\tcompleted\tsuccess\thttps://example/runs/21\tname\n"; fi
		}
		first_job_start() { [[ "$1" != 21 ]] || echo 1400; }
	' python.yml
	assert_success
	# A failure of either run counts: the first run's failure takes the row.
	assert_line "$(printf 'python.yml\tfailure\thttps://example/runs/11\tname\t\t\tnever-started\tlate-first\thttps://example/runs/21')"
	assert_output --partial 'first run https://example/runs/11 of python.yml started late (in_progress); cancelling it'
	assert_output --partial "first run https://example/runs/11 of python.yml started late and concluded 'failure'"
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://example/runs/11) · [second run](https://example/runs/21) |'
	assert_output --partial 'then started late and concluded `failure`. A failure of either run counts, so the first run decides; second run: https://example/runs/21'
	# Once when it was abandoned, once when it started (never on later polls).
	run grep -c 'actions/runs/11/cancel' "$MOCK_RUNS_DIR/api"
	assert_output 2
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
	ROWS="$(sed -n 1p "$MOCK_RUNS_DIR/results")" run bash "$CANARY_EVAL" 'failed_gates <<<"$ROWS"'
	assert_output "$(printf 'python.yml\tfailure')"
}

# Late first run concluding $1 while the second run concludes $2.
_poll_late_first() {
	_poll_stuck '
		main_rows() {
			if (($1 < 1500)); then printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"
			elif (($1 < 1600)); then printf "python.yml\tin_progress\t\thttps://example/runs/11\tname\n"
			else printf "python.yml\tcompleted\t'"$1"'\thttps://example/runs/11\tname\n"; fi
		}
		retry_rows() {
			if (($1 < 1800)); then printf "python.yml\tin_progress\t\thttps://example/runs/21\tname\n"
			else printf "python.yml\tcompleted\t'"$2"'\thttps://example/runs/21\tname\n"; fi
		}
		first_job_start() { [[ "$1" != 21 ]] || echo 1400; }
	' python.yml
}

@test "external-canary: a late first run that fails on infrastructure is inconclusive, not a gate failure" {
	_poll_stuck '
		main_rows() {
			if (($1 < 1500)); then printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"
			else printf "python.yml\tcompleted\tfailure\thttps://example/runs/11\tname\n"; fi
		}
		retry_rows() {
			if (($1 < 1800)); then printf "python.yml\tin_progress\t\thttps://example/runs/21\tname\n"
			else printf "python.yml\tcompleted\tsuccess\thttps://example/runs/21\tname\n"; fi
		}
		first_job_start() { [[ "$1" != 21 ]] || echo 1400; }
		# Only the late first run carries infrastructure proof.
		retry_eligible() { [[ "$3" == https://example/runs/11 ]] && echo infra; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tfailure\thttps://example/runs/11\tname\t\tinfra\tnever-started\tlate-first\thttps://example/runs/21')"
	assert_output --partial '| `failure` | ⚠️ inconclusive | [run](https://example/runs/11) · [second run](https://example/runs/21) |'
	assert_output --partial 'the late first run failed on fixture infrastructure (infra), not on the candidate.'
	# Classified, never dispatched a third time.
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
	ROWS="$(sed -n 1p "$MOCK_RUNS_DIR/results")" run bash "$CANARY_EVAL" 'inconclusive_gates <<<"$ROWS"'
	assert_output "$(printf 'python.yml\tfailure')"
}

@test "external-canary: a late first run that is cancelled or passes leaves the second run deciding" {
	_poll_late_first cancelled success
	assert_success
	assert_line "$(printf 'python.yml\tsuccess\thttps://example/runs/21\tname\t\t\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial '| `success` | ✅ pass | [run](https://example/runs/21) · [first run, not started in time](https://example/runs/11) |'
	_poll_late_first success failure
	assert_line "$(printf 'python.yml\tfailure\thttps://example/runs/21\tname\t\t\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial '❌ **gate failed**'
}

@test "external-canary: a second run cancelled after the first started late is inconclusive, not a gate failure" {
	_poll_late_first cancelled cancelled
	assert_success
	assert_line "$(printf 'python.yml\tcancelled\thttps://example/runs/21\tname\t\tfirst-run-started-late\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial '| `cancelled` | ⚠️ inconclusive |'
	assert_output --partial 'the first run started late and the second run was cancelled'
	ROWS="$(sed -n 1p "$MOCK_RUNS_DIR/results")" run bash "$CANARY_EVAL" 'inconclusive_gates <<<"$ROWS"'
	assert_output "$(printf 'python.yml\tcancelled')"
}

@test "external-canary: a never-started run whose second run fails on infrastructure is not dispatched a third time" {
	_poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
		retry_rows() { printf "python.yml\tcompleted\tstartup_failure\thttps://example/runs/21\tname\n"; }
		retry_eligible() { echo startup_failure; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tstartup_failure\thttps://example/runs/21\tname\t\tstartup_failure\tnever-started\tdispatched\thttps://example/runs/11')"
	assert_output --partial '⚠️ inconclusive'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
}

@test "external-canary: an infrastructure retry whose run never starts is not dispatched a third time" {
	_poll_stuck '
		main_rows() { printf "python.yml\tcompleted\tstartup_failure\thttps://example/runs/11\tname\n"; }
		retry_rows() { printf "python.yml\tqueued\t\thttps://example/runs/21\tname\n"; }
		retry_eligible() { [[ "$2" != startup_failure ]] || echo startup_failure; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/21\tname\t\t\tstartup_failure\tdispatched\thttps://example/runs/11')"
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
	# The retry's run is never counted: one fixture, two dispatches at most.
	assert_file_not_exists "$MOCK_RUNS_DIR/job-counts"
}

@test "external-canary: a failed second dispatch keeps the never-started run inconclusive" {
	STUCK_DISPATCH_FAIL_AT=2 _poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/11\tname\tgh: HTTP 502 \tnever-started\tnever-started\tfailed\thttps://example/runs/11')"
	assert_output --partial '| `queued-timeout` | ⚠️ inconclusive | [run](https://example/runs/11) |'
	assert_output --partial '> `python.yml`: its first run never started and dispatching it again failed; first run: https://example/runs/11'
	# The dispatch write is never replayed.
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output "$(printf 'python.yml\npython.yml')"
}

@test "external-canary: the queue budget can end before a never-started run is dispatched again" {
	# Detected at 2400, one poll before the 2500 deadline: no admission is left.
	STUCK_AFTER=1400 _poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/11\tname\t\tnever-started')"
	assert_output --partial 're-dispatching python.yml'
	assert_output --partial '| `queued-timeout` | ⚠️ inconclusive | [run](https://example/runs/11) |'
	assert_output --partial 'its first run never started, and the queue budget ran out before it could be dispatched again.'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output python.yml
}

@test "external-canary: manual release callers are never dispatched again" {
	_poll_stuck '
		main_rows() { printf "release-version-pr.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
	' release-version-pr.yml
	assert_success
	assert_line "$(printf 'release-version-pr.yml\tqueued-timeout\thttps://example/runs/11\tname')"
	assert_file_not_exists "$MOCK_RUNS_DIR/job-counts"
}

@test "external-canary: job count reads total_count and rejects a malformed answer" {
	run env MOCK_JOBS_TOTAL=0 bash "$CANARY_EVAL" 'run_job_count 11'
	assert_success
	assert_output 0
	run grep -F 'repos/owner/fixture/actions/runs/11/jobs?per_page=1 --jq .total_count' "$MOCK_CALLS"
	assert_success
	run env MOCK_JOBS_TOTAL=null bash "$CANARY_EVAL" 'run_job_count 11'
	assert_failure
	run env MOCK_JOBS_FAIL=1 bash "$CANARY_EVAL" 'run_job_count 11'
	assert_failure
}

@test "external-canary: a failed job count never triggers a second dispatch" {
	_poll_stuck '
		main_rows() { printf "python.yml\tqueued\t\thttps://example/runs/11\tname\n"; }
		run_job_count() { return 1; }
	' python.yml
	assert_success
	assert_line "$(printf 'python.yml\tqueued-timeout\thttps://example/runs/11\tname')"
	assert_output --partial 'cannot count the jobs of fixture run https://example/runs/11 (python.yml)'
	run cat "$MOCK_RUNS_DIR/dispatches"
	assert_output python.yml
}

@test "external-canary: rejects a zero re-dispatch threshold and a malformed cap before creating a ref" {
	run env CANARY_REDISPATCH_AFTER_SECONDS=0 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'CANARY_REDISPATCH_AFTER_SECONDS must be a positive integer'
	local bad
	for bad in -1 08 010 9999999; do
		run env CANARY_MAX_REDISPATCHES="$bad" bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial 'CANARY_MAX_REDISPATCHES must be a non-negative integer'
	done
	run env CANARY_REDISPATCH_AFTER_SECONDS=0300 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial 'CANARY_REDISPATCH_AFTER_SECONDS must be a positive integer'
	run grep -F 'git/refs' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: never-started prune age defaults to 24 hours and rejects a malformed or lower value before creating a ref" {
	run env -u CANARY_NEVER_STARTED_PRUNE_HOURS bash "$CANARY_EVAL" 'printf "%s\n" "$CANARY_NEVER_STARTED_PRUNE_HOURS"'
	assert_success
	assert_output 24
	local bad
	for bad in 0 1 23 024 -1 1.5 100000; do
		run env CANARY_NEVER_STARTED_PRUNE_HOURS="$bad" bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial 'CANARY_NEVER_STARTED_PRUNE_HOURS must be an integer from 24 to 99999'
	done
	run grep -F 'git/refs' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: sweep cap defaults to 20 and rejects a malformed value before creating a ref" {
	run env -u CANARY_SWEEP_MAX_REFS bash "$CANARY_EVAL" 'printf "%s\n" "$CANARY_SWEEP_MAX_REFS"'
	assert_success
	assert_output 20
	local bad
	for bad in 01 -1 1000 x 1.5 ' 5'; do
		run env CANARY_SWEEP_MAX_REFS="$bad" bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial 'CANARY_SWEEP_MAX_REFS must be an integer from 0 to 999 without leading zeros'
	done
	run grep -F 'git/refs' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: sweep budget, call timeout and job limit default and reject malformed values before creating a ref" {
	run env -u CANARY_SWEEP_BUDGET_SECONDS -u CANARY_SWEEP_CALL_TIMEOUT_SECONDS -u CANARY_JOB_TIMEOUT_MINUTES bash "$CANARY_EVAL" \
		'printf "%s %s %s\n" "$CANARY_SWEEP_BUDGET_SECONDS" "$CANARY_SWEEP_CALL_TIMEOUT_SECONDS" "$CANARY_JOB_TIMEOUT_MINUTES"'
	assert_success
	assert_output '120 30 55'
	local setting bad
	for setting in CANARY_SWEEP_BUDGET_SECONDS CANARY_SWEEP_CALL_TIMEOUT_SECONDS; do
		for bad in 0 01 -1 1000 x 1.5; do
			run env "${setting}=${bad}" bash "$SCRIPT" "$CANDIDATE"
			assert_failure
			assert_output --partial "${setting} must be an integer from 1 to 999 without leading zeros"
		done
	done
	for bad in 0 055 10000 x; do
		run env CANARY_JOB_TIMEOUT_MINUTES="$bad" bash "$SCRIPT" "$CANDIDATE"
		assert_failure
		assert_output --partial 'CANARY_JOB_TIMEOUT_MINUTES must be an integer from 1 to 9999 without leading zeros'
	done
	run grep -F 'git/refs' "$MOCK_CALLS"
	refute_output
}

@test "external-canary: an infrastructure retry links both runs in the table" {
	run call_fn "printf 'python.yml\tsuccess\thttps://example/runs/21\tname\t\t\tstartup_failure\tdispatched\thttps://example/runs/11\n' | render_summary '$CANDIDATE'"
	assert_output --partial '| [run](https://example/runs/21) · [first run](https://example/runs/11) |'
	assert_output --partial 'retried once (startup_failure); first run: https://example/runs/11'
}

# --- harden-runner agent did not start (#1616) -----------------------------

ANN_AGENT_STARTUP='{"path":".github","start_line":4,"end_line":4,"annotation_level":"failure","title":"harden-runner agent failed","message":"agent.service is not active; egress is not enforced","raw_details":""}'
ANN_AGENT_STATUS='{"path":".github","start_line":4,"end_line":4,"annotation_level":"failure","title":"harden-runner agent failed","message":"agent.status is not Initialized after 60s","raw_details":""}'
ANN_AGENT_RECHECK='{"path":".github","start_line":15,"end_line":15,"annotation_level":"failure","title":"harden-runner agent stopped","message":"harden-runner agent stopped enforcing mid-job; steps after it ran unhardened (resolved.conf no longer uses the agent'"'"'s DNS proxy: revert in progress or DNS changed by a step)","raw_details":""}'
ANN_EXIT_2='{"path":".github","start_line":13,"end_line":13,"annotation_level":"failure","title":"","message":"Process completed with exit code 2.","raw_details":""}'
ANN_EXIT_127='{"path":".github","start_line":21,"end_line":21,"annotation_level":"failure","title":"","message":"Process completed with exit code 127.","raw_details":""}'

# Fixture job 135649511127 (run 44549619441, actionlint): the verify step
# failed right after harden-runner, and a continue-on-error step that ran
# afterwards left its own exit line. Remaining arguments are its annotations.
agent_startup_job() {
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	jq -n '{jobs: [{id: 701, name: "actionlint / Actionlint", conclusion: "failure", steps: [
		{number: 1, name: "Set up job", conclusion: "success"},
		{number: 2, name: "Pre Harden runner", conclusion: "success"},
		{number: 3, name: "Harden runner", conclusion: "success"},
		{number: 4, name: "Verify harden-runner agent", conclusion: "failure"},
		{number: 5, name: "Checkout repository", conclusion: "skipped"},
		{number: 13, name: "Classify lint timeout", conclusion: "success"},
		{number: 14, name: "Upload linting report", conclusion: "success"},
		{number: 18, name: "Recheck harden-runner agent", conclusion: "skipped"},
		{number: 36, name: "Post Harden runner", conclusion: "success"},
		{number: 37, name: "Complete job", conclusion: "success"}]}]}' >"$MOCK_JOBS_JSON"
	jq -s . <<<"$*" >"$MOCK_ANNOTATIONS/701.json"
}

@test "external-canary: a harden-runner agent that did not start makes a failed gate eligible" {
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# Annotations only: the canary never reads job logs.
	run grep -c '/logs' "$MOCK_CALLS"
	assert_output 0
}

@test "external-canary: an agent start-up failure triggers exactly one retry that can pass" {
	retry_snapshots failure success
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: an agent start-up failure with a failed always() step and the downstream check is retried" {
	# Fixture run 44546927992 (docker-orchestrator.yml): job 135640146414's
	# Summarize blocked egress exited 127 after the verify step failed, and
	# the check job reported the reusable's failure.
	agent_startup_job "$ANN_EXIT_127" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	jq '.jobs[0].steps |= map(if .name == "Classify lint timeout" then .name = "Summarize blocked egress" | .conclusion = "failure"
		elif .name == "Upload linting report" then .conclusion = "skipped" else . end)
		| .jobs += [{id: 702, name: "check", conclusion: "failure", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 2, name: "Assert the split path ran through the facade", conclusion: "failure"}]}]' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/702.json"
	run call_fn retry_eligible docker-orchestrator.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
}

@test "external-canary: an aggregate job whose matrix gate failed after the agent did is retried" {
	# Fixture run 43995921467 (Aggregate Node.js Results): no matrix leg
	# failed; the always() gate fails because nothing was aggregated.
	local gate='{"path":".github","start_line":14,"end_line":14,"annotation_level":"failure","title":"","message":"A matrix test leg failed or its results could not be aggregated; failing the check.","raw_details":""}'
	agent_startup_job "$ANN_EXIT_1" "$gate" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	jq '.jobs[0].steps |= map(if .name == "Classify lint timeout" then .name = "Fail if any matrix leg failed" | .conclusion = "failure"
		elif .name == "Upload linting report" then .conclusion = "skipped" else . end)' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# A failed matrix leg is its own failed job and blocks the retry.
	jq '.jobs += [{id: 704, name: "test (3.12)", conclusion: "failure", steps: [
		{number: 1, name: "Set up job", conclusion: "success"},
		{number: 6, name: "Run tests", conclusion: "failure"}]}]' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/704.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a different agent failure in the verify step is not retried" {
	retry_snapshots failure success
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_STATUS"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/11)'
	refute_output --partial 'retried once'
}

@test "external-canary: the start-up message next to a product annotation is not retried" {
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_STARTUP" "$ANN_TEST"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# More exit lines than steps that ran after the verify step.
	agent_startup_job "$ANN_EXIT_1" "$ANN_EXIT_1" "$ANN_EXIT_1" "$ANN_EXIT_2" "$ANN_AGENT_STARTUP"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a verify failure after a job step ran is not retried" {
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	jq '.jobs[0].steps |= map(if .name == "Checkout repository" then .number = 3 | .conclusion = "success"
		elif .name == "Harden runner" then .number = 2 elif .name == "Pre Harden runner" then .number = 0 else . end)' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a mid-job recheck failure stays a gate failure" {
	# Fixture run 44565576621 (harden-runner's TLS-status fallback, which the
	# verify step now refuses at job start, #1668): the same annotation is what
	# a step that changed DNS or enforcement produces, so it is never retried.
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	jq -n '{jobs: [{id: 703, name: "python-compat / Aggregate Python Results", conclusion: "failure", steps: [
		{number: 1, name: "Set up job", conclusion: "success"},
		{number: 3, name: "Harden runner", conclusion: "success"},
		{number: 4, name: "Verify harden-runner agent", conclusion: "success"},
		{number: 13, name: "Aggregate matrix results", conclusion: "success"},
		{number: 15, name: "Recheck harden-runner agent", conclusion: "failure"}]}]}' >"$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1 $ANN_AGENT_RECHECK" >"$MOCK_ANNOTATIONS/703.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

# --- a start-up failure in both runs is a gate failure (#1616 review) -------

REPEAT_TEXT='harden-runner agent start-up failed in both runs; a candidate change (for example an allowed host that does not resolve) is the likely cause'

@test "external-canary: the first agent start-up failure is infrastructure and is retried" {
	retry_snapshots failure success
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11'
	refute_output --partial "$REPEAT_TEXT"
}

@test "external-canary: an agent start-up failure in the retried run too is a gate failure" {
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial "> \`python.yml\`: ${REPEAT_TEXT}. Retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11"
	assert_output --partial "::error title=external canary::gate python.yml concluded 'failure': ${REPEAT_TEXT}"
	refute_output --partial '⚠️ inconclusive'
	refute_output --partial 'result is inconclusive'
	# One retry only: no third dispatch.
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: the same annotation from a permanent cause is a gate failure, not infrastructure" {
	# An allowed host that does not resolve (NXDOMAIN, status 3) makes the
	# agent exit with exactly the shape and annotation of a transient DNS
	# answer; the canary reads no log, so only the repeat tells them apart.
	# A permanent cause repeats on the retry and must fail the gate.
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	jq '.jobs[0].steps |= map(if .name == "Classify lint timeout" or .name == "Upload linting report" then .conclusion = "skipped" else . end)' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "${REPEAT_TEXT}"
	assert_output --partial '❌ **gate failed**'
	refute_output --partial 'result is inconclusive'
	# The owner override label still applies to a gate failure, as for any other.
}

@test "external-canary: a start-up failure followed by another infrastructure cause stays inconclusive" {
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	# The retried run (21) fails on Docker readiness instead.
	export MOCK_JOBS_DIR="$BATS_TEST_TMPDIR/jobs-by-run"
	mkdir -p "$MOCK_JOBS_DIR"
	jq -n '{jobs: [{id: 501, conclusion: "failure", steps: [
		{name: "Set up job", conclusion: "success"},
		{name: "Harden runner", conclusion: "success"},
		{name: "Wait for hardener Docker readiness", conclusion: "failure"},
		{name: "Upload results", conclusion: "skipped"}]}]}' >"$MOCK_JOBS_DIR/21.json"
	jq -s . <<<"$ANN_EXIT_1 $ANN_DOCKER" >"$MOCK_ANNOTATIONS/501.json"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ⚠️ inconclusive |'
	refute_output --partial "$REPEAT_TEXT"
}

@test "external-canary: agent_startup_repeated needs the start-up label in both reasons" {
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-startup infra:harden-runner-agent-startup'
	assert_success
	run call_fn 'agent_startup_repeated infra:docker-readiness,harden-runner-agent-startup infra:harden-runner-agent-startup,apt-mirror'
	assert_success
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-startup infra:docker-readiness'
	assert_failure
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-startup ""'
	assert_failure
	run call_fn 'agent_startup_repeated startup_failure infra:harden-runner-agent-startup'
	assert_failure
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-startup-x infra:harden-runner-agent-startup'
	assert_failure
}

# --- harden-runner's eBPF fallback agent refused at job start (#1668) -------

ANN_AGENT_EBPF='{"path":".github","start_line":4,"end_line":4,"annotation_level":"failure","title":"harden-runner agent refused","message":"harden-runner installed its eBPF fallback agent; only the standard agent is trusted","raw_details":""}'
EBPF_REPEAT_TEXT='harden-runner agent failed at job start in both runs, the second time because harden-runner installed its eBPF fallback agent, which is never trusted; its TLS-status check keeps failing, or TLS inspection is enabled for the owner'
MIXED_TAIL='; a candidate change (for example an allowed host that does not resolve) can stop the agent, and a failing TLS-status check or TLS inspection for the owner brings the eBPF fallback agent'
MIXED_REPEAT_TEXT="harden-runner agent failed at job start in both runs, with different causes: the first run with harden-runner-agent-startup (the agent did not start), the retried run with harden-runner-agent-ebpf (harden-runner installed its eBPF fallback agent)${MIXED_TAIL}"
MIXED_REVERSED_TEXT="harden-runner agent failed at job start in both runs, with different causes: the first run with harden-runner-agent-ebpf (harden-runner installed its eBPF fallback agent), the retried run with harden-runner-agent-startup (the agent did not start)${MIXED_TAIL}"

@test "external-canary: a refused eBPF fallback agent makes a failed gate eligible (#1668)" {
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_EBPF"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-ebpf
	run grep -c '/logs' "$MOCK_CALLS"
	assert_output 0
}

@test "external-canary: the eBPF refusal next to another own annotation is not retried" {
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_EBPF" "$ANN_AGENT_STARTUP"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_EBPF" "$ANN_TEST"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: the eBPF refusal after a job step ran is not retried" {
	agent_startup_job "$ANN_EXIT_1" "$ANN_AGENT_EBPF"
	jq '.jobs[0].steps |= map(if .name == "Checkout repository" then .number = 3 | .conclusion = "success"
		elif .name == "Harden runner" then .number = 2 elif .name == "Pre Harden runner" then .number = 0 else . end)' \
		"$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: the first eBPF refusal is infrastructure and is retried" {
	retry_snapshots failure success
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_EBPF"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'retried once (infra:harden-runner-agent-ebpf); first run: https://github.com/owner/fixture/actions/runs/11'
	refute_output --partial "$EBPF_REPEAT_TEXT"
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: an eBPF refusal in the retried run too is a gate failure" {
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_EBPF"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial '| `failure` | ❌ **gate failed** | [run](https://github.com/owner/fixture/actions/runs/21)'
	assert_output --partial "> \`python.yml\`: ${EBPF_REPEAT_TEXT}. Retried once (infra:harden-runner-agent-ebpf); first run: https://github.com/owner/fixture/actions/runs/11"
	assert_output --partial "::error title=external canary::gate python.yml concluded 'failure': ${EBPF_REPEAT_TEXT}"
	refute_output --partial "$REPEAT_TEXT"
	refute_output --partial 'result is inconclusive'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: a start-up failure then an eBPF refusal is a gate failure too" {
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_STARTUP"
	# The retried run (21) refuses the eBPF agent instead.
	export MOCK_JOBS_DIR="$BATS_TEST_TMPDIR/jobs-by-run"
	mkdir -p "$MOCK_JOBS_DIR"
	jq '.jobs[0].id = 705' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_DIR/21.json"
	jq -s . <<<"$ANN_EXIT_2 $ANN_EXIT_1 $ANN_AGENT_EBPF" >"$MOCK_ANNOTATIONS/705.json"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	# Different causes in the two runs: the text names both (#1672 review).
	assert_output --partial "> \`python.yml\`: ${MIXED_REPEAT_TEXT}. Retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11"
	assert_output --partial "::error title=external canary::gate python.yml concluded 'failure': ${MIXED_REPEAT_TEXT}"
	refute_output --partial "$EBPF_REPEAT_TEXT"
	refute_output --partial "$REPEAT_TEXT"
	refute_output --partial 'result is inconclusive'
}

@test "external-canary: an eBPF refusal then a start-up failure names both causes in order" {
	retry_snapshots failure failure
	agent_startup_job "$ANN_EXIT_2" "$ANN_EXIT_1" "$ANN_AGENT_EBPF"
	export MOCK_JOBS_DIR="$BATS_TEST_TMPDIR/jobs-by-run"
	mkdir -p "$MOCK_JOBS_DIR"
	jq '.jobs[0].id = 706' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_DIR/21.json"
	jq -s . <<<"$ANN_EXIT_2 $ANN_EXIT_1 $ANN_AGENT_STARTUP" >"$MOCK_ANNOTATIONS/706.json"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "> \`python.yml\`: ${MIXED_REVERSED_TEXT}. Retried once (infra:harden-runner-agent-ebpf); first run: https://github.com/owner/fixture/actions/runs/11"
	refute_output --partial 'result is inconclusive'
}

@test "external-canary: agent_startup_repeated takes either agent label, and names the repeat after the retry" {
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-ebpf infra:harden-runner-agent-ebpf'
	assert_success
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-startup infra:harden-runner-agent-ebpf'
	assert_success
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-ebpf infra:docker-readiness'
	assert_failure
	run call_fn 'agent_startup_repeated infra:harden-runner-agent-ebpf-x infra:harden-runner-agent-ebpf'
	assert_failure
	run call_fn 'agent_repeat_status infra:harden-runner-agent-ebpf infra:docker-readiness,harden-runner-agent-ebpf'
	assert_output agent-ebpf-repeat
	run call_fn 'agent_repeat_status infra:harden-runner-agent-startup infra:harden-runner-agent-startup,apt-mirror'
	assert_output agent-startup-repeat
	# Different label sets name both runs' labels, start-up label first.
	run call_fn 'agent_repeat_status infra:harden-runner-agent-startup infra:harden-runner-agent-ebpf'
	assert_output agent-mixed-repeat:harden-runner-agent-startup:harden-runner-agent-ebpf
	run call_fn 'agent_repeat_status infra:harden-runner-agent-ebpf,harden-runner-agent-startup infra:harden-runner-agent-ebpf'
	assert_output agent-mixed-repeat:harden-runner-agent-startup,harden-runner-agent-ebpf:harden-runner-agent-ebpf
}

@test "external-canary: agent_repeat_text describes each repeat status" {
	run call_fn 'agent_repeat_text agent-startup-repeat'
	assert_output "$REPEAT_TEXT"
	run call_fn 'agent_repeat_text agent-ebpf-repeat'
	assert_output "$EBPF_REPEAT_TEXT"
	run call_fn 'agent_repeat_text agent-mixed-repeat:harden-runner-agent-startup:harden-runner-agent-ebpf'
	assert_output "$MIXED_REPEAT_TEXT"
	run call_fn 'agent_repeat_text agent-mixed-repeat:harden-runner-agent-startup,harden-runner-agent-ebpf:harden-runner-agent-ebpf'
	assert_output --partial 'the first run with harden-runner-agent-startup (the agent did not start) and harden-runner-agent-ebpf (harden-runner installed its eBPF fallback agent), the retried run with harden-runner-agent-ebpf'
	run call_fn 'agent_repeat_text dispatched'
	assert_failure
}

# --- an aggregate job that failed only because its prepare job did (#1670) --

ANN_PREPARE_GATE='{"path":".github","start_line":15,"end_line":15,"annotation_level":"failure","title":"","message":"Matrix preparation concluded '"'"'failure'"'"'; failing the check.","raw_details":""}'
ANN_MATRIX_GATE='{"path":".github","start_line":16,"end_line":16,"annotation_level":"failure","title":"","message":"A matrix test leg failed or its results could not be aggregated; failing the check.","raw_details":""}'
PREPARE_GATE_REUSABLES="reusable-test-python reusable-rust-test reusable-rust-test-run reusable-test-node reusable-test-node-run reusable-test-node-custom"

# The candidate SHA the prepare-gate rule compares with its merge base
# (prepare_gate_unchanged). The compare mock's default answer is a candidate
# that changed one docs file; a test sets MOCK_COMPARE_JSON for another.
prepare_gate_reusables() {
	export CANARY_CANDIDATE_SHA="$CANDIDATE"
	unset MOCK_COMPARE_JSON
}

# Write a compare response whose changed files are the arguments (each
# "<filename>" or "<filename>:<previous_filename>") to $MOCK_COMPARE_JSON.
prepare_gate_compare() {
	export MOCK_COMPARE_JSON="$BATS_TEST_TMPDIR/compare.json"
	printf '%s\n' "$@" | jq -R -s --arg base "$MOCK_MERGE_BASE" '
		{merge_base_commit: {sha: $base}, total_commits: 2, files: [split("\n")[] | select(. != "")
			| split(":") | {filename: .[0], status: "modified"}
				+ (if length > 1 then {status: "renamed", previous_filename: .[1]} else {} end)]}' \
		>"$MOCK_COMPARE_JSON"
}

# Fixture run 43858549864 (siblings.yml): caller `b`'s prepare job (801)
# failed on the harden-runner agent, so its aggregate job (802) failed on the
# prepare gate and the always() matrix gate; caller `a` passed. Arguments:
# caller (default b) and the prepare and aggregate families (default Python
# and Python).
prepare_gate_run() {
	local prefix="${1:-b}" prep="${2:-Python}" agg="${3:-Python}"
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	prepare_gate_reusables
	jq -n --arg p "$prefix" --arg prep "$prep" --arg agg "$agg" '{jobs: [
		{id: 800, name: "a / Prepare Python Matrix", conclusion: "success", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 11, name: "Generate Python matrix", conclusion: "success"}]},
		{id: 801, name: "\($p) / Prepare \($prep) Matrix", conclusion: "failure", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 2, name: "Pre Harden runner", conclusion: "success"},
			{number: 3, name: "Harden runner", conclusion: "success"},
			{number: 4, name: "Verify harden-runner agent", conclusion: "failure"},
			{number: 5, name: "Fail on unknown egress-preset", conclusion: "skipped"},
			{number: 6, name: "Checkout repository", conclusion: "skipped"},
			{number: 11, name: "Generate Python matrix", conclusion: "skipped"},
			{number: 12, name: "Recheck harden-runner agent", conclusion: "skipped"},
			{number: 24, name: "Post Harden runner", conclusion: "success"},
			{number: 25, name: "Complete job", conclusion: "success"}]},
		{id: 802, name: "\($p) / Aggregate \($agg) Results", conclusion: "failure", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 2, name: "Pre Harden runner", conclusion: "success"},
			{number: 3, name: "Harden runner", conclusion: "success"},
			{number: 4, name: "Verify harden-runner agent", conclusion: "success"},
			{number: 5, name: "Fail on unknown egress-preset", conclusion: "skipped"},
			{number: 6, name: "Fail if matrix preparation did not succeed", conclusion: "failure"},
			{number: 7, name: "Checkout repository", conclusion: "skipped"},
			{number: 8, name: "Checkout lgtm-ci tooling", conclusion: "skipped"},
			{number: 9, name: "Checkout and harden", conclusion: "skipped"},
			{number: 10, name: "Wait for and download matrix results", conclusion: "skipped"},
			{number: 11, name: "Aggregate matrix results", conclusion: "skipped"},
			{number: 12, name: "Fail if any matrix leg failed", conclusion: "failure"},
			{number: 13, name: "Recheck harden-runner agent", conclusion: "success"},
			{number: 26, name: "Post Harden runner", conclusion: "success"},
			{number: 27, name: "Complete job", conclusion: "success"}]},
		{id: 803, name: "\($p) / inputs.job-name", conclusion: "skipped", steps: []},
		{id: 804, name: "\($p) / publish-test-summary", conclusion: "skipped", steps: []}]}' >"$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1 $ANN_AGENT_STARTUP" >"$MOCK_ANNOTATIONS/801.json"
	jq -s . <<<"$ANN_EXIT_1 $ANN_MATRIX_GATE $ANN_EXIT_1 $ANN_PREPARE_GATE" >"$MOCK_ANNOTATIONS/802.json"
}

# Apply jq filter $1 to the mocked jobs JSON.
edit_jobs() {
	jq "$1" "$MOCK_JOBS_JSON" >"$MOCK_JOBS_JSON.tmp"
	mv "$MOCK_JOBS_JSON.tmp" "$MOCK_JOBS_JSON"
}

@test "external-canary: siblings: an aggregate that failed only on its failed prepare job is excused with the prepare job's label" {
	prepare_gate_run
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# Both jobs' annotations, and never a job log.
	run grep -c '/check-runs/80[12]/annotations' "$MOCK_CALLS"
	assert_output 2
	run grep -c '/logs' "$MOCK_CALLS"
	assert_output 0
	# One compare call for the candidate's changed files, and no contents read.
	run grep -cxF "api -X GET repos/lgtm-hq/lgtm-ci/compare/main...${CANDIDATE}" "$MOCK_CALLS"
	assert_output 1
	run grep -c '/contents/' "$MOCK_CALLS"
	assert_output 0
}

@test "external-canary: siblings: the same shape under caller a is excused" {
	# Fixture run 43886292079: caller a failed, caller b passed.
	prepare_gate_run a
	edit_jobs '.jobs[0].name = "b / Prepare Python Matrix"'
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
}

@test "external-canary: verify-fresh-install and the Node family: an aggregate after a failed prepare job is excused" {
	# Fixture run 43924199865 (reusable-rust-test.yml).
	prepare_gate_run rust-fresh-install Rust Rust
	run call_fn retry_eligible verify-fresh-install.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# Aggregate Node.js Results pairs with Prepare Node Matrix.
	prepare_gate_run node Node Node.js
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# Exact family names only: Node.js does not pair with itself.
	prepare_gate_run node Node.js Node.js
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: readonly-node: a failed check after an aggregate agent failure stays a product failure" {
	# Fixture run 43983818529: the aggregate job's own agent did not start,
	# and the fixture's check job failed with only GitHub's exit-code line.
	# Its one step asserts the reusable's result and the product outputs, so
	# that exit does not show which assertion failed.
	export MOCK_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json" MOCK_ANNOTATIONS="$BATS_TEST_TMPDIR/annotations"
	mkdir -p "$MOCK_ANNOTATIONS"
	jq -n '{jobs: [
		{id: 811, name: "node / Prepare Node Matrix", conclusion: "success", steps: []},
		{id: 812, name: "node / Node Tests (read-only)", conclusion: "success", steps: []},
		{id: 813, name: "node / Aggregate Node.js Results", conclusion: "failure", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 2, name: "Pre Harden runner", conclusion: "success"},
			{number: 3, name: "Harden runner", conclusion: "success"},
			{number: 4, name: "Verify harden-runner agent", conclusion: "failure"},
			{number: 5, name: "Fail on unknown egress-preset", conclusion: "skipped"},
			{number: 6, name: "Fail if matrix preparation did not succeed", conclusion: "skipped"},
			{number: 11, name: "Aggregate matrix results", conclusion: "skipped"},
			{number: 12, name: "Fail if any matrix leg failed", conclusion: "failure"},
			{number: 13, name: "Recheck harden-runner agent", conclusion: "skipped"},
			{number: 26, name: "Post Harden runner", conclusion: "success"},
			{number: 27, name: "Complete job", conclusion: "success"}]},
		{id: 814, name: "node / Pages coverage upload status", conclusion: "skipped", steps: []},
		{id: 815, name: "check", conclusion: "failure", steps: [
			{number: 1, name: "Set up job", conclusion: "success"},
			{number: 2, name: "Assert the read-only variant ran the tests", conclusion: "failure"},
			{number: 3, name: "Complete job", conclusion: "success"}]}]}' >"$MOCK_JOBS_JSON"
	jq -s . <<<"$ANN_EXIT_1 $ANN_MATRIX_GATE $ANN_EXIT_1 $ANN_AGENT_STARTUP" >"$MOCK_ANNOTATIONS/813.json"
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/815.json"
	run call_fn retry_eligible readonly-node.yml failure https://example/runs/11
	assert_failure
	# The aggregate job alone is still the existing agent rule.
	edit_jobs '.jobs |= map(select(.id != 815))'
	run call_fn retry_eligible readonly-node.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
}

@test "external-canary: an excused aggregate gets one retry that can pass" {
	prepare_gate_run
	retry_snapshots failure success
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial 'retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11'
	run grep -c '/actions/workflows/python.yml/dispatches' "$MOCK_CALLS"
	assert_output 2
}

@test "external-canary: an excused aggregate in both runs is a gate failure under the repeat rule" {
	prepare_gate_run
	retry_snapshots failure failure
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "> \`python.yml\`: ${REPEAT_TEXT}. Retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11"
	refute_output --partial 'result is inconclusive'
}

@test "external-canary: an excused aggregate with start-up, then eBPF on the retry, is a gate failure" {
	prepare_gate_run
	retry_snapshots failure failure
	# The retried run (21): the same shape, the prepare job refused the eBPF agent.
	export MOCK_JOBS_DIR="$BATS_TEST_TMPDIR/jobs-by-run"
	mkdir -p "$MOCK_JOBS_DIR"
	jq '.jobs |= map(.id += 100)' "$MOCK_JOBS_JSON" >"$MOCK_JOBS_DIR/21.json"
	jq -s . <<<"$ANN_EXIT_1 $ANN_AGENT_EBPF" >"$MOCK_ANNOTATIONS/901.json"
	cp "$MOCK_ANNOTATIONS/802.json" "$MOCK_ANNOTATIONS/902.json"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "> \`python.yml\`: ${MIXED_REPEAT_TEXT}. Retried once (infra:harden-runner-agent-startup); first run: https://github.com/owner/fixture/actions/runs/11"
	refute_output --partial 'result is inconclusive'
}

@test "external-canary: a prepare job with a table signature does not excuse its aggregate" {
	# apt-mirror is a signature of its own, but not one of the two agent
	# causes, so its aggregate stays a product failure.
	prepare_gate_run
	edit_jobs '.jobs[1].steps |= map(if .name == "Verify harden-runner agent" then .conclusion = "success"
		elif .name == "Generate Python matrix" then .name = "Install musl toolchain" | .conclusion = "failure" else . end)'
	jq -s . <<<"$ANN_EXIT_1 $ANN_APT" >"$MOCK_ANNOTATIONS/801.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# The same prepare job alone is still classified by the table.
	edit_jobs '.jobs |= map(select(.id != 802))'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:apt-mirror
}

@test "external-canary: an aggregate that ran its own work and failed stays a product failure" {
	# The matrix gate failed after the job checked out and aggregated.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .number >= 7 and .number <= 11 then .conclusion = "success" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A product failure of the aggregate step itself.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .number == 11 then .conclusion = "failure" elif .number >= 7 and .number <= 10 then .conclusion = "success" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A failed recheck after the gate is never excused.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .name == "Recheck harden-runner agent" then .conclusion = "failure" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: an aggregate is excused only with the full ordered step sequence" {
	local filter
	for filter in \
		'map(select(.name != "Set up job"))' \
		'map(select(.name != "Pre Harden runner"))' \
		'map(select(.name != "Harden runner"))' \
		'map(select(.name != "Fail on unknown egress-preset"))' \
		'map(select(.name != "Recheck harden-runner agent"))' \
		'map(select(.name != "Post Harden runner"))' \
		'map(select(.name != "Complete job"))' \
		'map(select(.number != 6 and .number != 12)) + [{number: 6, name: "Fail if any matrix leg failed", conclusion: "failure"}, {number: 12, name: "Fail if matrix preparation did not succeed", conclusion: "failure"}]' \
		'. + [{number: 0, name: "Run tests", conclusion: "success"}]' \
		'. + [{number: 20, name: "Upload results", conclusion: "success"}]' \
		'map(if .number == 8 then .conclusion = null else . end)' \
		'map(if .number == 8 then .conclusion = "cancelled" else . end)' \
		'map(if .name == "Fail on unknown egress-preset" then .conclusion = "success" else . end)' \
		'map(if .name == "Post Harden runner" then .conclusion = "skipped" else . end)' \
		'map(if .number == 9 then del(.number) else . end)'; do
		prepare_gate_run
		edit_jobs ".jobs[2].steps |= (${filter})"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
}

@test "external-canary: a forged prepare gate message in a job that ran its own steps is not excused" {
	# Every annotation is exact, but a checkout ran before the gate step, or
	# a job step ran after it.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .name == "Fail on unknown egress-preset" then .name = "Checkout repository" | .conclusion = "success" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .name == "Checkout lgtm-ci tooling" then .conclusion = "success" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# The gate step failing with the matrix gate skipped is not the shape.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .name == "Fail if any matrix leg failed" then .conclusion = "skipped" else . end)'
	jq -s . <<<"$ANN_EXIT_1 $ANN_PREPARE_GATE" >"$MOCK_ANNOTATIONS/802.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Steps renumbered so the gate step runs after a checkout.
	prepare_gate_run
	edit_jobs '.jobs[2].steps |= map(if .name == "Fail if matrix preparation did not succeed" then .number = 8 elif .name == "Checkout lgtm-ci tooling" then .number = 6 | .conclusion = "success" else . end)'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# The name alone does not excuse a job: a Python Tests job with the same
	# steps and annotations is no aggregate.
	prepare_gate_run
	edit_jobs '.jobs[2].name = "b / Python Tests (b)"'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a candidate that changes a watched path gets no excuse" {
	local path
	# A workflow outside the six, a workflow-level env change in one of the six
	# (any change to the file), an action, a listed step script, the canary's
	# classifier and its signatures.
	for path in .github/workflows/reusable-docker.yml \
		.github/workflows/reusable-test-python.yml \
		.github/actions/run-pytest/action.yml \
		scripts/ci/bootstrap/verify-harden-runner-agent.sh \
		scripts/ci/bootstrap/recheck-harden-runner-agent.sh \
		scripts/ci/bootstrap/fail-unknown-egress-preset.sh \
		scripts/ci/canary/runs.sh \
		scripts/ci/canary/prepare-gate.sh \
		scripts/ci/actions/external-canary.sh \
		scripts/ci/lib/infra-signatures.sh \
		scripts/ci/lib/log.sh \
		scripts/ci/lib/github/output.sh \
		scripts/ci/lib/cosign.sh; do
		prepare_gate_run
		prepare_gate_compare docs/README.md "$path"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
}

@test "external-canary: a rename into or out of a watched path gets no excuse" {
	# Into a watched path, then out of one.
	prepare_gate_run
	prepare_gate_compare '.github/workflows/new.yml:docs/old.yml'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	prepare_gate_run
	prepare_gate_compare 'docs/new.yml:.github/actions/old/action.yml'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A rename between unwatched paths is excused.
	prepare_gate_run
	prepare_gate_compare 'docs/new.md:docs/old.md'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
}

@test "external-canary: a candidate that changes only unwatched files, or nothing, is excused" {
	# Docs, an unrelated script, tests, a library the canary does not source,
	# and names that only look like watched paths (matched as exact names or
	# prefixes, never as patterns).
	prepare_gate_run
	prepare_gate_compare docs/workflow-contract.md scripts/ci/maintenance/duplication_scan.py \
		tests/bats/unit/test_external_canary.bats .github/workflows.md \
		scripts/ci/canary.md scripts/ci/bootstrap/verify-harden-runner-agent.sh.bak \
		'.github/workflows' '.github/workflow/x.yml' scripts/ci/libx/log.sh scripts/ci/lib \
		scripts/ci/lib/python.sh scripts/ci/lib/log.sh.bak scripts/ci/lib/github/output.sh.orig
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	# A candidate already on main: no file differs.
	prepare_gate_run
	prepare_gate_compare
	jq -e '.files == []' "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
}

@test "external-canary: an incomplete or untrustworthy compare response gets no excuse" {
	local filter
	# At GitHub's 300-file cap, beyond the 250-commit limit, and malformed.
	for filter in \
		'.files = [range(300) | {filename: "docs/f\(.).md", status: "modified"}]' \
		'.total_commits = 251' \
		'del(.total_commits)' \
		'.total_commits = "2"' \
		'.total_commits = -1' \
		'.total_commits = 1.5' \
		'.total_commits = null' \
		'del(.files)' \
		'.files = {}' \
		'.files = [{filename: 5, status: "modified"}]' \
		'.files = [{}]' \
		'.files = ["docs/README.md"]' \
		'.files = [{filename: "", status: "modified"}]' \
		'.files = [{filename: "docs/README.md"}]' \
		'.files = [{filename: "docs/README.md", status: null}]' \
		'.files = [{filename: "docs/README.md", status: "moved"}]' \
		'.files = [{filename: "docs/README.md", status: "Modified"}]' \
		'.files = [{filename: "docs/a.md", status: "renamed"}]' \
		'.files = [{filename: "docs/a.md", status: "renamed", previous_filename: null}]' \
		'.files = [{filename: "docs/a.md", status: "renamed", previous_filename: false}]' \
		'.files = [{filename: "docs/a.md", status: "renamed", previous_filename: ""}]' \
		'.files = [{filename: "docs/a.md", status: "copied"}]' \
		'.files = [{filename: "docs/README.md", status: "modified", previous_filename: 7}]' \
		'.files = [{filename: "docs/README.md", status: "modified", previous_filename: null}]' \
		'del(.merge_base_commit)' \
		'.merge_base_commit = "x"' \
		'.merge_base_commit.sha = "abc"' \
		'.merge_base_commit.sha = null' \
		'[.]' \
		'"not an object"'; do
		prepare_gate_run
		prepare_gate_compare docs/README.md
		jq "$filter" "$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
		mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
	# 299 unwatched files are still a complete list.
	prepare_gate_run
	prepare_gate_compare docs/README.md
	jq '.files = [range(299) | {filename: "docs/f\(.).md", status: "modified"}]' "$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
	mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	# Every documented status, 250 commits and a copy with its old name pass.
	prepare_gate_run
	prepare_gate_compare docs/README.md
	jq '.total_commits = 250 | .files = ([("added", "removed", "modified", "changed", "unchanged")
		| {filename: "docs/\(.).md", status: .}]
		+ [{filename: "docs/c.md", status: "copied", previous_filename: "docs/b.md"}])' \
		"$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
	mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
	# A copy from a watched path is a watched name.
	jq '.files += [{filename: "docs/x.yml", status: "copied", previous_filename: ".github/workflows/ci.yml"}]' \
		"$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
	mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Two root objects, the first naming a watched path and the second clean,
	# and two clean ones: the response must be exactly one JSON value.
	prepare_gate_run
	prepare_gate_compare .github/workflows/ci.yml
	cp "$MOCK_COMPARE_JSON" "$BATS_TEST_TMPDIR/watched.json"
	prepare_gate_compare docs/README.md
	cat "$BATS_TEST_TMPDIR/watched.json" "$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
	mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	prepare_gate_compare docs/README.md
	cat "$MOCK_COMPARE_JSON" "$MOCK_COMPARE_JSON" >"$MOCK_COMPARE_JSON.tmp"
	mv "$MOCK_COMPARE_JSON.tmp" "$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Truncated or empty JSON.
	prepare_gate_run
	printf '{"merge_base_commit":{"sha":"%s"},"total_commits":1,"files":[{"filename":"docs/a.md"}' \
		"$MOCK_MERGE_BASE" >"$BATS_TEST_TMPDIR/compare.json"
	export MOCK_COMPARE_JSON="$BATS_TEST_TMPDIR/compare.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	: >"$MOCK_COMPARE_JSON"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: the changed-files check fails closed without a compare or a candidate SHA" {
	# An API error.
	prepare_gate_run
	run env MOCK_COMPARE_FAIL=1 bash "$CANARY_EVAL" 'retry_eligible python.yml failure https://example/runs/11'
	assert_failure
	# No candidate SHA, or a symbolic one.
	run env -u CANARY_CANDIDATE_SHA bash "$CANARY_EVAL" 'retry_eligible python.yml failure https://example/runs/11'
	assert_failure
	run env CANARY_CANDIDATE_SHA=main bash "$CANARY_EVAL" 'retry_eligible python.yml failure https://example/runs/11'
	assert_failure
	run grep -c 'compare/main...main' "$MOCK_CALLS"
	assert_output 0
	# The baseline itself still passes.
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_success
}

@test "external-canary: an aggregate with any other failure annotation is not excused" {
	local ann
	for ann in "$ANN_TEST" "$ANN_PREPARE_GATE" "$ANN_MATRIX_GATE" "$ANN_EXIT_2" "$ANN_AGENT_STARTUP"; do
		prepare_gate_run
		jq -s . <<<"$ANN_EXIT_1 $ANN_MATRIX_GATE $ANN_EXIT_1 $ANN_PREPARE_GATE $ann" >"$MOCK_ANNOTATIONS/802.json"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
	# The prepare gate message with another concluded value.
	prepare_gate_run
	jq -s '.[2].message |= sub("failure"; "cancelled")' <<<"$ANN_EXIT_1 $ANN_MATRIX_GATE $ANN_PREPARE_GATE" >"$MOCK_ANNOTATIONS/802.json"
	run jq -r '.[2].message' "$MOCK_ANNOTATIONS/802.json"
	assert_output "Matrix preparation concluded 'cancelled'; failing the check."
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# An annotation read error fails closed.
	prepare_gate_run
	rm "$MOCK_ANNOTATIONS/802.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: a second, unrelated failed job keeps the run a product failure" {
	prepare_gate_run
	edit_jobs '.jobs += [{id: 805, name: "artifacts", conclusion: "failure", steps: [
		{number: 1, name: "Set up job", conclusion: "success"},
		{number: 2, name: "Require distinct artifact names across sibling calls", conclusion: "failure"}]}]'
	jq -s . <<<"$ANN_EXIT_1" >"$MOCK_ANNOTATIONS/805.json"
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_failure
	# A failed matrix leg of the other caller.
	prepare_gate_run
	edit_jobs '.jobs += [{id: 806, name: "a / Python Tests (a)", conclusion: "failure", steps: [
		{number: 1, name: "Set up job", conclusion: "success"},
		{number: 17, name: "Run pytest", conclusion: "failure"}]}]'
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/806.json"
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: an aggregate whose prepare job failed on a product error is not excused" {
	# The prepare job ran its matrix step and failed with its own message.
	prepare_gate_run
	edit_jobs '.jobs[1].steps |= map(if .name == "Verify harden-runner agent" then .conclusion = "success"
		elif .name == "Generate Python matrix" then .conclusion = "failure" else . end)'
	jq -s . <<<"$ANN_EXIT_1 $ANN_TEST" >"$MOCK_ANNOTATIONS/801.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A different agent failure in the prepare job is no signature either.
	prepare_gate_run
	jq -s . <<<"$ANN_EXIT_1 $ANN_AGENT_STATUS" >"$MOCK_ANNOTATIONS/801.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: an aggregate is excused only beside exactly one failed prepare job of its own caller and family" {
	# The failed prepare job belongs to caller a, the aggregate to caller b.
	prepare_gate_run
	edit_jobs '.jobs[1].name = "a / Prepare Python Matrix" | .jobs[0].name = "b / Prepare Python Matrix"'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Another family's failed prepare job of the same caller, while the
	# aggregate's own prepare job passed.
	prepare_gate_run
	edit_jobs '.jobs[1].name = "b / Prepare Rust Matrix" | .jobs[0].name = "b / Prepare Python Matrix"'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Its own prepare job missing, successful, skipped or cancelled.
	local filter
	for filter in 'del(.jobs[1])' \
		'.jobs[1].conclusion = "success" | .jobs[1].steps = []' \
		'.jobs[1].conclusion = "skipped" | .jobs[1].steps = []' \
		'.jobs[1].conclusion = "cancelled"'; do
		prepare_gate_run
		edit_jobs "$filter"
		run call_fn retry_eligible python.yml failure https://example/runs/11
		assert_failure
	done
	# Two jobs named as its prepare job, both failed on the agent.
	prepare_gate_run
	edit_jobs '.jobs += [.jobs[1] | .id = 807]'
	cp "$MOCK_ANNOTATIONS/801.json" "$MOCK_ANNOTATIONS/807.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A successful job with its prepare job's name next to the failed one.
	prepare_gate_run
	edit_jobs '.jobs += [{id: 808, name: "b / Prepare Python Matrix", conclusion: "success", steps: []}]'
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# Two aggregates of the same caller and family.
	prepare_gate_run
	edit_jobs '.jobs += [.jobs[2] | .id = 809]'
	cp "$MOCK_ANNOTATIONS/802.json" "$MOCK_ANNOTATIONS/809.json"
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
	# A family the six reusables do not have.
	prepare_gate_run b Go Go
	run call_fn retry_eligible python.yml failure https://example/runs/11
	assert_failure
}

@test "external-canary: aggregate reads count toward the five-read annotation budget" {
	# Callers a and b each with a failed prepare and aggregate: four
	# annotation reads, and one compare call for the whole classification.
	prepare_gate_run
	edit_jobs '.jobs |= (map(select(.id != 800)) + [.[1], .[2] | .id += 10 | .name |= sub("^b / "; "a / ")])'
	cp "$MOCK_ANNOTATIONS/801.json" "$MOCK_ANNOTATIONS/811.json"
	cp "$MOCK_ANNOTATIONS/802.json" "$MOCK_ANNOTATIONS/812.json"
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_success
	assert_output infra:harden-runner-agent-startup
	run grep -c '/check-runs/8[0-9]*/annotations' "$MOCK_CALLS"
	assert_output 4
	run grep -c 'lgtm-ci/compare/' "$MOCK_CALLS"
	assert_output 1
	# A third caller makes six: the sixth read is never made.
	: >"$MOCK_CALLS"
	edit_jobs '.jobs += [.jobs[0], .jobs[1] | .id += 20 | .name |= sub("^b / "; "c / ")]'
	cp "$MOCK_ANNOTATIONS/801.json" "$MOCK_ANNOTATIONS/821.json"
	cp "$MOCK_ANNOTATIONS/802.json" "$MOCK_ANNOTATIONS/822.json"
	run call_fn retry_eligible siblings.yml failure https://example/runs/11
	assert_failure
	run grep -c '/check-runs/8[0-9]*/annotations' "$MOCK_CALLS"
	assert_output 5
	run grep -c 'lgtm-ci/compare/' "$MOCK_CALLS"
	assert_output 1
}

# Print the aggregate job (`    name: Aggregate <family> Results`) of
# workflow file $1, from its job key line to the line before the next job or
# top-level key; fail unless exactly one exists. Line-based, for the
# two-space indentation yamllint enforces.
aggregate_job_text() {
	awk '
		function flush() {
			if (isagg) { found++; out = buf }
			buf = ""
			isagg = 0
		}
		/^jobs:[[:space:]]*$/ { injobs = 1; next }
		injobs && /^[^ #]/ { flush(); injobs = 0; key = 0 }
		injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); key = 1; buf = $0 "\n"; next }
		injobs && key {
			buf = buf $0 "\n"
			if ($0 ~ /^    name: Aggregate [^\/]+ Results$/) isagg = 1
		}
		END {
			flush()
			if (found != 1) exit 1
			printf "%s", out
		}
	' "$1"
}

# Print the pinned parts of the aggregate job of reusable $1: its lines up
# to `runs-on:` (name, needs, if), every step name in order, and both gate
# steps in full (condition and body).
prepare_gate_pin_text() {
	aggregate_job_text "${PROJECT_ROOT}/.github/workflows/${1}.yml" | awk '
		NR == 1 { head = 1 }
		/^    runs-on:/ { head = 0 }
		head { print "head: " $0 }
		/^      - name: / {
			names = names $0 "\n"
			gate = ($0 ~ /^      - name: Fail if (matrix preparation did not succeed|any matrix leg failed)$/)
		}
		/^    [^ ]/ { gate = 0 }
		gate { print "gate: " $0 }
		END { printf "%s", names }
	'
}

@test "external-canary: every reusable aggregate job keeps the pinned gate steps, needs/if and step order" {
	local wf text order
	# git hash-object of prepare_gate_pin_text per reusable. A change to a gate
	# step's condition or body, the job's needs/if lines or the step order
	# changes it: update the hash only together with prepare-gate.sh. At run
	# time any change to a workflow withholds the excuse until it is on main
	# (prepare_gate_unchanged).
	declare -A expected=(
		[reusable-test-python]=e383fd4a6ab496d3f2445d6eb0c981bcd9fa075e
		[reusable-rust-test]=3db7334a2b677b1c49c8906489865884418e293c
		[reusable-rust-test-run]=3db7334a2b677b1c49c8906489865884418e293c
		[reusable-test-node]=866e4bce981ecaccb56cd2e6a878e686486d08d5
		[reusable-test-node-run]=d78353d207e1a06192a5a7ca04db86e3a85ddcdc
		[reusable-test-node-custom]=5f13b7a3bd527447b9b5318a7df8890cf3bdc26d
	)
	order='Harden runner|Verify harden-runner agent|Fail on unknown egress-preset|Fail if matrix preparation did not succeed|Checkout repository|Check tooling App credential|Mint tooling App token|Checkout lgtm-ci tooling|Checkout and harden|Wait for and download matrix results|Aggregate matrix results|Fail if any matrix leg failed|Recheck harden-runner agent'
	for wf in $PREPARE_GATE_REUSABLES; do
		text="$(prepare_gate_pin_text "$wf")"
		run git hash-object --stdin <<<"$text"
		assert_output "${expected[$wf]}"
		run bash -c 'grep "^      - name: " | sed "s/^      - name: //" | paste -sd "|" -' <<<"$text"
		if [[ "$wf" == reusable-test-node-custom ]]; then
			assert_output "${order/Wait for and download matrix results|Aggregate matrix results/Aggregate matrix custom test results}"
		else
			assert_output "$order"
		fi
		run bash -c 'grep "^gate: " | grep -cF "echo \"::error::Matrix preparation concluded '"'"'\${PREPARE_RESULT}'"'"'; failing the check.\""' <<<"$text"
		assert_output 1
		run bash -c 'grep "^gate: " | grep -cF "if: needs.prepare.result != '"'"'success'"'"'"' <<<"$text"
		assert_output 1
	done
}

@test "external-canary: the prepare-gate families name every reusable aggregate job" {
	local wf agg prep found
	# Exactly the six reusables have an aggregate job.
	found="$(grep -lE '^    name: Aggregate [^/]+ Results$' "${PROJECT_ROOT}"/.github/workflows/*.yml | xargs -n1 basename | sort | paste -sd ' ' -)"
	assert_equal "$found" "reusable-rust-test-run.yml reusable-rust-test.yml reusable-test-node-custom.yml reusable-test-node-run.yml reusable-test-node.yml reusable-test-python.yml"
	# Each one's aggregate family pairs with its own prepare job's family.
	for wf in $PREPARE_GATE_REUSABLES; do
		agg="$(sed -n 's/^    name: Aggregate \([^/]*\) Results$/\1/p' "${PROJECT_ROOT}/.github/workflows/${wf}.yml")"
		prep="$(F="$agg" bash "$CANARY_EVAL" 'jq -rn --arg f "$F" --arg gate x --arg matrix y "${CANARY_PREPARE_GATE_JQ} \$f | prepare_gate_family"')"
		[[ -n "$prep" && "$prep" != null ]]
		run grep -cxF "    name: Prepare ${prep} Matrix" "${PROJECT_ROOT}/.github/workflows/${wf}.yml"
		assert_output 1
	done
	run bash "$CANARY_EVAL" 'printf "%s\n" "$CANARY_PREPARE_GATE_STEP" "$CANARY_PREPARE_GATE_MESSAGE"'
	assert_output $'Fail if matrix preparation did not succeed\nMatrix preparation concluded \'failure\'; failing the check.'
}

# Print the lines of the steps an excused aggregate job runs (harden-runner,
# verify, egress-preset, both gates, recheck) from the aggregate job text on
# stdin. The skipped middle steps do not run in the excused shape.
excused_step_lines() {
	awk '
		/^      - name: / {
			keep = ($0 ~ /^      - name: (Harden runner|Verify harden-runner agent|Fail on unknown egress-preset|Fail if matrix preparation did not succeed|Fail if any matrix leg failed|Recheck harden-runner agent)$/)
		}
		/^    [^ ]/ { keep = 0 }
		keep { print }
	'
}

# Classify every repository dependency the step text on stdin can name, and
# print each listed step script (CANARY_PREPARE_GATE_STEP_SCRIPTS) it finds,
# one per line. Strict rather than smart: return 1, with a message per
# finding on stdout, on anything it cannot classify:
#   - a `uses:` value (quotes stripped) other than <owner>/<repo>@<40-hex SHA>,
#     so every local action (`./...`, quoted or not) fails;
#   - a token that looks like a repository file: any path ending in .sh, .py
#     or .bash (with or without a directory), or any path under scripts/,
#     tools/, bin/, hack/, lib/ or .github/, that is not a listed step script.
# The one inert mention allowed is sync_inline_blocks.py, the generator named
# in each generated copy's header; it never runs in the job.
prepare_gate_step_inventory() {
	local text token value listed status=0
	text="$(cat)"
	listed=" $(bash "$CANARY_EVAL" 'printf "%s " "${CANARY_PREPARE_GATE_STEP_SCRIPTS[@]}"') "
	while IFS= read -r value; do
		[[ -n "$value" ]] || continue
		value="${value#uses:}"
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value//\"/}"
		value="${value//\'/}"
		if ! [[ "$value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ ]]; then
			echo "unclassified uses: ${value}: add the action's files to CANARY_PREPARE_GATE_WATCHED (scripts/ci/canary/prepare-gate.sh)"
			status=1
		fi
	done < <(grep -oE 'uses:[[:space:]]*[^[:space:]#]+' <<<"$text")
	while IFS= read -r token; do
		[[ -n "$token" ]] || continue
		token="${token#[^A-Za-z0-9_./-]}"
		token="${token#./}"
		token="${token#.lgtm-ci-tooling/}"
		if [[ "$listed" == *" ${token} "* ]]; then
			printf '%s\n' "$token"
		elif [[ "$token" != sync_inline_blocks.py ]]; then
			echo "unclassified file ${token}: add it to CANARY_PREPARE_GATE_WATCHED (scripts/ci/canary/prepare-gate.sh)"
			status=1
		fi
	done < <(grep -oE '[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(sh|py|bash)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_./-])(\./)?(scripts|tools|bin|hack|lib|\.github)/[A-Za-z0-9_./-]*[A-Za-z0-9_-]' <<<"$text" |
		sed -E 's/[^A-Za-z0-9_-]$//')
	return "$status"
}

@test "external-canary: the prepare-gate step scripts are derived from the six aggregate jobs" {
	local wf text derived listed
	text="$(for wf in $PREPARE_GATE_REUSABLES; do
		aggregate_job_text "${PROJECT_ROOT}/.github/workflows/${wf}.yml" | excused_step_lines
	done)"
	[[ "$(wc -l <<<"$text")" -gt 100 ]]
	run prepare_gate_step_inventory <<<"$text"
	assert_success
	derived="$(sort -u <<<"$output" | paste -sd ' ' -)"
	listed="$(bash "$CANARY_EVAL" 'printf "%s\n" "${CANARY_PREPARE_GATE_STEP_SCRIPTS[@]}"' | sort -u | paste -sd ' ' -)"
	assert_equal "$derived" "$listed"
	# Each listed script exists.
	for wf in $listed; do
		[[ -f "${PROJECT_ROOT}/${wf}" ]]
	done
	run bash "$CANARY_EVAL" 'printf "%s\n" "${CANARY_PREPARE_GATE_WATCHED[@]}"'
	assert_output $'.github/workflows/\n.github/actions/\nscripts/ci/bootstrap/fail-unknown-egress-preset.sh\nscripts/ci/bootstrap/recheck-harden-runner-agent.sh\nscripts/ci/bootstrap/verify-harden-runner-agent.sh\nscripts/ci/canary/\nscripts/ci/actions/external-canary.sh\nscripts/ci/lib/cosign.sh\nscripts/ci/lib/github/output.sh\nscripts/ci/lib/infra-signatures.sh\nscripts/ci/lib/log.sh'
}

@test "external-canary: the step inventory fails on any dependency it cannot classify" {
	local text gate='          echo "::error::Matrix preparation concluded'
	text="$(aggregate_job_text "${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml" | excused_step_lines)"
	run prepare_gate_step_inventory <<<"$text"
	assert_success
	# A helper outside scripts/ci, run from a gate step.
	run prepare_gate_step_inventory <<<"${text/"$gate"/          bash tools/new-helper.sh
$gate}"
	assert_failure
	assert_output --partial 'unclassified file tools/new-helper.sh: add it to CANARY_PREPARE_GATE_WATCHED'
	# The harden-runner step replaced by a quoted, single-quoted or bare local action.
	local action
	for action in '"./.github/actions/new-helper"' "'./.github/actions/new-helper'" './.github/actions/new-helper' \
		'"./tools/action"' 'actions/checkout@v4' 'docker://alpine:3'; do
		run prepare_gate_step_inventory <<<"${text/uses: step-security\/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43/uses: ${action}}"
		assert_failure
		assert_output --partial 'unclassified uses: '
	done
	# Other forms: a sourced library, a bare script name, a Python helper, a
	# path with no extension under a script directory.
	local line
	for line in 'source scripts/ci/lib/new-helper.sh' '. "$GITHUB_WORKSPACE/helper.sh"' \
		'python3 -I hack/check.py' 'bash new.bash' './bin/run-thing' 'tools/run-thing --check'; do
		run prepare_gate_step_inventory <<<"${text/"$gate"/          ${line}
$gate}"
		assert_failure
		assert_output --partial 'unclassified file '
	done
}

# Print, one per line and repository-relative, every file reachable through
# `source` or `.` from the files given as arguments (repository-relative, under
# root $1), the arguments included. Each line must be `source "$VAR/<path>"`
# (or `.`) where VAR is set in the same file from dirname of BASH_SOURCE;
# print `unclassified <file>: <line>` and return 1 for any other form.
canary_source_closure() {
	local root file dir line var rel target own status=0
	root="$(cd "$1" && pwd -P)" || return 1
	shift
	local -a queue=("$@")
	local -A seen=()
	while ((${#queue[@]})); do
		file="${queue[0]}"
		queue=("${queue[@]:1}")
		[[ -z "${seen[$file]:-}" ]] || continue
		seen[$file]=1
		printf '%s\n' "$file"
		dir="$(dirname "$file")"
		while IFS= read -r line; do
			own=""
			if [[ "$line" =~ ^[[:space:]]*(source|\.)[[:space:]]+\"\$([A-Za-z_][A-Za-z0-9_]*)/([A-Za-z0-9_./-]+)\"[[:space:]]*$ ]]; then
				var="${BASH_REMATCH[2]}"
				rel="${BASH_REMATCH[3]}"
				# VAR must be set, in this file, to the file's own directory.
				own="$(awk -v a="${var}"'="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
					-v b="${var}"'="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"' '
					{ sub(/^[[:space:]]+/, "") }
					index($0, a) == 1 || index($0, b) == 1 { found = 1 }
					END { if (found) print "yes" }' "$root/$file")"
			fi
			if [[ "$own" == yes ]] &&
				target="$(cd "$root/$dir/$(dirname "$rel")" 2>/dev/null && pwd -P)/$(basename "$rel")" &&
				[[ "$target" == "$root"/* && -f "$target" ]]; then
				queue+=("${target#"$root"/}")
			else
				echo "unclassified ${file}: ${line}"
				status=1
			fi
		done < <(grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$root/$file")
	done
	return "$status"
}

@test "external-canary: every file the canary process sources is a watched path" {
	local file watched found=""
	local -a files=(scripts/ci/actions/external-canary.sh)
	for file in "${PROJECT_ROOT}"/scripts/ci/canary/*.sh; do
		files+=("${file#"${PROJECT_ROOT}"/}")
	done
	run canary_source_closure "$PROJECT_ROOT" "${files[@]}"
	assert_success
	found="$output"
	# The walker reaches the libraries the review named.
	for file in scripts/ci/lib/log.sh scripts/ci/lib/github/output.sh scripts/ci/lib/cosign.sh \
		scripts/ci/lib/infra-signatures.sh scripts/ci/canary/runs.sh scripts/ci/canary/prepare-gate.sh; do
		grep -qxF "$file" <<<"$found"
	done
	watched="$(bash "$CANARY_EVAL" 'printf "%s\n" "${CANARY_PREPARE_GATE_WATCHED[@]}"')"
	while IFS= read -r file; do
		if ! jq -en --arg p "$file" --arg w "$watched" >/dev/null \
			'any($w | split("\n")[] | select(. != ""); . as $e | if ($e | endswith("/")) then ($p | startswith($e)) else $p == $e end)'; then
			fail "sourced file ${file} is not a watched path: add it to CANARY_PREPARE_GATE_WATCHED (scripts/ci/canary/prepare-gate.sh)"
		fi
	done <<<"$found"
}

@test "external-canary: the source walk fails on an unwatched or unclassifiable source" {
	local root="$BATS_TEST_TMPDIR/tree"
	mkdir -p "$root/scripts/ci/actions" "$root/scripts/ci/new"
	: >"$root/scripts/ci/new/helper.sh"
	cat >"$root/scripts/ci/actions/external-canary.sh" <<'EOF'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../new/helper.sh"
EOF
	run canary_source_closure "$root" scripts/ci/actions/external-canary.sh
	assert_success
	assert_output $'scripts/ci/actions/external-canary.sh\nscripts/ci/new/helper.sh'
	# scripts/ci/new/ is not watched.
	run bash "$CANARY_EVAL" 'printf "%s\n" "${CANARY_PREPARE_GATE_WATCHED[@]}"'
	refute_output --partial 'scripts/ci/new'
	# A variable not set from BASH_SOURCE, a computed path and a missing file.
	local line
	for line in 'source "$OTHER_DIR/x.sh"' 'source "$SCRIPT_DIR/$name.sh"' '. "$SCRIPT_DIR/../new/missing.sh"' \
		'source /etc/profile' 'source <(echo x)'; do
		printf '%s\n' 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' "$line" \
			>"$root/scripts/ci/actions/external-canary.sh"
		run canary_source_closure "$root" scripts/ci/actions/external-canary.sh
		assert_failure
		assert_output --partial 'unclassified scripts/ci/actions/external-canary.sh: '
	done
}
