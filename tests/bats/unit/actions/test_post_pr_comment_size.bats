#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: The comment file snapshot (#1716) of
# scripts/ci/actions/post-pr-comment.sh with
# scripts/ci/lib/github/comment_body_file.sh, and the notice that replaces a
# body over GitHub's limit, then fails the step (#1705)

load "../../../helpers/common"
load "../../../helpers/post_pr_comment_size"

bats_require_minimum_version 1.5.0

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
	assert_equal "${LOAD_SNAPSHOT%/*}" "$(cd -P "$RUNNER_TEMP" && pwd -P)"
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
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
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
	_assert_notice "summary file" "is 6,291,456 bytes"
	run grep -c '^PATCH /repos/lgtm-hq/consumer/issues/comments/7 ' "$GH_CALLS"
	assert_output "1"
}

@test "file: a file over the 64 MiB read cap is oversized without being read further" {
	_stale_passed
	python3 -c 'import sys; f = open(sys.argv[1], "wb"); f.truncate(65 * 1024 * 1024); f.close()' \
		"${BATS_TEST_TMPDIR}/body.md"
	_post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_equal "$LOAD_STATE" "oversized"
	_assert_notice "summary file" "is over 67,108,864 bytes"
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
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "from the file")"
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

	_assert_notice "summary file" "is 600,000 bytes"
	run grep -c '^DELETE ' "$GH_CALLS"
	assert_output "0"
}

@test "file: a symlink to a regular file is followed, as the read-file step did" {
	printf 'linked\n' >"${BATS_TEST_TMPDIR}/target.md"
	ln -s "${BATS_TEST_TMPDIR}/target.md" "${BATS_TEST_TMPDIR}/link.md"
	_post_file "${BATS_TEST_TMPDIR}/link.md"

	assert_success
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "linked")"
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
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the summary file for this run is 600,000 bytes. Posting the notice that replaces it failed too (the API call failed); the previous comment is unchanged."
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
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the comment for this run could not be measured. The notice that would replace it cannot be posted: it cannot be measured within the limit either. Nothing was posted; the previous comment is unchanged."
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

	_assert_notice comment "could not be measured"
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
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "### ❌ FAILED")"
}

@test "notice: the reserved namespace and comment-fields of an oversized body never reach it" {
	_write "${BATS_TEST_TMPDIR}/body.md" 600000 r $'<!-- lgtm-ci:other -->\n<!-- lgtm-ci:history:latest sha=x run=999 attempt=1 number=9 at=y -->\n'
	COMMENT_FIELDS="Status: PASSED" _post_file "${BATS_TEST_TMPDIR}/body.md"

	_assert_notice "summary file" "is $(_fmt "$(_bytes "${BATS_TEST_TMPDIR}/body.md")") bytes"
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
	assert_output --partial "> The summary file for this run is 600,000 bytes, so the summary is not shown."
	assert_output --partial "see this pull request's checks for the outcome."
	refute_output --partial "](http"
}

# =============================================================================
# The reader: one bounded byte stream (#1716, third review)
# =============================================================================

# A UTF-8 locale this system has, for the locale cases.
_utf8_locale() {
	locale -a 2>/dev/null | grep -iE '^(C\.UTF-?8|en_US\.UTF-?8)$' | head -n 1
}

@test "reader: with SIGPIPE ignored, as on the runners, a file over the snapshot bound is oversized" {
	# Review case: a closed pipe there is an error (EPIPE), not a signal.
	_stale_passed
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	local out="${BATS_TEST_TMPDIR}/load_output"
	: >"$out"
	run bash -c 'trap "" PIPE; exec env -u GH_TOKEN STEP=load-file COMMENT_FILE="$1" GITHUB_OUTPUT="$2" bash "$3"' \
		_ "${BATS_TEST_TMPDIR}/body.md" "$out" "$POSTER"

	assert_success
	refute_output --partial "Cannot read comment file"
	run sed -n 's/^state=//p' "$out"
	assert_output "oversized"
	run sed -n 's/^bytes=//p' "$out"
	assert_output "600000"
}

