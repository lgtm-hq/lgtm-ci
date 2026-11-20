#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: The comment file snapshot (#1716) of
# scripts/ci/actions/post-pr-comment.sh with
# scripts/ci/lib/github/comment_body_file.sh, and the notice that replaces a
# body over GitHub's limit, then fails the step (#1705)

load "../../../helpers/common"
load "../../../helpers/post_pr_comment_size"

setup() {
	post_pr_comment_size_setup
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# The load step snapshots the file without the token (#1716)
# =============================================================================

@test "load: the reader of the caller's file never has the token, even when the step does" {
	# Stand-in for a symlink to /proc/self/environ: a head that prints its own
	# environment instead of the file. The load step is given the token here
	# (a misconfigured caller); the reader still runs without it.
	local bin="${BATS_TEST_TMPDIR}/stub" real_head
	real_head="$(command -v head)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nif [[ " $* " == *" -c "* && " $* " == *" -- "* ]]; then env; exit 0; fi\nexec "%s" "$@"\n' \
		"$real_head" >"${bin}/head"
	chmod +x "${bin}/head"
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	local out="${BATS_TEST_TMPDIR}/load_output"
	: >"$out"
	run env PATH="${bin}:${PATH}" GH_TOKEN="$SECRET" GITHUB_TOKEN="$SECRET" STEP=load-file \
		COMMENT_FILE="${BATS_TEST_TMPDIR}/body.md" GITHUB_OUTPUT="$out" bash "$POSTER"
	assert_success
	LOAD_STATE="$(sed -n 's/^state=//p' "$out")"
	LOAD_SNAPSHOT="$(sed -n 's/^snapshot=//p' "$out")"
	LOAD_BYTES=""
	assert_equal "$LOAD_STATE" "ok"
	refute grep -q "$SECRET" "$LOAD_SNAPSHOT"
	grep -q "STEP=load-file" "$LOAD_SNAPSHOT"

	PATH="${bin}:${PATH}" _post_snapshot
	assert_success
	refute grep -q "$SECRET" "$GH_BODY"
	_assert_all_sent_fit
}

@test "load: a symlink to /proc/self/environ is refused with a red step (Linux)" {
	[[ -r /proc/self/environ ]] || skip "no /proc on this system"
	ln -s /proc/self/environ "${BATS_TEST_TMPDIR}/body.md"
	GH_TOKEN="$SECRET" run env STEP=load-file COMMENT_FILE="${BATS_TEST_TMPDIR}/body.md" \
		GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/load_output" bash "$POSTER"

	assert_failure
	assert_output --partial "::error::Cannot read comment file: ${BATS_TEST_TMPDIR}/body.md (it resolves under /proc, /sys or /dev)"
	refute_output --partial "$SECRET"
	run find "$RUNNER_TEMP" -type f
	assert_output ""
}

@test "load: the snapshot is private to the runner user, in RUNNER_TEMP, with an unpredictable name" {
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	_load "${BATS_TEST_TMPDIR}/body.md"

	assert_equal "$LOAD_STATUS" "0"
	assert_equal "$LOAD_STATE" "ok"
	assert_equal "${LOAD_SNAPSHOT%/*}" "$RUNNER_TEMP"
	[[ "${LOAD_SNAPSHOT##*/}" =~ ^lgtm-ci-comment-body\.[A-Za-z0-9]{10}$ ]]
	run find "$LOAD_SNAPSHOT" -perm 600
	assert_output "$LOAD_SNAPSHOT"
}

@test "load: a file swapped after the load step has no effect on what is posted" {
	printf '### ❌ FAILED\n' >"${BATS_TEST_TMPDIR}/body.md"
	_load "${BATS_TEST_TMPDIR}/body.md"
	printf '### ✅ PASSED\n' >"${BATS_TEST_TMPDIR}/body.md"
	rm -f "${BATS_TEST_TMPDIR}/body.md"
	ln -s /etc/hosts "${BATS_TEST_TMPDIR}/body.md"
	_post_snapshot

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
}

@test "post: a snapshot that is not the load step's is refused and nothing is posted" {
	local outside="${BATS_TEST_TMPDIR}/lgtm-ci-comment-body.outside1"
	printf 'secret file\n' >"$outside"
	printf 'real\n' >"${RUNNER_TEMP}/target"
	ln -s "${RUNNER_TEMP}/target" "${RUNNER_TEMP}/lgtm-ci-comment-body.symlinked"
	printf 'named wrong\n' >"${RUNNER_TEMP}/other-name"
	mkdir -p "${BATS_TEST_TMPDIR}/elsewhere"
	printf 'through a linked dir\n' >"${BATS_TEST_TMPDIR}/elsewhere/lgtm-ci-comment-body.viadir1"
	ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${RUNNER_TEMP}/linked"
	local snapshot
	for snapshot in "$outside" "${RUNNER_TEMP}/lgtm-ci-comment-body.symlinked" \
		"${RUNNER_TEMP}/lgtm-ci-comment-body.missing1" "${RUNNER_TEMP}/other-name" \
		"${RUNNER_TEMP}/linked/lgtm-ci-comment-body.viadir1" "lgtm-ci-comment-body.relative" ""; do
		LOAD_SNAPSHOT="$snapshot" LOAD_STATE=ok LOAD_BYTES=""
		_post_snapshot
		assert_failure
		assert_output --partial "::error::The comment file snapshot is not the file the load step wrote; nothing is posted"
	done
	LOAD_SNAPSHOT="${RUNNER_TEMP}/target" LOAD_STATE=ok LOAD_BYTES=""
	RUNNER_TEMP="" _post_snapshot
	assert_failure
	assert_output --partial "::error::The comment file snapshot cannot be checked: RUNNER_TEMP is not a directory"
	LOAD_STATE=whatever
	_post_snapshot
	assert_failure
	assert_output --partial "::error::The comment file snapshot has an unknown state; nothing is posted"
	run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
	assert_output "0"
}

@test "load: the path in a warning cannot start or end a workflow command" {
	local path="${BATS_TEST_TMPDIR}/a%b::c"$'\n'"::error::forged"
	_post_file "$path"

	assert_success
	run grep -c '^::' <<<"$output"
	assert_output "1"
	run grep '^::warning::' <<<"$LOAD_LOG"
	assert_output "::warning::Comment file not found: ${BATS_TEST_TMPDIR}/a%25b: :c%0A: :error: :forged"
}

@test "load: the earlier read-file step reads the file without the token" {
	local bin="${BATS_TEST_TMPDIR}/stub" real_cat
	real_cat="$(command -v cat)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nif (($# > 0)); then env; exit 0; fi\nexec "%s"\n' "$real_cat" >"${bin}/cat"
	chmod +x "${bin}/cat"
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	run env PATH="${bin}:${PATH}" GH_TOKEN="$SECRET" GITHUB_TOKEN="$SECRET" STEP=read-file \
		COMMENT_FILE="${BATS_TEST_TMPDIR}/body.md" bash "$POSTER"

	assert_success
	grep -q 'STEP=read-file' "$GITHUB_OUTPUT"
	refute grep -q "$SECRET" "$GITHUB_OUTPUT"
}

# =============================================================================
# The file: normalised as before, then bounded (#1716)
# =============================================================================

@test "file: NUL bytes are dropped before the size is decided, as before" {
	# Review case: 270,022 bytes, of which 270,000 NUL. On main this posted
	# the short report and exited 0.
	python3 -c 'import sys; open(sys.argv[1], "wb").write(b"### FAILED: 2 of 9 tests\n" + b"\0" * 270000)' \
		"${BATS_TEST_TMPDIR}/body.md"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(_commands)" "0"
	assert_equal "$(od -c "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "### FAILED: 2 of 9 tests" | od -c)"
}

