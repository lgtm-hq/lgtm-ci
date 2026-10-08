#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/external-canary.sh (#1074)
#
# `gh` is mocked: every call is appended to $MOCK_CALLS; GET responses come
# from a fake fixture checkout and a sequence of run-list snapshots so the
# poll loop can be driven through in-progress -> completed, failure and
# timeout without touching the network.

load "../../helpers/common"
load "../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/external-canary.sh"
CANDIDATE="1111111111111111111111111111111111111111"
OLD_PIN="f29da756f9f1673d6d10c5b956480807e5dc8a9b"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT CANDIDATE OLD_PIN
	export GH_TOKEN=fixture-token
	export LGTM_CI_TOKEN=lgtm-ci-token
	export FIXTURE_REPO=owner/fixture
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export CANARY_POLL_SECONDS=0
	export CANARY_TIMEOUT_SECONDS=60
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output.txt"
	: >"$GITHUB_STEP_SUMMARY"
	: >"$GITHUB_OUTPUT"

	# Fake fixture: three dispatchable workflows (one gate, one informational
	# negative, one informational release path) and one push-only workflow.
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
	: >"$MOCK_CALLS"
	install_mock_gh
}

teardown() {
	restore_path
	teardown_temp_dir
}

# gh mock: dispatches on the argument string. Run-list snapshots are served
# in order from $MOCK_RUNS_DIR/runs.<n>; the last one repeats.
install_mock_gh() {
	local bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$bin"
	cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK_CALLS"
args="$*"
case "$args" in
*"repos/lgtm-hq/lgtm-ci/commits/"*)
	echo "$CANDIDATE"
	;;
*"repos/lgtm-hq/lgtm-ci/pulls/"*"/files?per_page=100 --paginate --jq .[].filename")
	cat "${MOCK_PR_FILES:-/dev/null}"
	;;
*"git/ref/heads/main --jq .object.sha")
	echo "basebasebasebasebasebasebasebasebasebase"
	;;
*"git/commits/basebase"*"--jq .tree.sha")
	echo "treetreetreetreetreetreetreetreetreetree"
	;;
*"git/trees/treetree"*"recursive=1"*)
	for f in "$MOCK_FIXTURE_DIR"/*.yml; do echo ".github/workflows/$(basename "$f")"; done
	echo "README.md" >/dev/null
	;;
*"/contents/.github/workflows/"*)
	path="${args##*/contents/}"
	path="${path%%\?*}"
	cat "$MOCK_FIXTURE_DIR/$(basename "$path")"
	;;
*"-X POST repos/owner/fixture/git/trees --input - --jq .sha")
	cat >"$MOCK_POSTED_TREE"
	echo "newtreenewtreenewtreenewtreenewtreenewtr"
	;;
*"-X POST repos/owner/fixture/git/commits --input - --jq .sha")
	cat >/dev/null
	echo "cafecafecafecafecafecafecafecafecafecafe"
	;;
*"-X POST repos/owner/fixture/git/refs -f ref="*)
	echo "refs/heads/canary/$CANDIDATE"
	;;
*"/actions/workflows/"*"/dispatches -f ref="*)
	[[ "${MOCK_DISPATCH_FAIL:-}" == *"${args##*/actions/workflows/}"* ]] && exit 1
	;;
*"/actions/runs?branch="*)
	count_file="$MOCK_RUNS_DIR/.count"
	n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$count_file"
	while [[ $n -gt 1 && ! -f "$MOCK_RUNS_DIR/runs.$n" ]]; do n=$((n - 1)); done
	[[ -f "$MOCK_RUNS_DIR/runs.$n" ]] && cat "$MOCK_RUNS_DIR/runs.$n"
	;;
*"-X DELETE repos/owner/fixture/git/refs/heads/canary/"*)
	[[ "${MOCK_DELETE_FAIL:-}" == "1" ]] && exit 1
	;;
*)
	echo "unexpected gh call: $args" >&2
	exit 99
	;;
esac
EOF
	chmod +x "$bin/gh"
	export PATH="$bin:$PATH"
}

# One TSV row of a run-list snapshot.
run_row() {
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "https://github.com/owner/fixture/actions/runs/${4:-1}" "fixture-${1%.yml}"
}

all_green_snapshot() {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed failure 12
		run_row release-version-pr.yml completed success 13
	} >"$MOCK_RUNS_DIR/runs.1"
}