@test "reader: with SIGPIPE ignored, a file within the bound loads and posts" {
	printf '### FAILED\n' >"${BATS_TEST_TMPDIR}/body.md"
	local out="${BATS_TEST_TMPDIR}/load_output"
	: >"$out"
	run bash -c 'trap "" PIPE; exec env -u GH_TOKEN STEP=load-file COMMENT_FILE="$1" GITHUB_OUTPUT="$2" bash "$3"' \
		_ "${BATS_TEST_TMPDIR}/body.md" "$out" "$POSTER"
	assert_success
	LOAD_STATE="$(sed -n 's/^state=//p' "$out")"
	LOAD_SNAPSHOT="$(sed -n 's/^snapshot=//p' "$out")"
	LOAD_BYTES=""
	assert_equal "$LOAD_STATE" "ok"
	_post_snapshot
	assert_success
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "### FAILED")"
}

@test "reader: invalid UTF-8 loads under a UTF-8 locale, as on main" {
	# Review case: macOS tr rejected these bytes under a UTF-8 locale.
	local utf8
	utf8="$(_utf8_locale)"
	[[ -n "$utf8" ]] || skip "no UTF-8 locale on this system"
	printf 'failed \x80\xed\xa0\x80 tail\n' >"${BATS_TEST_TMPDIR}/body.md"
	LC_ALL="$utf8" LANG="$utf8" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "$LOAD_STATE" "ok"
	assert_equal "$(od -c "$GH_BODY")" "$(printf '%s\nfailed \x80\xed\xa0\x80 tail' "$MARKER_LINE" | od -c)"
}

# _growing_head GROW_ON: a head stand-in for the caller's body.md: the first
# open reads it as it is (7 bytes); from open GROW_ON on it reads the file
# grown past the raw cap (prefix, NUL padding, END), as a file still being
# written would. Every open is logged in "reads".
_growing_head() {
	local bin="${BATS_TEST_TMPDIR}/stub" real_head big="${BATS_TEST_TMPDIR}/big.md"
	real_head="$(command -v head)"
	python3 -c 'import sys; f = open(sys.argv[1], "wb"); f.write(b"prefix\n"); f.truncate(65 * 1024 * 1024); f.seek(0, 2); f.write(b"END"); f.close()' "$big"
	printf 'prefix\n' >"${BATS_TEST_TMPDIR}/body.md"
	mkdir -p "$bin"
	cat >"${bin}/head" <<EOF
#!/usr/bin/env bash
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
	if [[ "\${args[i]}" == "\$(cd -P "${BATS_TEST_TMPDIR}" && pwd -P)/body.md" ]]; then
		printf 'read\n' >>"${BATS_TEST_TMPDIR}/reads"
		if (( \$(wc -l <"${BATS_TEST_TMPDIR}/reads") >= $1 )); then
			args[i]="$big"
		fi
	fi
done
exec "$real_head" "\${args[@]}"
EOF
	chmod +x "${bin}/head"
}

@test "reader: the caller's file is read once, so a file that grows is never posted truncated" {
	# Review case: the count and the snapshot came from two reads; a file that
	# grew past the cap between them gave state=ok and its first bytes were
	# posted as if complete. One read gives both now.
	_growing_head 2
	_stale_passed
	PATH="${BATS_TEST_TMPDIR}/stub:${PATH}" _post_file "${BATS_TEST_TMPDIR}/body.md"

	run grep -c '^read$' "${BATS_TEST_TMPDIR}/reads"
	assert_output "1"
	assert_success
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "prefix")"
}

@test "reader: a read that reaches the raw cap is oversized" {
	_growing_head 1
	_stale_passed
	PATH="${BATS_TEST_TMPDIR}/stub:${PATH}" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_equal "$LOAD_STATE" "oversized"
	_assert_notice "summary file" "is over 67,108,864 bytes"
}