@test "file: several MiB are never read in full and take the notice" {
	_stale_passed
	_write "${BATS_TEST_TMPDIR}/body.md" $((6 * 1024 * 1024))
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_equal "$LOAD_STATE" "oversized"
	_assert_notice "is 6,291,456 bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
}

@test "file: a file over the 64 MiB read cap is oversized without being read further" {
	_stale_passed
	python3 -c 'import sys; f = open(sys.argv[1], "wb"); f.truncate(65 * 1024 * 1024); f.close()' \
		"${BATS_TEST_TMPDIR}/body.md"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_equal "$LOAD_STATE" "oversized"
	_assert_notice "is over that limit"
}

@test "file: the body is the file less one trailing newline, as the read-file step delivered it" {
	printf '## Report\r\n\r\nline\n\n' >"${BATS_TEST_TMPDIR}/body.md"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(od -c "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" $'## Report\n\nline\n' | od -c)"
}

@test "file: the file takes precedence over the body input" {
	printf 'from the file\n' >"${BATS_TEST_TMPDIR}/body.md"
	BODY_FROM_INPUT="from the input" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "from the file")"
}

@test "file: a missing file, a directory or a device warns and skips, as before" {
	local path
	for path in "${BATS_TEST_TMPDIR}/missing.md" "$BATS_TEST_TMPDIR" /dev/null; do
		: >"$GITHUB_OUTPUT"
		_post_file "$path"
		assert_success
		assert_output --partial "::warning::Comment file not found: ${path}"
		assert_output --partial "Skipped: empty body"
		grep -q 'action-taken=skipped' "$GITHUB_OUTPUT"
	done
	assert [ ! -e "$GH_BODY" ]
}

@test "file: a missing file with delete-on-empty deletes the comment, as before" {
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")"
	DELETE_ON_EMPTY=true _post_file "${BATS_TEST_TMPDIR}/missing.md"

	assert_success
	grep -q 'action-taken=deleted' "$GITHUB_OUTPUT"
	run grep -c '^DELETE /repos/lgtm-hq/consumer/issues/comments/7 $' "$GH_CALLS"
	assert_output "1"
}

@test "file: an oversized file never counts as empty, even with delete-on-empty" {
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")"
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	DELETE_ON_EMPTY=true _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is 600,000 bytes"
	run grep -c '^DELETE ' "$GH_CALLS"
	assert_output "0"
}

