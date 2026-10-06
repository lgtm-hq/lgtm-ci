#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-ai-review.sh (preflight + exit contract)

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-ai-review.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Write a fake lintro binary that prints $1 to stdout, $2 to stderr, exits $3.
write_fake_lintro() {
	local out="$1" err="$2" code="$3"
	local bin="${BATS_TEST_TMPDIR}/lintro"
	{
		echo '#!/usr/bin/env bash'
		printf 'cat <<'\''LINTRO_OUT'\''\n%s\nLINTRO_OUT\n' "$out"
		printf 'cat <<'\''LINTRO_ERR'\''>&2\n%s\nLINTRO_ERR\n' "$err"
		echo "exit ${code}"
	} >"$bin"
	chmod +x "$bin"
	echo "$bin"
}

success_json() {
	cat <<'JSON'
{"metadata":{"model":"grok-4.6","provider":"cursor","verdict":"approve"},"summary":"ok","findings":[],"verdict":"approve"}
JSON
}

error_json() {
	cat <<'JSON'
{"error":{"kind":"auth_failed","provider":"anthropic","status":401,"retryable":false,"provider_unavailable":true,"message":"invalid key"}}
JSON
}

run_review() {
	env STEP=run \
		GITHUB_REPOSITORY="x/y" PR_NUMBER=1 \
		"$@" bash "$SCRIPT"
}

# --- preflight ---------------------------------------------------------------

@test "preflight: same-repo PR runs" {
	STEP=preflight EVENT_NAME=pull_request HEAD_REPO="x/y" BASE_REPO="x/y" \
		PR_NUMBER=1 run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "should-run=true"
	assert_output --partial "skip-reason="
}

@test "preflight: fork PR skips with fork reason" {
	STEP=preflight EVENT_NAME=pull_request HEAD_REPO="fork/y" BASE_REPO="x/y" \
		PR_NUMBER=1 run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "should-run=false"
	assert_output --partial "skip-reason=fork"
}

@test "preflight: non-PR event skips with not-a-pr reason" {
	STEP=preflight EVENT_NAME=push PR_NUMBER=1 run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "skip-reason=not-a-pr"
}

@test "preflight: missing PR number skips with not-a-pr reason" {
	STEP=preflight EVENT_NAME=pull_request HEAD_REPO="x/y" BASE_REPO="x/y" \
		PR_NUMBER="" run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "should-run=false"
	assert_output --partial "skip-reason=not-a-pr"
}

# --- run: exit-code contract -------------------------------------------------

@test "run: exit 0 is reviewed and succeeds even when blocking" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=true
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
	assert_output --partial "exit-code=0"
}

@test "run: exit 1 findings succeed when non-blocking" {
	local bin
	bin="$(write_fake_lintro '{"verdict":"changes_requested"}' "" 1)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=findings"
}

@test "run: exit 1 changes-requested fails when blocking" {
	local bin
	bin="$(write_fake_lintro '{"verdict":"changes_requested"}' "" 1)"
	run run_review LINTRO_BIN="$bin" BLOCKING=true
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=findings"
	assert_output --partial "verdict=changes_requested"
}

@test "run: exit 1 with empty verdict fails when blocking" {
	local bin
	bin="$(write_fake_lintro '{}' "" 1)"
	run run_review LINTRO_BIN="$bin" BLOCKING=true
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=findings"
	assert_output --partial "verdict="
}

@test "run: exit 1 approve verdict succeeds even when blocking" {
	local bin
	bin="$(write_fake_lintro '{"verdict":"approve"}' "" 1)"
	run run_review LINTRO_BIN="$bin" BLOCKING=true
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=findings"
	assert_output --partial "verdict=approve"
}