@test "reader: a read that fails part-way is never handed over, and nothing is posted" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nif [[ " $* " == *" -- "* ]]; then printf "partial report"; exit 1; fi\nexec %q "$@"\n' \
		"$(command -v head)" >"${bin}/head"
	chmod +x "${bin}/head"
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")"
	printf 'the whole report\n' >"${BATS_TEST_TMPDIR}/body.md"
	DELETE_ON_EMPTY=true PATH="${bin}:${PATH}" _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_failure
	assert_output --partial "(the read did not finish cleanly)"
	assert [ ! -e "$GH_BODY" ]
	run grep -cE '^(POST|PATCH|DELETE) ' "$GH_CALLS"
	assert_output "0"
	run find "$RUNNER_TEMP" -name 'lgtm-ci-comment-*'
	assert_output ""
}

@test "reader: a file name that ends in a newline is read, not taken for missing" {
	# Review case: command substitution dropped the name's own newline, the
	# file counted as missing and delete-on-empty removed the comment.
	local name="${BATS_TEST_TMPDIR}/trailing-newline"$'\n'
	printf 'FAILED report\n' >"$name"
	ln -s "$name" "${BATS_TEST_TMPDIR}/link.md"
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")"
	local path
	for path in "$name" "${BATS_TEST_TMPDIR}/link.md"; do
		: >"$GH_CALLS"
		DELETE_ON_EMPTY=true _post_file "$path"
		assert_success
		assert_equal "$LOAD_STATE" "ok"
		_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "FAILED report")"
		run grep -c '^DELETE ' "$GH_CALLS"
		assert_output "0"
	done
}

@test "reader: without realpath the fallback resolves paths to the same answer" {
	command -v realpath >/dev/null 2>&1 || skip "no realpath to compare with"
	local d="${BATS_TEST_TMPDIR}/tree"
	mkdir -p "$d/a/b" "$d/c"
	printf 'x' >"$d/a/b/file.md"
	printf 'y' >"$d/a/b/name"$'\n'
	ln -s "$d/a/b/file.md" "$d/abs-link"
	ln -s "b/file.md" "$d/a/rel-link"
	ln -s "../a/rel-link" "$d/c/chain"
	ln -s "$d/a/b" "$d/c/dir-link"
	ln -s "$d/a/b/name"$'\n' "$d/c/nl-link"
	local path want got
	for path in "$d/a/b/file.md" "$d/abs-link" "$d/a/rel-link" "$d/c/chain" \
		"$d/c/dir-link/file.md" "$d/c/dir-link/../b/file.md" "$d/c/nl-link" \
		"$d/a/b/name"$'\n' "$d/c/./chain"; do
		want="$(realpath -- "$path"; printf x)"
		want="${want%x}"
		want="${want%$'\n'}"
		got="$(
			source "${PROJECT_ROOT}/scripts/ci/lib/github/comment_body_file.sh"
			comment_body_resolve_fallback "$path"
		)"
		assert_equal "${got%x}" "$want"
	done
	run bash -c 'source "$1"; comment_body_resolve_fallback "$2"' _ \
		"${PROJECT_ROOT}/scripts/ci/lib/github/comment_body_file.sh" "$d/nowhere/file.md"
	assert_failure
}

# =============================================================================
# The hand-off fails closed (#1716, third review)
# =============================================================================

@test "hand-off: a file was given but the load step reported no state: nothing posted or deleted" {
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=lgtm-hq/consumer \
		BODY_FILE_GIVEN=true BODY_SNAPSHOT_STATE="" BODY_FROM_INPUT="" DELETE_ON_EMPTY=true bash "$POSTER"

	assert_failure
	assert_output --partial "::error::A comment file was given but the load step reported no state; nothing is posted or deleted"
	run grep -cE '^(POST|PATCH|DELETE) ' "$GH_CALLS"
	assert_output "0"
}

