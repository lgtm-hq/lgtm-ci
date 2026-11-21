#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared harness of the post-pr-comment size tests (#1705, #1716):
# test_post_pr_comment_size.bats, test_post_pr_comment_byte_limit.bats and
# test_post_pr_comment_history_budget.bats. The cases are split across files
# so that the coverage shards share the cost of the 262,144-byte bodies.
#
# Large content never goes through an argument or an environment variable
# here (Linux caps each at 128 KiB): bodies and listings are files.
# shellcheck disable=SC2034 # read by the test files that load this helper

POSTER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment.sh"
HELPER="${PROJECT_ROOT}/scripts/ci/actions/post-pr-comment-history.sh"
MARKER_LINE='<!-- lgtm-ci:test-marker -->'
RUN_URL_200='https://github.com/lgtm-hq/consumer/actions/runs/200'
# GitHub's limit on a comment body, in bytes.
LIMIT=262144
SECRET="dummy-secret-1705-do-not-post"

# --- Large comments built straight into files ---------------------------------
# Under coverage every traced shell line that expands a large string costs
# time, so these builders write with python and the assertions below read
# files with external tools; no large body passes through a shell variable.

# _history_file FILE KIND PAD: an existing own history comment, written to
# FILE. KIND "passed": run 100 on top that said PASSED (with a summary), its
# body padded with PAD bytes. KIND "two": run 100 on top and run 50 archived,
# each body padded with PAD bytes.
_history_file() {
	python3 - "$1" "$2" "$3" "$MARKER_LINE" <<'PY'
import base64
import sys

path, kind, pad, marker = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
stamp = ("<!-- lgtm-ci:history:latest sha=1111111111111111111111111111111111111111"
         " run=100 attempt=1 number=1 at=2026-11-19T12:00:00Z")
if kind == "passed":
    summary = base64.b64encode(b"all 42 passed").decode()
    text = f"{marker}\n{stamp} summary={summary} -->\n### ✅ PASSED (run 100)" + "p" * pad
else:
    text = (
        f"{marker}\n{stamp} -->\n### run 100 " + "p" * pad
        + "\n\n---\n\n<details><summary>\U0001f558 Previous runs (1)</summary>\n\n"
        + "<!-- lgtm-ci:history:start -->\n"
        + "<!-- lgtm-ci:history:entry sha=5555555555555555555555555555555555555555"
        + " run=50 attempt=1 number=0 at=2026-11-18T12:00:00Z -->\n"
        + "<details><summary>Run #0</summary>\n\n### run 50 " + "q" * pad
        + "\n\n</details>\n\n<!-- lgtm-ci:history:end -->\n\n</details>"
    )
with open(path, "w", encoding="utf-8") as out:
    out.write(text)
PY
}

# _archive_file FILE N BYTES [TEXT]: an existing comment whose archive holds
# runs 1..N (newest last) and whose latest is run N+1, each archived body
# BYTES copies of TEXT (default a).
_archive_file() {
	python3 - "$1" "$2" "$3" "${4:-a}" "$MARKER_LINE" <<'PY'
import sys

path, n, size, text, marker = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
blocks = ""
for i in range(n, 0, -1):
    blocks += f"<!-- lgtm-ci:history:entry sha=s{i} run={i} attempt=1 number={i} at=t -->\n"
    blocks += f"<details><summary>Run #{i}</summary>\n\nrun {i} " + text * size + "\n\n</details>\n"
with open(path, "w", encoding="utf-8") as out:
    out.write(
        f"{marker}\n<!-- lgtm-ci:history:latest sha=s{n + 1} run={n + 1} attempt=1 number={n + 1} at=t -->\n"
        f"latest {n + 1}\n\n---\n\n<details><summary>\U0001f558 Previous runs ({n})</summary>\n\n"
        "<!-- lgtm-ci:history:start -->\n" + blocks + "<!-- lgtm-ci:history:end -->\n\n</details>\n"
    )
PY
}