@test "run: review argv targets the PR repo" {
	local bin="${BATS_TEST_TMPDIR}/lintro"
	local argv_file="${BATS_TEST_TMPDIR}/argv"
	{
		echo '#!/usr/bin/env bash'
		printf 'printf "%%s\\n" "$@" >"%s"\n' "$argv_file"
		printf 'cat <<'\''LINTRO_OUT'\''\n%s\nLINTRO_OUT\n' "$(success_json)"
		echo "exit 0"
	} >"$bin"
	chmod +x "$bin"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_success
	# Bind each option to its value — presence alone would pass with --repo
	# pointing at another repository. (Flag tokens start with --, which the
	# assert_line fallback rejects as an option, hence grep.)
	run bash -c "grep -Fx -A1 -- '--repo' '$argv_file' | tail -1"
	assert_output "x/y"
	run bash -c "grep -Fx -A1 -- '--pr' '$argv_file' | tail -1"
	assert_output "1"
}

@test "run: exit 2 is no-review and succeeds when non-blocking" {
	local bin
	bin="$(write_fake_lintro "$(error_json)" "" 2)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=no-review"
	assert_output --partial "error-kind=auth_failed"
}

@test "run: exit 2 fails when blocking" {
	local bin
	bin="$(write_fake_lintro "$(error_json)" "" 2)"
	run run_review LINTRO_BIN="$bin" BLOCKING=true
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=no-review"
}

@test "run: unexpected exit code fails even when non-blocking" {
	local bin
	bin="$(write_fake_lintro "" "boom" 3)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=broken"
}

@test "run: incomplete coverage reddens the check even when non-blocking" {
	local bin
	bin="$(write_fake_lintro '{"readiness_verdict":"incomplete","coverage":{"complete":false,"covered_at_head":2,"eligible":5},"verdict":"nits"}' "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=incomplete"
	assert_output --partial "verdict=incomplete"
}

@test "run: coverage.complete false alone reddens incomplete without readiness_verdict" {
	# jq // treats JSON false as missing; the gate must still fire on complete:false.
	local bin
	bin="$(write_fake_lintro '{"coverage":{"complete":false,"covered_at_head":2,"eligible":5},"verdict":"nits"}' "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=incomplete"
	assert_output --partial "verdict=incomplete"
}

@test "run: complete coverage does not trip the incomplete gate" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
}

# --- run: timeout + size gate conclusion matrix (#1098) ----------------------

# Fake lintro that never finishes. REVIEW_TIMEOUT_SECONDS=1 makes GNU
# timeout signal it, which is exactly the job-cap shape on #1094/#1097.
# $1 = "ignore-term" makes it survive SIGTERM so --kill-after escalates.
write_hanging_lintro() {
	local bin="${BATS_TEST_TMPDIR}/lintro"
	{
		echo '#!/usr/bin/env bash'
		if [[ "${1:-}" == "ignore-term" ]]; then
			echo "trap '' TERM"
		fi
		# A partial stderr line (no newline) at the moment the bound fires —
		# the wrapper's diagnostic must still be recognised (#1099 review).
		echo 'printf "partial line" >&2'
		echo 'sleep 30'
		echo 'exit 0'
	} >"$bin"
	chmod +x "$bin"
	echo "$bin"
}