@test "hand-off: a snapshot path through .. out of RUNNER_TEMP is refused" {
	mkdir -p "${BATS_TEST_TMPDIR}/elsewhere/deep"
	printf 'OUTSIDE-SECRET\n' >"${BATS_TEST_TMPDIR}/elsewhere/lgtm-ci-comment-body.dotdot1"
	ln -s "${BATS_TEST_TMPDIR}/elsewhere/deep" "${RUNNER_TEMP}/sub"
	LOAD_SNAPSHOT="${RUNNER_TEMP}/sub/../lgtm-ci-comment-body.dotdot1" LOAD_STATE=ok LOAD_BYTES=""
	_post_snapshot

	assert_failure
	assert_output --partial "::error::The comment file snapshot is not the file the load step wrote; nothing is posted"
	assert [ ! -e "$GH_BODY" ]
	assert [ -e "${BATS_TEST_TMPDIR}/elsewhere/lgtm-ci-comment-body.dotdot1" ]
}

@test "hand-off: a checked snapshot is removed on every exit; one that fails the checks never is" {
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	# A fork skip.
	_load "${BATS_TEST_TMPDIR}/body.md"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=fork/consumer \
		BODY_SNAPSHOT="$LOAD_SNAPSHOT" BODY_SNAPSHOT_STATE=ok bash "$POSTER"
	assert_success
	assert [ ! -e "$LOAD_SNAPSHOT" ]
	# A bad marker.
	_load "${BATS_TEST_TMPDIR}/body.md"
	MARKER=$'two\nlines' _post_snapshot
	assert_failure
	assert [ ! -e "$LOAD_SNAPSHOT" ]
	# A read that fails.
	_load "${BATS_TEST_TMPDIR}/body.md"
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${bin}/head"
	chmod +x "${bin}/head"
	PATH="${bin}:${PATH}" _post_snapshot
	assert_failure
	assert_output --partial "::error::The comment file snapshot cannot be read; nothing is posted"
	assert [ ! -e "$LOAD_SNAPSHOT" ]
	# A path that fails the checks stays.
	local outside="${BATS_TEST_TMPDIR}/lgtm-ci-comment-body.keepme"
	printf 'not ours\n' >"$outside"
	LOAD_SNAPSHOT="$outside" LOAD_STATE=ok
	_post_snapshot
	assert_failure
	assert [ -e "$outside" ]
}

@test "hand-off: when the load step's outputs cannot be written, its snapshot is removed" {
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	mkdir -p "${BATS_TEST_TMPDIR}/output-is-a-directory"
	run env -u GH_TOKEN STEP=load-file COMMENT_FILE="${BATS_TEST_TMPDIR}/body.md" \
		GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output-is-a-directory" bash "$POSTER"

	assert_failure
	assert_output --partial "::error::Cannot hand the comment file over to the post step: its outputs could not be written"
	run find "$RUNNER_TEMP" -name 'lgtm-ci-comment-*'
	assert_output ""
}

@test "hand-off: a Windows RUNNER_TEMP is turned into a POSIX path with cygpath" {
	# Stand-in for Git Bash on a Windows runner: RUNNER_TEMP is D:\a\_temp and
	# cygpath maps it; the same checks then apply. Not run on Windows here.
	local bin="${BATS_TEST_TMPDIR}/stub" posix
	posix="$(cd -P "$RUNNER_TEMP" && pwd -P)"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\n[[ "$1" == "-u" && "$3" == "D:\\\\a\\\\_temp" ]] || exit 1\nprintf "%%s\\n" %q\n' \
		"$posix" >"${bin}/cygpath"
	chmod +x "${bin}/cygpath"
	printf 'report from windows\n' >"${BATS_TEST_TMPDIR}/body.md"
	PATH="${bin}:${PATH}" RUNNER_TEMP='D:\a\_temp' _post_file "${BATS_TEST_TMPDIR}/body.md"

	assert_success
	assert_equal "${LOAD_SNAPSHOT%/*}" "$posix"
	_assert_sent_body "$(printf '%s\n%s' "$MARKER_LINE" "report from windows")"
	assert [ ! -e "$LOAD_SNAPSHOT" ]
}

@test "hand-off: an invalid history setting in the first composition of an oversized result says the notice could not be posted" {
	_write "${BATS_TEST_TMPDIR}/body.md" 300000
	local setting
	for setting in HISTORY_MAX_BYTES HISTORY_LIMIT; do
		: >"$GH_CALLS"
		export "${setting}=lots"
		_post_file "${BATS_TEST_TMPDIR}/body.md" true
		unset "$setting"
		assert_failure
		assert_equal "$(_commands)" "1"
		assert_output --partial "the comment for this run would be 300,029 bytes. The notice that would replace it cannot be posted: composing it failed: post-pr-comment-history: ${setting} must be a non-negative integer, got 'lots'."
		run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
		assert_output "0"
	done
}