# Call one function of the script with the environment of this test.
call_fn() {
	bash -c "source '$SCRIPT'; $*"
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
		python-private-dep.yml verify-fresh-install.yml rust-release-build.yml; do
		run call_fn classify_workflow "$wf"
		assert_success
		assert_output "$(printf 'gate\tsuccess')"
	done
}

@test "external-canary: release and App-token paths are informational expecting success" {
	local wf
	for wf in release-version-pr.yml release-benign-hook.yml app-token-probe.yml sbom-release-upload.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tsuccess')"
	done
}

@test "external-canary: negative-by-design probes are informational expecting failure" {
	local wf
	for wf in release-tamper-hook.yml verify-negative.yml playwright-negative.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tfailure')"
	done
	run call_fn classify_workflow perms-negative.yml
	assert_output "$(printf 'informational\tstartup_failure')"
}

@test "external-canary: an unknown workflow is a gate (fail closed)" {
	run call_fn classify_workflow brand-new-probe.yml
	assert_output "$(printf 'gate\tsuccess')"
	run call_fn classify_workflow .github/workflows/release-version-pr.yml
	assert_output "$(printf 'informational\tsuccess')"
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

@test "external-canary: rewrite_pins rejects a short SHA" {
	cp "$MOCK_FIXTURE_DIR/python.yml" "$BATS_TEST_TMPDIR/wf.yml"
	run call_fn rewrite_pins "$BATS_TEST_TMPDIR/wf.yml" abc123
	assert_failure
	assert_output --partial "not a full SHA"
}

@test "external-canary: discover_dispatchable lists only workflow_dispatch workflows" {
	run call_fn discover_dispatchable "$MOCK_FIXTURE_DIR"
	assert_success
	assert_line "python.yml"
	assert_line "verify-negative.yml"
	assert_line "release-version-pr.yml"
	refute_line "starter-python.yml"
}

@test "external-canary: build_tree_payload emits one blob entry per workflow under .github/workflows" {
	run bash -c "source '$SCRIPT'; build_tree_payload treesha '$MOCK_FIXTURE_DIR' | jq -r '.base_tree, (.tree | length), (.tree[] | \"\\(.mode) \\(.type) \\(.path)\")'"
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

@test "external-canary: branch helpers refuse anything outside canary/" {
	run call_fn delete_canary_branch main
	assert_failure
	assert_output --partial "refusing to delete"
	run call_fn canary_branch_name "$CANDIDATE"
	assert_output "canary/$CANDIDATE"
}

# --- dispatch arg building ------------------------------------------------

@test "external-canary: main creates canary/<sha> from base and dispatches every dispatchable workflow on it" {
	all_green_snapshot
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success

	# Branch created from the base branch's commit and tree, never on main.
	run grep -F "git/ref/heads/main --jq .object.sha" "$MOCK_CALLS"
	assert_success
	run grep -F -- "-X POST repos/owner/fixture/git/refs -f ref=refs/heads/canary/${CANDIDATE} -f sha=cafecafe" "$MOCK_CALLS"
	assert_success
	run grep -E -- "-X (POST|PATCH|PUT|DELETE) [^ ]*(heads/main|git/refs/heads/main)" "$MOCK_CALLS"
	refute_output

	# The posted tree carries the re-pinned files (candidate in, old pin out).
	run jq -r '.base_tree' "$MOCK_POSTED_TREE"
	assert_output "treetreetreetreetreetreetreetreetreetree"
	run bash -c "jq -r '.tree[].content' '$MOCK_POSTED_TREE' | grep -c '@${CANDIDATE}'"
	assert_output "5"
	run bash -c "jq -r '.tree[].content' '$MOCK_POSTED_TREE' | grep -c 'lgtm-hq/lgtm-ci/[^ ]*@${OLD_PIN}'"
	assert_output "0"

	# One dispatch per dispatchable workflow, on the canary branch.
	run grep -c -- "/actions/workflows/[a-z-]*.yml/dispatches -f ref=canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_output "3"
	run grep -F "actions/workflows/python.yml/dispatches -f ref=canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_success
	run grep -F "actions/workflows/starter-python.yml/dispatches" "$MOCK_CALLS"
	refute_output

	# Poll filters to the branch, the dispatch event, and runs created since dispatch.
	run grep -E "actions/runs\?branch=canary/${CANDIDATE}&event=workflow_dispatch&created=%3E%3D[0-9T:Z-]+&per_page=100" "$MOCK_CALLS"
	assert_success

	# Branch deleted at the end.
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: a failed dispatch is reported and the workflow lands as missing" {
	all_green_snapshot
	: >"$MOCK_RUNS_DIR/runs.1"
	run_row python.yml completed success 11 >>"$MOCK_RUNS_DIR/runs.1"
	run_row release-version-pr.yml completed success 13 >>"$MOCK_RUNS_DIR/runs.1"
	run env MOCK_DISPATCH_FAIL=verify-negative.yml CANARY_TIMEOUT_SECONDS=0 bash "$SCRIPT" "$CANDIDATE"
	assert_success # verify-negative is informational; the gate passed
	assert_output --partial "dispatch failed for verify-negative.yml"
	assert_output --partial "| \`verify-negative.yml\` | informational | \`failure\` | \`missing\` | ⚠️ unexpected |"
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
	run call_fn poll_runs "canary/$CANDIDATE" 2026-10-08T00:00:00Z python.yml verify-negative.yml
	assert_success
	assert_line "$(printf 'python.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	assert_line "$(printf 'verify-negative.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/12\tfixture-verify-negative')"
	run cat "$MOCK_RUNS_DIR/.count"
	assert_output "3"
}

@test "external-canary: poll_runs terminates on a failed run" {
	run_row python.yml completed failure 11 >"$MOCK_RUNS_DIR/runs.1"
	run call_fn poll_runs "canary/$CANDIDATE" 2026-10-08T00:00:00Z python.yml
	assert_success
	assert_output "$(printf 'python.yml\tfailure\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	run cat "$MOCK_RUNS_DIR/.count"
	assert_output "1"
}

@test "external-canary: poll_runs terminates at the bound with timeout and missing rows" {
	run_row python.yml in_progress "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run env CANARY_TIMEOUT_SECONDS=0 bash -c "source '$SCRIPT'; poll_runs canary/$CANDIDATE 2026-10-08T00:00:00Z python.yml rust.yml"
	assert_success
	assert_line "$(printf 'python.yml\ttimeout\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	assert_line "$(printf 'rust.yml\tmissing\t\t')"
}

@test "external-canary: poll_runs uses the latest run when a workflow has several" {
	{
		run_row python.yml completed success 22
		run_row python.yml completed failure 11
	} >"$MOCK_RUNS_DIR/runs.1"
	run call_fn poll_runs "canary/$CANDIDATE" 2026-10-08T00:00:00Z python.yml
	assert_output --partial "runs/22"
	refute_output --partial "runs/11"
}

# --- summary rendering and gate evaluation --------------------------------

@test "external-canary: render_summary writes a table with role, expected, conclusion, verdict and run link" {
	local rows
	rows="$(
		run_row python.yml x success 11 | awk -F'\t' 'BEGIN{OFS="\t"}{print $1,$3,$4,$5}'
		run_row verify-negative.yml x failure 12 | awk -F'\t' 'BEGIN{OFS="\t"}{print $1,$3,$4,$5}'
		run_row release-version-pr.yml x failure 13 | awk -F'\t' 'BEGIN{OFS="\t"}{print $1,$3,$4,$5}'
		printf 'rust.yml\tmissing\t\t\n'
	)"
	ROWS="$rows" run bash -c "source '$SCRIPT'; render_summary '$CANDIDATE' 'canary/$CANDIDATE' <<<\"\$ROWS\""
	assert_success
	assert_line "## External consumer canary"
	assert_line "| Workflow | Role | Expected | Conclusion | Verdict | Run |"
	assert_line "| \`python.yml\` | gate | \`success\` | \`success\` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/11) |"
	assert_line "| \`verify-negative.yml\` | informational | \`failure\` | \`failure\` | ✅ pass | [run](https://github.com/owner/fixture/actions/runs/12) |"
	assert_line "| \`release-version-pr.yml\` | informational | \`success\` | \`failure\` | ⚠️ unexpected | [run](https://github.com/owner/fixture/actions/runs/13) |"
	assert_line "| \`rust.yml\` | gate | \`success\` | \`missing\` | ❌ **gate failed** | — |"
	assert_output --partial "pinned to \`${CANDIDATE}\`"
}

@test "external-canary: failed_gates lists gate mismatches only" {
	local rows
	rows="$(printf 'python.yml\tfailure\tu\tn\nrust.yml\tsuccess\tu\tn\nverify-negative.yml\tsuccess\tu\tn\nperms-negative.yml\tstartup_failure\tu\tn\n')"
	ROWS="$rows" run bash -c "source '$SCRIPT'; failed_gates <<<\"\$ROWS\""
	assert_success
	assert_output "$(printf 'python.yml\tfailure')"
}

@test "external-canary: main exits non-zero when a gate fails and writes summary and outputs" {
	{
		run_row python.yml completed failure 11
		run_row verify-negative.yml completed failure 12
		run_row release-version-pr.yml completed success 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "::error title=external canary::gate python.yml concluded 'failure'"
	run grep -F "| \`python.yml\` | gate | \`success\` | \`failure\` | ❌ **gate failed** |" "$GITHUB_STEP_SUMMARY"
	assert_success
	run grep -F "gate-failures=1" "$GITHUB_OUTPUT"
	assert_success
	run grep -F "branch=canary/${CANDIDATE}" "$GITHUB_OUTPUT"
	assert_success
	# Branch is still cleaned up on failure.
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_success
}

@test "external-canary: informational workflows never fail the canary" {
	{
		run_row python.yml completed success 11
		run_row verify-negative.yml completed success 12 # unexpected green: a finding, not a gate failure
		run_row release-version-pr.yml completed failure 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "| \`verify-negative.yml\` | informational | \`failure\` | \`success\` | ⚠️ unexpected |"
	assert_output --partial "| \`release-version-pr.yml\` | informational | \`success\` | \`failure\` | ⚠️ unexpected |"
	run grep -F "gate-failures=0" "$GITHUB_OUTPUT"
	assert_success
}

@test "external-canary: a gate that never completes fails the canary as timeout" {
	{
		run_row python.yml in_progress "" 11
		run_row verify-negative.yml completed failure 12
		run_row release-version-pr.yml completed success 13
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
	run env EVENT_NAME=workflow_dispatch bash -c "source '$SCRIPT'; decide_run_mode"
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
		run env EVENT_NAME=pull_request PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
			bash -c "source '$SCRIPT'; decide_run_mode"
		assert_success
		assert_output "$(printf 'full\tpull request touches %s' "$path")"
		run grep -F "repos/lgtm-hq/lgtm-ci/pulls/42/files?per_page=100 --paginate" "$MOCK_CALLS"
		assert_success
	done
}

@test "external-canary: a pull request with no adoption-relevant change skips" {
	printf 'README.md\ndocs/workflow-contract.md\ntests/bats/unit/x.bats\nscripts/other.sh\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env EVENT_NAME=pull_request PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
		bash -c "source '$SCRIPT'; decide_run_mode"
	assert_success
	assert_output --partial "$(printf 'skip\tno adoption-relevant changes')"
}

@test "external-canary: the needs-external-canary label forces a full run without listing files" {
	run env EVENT_NAME=pull_request PR_NUMBER=42 PR_LABELS="docs, needs-external-canary" \
		bash -c "source '$SCRIPT'; decide_run_mode"
	assert_success
	assert_output "$(printf 'full\tlabel needs-external-canary forces a full run')"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: a fork pull request skips because the secret is unavailable" {
	run env EVENT_NAME=pull_request PR_NUMBER=42 PR_HEAD_REPO_FORK=true \
		bash -c "source '$SCRIPT'; decide_run_mode"
	assert_success
	assert_output --partial "$(printf 'skip\tfork pull request')"
	run grep -F "/pulls/" "$MOCK_CALLS"
	refute_output
}

@test "external-canary: main on a skipped PR exits 0, writes the skipped summary and touches no fixture" {
	printf 'README.md\n' >"$BATS_TEST_TMPDIR/files.txt"
	run env -u GH_TOKEN EVENT_NAME=pull_request PR_NUMBER=42 MOCK_PR_FILES="$BATS_TEST_TMPDIR/files.txt" \
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
		run_row release-version-pr.yml completed success 13
	} >"$MOCK_RUNS_DIR/runs.1"
	run env EVENT_NAME=pull_request PR_NUMBER=42 PR_LABELS="needs-external-canary,canary-informational" \
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
	run env EVENT_NAME=pull_request PR_NUMBER=42 PR_LABELS="needs-external-canary,canary-informational" \
		bash "$SCRIPT" "$CANDIDATE"
	assert_success
	refute_output --partial "::warning"
}