# Mock gh: records every call with its GH_TOKEN; answers the pulls/N size
# lookup with $1; the comment-list lookup applies the real --jq filter to
# the JSON array in $2 (default: no comments). $3 = "patch-fails" makes
# PATCH exit 1 (403 shape). Writes exit 0.
_mock_gh_comment() {
	local diff_lines="$1" comments_json="${2:-[]}" patch_mode="${3:-}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '%s' "$comments_json" >"${BATS_TEST_TMPDIR}/comments.json"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${BATS_TEST_TMPDIR}/gh-calls"
echo "token=\${GH_TOKEN:-}" >>"${BATS_TEST_TMPDIR}/gh-calls"
echo "--" >>"${BATS_TEST_TMPDIR}/gh-calls"
if [[ " \$* " == *" --method PATCH "* ]]; then
	[[ "${patch_mode}" == "patch-fails" ]] && exit 1
	exit 0
fi
if [[ " \$* " == *" --method "* ]]; then
	exit 0
fi
if [[ " \$* " == *"/issues/"*"/comments?per_page="* ]]; then
	[[ " \$* " == *" --paginate "* ]] || { echo "comment lookup must paginate" >&2; exit 1; }
	jq_filter=""
	while [[ \$# -gt 0 ]]; do
		if [[ "\$1" == "--jq" ]]; then jq_filter="\$2"; fi
		shift
	done
	jq -r "\$jq_filter" "${BATS_TEST_TMPDIR}/comments.json"
	exit 0
fi
echo "${diff_lines}"
EOF
	chmod +x "${mock_bin}/gh"
	save_path
	export PATH="${mock_bin}:$PATH"
}

BOT_MARKER_COMMENT='[{"id":4242,"user":{"type":"Bot","login":"lintro-review[bot]"},"body":"<!-- lintro-ai-review-incomplete -->\n:warning: old"}]'
USER_MARKER_COMMENT='[{"id":7,"user":{"type":"User","login":"someone"},"body":"<!-- lintro-ai-review-incomplete -->\nspoof"}]'

@test "run: timed-out review is neutral (exit 0) when non-blocking" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro)"
	_mock_gh_comment 1900
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=1 \
		GH_TOKEN=workflow-token GITHUB_TOKEN=app-token
	assert_success
	assert_output --partial "::warning::AI review did not complete"
	assert_output --partial "(diff: 1900 lines)"
	assert_output --partial "This check is neutral"
	refute_output --partial "::error::"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=timed-out"
	assert_output --partial "exit-code=124"
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "did not complete"
	# Size lookup uses the workflow token; the comment goes out as the bot
	# (App token). Each gh call is recorded as args, token line, "--".
	run awk -v RS='--\n' '/pulls\/1/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "token=workflow-token"
	refute_output --partial "token=app-token"
	run awk -v RS='--\n' '/--method/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "POST"
	assert_output --partial "repos/x/y/issues/1/comments"
	assert_output --partial "lintro-ai-review-incomplete"
	assert_output --partial "token=app-token"
}

@test "run: timed-out review updates its existing PR comment instead of adding one" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro)"
	_mock_gh_comment 1900 "$BOT_MARKER_COMMENT"
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=1 GITHUB_TOKEN=app-token
	assert_success
	run awk -v RS='--\n' '/--method/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "PATCH"
	assert_output --partial "repos/x/y/issues/comments/4242"
	refute_output --partial "POST"
}

@test "run: a marker comment from a non-bot user is ignored and a fresh one is posted" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro)"
	_mock_gh_comment 1900 "$USER_MARKER_COMMENT"
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=1 GITHUB_TOKEN=app-token
	assert_success
	run awk -v RS='--\n' '/--method/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "POST"
	refute_output --partial "PATCH"
	refute_output --partial "issues/comments/7"
}

@test "run: a failed PATCH falls back to posting a new comment" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro)"
	_mock_gh_comment 1900 "$BOT_MARKER_COMMENT" patch-fails
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=1 GITHUB_TOKEN=app-token
	assert_success
	refute_output --partial "could not post"
	run awk -v RS='--\n' '/--method/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "PATCH"
	assert_output --partial "POST"
}

@test "run: a review that ignores SIGTERM is killed and still timed-out, not broken" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro ignore-term)"
	_mock_gh_comment 1900
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=1 REVIEW_KILL_AFTER_SECONDS=1
	assert_success
	refute_output --partial "::error::"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=timed-out"
	assert_output --partial "exit-code=137"
}

@test "run: timed-out review fails when blocking and says so in the notice" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	bin="$(write_hanging_lintro)"
	_mock_gh_comment 1900
	run run_review LINTRO_BIN="$bin" BLOCKING=true REVIEW_TIMEOUT_SECONDS=1
	assert_failure
	assert_output --partial "blocking: true"
	refute_output --partial "This check is neutral"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=timed-out"
}