@test "hand-off: an invalid history setting on a result within the limit fails as on main" {
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	HISTORY_LIMIT=lots _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_failure
	assert_output --partial "::error::post-pr-comment-history: HISTORY_LIMIT must be a non-negative integer, got 'lots'"
	refute_output --partial "Summary too long"
}

@test "annotations: an account warning stays, and the size decision is logged once" {
	# Workflow commands are read from the post step's stdout alone: a shell
	# trace on stderr (under coverage) must not be counted or split them.
	_write "${BATS_TEST_TMPDIR}/body.md" 600000
	_load "${BATS_TEST_TMPDIR}/body.md"
	run --separate-stderr env GH_VIEWER_FAIL=1 STEP=post EVENT_NAME=pull_request \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=lgtm-hq/consumer BODY_SNAPSHOT="$LOAD_SNAPSHOT" \
		BODY_SNAPSHOT_STATE="$LOAD_STATE" BODY_SNAPSHOT_BYTES="$LOAD_BYTES" bash "$POSTER"

	assert_failure
	local log="$output"
	run grep -c '^::warning::post-pr-comment: could not determine the account' <<<"$log"
	assert_output "1"
	run grep -c 'Summary too long to post' <<<"$log"
	assert_output "1"
	run grep -cE '^::(warning|error)' <<<"$log"
	assert_output "2"
}

# =============================================================================
# Tiny files, counted with wc (#1716, fourth review)
# =============================================================================

# _load_bytes NAME BYTES: write BYTES (printf escapes) to NAME and load it.
_load_bytes() {
	printf "$2" >"${BATS_TEST_TMPDIR}/$1"
	_load "${BATS_TEST_TMPDIR}/$1"
}

@test "tiny: files of 0, 1 and 2 bytes, one LF and one NUL load and post as on main" {
	# Review case: GNU dd prints "1 byte copied", which the count parser did
	# not read, so a one-byte file failed on the runners.
	_load_bytes empty ''
	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
	_load_bytes one 'x'
	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
	_post_snapshot
	assert_success
	_assert_sent_body "$(printf '%s\nx' "$MARKER_LINE")"
	rm -f "$GH_BODY"
	_load_bytes two 'xy'
	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
	_post_snapshot
	_assert_sent_body "$(printf '%s\nxy' "$MARKER_LINE")"
	_load_bytes lf '\n'
	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
	_load_bytes nul '\000'
	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
}

@test "tiny: one LF or one NUL with delete-on-empty deletes the comment, as on main" {
	local name
	for name in lf nul; do
		_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "old")"
		: >"$GH_CALLS"
		case "$name" in
		lf) _load_bytes lf '\n' ;;
		nul) _load_bytes nul '\000' ;;
		esac
		assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
		BODY_FILE_GIVEN=true DELETE_ON_EMPTY=true _post_snapshot
		assert_success
		run grep -c '^DELETE /repos/lgtm-hq/consumer/issues/comments/7 $' "$GH_CALLS"
		assert_output "1"
	done
}

@test "tiny: the count does not depend on how a tool words its messages" {
	# A dd that words its report as GNU dd does for one byte ("1 byte
	# copied") and a sed that would see it: the reader counts with wc -c, so
	# neither is consulted and a one-byte file loads.
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nn="$(cat | tee /dev/stdout | wc -c)"\n[[ "${n// /}" == 1 ]] && echo "1 byte copied, 0 s, 1 B/s" >&2 || echo "${n// /} bytes copied, 0 s" >&2\n' >"${bin}/dd"
	chmod +x "${bin}/dd"
	PATH="${bin}:${PATH}" _load_bytes one 'x'

	assert_equal "$LOAD_STATUS/$LOAD_STATE" "0/ok"
	assert_equal "$(cat "$LOAD_SNAPSHOT")" "x"
}