# _set_listing_file ID FILE: the listing the gh stub prints: one own comment
# with the body in FILE.
_set_listing_file() {
	local list="${BATS_TEST_TMPDIR}/listing"
	jq -n --argjson id "$1" --rawfile body "$2" \
		'[{id: $id, user: {login: "github-actions[bot]", id: 41898282, type: "Bot"}, body: $body}]' >"$list"
	export GH_LIST_FILE="$list"
}

# _has FILE TEXT / _lacks FILE TEXT: FILE contains, or does not contain, TEXT.
_has() {
	grep -qF -- "$2" "$1" || {
		echo "expected in $1: $2" >&2
		return 1
	}
}
_lacks() {
	if grep -qF -- "$2" "$1"; then
		echo "not expected in $1: $2" >&2
		return 1
	fi
}

# _line_starts FILE N PREFIX: line N of FILE starts with PREFIX (only its
# first bytes are read into the shell).
_line_starts() {
	# Compared byte for byte inside awk (C locale): only the verdict and, on
	# a mismatch, the line's first 80 bytes come back.
	LC_ALL=C awk -v n="$2" -v prefix="$3" '
		NR == n { found = 1; if (index($0, prefix) == 1) exit 0; print "line " n " starts with: " substr($0, 1, 80) > "/dev/stderr"; exit 1 }
		END { if (!found) { print "no line " n > "/dev/stderr"; exit 1 } }' "$1"
}

# Set what bats' `run` would: status, output and lines.
# Usage: _set_run STATUS OUTPUT
_set_run() {
	status="$1"
	output="$2"
	mapfile -t lines <<<"$output"
}

# _post BODY [HISTORY]: post BODY given as the body input (small bodies only).
_post() {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_FROM_INPUT="$1" \
		HISTORY="${2:-false}" \
		bash "$POSTER"
}

# _load PATH: the action's load step on PATH, without the token. Sets
# LOAD_STATUS, LOAD_LOG (its stdout, where workflow commands go; stderr is
# kept apart, since under kcov it carries the trace), LOAD_STATE,
# LOAD_SNAPSHOT and LOAD_BYTES.
_load() {
	local out="${BATS_TEST_TMPDIR}/load_output"
	: >"$out"
	LOAD_STATUS=0
	LOAD_LOG="$(env -u GH_TOKEN STEP=load-file COMMENT_FILE="$1" GITHUB_OUTPUT="$out" \
		bash "$POSTER" 2>"${BATS_TEST_TMPDIR}/load_stderr")" || LOAD_STATUS=$?
	LOAD_STATE="$(sed -n 's/^state=//p' "$out")"
	LOAD_SNAPSHOT="$(sed -n 's/^snapshot=//p' "$out")"
	LOAD_BYTES="$(sed -n 's/^bytes=//p' "$out")"
}

# _post_snapshot [HISTORY]: the post step on the last _load's outputs.
_post_snapshot() {
	run env \
		STEP="post" \
		EVENT_NAME="pull_request" \
		EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME="lgtm-hq/consumer" \
		BODY_SNAPSHOT="$LOAD_SNAPSHOT" \
		BODY_SNAPSHOT_STATE="$LOAD_STATE" \
		BODY_SNAPSHOT_BYTES="$LOAD_BYTES" \
		HISTORY="${1:-false}" \
		bash "$POSTER"
}

# _post_file PATH [HISTORY]: the action's two steps on the file at PATH. The
# output holds both logs; the status is the load step's when it failed.
_post_file() {
	_load "$1"
	if ((LOAD_STATUS != 0)); then
		_set_run "$LOAD_STATUS" "$LOAD_LOG"
		return 0
	fi
	_post_snapshot "${2:-false}"
	_set_run "$status" "${LOAD_LOG:+${LOAD_LOG}$'\n'}${output}"
}