@test "run: lintro's own 124 or 137 under the wrapper is broken when the bound did not fire" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin
	for code in 124 137; do
		: >"$GITHUB_OUTPUT"
		bin="$(write_fake_lintro "" "boom" "$code")"
		run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=60
		assert_failure
		run cat "$GITHUB_OUTPUT"
		assert_output --partial "outcome=broken"
	done
	# Delayed self-exit: lintro runs a while, then exits 124 on its own
	# (an elapsed-seconds heuristic misread this); the wrapper's own
	# "sending signal" diagnostic is the only evidence that counts. The
	# bound is generous so runner load cannot make it fire first.
	: >"$GITHUB_OUTPUT"
	bin="${BATS_TEST_TMPDIR}/lintro"
	printf '#!/usr/bin/env bash\nsleep 2.3\nexit 124\n' >"$bin"
	chmod +x "$bin"
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=30
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=broken"
	# lintro printing the wrapper's diagnostic itself is not evidence: the
	# wrapper's stderr is a separate stream.
	: >"$GITHUB_OUTPUT"
	printf '#!/usr/bin/env bash\necho "timeout: sending signal TERM to command lintro" >&2\nexit 124\n' >"$bin"
	chmod +x "$bin"
	run run_review LINTRO_BIN="$bin" BLOCKING=false REVIEW_TIMEOUT_SECONDS=60
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=broken"
}

@test "run: review bound is the cap remainder from preflight minus the margin" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin now
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	now="$(date +%s)"
	# 30-minute cap, preflight anchored 600s ago → 1800-600-240 = 960s.
	run run_review LINTRO_BIN="$bin" JOB_TIMEOUT_MINUTES=30 JOB_STARTED_AT=$((now - 600)) BLOCKING=false
	assert_success
	assert_output --regexp "review-timeout=9(59|60)s"
	# No anchor: measured from now.
	run run_review LINTRO_BIN="$bin" JOB_TIMEOUT_MINUTES=30 BLOCKING=false
	assert_success
	assert_output --regexp "review-timeout=15(59|60)s"
	# Test hook wins over the derivation.
	run run_review LINTRO_BIN="$bin" JOB_TIMEOUT_MINUTES=30 REVIEW_TIMEOUT_SECONDS=42 BLOCKING=false
	assert_success
	assert_output --partial "review-timeout=42s"
}

@test "run: too little cap left is timed-out without running lintro" {
	local bin="${BATS_TEST_TMPDIR}/lintro" now
	{
		echo '#!/usr/bin/env bash'
		echo "touch '${BATS_TEST_TMPDIR}/lintro-ran'"
		echo 'exit 0'
	} >"$bin"
	chmod +x "$bin"
	_mock_gh_comment 1900
	now="$(date +%s)"
	# 30-minute cap with 28 minutes already gone: 120-240 < 60.
	run run_review LINTRO_BIN="$bin" JOB_TIMEOUT_MINUTES=30 JOB_STARTED_AT=$((now - 1680)) BLOCKING=false
	assert_success
	assert_output --partial "job cap remained before the review could start"
	assert_output --partial "Re-run the job"
	refute_output --partial "Split the PR"
	[[ ! -e "${BATS_TEST_TMPDIR}/lintro-ran" ]]
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=timed-out"
	# lintro did not run, so there is no lintro exit code to report.
	assert_output --partial "exit-code=0"
}

@test "run: wrapper pins LC_ALL=C for itself but lintro keeps the caller's locale" {
	command -v timeout >/dev/null || skip "GNU timeout not installed"
	local bin="${BATS_TEST_TMPDIR}/lintro"
	{
		echo '#!/usr/bin/env bash'
		echo "printf '%s' \"\${LC_ALL:-unset}\" >'${BATS_TEST_TMPDIR}/lc'"
		printf 'cat <<'\''LINTRO_OUT'\''\n%s\nLINTRO_OUT\n' "$(success_json)"
		echo 'exit 0'
	} >"$bin"
	chmod +x "$bin"
	run run_review LINTRO_BIN="$bin" BLOCKING=false LC_ALL=fr_FR.UTF-8
	assert_success
	run cat "${BATS_TEST_TMPDIR}/lc"
	assert_output "fr_FR.UTF-8"
	# Empty LC_ALL in the caller's env: the shim unsets it for lintro.
	run run_review LINTRO_BIN="$bin" BLOCKING=false LC_ALL=
	assert_success
	run cat "${BATS_TEST_TMPDIR}/lc"
	assert_output "unset"
}