@test "file: a symlink to a regular file is followed, as the read-file step did" {
	printf 'linked\n' >"${BATS_TEST_TMPDIR}/target.md"
	ln -s "${BATS_TEST_TMPDIR}/target.md" "${BATS_TEST_TMPDIR}/link.md"
	_post_file "${BATS_TEST_TMPDIR}/link.md"

	assert_success
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "linked")"
}

@test "file: a read that fails fails the load step and posts nothing" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\necho "head: read error" >&2\nexit 1\n' >"${bin}/head"
	chmod +x "${bin}/head"
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	PATH="${bin}:${PATH}" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_output --partial "::error::Cannot read comment file: ${BATS_TEST_TMPDIR}/body.md"
	assert [ ! -e "$GH_BODY" ]
}

# =============================================================================
# After the notice the step fails; paths that write nothing skip (#1705)
# =============================================================================

@test "fail: when posting the notice fails, the error says so and no notice is claimed" {
	_stale_passed
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	GH_WRITE_FAIL=1 _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary for this run is 600,000 bytes. Posting the notice that replaces it failed too (the API call failed); the previous comment is unchanged."
	refute_output --partial "was posted in its place"
	_assert_all_sent_fit
}

@test "fail: when not even the notice can be measured, nothing is posted" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${bin}/wc"
	chmod +x "${bin}/wc"
	PATH="${bin}:${PATH}" _post "### ✅ PASSED"

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary for this run could not be measured. The notice that would replace it cannot be posted: it cannot be measured within the limit either. Nothing was posted; the previous comment is unchanged."
	run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
	assert_output "0"
}

@test "fail: an invalid history setting on the oversized path says the notice could not be posted, once" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	local setting
	for setting in HISTORY_MAX_BYTES HISTORY_LIMIT; do
		: >"$GH_CALLS"
		export "${setting}=lots"
		_post_file "${BATS_TEST_TMPDIR}/body.md" true
		unset "$setting"
		assert_failure
		assert_equal "$(_commands)" "1"
		assert_output --partial "The notice that would replace it cannot be posted: composing it failed: post-pr-comment-history: ${setting} must be a non-negative integer, got 'lots'. Nothing was posted; the previous comment is unchanged."
		run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
		assert_output "0"
	done
}

@test "fail: a body that cannot be measured is replaced, not sent" {
	local bin="${BATS_TEST_TMPDIR}/stub" real_jq
	real_jq="$(command -v jq)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\n[[ " $* " == *utf8bytelength* ]] && exit 3\nexec "%s" "$@"\n' "$real_jq" >"${bin}/jq"
	chmod +x "${bin}/jq"
	PATH="${bin}:${PATH}" _post "### ✅ PASSED $(_pad 70000)"

	_assert_notice "could not be measured"
}

@test "skip: update mode without a comment, an unknown mode and a fork post nothing and do not fail" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	MODE=update _post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_output --partial "Skipped: no existing comment to update"
	assert_equal "$(_commands)" "0"

	MODE=sideways _post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_success
	assert_equal "$(_commands)" "0"

	_load "${BATS_TEST_TMPDIR}/body.md"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=fork/consumer \
		BODY_SNAPSHOT="$LOAD_SNAPSHOT" BODY_SNAPSHOT_STATE="$LOAD_STATE" BODY_SNAPSHOT_BYTES="$LOAD_BYTES" \
		bash "$POSTER"
	assert_success
	assert_output --partial "Skipped: fork PR cannot receive workflow comments"
	assert [ ! -e "$GH_BODY" ]
}

# =============================================================================
# The notice (#1705)
# =============================================================================

@test "notice: the next normal run updates the same comment" {
	_stale_passed
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	_post_file "${BATS_TEST_TMPDIR}/body.md"
	assert_failure

	_set_listing 7 "$(cat "$GH_BODY")"
	: >"$GH_CALLS"
	_post "### ❌ FAILED"
	assert_success
	assert_equal "$(_commands)" "0"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 field$' "$GH_CALLS"
	assert_output "1"
	assert_equal "$(cat "$GH_BODY")" "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
}

@test "notice: the reserved namespace and comment-fields of an oversized body never reach it" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000 r $'<!-- lgtm-ci:other -->\n<!-- lgtm-ci:history:latest sha=x run=999 attempt=1 number=9 at=y -->\n'
	COMMENT_FIELDS="Status: PASSED" _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
	run grep -c 'lgtm-ci:' "$GH_BODY"
	assert_output "1"
	_refute_fields_messages
}

@test "notice: comment-fields messages still show when the body is posted" {
	COMMENT_FIELDS="Env: staging" _post "## Report"

	assert_success
	assert_output --partial "comment-fields: 1 field shown."
}

@test "notice: without a run id or a commit id it points at the pull request's checks" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	GITHUB_RUN_ID="" EVENT_PULL_REQUEST_HEAD_SHA="not-a-sha" GITHUB_SHA="" \
		_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	run cat "$GH_BODY"
	assert_output --partial "> The summary for this run is 600,000 bytes, so it is not shown."
	assert_output --partial "see this pull request's checks for the outcome."
	refute_output --partial "](http"
}
