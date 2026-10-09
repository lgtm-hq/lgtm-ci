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

# Runner *file* for calling functions of the script. Under kcov (CI
# coverage) `bash -c "source ..."` leaves BASH_SOURCE unbound and the
# script's `set -u` aborts; a script file keeps it bound (see
# test_egress_presets_rendered.bats). Usage: bash "$CANARY_EVAL" '<cmd>'
_write_canary_eval() {
	export CANARY_EVAL="${BATS_TEST_TMPDIR}/canary-eval.sh"
	printf '%s\n' '# shellcheck disable=SC1090' 'source "$SCRIPT"' 'eval "$1"' >"$CANARY_EVAL"
}

setup() {
	setup_temp_dir
	save_path
	export SCRIPT CANDIDATE OLD_PIN
	export GH_TOKEN=fixture-token
	export LGTM_CI_TOKEN=lgtm-ci-token
	export FIXTURE_REPO=owner/fixture
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export CANARY_POLL_SECONDS=0
	export CANARY_WRITE_RETRY_SECONDS=0
	export CANARY_TIMEOUT_SECONDS=60
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
# MOCK_DELETE_FAIL, MOCK_CONTENTS_FAIL, MOCK_COMPARE_FAIL.
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
	echo "refs/heads/canary/$CANDIDATE"
	;;
*"/actions/workflows/"*"/dispatches -f ref="*)
	if [[ -n "${MOCK_DISPATCH_FAIL:-}" && "$args" == *"/actions/workflows/${MOCK_DISPATCH_FAIL}/dispatches"* ]]; then
		echo "gh: HTTP 422" >&2
		exit 1
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
	assert_output "27"
}

@test "external-canary: App-token, SBOM and negative-probe paths are informational expecting success" {
	local wf
	for wf in app-token-probe.yml sbom-release-upload.yml perms-negative-probe.yml \
		playwright-negative-probe.yml verify-negative-probe.yml; do
		run call_fn classify_workflow "$wf"
		assert_output "$(printf 'informational\tsuccess')"
	done
}

@test "external-canary: negative-by-design workflows are informational expecting failure" {
	local wf
	for wf in verify-negative.yml playwright-negative.yml docker-scan-failure.yml; do
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
	assert_output "canary/$CANDIDATE"
}

# --- dispatch arg building ------------------------------------------------

@test "external-canary: main creates canary/<sha> from base and dispatches every gate and informational workflow on it" {
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
	run grep -c -- "/actions/workflows/[a-z-]*.yml/dispatches -f ref=canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_output "2"
	run grep -F "actions/workflows/python.yml/dispatches -f ref=canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_success
	run grep -F "actions/workflows/verify-negative.yml/dispatches" "$MOCK_CALLS"
	assert_success
	run grep -E "actions/workflows/(starter-python|release-version-pr).yml/dispatches" "$MOCK_CALLS"
	refute_output

	# Poll filters to the branch, the dispatch event, and runs created since dispatch.
	run grep -E "actions/runs\?branch=canary/${CANDIDATE}&event=workflow_dispatch&created=%3E%3D[0-9T:Z-]+&per_page=100" "$MOCK_CALLS"
	assert_success

	# Branch deleted at the end, successfully; the manual row is listed.
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_success
	run bash "$SCRIPT" "$CANDIDATE"
	assert_output --partial "dispatched python.yml on canary/${CANDIDATE}"
	assert_output --partial "| \`release-version-pr.yml\` | manual | \`success\` | \`not_dispatched\` | ➖ not dispatched | — |"
	assert_output --partial "deleted owner/fixture@canary/${CANDIDATE}"
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
	run grep -c -- "/dispatches -f ref=canary/${CANDIDATE}" "$MOCK_CALLS"
	assert_output "3"
	run grep -F "| \`release-version-pr.yml\` | manual | \`success\` | \`success\` | ✅ pass |" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "external-canary: a failed dispatch lands as dispatch_failed without waiting for the bound" {
	run_row verify-negative.yml completed failure 12 >"$MOCK_RUNS_DIR/runs.1"
	run env MOCK_DISPATCH_FAIL=python.yml CANARY_TIMEOUT_SECONDS=600 bash "$SCRIPT" "$CANDIDATE"
	assert_failure
	assert_output --partial "dispatch python.yml failed on owner/fixture: gh: HTTP 422"
	assert_output --partial "| \`python.yml\` | gate | \`success\` | \`dispatch_failed\` | ❌ **gate failed** | — |"
	assert_output --partial "::error title=external canary::gate python.yml concluded 'dispatch_failed'"
	# Only the dispatched workflow is polled, and the snapshot completes it at once.
	run cat "$MOCK_RUNS_DIR/.count"
	assert_output "1"
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
	run env CANARY_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" "poll_runs canary/$CANDIDATE 2026-10-08T00:00:00Z python.yml rust.yml"
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

@test "external-canary: poll_runs keeps the previous snapshot when a list fetch fails" {
	run_row python.yml in_progress "" 11 >"$MOCK_RUNS_DIR/runs.1"
	run_row python.yml completed success 11 >"$MOCK_RUNS_DIR/runs.2"
	# Call 2 fails; call 3 serves the completed snapshot.
	run env MOCK_RUNS_FAIL_AT=2 bash "$CANARY_EVAL" "poll_runs canary/$CANDIDATE 2026-10-08T00:00:00Z python.yml"
	assert_success
	assert_output --partial "run list fetch failed; keeping the previous snapshot"
	assert_line "$(printf 'python.yml\tsuccess\thttps://github.com/owner/fixture/actions/runs/11\tfixture-python')"
	# A failure on the final poll at the bound still reports the last good rows.
	rm -f "$MOCK_RUNS_DIR/.count" "$MOCK_RUNS_DIR/runs.2"
	run env MOCK_RUNS_FAIL_AT=2 CANARY_TIMEOUT_SECONDS=0 bash "$CANARY_EVAL" "poll_runs canary/$CANDIDATE 2026-10-08T00:00:00Z python.yml"
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
	ROWS="$rows" run bash "$CANARY_EVAL" "render_summary '$CANDIDATE' 'canary/$CANDIDATE' <<<\"\$ROWS\""
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
	assert_output --partial "another canary for this SHA may hold it; it is left untouched"
	run grep -F -- "-X DELETE" "$MOCK_CALLS"
	refute_output
	run grep -c -- "/dispatches" "$MOCK_CALLS"
	assert_output "0"
}

@test "external-canary: a failed branch deletion is a warning, not a failure" {
	all_green_snapshot
	run env MOCK_DELETE_FAIL=1 bash "$SCRIPT" "$CANDIDATE"
	assert_success
	assert_output --partial "could not delete owner/fixture@canary/${CANDIDATE}"
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
	run grep -F -- "-X DELETE repos/owner/fixture/git/refs/heads/canary/${CANDIDATE}" "$MOCK_CALLS"
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