@test "run: without GNU timeout a 124 is broken, not timed-out" {
	# Only the wrapper's 124 means timed-out. With no `timeout` on PATH the
	# code is lintro's own and stays in the unexpected-exit branch.
	local bin
	bin="$(write_fake_lintro "" "boom" 124)"
	local empty_bin="${BATS_TEST_TMPDIR}/nopath"
	mkdir -p "$empty_bin"
	for tool in bash jq cat mktemp rm mkdir env dirname tr date; do
		ln -s "$(command -v "$tool")" "${empty_bin}/${tool}"
	done
	PATH="$empty_bin" run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	assert_output --partial "GNU timeout not found"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=broken"
}

@test "run: diff above max-diff-lines is skipped-size, neutral, and never runs lintro" {
	local bin="${BATS_TEST_TMPDIR}/lintro"
	{
		echo '#!/usr/bin/env bash'
		echo "touch '${BATS_TEST_TMPDIR}/lintro-ran'"
		echo 'exit 0'
	} >"$bin"
	chmod +x "$bin"
	_mock_gh_comment 2500
	run run_review LINTRO_BIN="$bin" BLOCKING=false MAX_DIFF_LINES=2000 \
		GH_TOKEN=workflow-token GITHUB_TOKEN=app-token
	assert_success
	assert_output --partial "::warning::AI review did not complete: the diff exceeds max-diff-lines=2000 (diff: 2500 lines)"
	[[ ! -e "${BATS_TEST_TMPDIR}/lintro-ran" ]]
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=skipped-size"
	run awk -v RS='--\n' '/pulls\/1/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "token=workflow-token"
	run awk -v RS='--\n' '/--method/' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_output --partial "repos/x/y/issues/1/comments"
	assert_output --partial "token=app-token"
}

@test "run: skipped-size fails when blocking (diff size is author-controlled)" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	_mock_gh_comment 2500
	run run_review LINTRO_BIN="$bin" BLOCKING=true MAX_DIFF_LINES=2000
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=skipped-size"
}

@test "run: diff at or below max-diff-lines runs the review" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	_mock_gh_comment 2000
	run run_review LINTRO_BIN="$bin" BLOCKING=false MAX_DIFF_LINES=2000
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
}

@test "run: size gate fails open with a notice when the lookup fails" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	_mock_gh_comment "not-a-number"
	run run_review LINTRO_BIN="$bin" BLOCKING=false MAX_DIFF_LINES=2000
	assert_success
	assert_output --partial "::notice::size gate: could not read the PR diff size"
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
}

@test "run: max-diff-lines=0 disables the size gate" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	_mock_gh_comment 999999
	run run_review LINTRO_BIN="$bin" BLOCKING=false MAX_DIFF_LINES=0
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
}

@test "run: real errors still fail alongside the neutral timeout path" {
	# Conclusion matrix guard: only a bound that fired maps to exit 0;
	# INCOMPLETE and unexpected codes keep reddening.
	local bin
	bin="$(write_fake_lintro '{"coverage":{"complete":false,"covered_at_head":1,"eligible":4}}' "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	bin="$(write_fake_lintro "" "boom" 7)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_failure
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=broken"
}

@test "preflight: emits the started-at epoch anchor for the review budget" {
	STEP=preflight EVENT_NAME=pull_request HEAD_REPO="x/y" BASE_REPO="x/y" \
		PR_NUMBER=1 run bash "$SCRIPT"
	assert_success
	run bash -c "grep -E '^started-at=[0-9]{10}' '$GITHUB_OUTPUT'"
	assert_success
}