@test "fallback: an exported CDPATH does not change how a relative path resolves" {
	# Review case: cd followed CDPATH and printed the directory, so an
	# existing file was reported missing (and delete-on-empty could fire).
	local d="${BATS_TEST_TMPDIR}/cdpath"
	mkdir -p "$d/work/reports" "$d/elsewhere/reports"
	printf 'here\n' >"$d/work/reports/r.md"
	local got want
	want="$(CDPATH='' cd -P "$d/work/reports" && pwd -P)/r.md"
	got="$(
		cd "$d/work" || exit 1
		export CDPATH="$d/elsewhere"
		source "${PROJECT_ROOT}/scripts/ci/lib/github/comment_body_file.sh"
		comment_body_resolve_fallback reports/r.md
	)"
	assert_equal "${got%x}" "$want"
}

@test "hand-off: an invalid history setting with a result over the limit only once encoded says the notice could not be posted" {
	# Review case: 100,000 stray continuation bytes are 100,029 bytes raw and
	# 300,029 once encoded; the wrapper measured the raw bytes.
	_write "${BATS_TEST_TMPDIR}/body.md" 100000 '\x80'
	HISTORY_LIMIT=lots _post_file "${BATS_TEST_TMPDIR}/body.md" true

	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "the comment for this run would be 300,029 bytes. The notice that would replace it cannot be posted: composing it failed: post-pr-comment-history: HISTORY_LIMIT must be a non-negative integer, got 'lots'."
	run grep -cE '^(POST|PATCH) ' "$GH_CALLS"
	assert_output "0"
}

@test "load: killed mid-read, the load step leaves no copy of the file in RUNNER_TEMP" {
	# A stand-in head that takes two seconds to read the caller's file; the
	# step is sent TERM while it reads.
	local bin="${BATS_TEST_TMPDIR}/stub" pid status=0 i
	mkdir -p "$bin"
	printf '#!/usr/bin/env bash\nif [[ " $* " == *" -- "* ]]; then sleep 2; exit 0; fi\nexec %q "$@"\n' \
		"$(command -v head)" >"${bin}/head"
	chmod +x "${bin}/head"
	printf 'report\n' >"${BATS_TEST_TMPDIR}/body.md"
	env -u GH_TOKEN PATH="${bin}:${PATH}" STEP=load-file COMMENT_FILE="${BATS_TEST_TMPDIR}/body.md" \
		GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/load_output" bash "$POSTER" >/dev/null 2>&1 &
	pid=$!
	for ((i = 0; i < 50; i++)); do
		[[ -z "$(find "$RUNNER_TEMP" -name 'lgtm-ci-comment-count.*')" ]] || break
		sleep 0.1
	done
	kill -TERM "$pid"
	wait "$pid" || status=$?

	assert_equal "$status" "143"
	run find "$RUNNER_TEMP" -name 'lgtm-ci-comment-*'
	assert_output ""
}

@test "old bash: the non-history paths that create no temp file exit cleanly" {
	# Before bash 4.4 an empty array is "unbound" under set -u, which the
	# post step's cleanup must not trip over. Runs where the system bash is
	# that old (macOS's 3.2); the history composer itself needs bash 4.
	local old_bash=/bin/bash
	[[ -x "$old_bash" ]] && "$old_bash" -c '((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)))' ||
		skip "no bash older than 4.4 at /bin/bash"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=lgtm-hq/consumer \
		BODY_FROM_INPUT="### FAILED" "$old_bash" "$POSTER"
	assert_success
	refute_output --partial "unbound variable"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=fork/consumer \
		BODY_FROM_INPUT="### FAILED" "$old_bash" "$POSTER"
	assert_success
	refute_output --partial "unbound variable"
	run env STEP=post EVENT_NAME=pull_request EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME=lgtm-hq/consumer \
		BODY_SNAPSHOT_STATE=missing BODY_FILE_GIVEN=true "$old_bash" "$POSTER"
	assert_success
	refute_output --partial "unbound variable"
}