# _set_listing [ID BODY]...: the listing the gh stub prints, one own comment
# per pair, built through files.
_set_listing() {
	local list="${BATS_TEST_TMPDIR}/listing"
	: >"${list}.items"
	while (($# >= 2)); do
		printf '%s' "$2" >"${list}.body"
		jq -cn --argjson id "$1" --rawfile body "${list}.body" \
			'{id: $id, user: {login: "github-actions[bot]", id: 41898282, type: "Bot"}, body: $body}' \
			>>"${list}.items"
		shift 2
	done
	jq -s '.' "${list}.items" >"$list"
	export GH_LIST_FILE="$list"
}

# _write_runs FILE [COUNT TEXT]...: write each TEXT COUNT times to FILE, in
# order, with no trailing newline. Only counts and short texts go through
# argv, so a large file never meets Linux's 128 KiB limit on one argument.
_write_runs() {
	python3 -c '
import sys
with open(sys.argv[1], "wb") as out:
    args = sys.argv[2:]
    for count, text in zip(args[0::2], args[1::2]):
        out.write(text.encode("utf-8") * int(count))
' "$@"
}

# _write FILE COUNT [TEXT] [HEAD]: write HEAD, then COUNT copies of TEXT
# (default r) to FILE, with no trailing newline. TEXT may hold \x escapes.
_write() {
	python3 -c '
import sys
text = sys.argv[3].encode("utf-8").decode("unicode_escape").encode("latin-1") if "\\x" in sys.argv[3] else sys.argv[3].encode("utf-8")
with open(sys.argv[1], "wb") as out:
    out.write(sys.argv[4].encode("utf-8"))
    out.write(text * int(sys.argv[2]))
' "$1" "$2" "${3:-r}" "${4:-}"
}

# _pad COUNT [TEXT]: COUNT copies of TEXT (default r) on stdout.
_pad() {
	python3 -c 'import sys; sys.stdout.write(sys.argv[2] * int(sys.argv[1]))' "$1" "${2:-r}"
}

# _fmt N: N with thousands separators.
_fmt() {
	python3 -c 'import sys; print(f"{int(sys.argv[1]):,}")' "$1"
}

_bytes() {
	wc -c <"$1" | tr -d '[:space:]'
}

# Every body the API received is within GitHub's limit and free of the token.
_assert_all_sent_fit() {
	local f
	for f in "$GH_SENT"/*; do
		[[ -e "$f" ]] || continue
		assert [ "$(_bytes "$f")" -le "$LIMIT" ]
		refute grep -q "$SECRET" "$f"
	done
}

# Workflow command lines (::warning and ::error) in $output.
_commands() {
	grep -cE '^::(warning|error)' <<<"$output" || true
}

# The stamp line the composer writes for run 200 in these tests.
_stamp_200() {
	printf '<!-- lgtm-ci:history:latest sha=%s run=200 attempt=1 number=2 at=%s -->' \
		"$EVENT_PULL_REQUEST_HEAD_SHA" "$HISTORY_NOW"
}

# Assert that $GH_BODY is the notice for run 200 and that the step failed
# with one ::error after posting it. SUBJECT is what was measured (comment
# or summary file). Usage: _assert_notice SUBJECT SIZE_TEXT
_assert_notice() {
	assert_failure
	assert_equal "$(_commands)" "1"
	assert_output --partial "::error title=post-pr-comment::Summary too long to post: GitHub accepts at most 262,144 bytes in one comment, and the $1 for this run $2. A notice with no result was posted in its place (comment 7)"
	_line_starts "$GH_BODY" 1 "$MARKER_LINE"
	_has "$GH_BODY" "### ⚠️ Summary too long to post"
	_has "$GH_BODY" "> GitHub accepts at most 262,144 bytes in one comment."
	_has "$GH_BODY" "> The $1 for this run (commit \`abcdef1\`) $2, so the summary is not shown."
	_has "$GH_BODY" "> **No result is shown for this run**, and no earlier result applies to it: see the [workflow run](${RUN_URL_200}) for the outcome."
	# Above the archive (if any) no result shows.
	sed -n '1,/^---$/p' "$GH_BODY" >"${BATS_TEST_TMPDIR}/above-archive"
	_lacks "${BATS_TEST_TMPDIR}/above-archive" "PASSED"
	_lacks "${BATS_TEST_TMPDIR}/above-archive" "passed"
	_assert_all_sent_fit
}

# The stale comment that said PASSED, as the listing.
_stale_passed() {
	_set_listing 7 "$(printf '%s\n%s' "$MARKER_LINE" "### ✅ PASSED")"
}

# Set up a test: the stubbed gh, RUNNER_TEMP and the run's metadata.
post_pr_comment_size_setup() {
	setup_temp_dir
	export GH_TOKEN="$SECRET"
	export GITHUB_REPOSITORY="lgtm-hq/consumer"
	export PR_NUMBER="42"
	export MARKER="test-marker"
	export MODE="upsert"
	export DELETE_ON_EMPTY="false"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	mkdir -p "$RUNNER_TEMP"
	export GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1 GITHUB_RUN_NUMBER=2
	export GITHUB_SHA=0000000000000000000000000000000000000000
	export EVENT_PULL_REQUEST_HEAD_SHA=abcdef1234567890abcdef1234567890abcdef12
	export GITHUB_SERVER_URL="https://github.com"
	export HISTORY_NOW="2026-11-20T12:00:00Z"
	unset COMMENT_FIELDS HISTORY HISTORY_SUMMARY HISTORY_FIELDS HISTORY_MAX_BYTES HISTORY_LIMIT
	unset GH_VIEWER_FAIL GH_WRITE_FAIL BODY_FILE_GIVEN
	unset BODY_SNAPSHOT BODY_SNAPSHOT_STATE BODY_SNAPSHOT_BYTES GH_LIST_FILE

	# gh stub. The viewer is github-actions[bot]; the listing prints the file
	# $GH_LIST_FILE (or "[]"); DELETE succeeds. POST/PATCH write the body they
	# were given to $GH_BODY and keep a copy of each in $GH_SENT: from
	# `-f body=` (logged as "field") or from the JSON file of `--input`
	# (logged as "json"). With $GH_WRITE_FAIL set a write answers HTTP 422.
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export GH_BODY="${BATS_TEST_TMPDIR}/gh_body"
	export GH_SENT="${BATS_TEST_TMPDIR}/sent"
	mkdir -p "$GH_SENT"
	: >"$GH_CALLS"
	rm -f "$GH_BODY"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "api graphql" ]]; then
	printf 'graphql\n' >>"$GH_CALLS"
	if [[ -n "${GH_VIEWER_FAIL:-}" ]]; then
		echo "gh: HTTP 401: Bad credentials" >&2
		exit 1
	fi
	printf '{"data":{"viewer":{"login":"github-actions[bot]","databaseId":41898282}}}\n'
	exit 0
fi
args=("$@")
method=GET path="" transport=""
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	-X) method="${args[i + 1]}" ;;
	/repos/*) path="${args[i]}" ;;
	--input)
		transport=json
		jq -j '.body' "${args[i + 1]}" >"$GH_BODY"
		;;
	-f)
		if [[ "${args[i + 1]}" == body=* ]]; then
			transport=field
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
		fi
		;;
	esac
done
printf '%s %s %s\n' "$method" "$path" "$transport" >>"$GH_CALLS"
case "$method" in
DELETE) exit 0 ;;
POST | PATCH)
	n=0
	while [[ -e "${GH_SENT}/${n}" ]]; do n=$((n + 1)); done
	cp "$GH_BODY" "${GH_SENT}/${n}"
	if [[ -n "${GH_WRITE_FAIL:-}" ]]; then
		echo "gh: Validation Failed (HTTP 422)" >&2
		exit 1
	fi
	printf '{"id": 7, "html_url": "https://github.com/c/7"}\n'
	exit 0
	;;
esac
if [[ -n "${GH_LIST_FILE:-}" ]]; then
	cat "$GH_LIST_FILE"
else
	printf '[]\n'
fi
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

# No comment-fields message reached the log: neither a workflow command nor
# a line the fields renderer prints (a shell trace may mention the name).
_refute_fields_messages() {
	refute grep -qE '^(::[a-z]+( [^:]*)?::.*comment-fields|comment-fields:)' <<<"$output"
}

# An existing history comment for run 100 that said PASSED, with a summary,
# and a body padded by BYTES (default: none).
_passed_history_comment() {
	local summary
	summary="$(printf '%s' 'all 42 passed' | base64)"
	printf '%s\n%s\n%s%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=1111111111111111111111111111111111111111 run=100 attempt=1 number=1 at=2026-11-19T12:00:00Z summary=${summary} -->" \
		"### ✅ PASSED (run 100)" "$(_pad "${1:-0}" p)"
}

# An existing history comment: run 100 on top and run 50 archived, each body
# padded by BYTES.
_two_run_comment() {
	printf '%s\n%s\n%s\n\n---\n\n%s\n\n%s\n%s\n%s\n\n%s\n\n%s\n%s\n\n%s' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=1111111111111111111111111111111111111111 run=100 attempt=1 number=1 at=2026-11-19T12:00:00Z -->" \
		"### run 100 $(_pad "$1" p)" \
		"<details><summary>🕘 Previous runs (1)</summary>" \
		"<!-- lgtm-ci:history:start -->" \
		"<!-- lgtm-ci:history:entry sha=5555555555555555555555555555555555555555 run=50 attempt=1 number=0 at=2026-11-18T12:00:00Z -->" \
		"<details><summary>Run #0</summary>" "### run 50 $(_pad "$1" q)" "</details>" \
		"<!-- lgtm-ci:history:end -->" "</details>"
}

# _compose EXISTING_FILE NEW_BODY [ENV...]: run the composer for run 200.
_compose() {
	local existing="$1" body="$2"
	shift 2
	local composed="${BATS_TEST_TMPDIR}/composed" composed_status=0
	printf '%s\n' "$body" >"${BATS_TEST_TMPDIR}/new.md"
	_compose_file "$existing" "${BATS_TEST_TMPDIR}/new.md" "$@"
}

# _compose_file EXISTING_FILE NEW_BODY_FILE [ENV...]: run the composer for
# run 200. The composed body is "${BATS_TEST_TMPDIR}/composed"; the output is
# only the composer's ::error lines, so no large body enters the shell.
_compose_file() {
	local existing="$1" new="$2" composed="${BATS_TEST_TMPDIR}/composed" composed_status=0
	shift 2
	env NEW_BODY_FILE="$new" MARKER_TAG="$MARKER_LINE" \
		HEAD_SHA=abcdef1 RUN_ID=200 RUN_ATTEMPT=1 RUN_NUMBER=2 RUN_URL="$RUN_URL_200" \
		"$@" bash "$HELPER" <"$existing" >"$composed" 2>"${composed}.err" || composed_status=$?
	_set_run "$composed_status" "$(grep '^::' "${composed}.err")"
}

# Bytes the last _compose wrote, its trailing newline excluded.
_composed_bytes() {
	echo $(($(wc -c <"${BATS_TEST_TMPDIR}/composed") - 1))
}

# _archive FILE N BYTES [TEXT]: an existing comment whose archive holds runs
# 1..N (newest last) and whose latest is run N+1, each archived body BYTES
# copies of TEXT (default a).
_archive() {
	local file="$1" n="$2" bytes="$3" text="${4:-a}" i blocks=""
	for ((i = n; i >= 1; i--)); do
		blocks+="<!-- lgtm-ci:history:entry sha=s${i} run=${i} attempt=1 number=${i} at=t -->"$'\n'
		blocks+="<details><summary>Run #${i}</summary>"$'\n\n'"run ${i} $(_pad "$bytes" "$text")"$'\n\n'"</details>"$'\n'
	done
	printf '%s\n%s\n%s\n\n---\n\n%s\n\n%s\n%s%s\n' "$MARKER_LINE" \
		"<!-- lgtm-ci:history:latest sha=s$((n + 1)) run=$((n + 1)) attempt=1 number=$((n + 1)) at=t -->" \
		"latest $((n + 1))" "<details><summary>🕘 Previous runs (${n})</summary>" \
		"<!-- lgtm-ci:history:start -->" "$blocks" "<!-- lgtm-ci:history:end -->" >"$file"
	printf '\n</details>\n' >>"$file"
}