@test "locate: writes empty run-id when gh is unavailable or lists nothing" {
	PATH="/usr/bin:/bin" STEP=locate GITHUB_REPOSITORY="x/y" PR_NUMBER=1 \
		GITHUB_RUN_ID=9 run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "run-id="
}

# Mock gh that applies --jq to a fixture (same as real `gh api --jq`) and
# answers run-status lookups. Artifact created_at order is newest-wins;
# numeric unique must not flip that to oldest-first.
_mock_gh_locate() {
	local artifacts_json="$1"
	local status_map="$2"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '%s' "$artifacts_json" >"${BATS_TEST_TMPDIR}/artifacts.json"
	printf '%s' "$status_map" >"${BATS_TEST_TMPDIR}/run_status.json"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
jq_filter=""
url=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	--jq)
		jq_filter="\$2"
		shift 2
		;;
	--paginate)
		shift
		;;
	api)
		shift
		;;
	*)
		if [[ -z "\$url" && "\$1" == repos/* ]]; then
			url="\$1"
		fi
		shift
		;;
	esac
done
if [[ "\$url" == *"/actions/artifacts"* ]]; then
	if [[ -n "\$jq_filter" ]]; then
		jq -r "\$jq_filter" "${BATS_TEST_TMPDIR}/artifacts.json"
	else
		cat "${BATS_TEST_TMPDIR}/artifacts.json"
	fi
	exit 0
fi
if [[ "\$url" == *"/actions/runs/"* ]]; then
	run_id="\${url##*/}"
	status="\$(jq -r --arg id "\$run_id" '.[\$id] // empty' "${BATS_TEST_TMPDIR}/run_status.json")"
	if [[ -n "\$jq_filter" ]]; then
		jq -r "\$jq_filter" <<<"{\"status\": \"\${status}\"}"
	else
		printf '%s\n' "\$status"
	fi
	exit 0
fi
echo "unexpected gh call url=\$url" >&2
exit 1
EOF
	chmod +x "${mock_bin}/gh"
	save_path
	export PATH="${mock_bin}:$PATH"
}

@test "locate: newest completed trusted run wins (not oldest unique id)" {
	# Older completed 100, newer completed 200, newest in-progress 300.
	# jq unique re-sorts ids 100,200,300 and would pick 100; newest-wins is 200.
	_mock_gh_locate "$(
		cat <<'JSON'
{"artifacts":[
  {"expired":false,"name":"lintro-review-state-pr-1-old","workflow_run":{"id":100},"created_at":"2020-01-01T00:00:00Z"},
  {"expired":false,"name":"lintro-review-state-pr-1-new","workflow_run":{"id":200},"created_at":"2024-01-01T00:00:00Z"},
  {"expired":false,"name":"lintro-review-state-pr-1-live","workflow_run":{"id":300},"created_at":"2025-01-01T00:00:00Z"},
  {"expired":false,"name":"lintro-review-state-pr-1-self","workflow_run":{"id":9},"created_at":"2026-01-01T00:00:00Z"}
]}
JSON
	)" '{"100":"completed","200":"completed","300":"in_progress","9":"completed"}'
	STEP=locate GITHUB_REPOSITORY="x/y" PR_NUMBER=1 GITHUB_RUN_ID=9 \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "run-id=200"
	# Guard against oldest-wins regressing while still matching the partial.
	run bash -c "grep -E '^run-id=' '$GITHUB_OUTPUT'"
	assert_output "run-id=200"
}

@test "run: invokes lintro with --pr --post --output json" {
	local bin="${BATS_TEST_TMPDIR}/lintro"
	{
		echo '#!/usr/bin/env bash'
		echo 'printf "%s\n" "$@" >"'"${BATS_TEST_TMPDIR}"'/args"'
		echo 'echo "{\"metadata\":{}}"'
		echo 'exit 0'
	} >"$bin"
	chmod +x "$bin"
	run run_review LINTRO_BIN="$bin"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/args"
	assert_output --partial "review"
	assert_output --partial "--pr"
	assert_output --partial "--post"
	assert_output --partial "--output"
	assert_output --partial "json"
}
