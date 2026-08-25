#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-ai-review.sh (preflight + exit contract)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-ai-review.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
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

@test "run: complete coverage does not trip the incomplete gate" {
	local bin
	bin="$(write_fake_lintro "$(success_json)" "" 0)"
	run run_review LINTRO_BIN="$bin" BLOCKING=false
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "outcome=reviewed"
}

@test "locate: writes empty run-id when gh is unavailable or lists nothing" {
	PATH="/usr/bin:/bin" STEP=locate GITHUB_REPOSITORY="x/y" PR_NUMBER=1 \
		GITHUB_RUN_ID=9 run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "run-id="
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
