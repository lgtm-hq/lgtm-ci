#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: The comment body file of post-pr-comment (#1716): a bounded
# snapshot taken by a step that holds no token, and the checks the post step
# makes before it reads that snapshot.
#
# The caller's path is opened only by comment_body_file_load, which runs in
# the load step. That step's own environment carries no token, and the reader
# it starts runs with GH_TOKEN and GITHUB_TOKEN removed besides (a composite
# action still inherits whatever else its caller puts in the job's
# environment). The post step, which holds the token, reads only the snapshot
# the load step wrote, after checking where it is, its name, its type and its
# owner. Those checks do not authenticate who wrote it: the guarantee rests on
# the snapshot's unpredictable name and on a step output no other step can
# write, inside a job that runs no pull request code.
#
# Sourced by scripts/ci/actions/post-pr-comment.sh.

# GitHub's limit on a comment body, in bytes of UTF-8 (#1705).
readonly COMMENT_BODY_MAX_BYTES=262144
# Largest NUL-free snapshot kept. Line endings can at most halve a body (CRLF
# becomes LF), so a NUL-free stream over twice the limit plus the one
# trailing newline the post step strips is over the limit whatever the post
# step does to it; anything up to this size is handed over and measured there
# after the established normalisation.
readonly COMMENT_BODY_SNAPSHOT_MAX_BYTES=$((2 * COMMENT_BODY_MAX_BYTES + 3))
# Most raw bytes read from the caller's file: 64 MiB, 256 times the limit.
# Generous, so a report padded with NUL bytes (which are dropped, as before)
# still normalises and posts as it did; bounded, so a multi-gigabyte file
# stops after a fraction of a second. A read of more than this many bytes
# (this many plus one) is oversized; exactly this many is read and measured.
# Disk: a private raw copy of at most this many bytes plus one, and its
# NUL-free copy of at most as many, both in RUNNER_TEMP, so at most twice
# that for a moment; the raw copy is removed as soon as the NUL-free copy is
# written, and the NUL-free copy after the bounded read when it is over
# COMMENT_BODY_SNAPSHOT_MAX_BYTES and not just trailing whitespace.
readonly COMMENT_BODY_RAW_MAX_BYTES=$((64 * 1024 * 1024))
# Snapshot names, inside RUNNER_TEMP.
readonly COMMENT_BODY_SNAPSHOT_PREFIX="lgtm-ci-comment-body."
# Symlinks followed before a path counts as unresolvable (the fallback only).
readonly COMMENT_BODY_MAX_LINKS=40

# Text from a caller (a path) made safe inside a workflow command: %, CR and
# LF are escaped as the runner expects, and `::` is broken up, so the text
# can neither end the command nor start another.
# Usage: comment_body_command_value TEXT
comment_body_command_value() {
	local text="$1" pct='%' cr=$'\r' lf=$'\n'
	text="${text//"$pct"/%25}"
	text="${text//"$cr"/%0D}"
	text="${text//"$lf"/%0A}"
	printf '%s' "${text//::/: :}"
}

# Run a command that reads a caller's path with the token variables removed
# from its environment, in the C locale so every byte is a byte.
# Usage: comment_body_without_token COMMAND [ARG...]
comment_body_without_token() {
	env -u GH_TOKEN -u GITHUB_TOKEN LC_ALL=C "$@"
}

# RUNNER_TEMP as a POSIX path, in COMMENT_BODY_TEMP_DIR: on Windows the runner
# gives D:\a\_temp, which cygpath (Git Bash, MSYS) turns into /d/a/_temp.
# Empty when there is no usable directory. Sets a variable rather than
# printing, so no subshell runs this code.
# Usage: comment_body_temp_dir
comment_body_temp_dir() {
	local dir="${RUNNER_TEMP:-}"
	COMMENT_BODY_TEMP_DIR=""
	[[ -n "$dir" ]] || return 0
	if [[ "$dir" != /* ]] && command -v cygpath >/dev/null 2>&1; then
		dir="$(cygpath -u -- "$dir" 2>/dev/null)" || dir=""
	fi
	[[ "$dir" == /* && -d "$dir" ]] || return 0
	COMMENT_BODY_TEMP_DIR="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || COMMENT_BODY_TEMP_DIR=""
}

# The output of COMMAND, all of it: command substitution would strip every
# trailing newline, which may belong to a path. Only the one newline the
# utility ends its output with is removed. Fails when COMMAND fails.
# Usage: VAR="$(comment_body_exact COMMAND [ARG...])" (then strip "x")
comment_body_exact() {
	"$@" || return 1
	printf x
}

# Resolve PATH as `realpath` does, without realpath (older macOS): every
# symlink followed, `.` and `..` resolved physically. Prints the path and an
# "x" sentinel; fails when it cannot be resolved.
# Usage: comment_body_resolve_fallback PATH
comment_body_resolve_fallback() {
	local path="$1" dir base target links=0
	while :; do
		if [[ "$path" == */* ]]; then
			dir="${path%/*}"
			base="${path##*/}"
			dir="${dir:-/}"
		else
			dir="."
			base="$path"
		fi
		dir="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && comment_body_exact pwd -P)" || return 1
		dir="${dir%x}"
		dir="${dir%$'\n'}"
		case "$base" in
		. | ..)
			path="${dir%/}/${base}"
			dir="$(CDPATH='' cd -P -- "$path" 2>/dev/null && comment_body_exact pwd -P)" || return 1
			dir="${dir%x}"
			printf '%sx' "${dir%$'\n'}"
			return 0
			;;
		esac
		path="${dir%/}/${base}"
		[[ -L "$path" ]] || break
		((++links <= COMMENT_BODY_MAX_LINKS)) || return 1
		# -n: the target exactly, with no newline added (GNU and BSD).
		target="$(comment_body_exact readlink -n -- "$path")" || return 1
		target="${target%x}"
		[[ -n "$target" ]] || return 1
		if [[ "$target" == /* ]]; then
			path="$target"
		else
			path="${dir%/}/${target}"
		fi
	done
	printf '%sx' "$path"
}

# Resolve PATH to an absolute path with every symlink followed, keeping every
# byte of the name (a trailing newline included). Sets COMMENT_BODY_RESOLVED.
# Fails when it cannot be resolved.
# Usage: comment_body_resolve PATH
comment_body_resolve() {
	local resolved
	COMMENT_BODY_RESOLVED=""
	if command -v realpath >/dev/null 2>&1; then
		resolved="$(comment_body_exact realpath -- "$1" 2>/dev/null)" || return 1
		resolved="${resolved%x}"
		# realpath ends its output with one newline; any other is the name's.
		[[ "$resolved" == *$'\n' ]] || return 1
		resolved="${resolved%$'\n'}"
	else
		resolved="$(comment_body_resolve_fallback "$1")" || return 1
		resolved="${resolved%x}"
	fi
	[[ "$resolved" == /* ]] || return 1
	COMMENT_BODY_RESOLVED="$resolved"
}

# Remove a snapshot this step created (the load step, on a failure after it
# was made).
# Usage: comment_body_drop_snapshot PATH
comment_body_drop_snapshot() {
	[[ -z "$1" ]] || rm -f -- "$1"
}

# The size of FILE in bytes, in COMMENT_BODY_COUNT: `wc -c` prints only a
# number (with blanks), written to COUNT_FILE and read back, so nothing
# depends on how a tool words its messages and no subshell runs this code.
# Fails when the size cannot be read.
# Usage: comment_body_size FILE COUNT_FILE
comment_body_size() {
	COMMENT_BODY_COUNT=""
	LC_ALL=C wc -c <"$1" >"$2" || return 1
	comment_body_count_text "$2"
}

# The number `wc -c` wrote to COUNT_FILE, in COMMENT_BODY_COUNT. Fails when
# it is not one.
# Usage: comment_body_count_text COUNT_FILE
comment_body_count_text() {
	local count=""
	COMMENT_BODY_COUNT=""
	read -r count <"$1" || [[ -n "$count" ]] || return 1
	count="${count//[[:space:]]/}"
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	COMMENT_BODY_COUNT="$count"
}

# The bytes history's composition removes from the end of a body, in the C
# locale: the trailing newlines `$(cat …)` drops and the [:space:] run
# trim_trailing drops (space, tab, LF, VT, FF; CR is normalised to LF first).
readonly COMMENT_BODY_TRAILING_SPACE=$' \t\n\v\f\r'

# A NUL-free SNAPSHOT over COMMENT_BODY_SNAPSHOT_MAX_BYTES may still be a
# result that fits: with history on, composition drops any amount of trailing
# whitespace. When every byte past the first COMMENT_BODY_SNAPSHOT_MAX_BYTES
# + 1 is such whitespace, the snapshot is cut to those bytes: the cut removes
# trailing whitespace only, so history posts exactly what it would have, and
# without history the body is still over the limit after any normalisation
# (even if every byte were a CRLF pair, (524,292 - 1) / 2 > 262,144), so it
# takes the notice, as before. Each tool reads its input to the end and no
# shell code runs in the pipeline.
# Returns 0 with COMMENT_BODY_TRIMMED set to the cut snapshot (SNAPSHOT is
# removed), 2 when a byte that is not trailing whitespace lies past the
# bound, 1 when it cannot be measured or cut.
# Usage: comment_body_trim_snapshot SNAPSHOT TEMP_DIR COUNT_FILE
comment_body_trim_snapshot() {
	local snapshot="$1" temp_dir="$2" counted="$3" statuses cut
	COMMENT_BODY_TRIMMED=""
	LC_ALL=C tail -c "+$((COMMENT_BODY_SNAPSHOT_MAX_BYTES + 2))" -- "$snapshot" |
		LC_ALL=C tr -d "$COMMENT_BODY_TRAILING_SPACE" |
		LC_ALL=C wc -c >"$counted"
	statuses="${PIPESTATUS[*]}"
	[[ "$statuses" == "0 0 0" ]] || return 1
	comment_body_count_text "$counted" || return 1
	((COMMENT_BODY_COUNT == 0)) || return 2
	cut="$(mktemp "${temp_dir%/}/${COMMENT_BODY_SNAPSHOT_PREFIX}XXXXXXXXXX")" || return 1
	if ! LC_ALL=C head -c "$((COMMENT_BODY_SNAPSHOT_MAX_BYTES + 1))" -- "$snapshot" >"$cut"; then
		rm -f -- "$cut"
		return 1
	fi
	rm -f -- "$snapshot"
	COMMENT_BODY_TRIMMED="$cut"
}

# Snapshot the caller's comment file into RUNNER_TEMP. Sets
# COMMENT_BODY_STATE (ok, missing or oversized), COMMENT_BODY_SNAPSHOT (the
# snapshot path, for ok) and COMMENT_BODY_BYTES (the bytes read, for
# oversized below the raw cap). NUL bytes are dropped on the way, as the
# earlier read dropped them; everything else is copied as it is.
#
# One read of the caller's file, in bytes: `head` copies at most the raw cap
# plus one byte into a private file, `wc -c` counts it, and `tr` drops NUL
# bytes from it into the snapshot. No pipe is involved in the read, so
# nothing depends on a pipe closing (runners ignore SIGPIPE, so a closed pipe
# is an error there, not a signal), and no count depends on how a tool words
# its messages. Every tool must exit 0, and a read that did not finish
# cleanly is never handed over. A NUL-free body over the snapshot bound that
# is only trailing whitespace past it is cut, not refused (see
# comment_body_trim_snapshot).
#
# Path rule, as before: a regular file after symlinks are followed; a
# missing path, a directory, a FIFO or a device logs "Comment file not found"
# and counts as missing (an empty body). A path that resolves under /proc,
# /sys or /dev, that cannot be resolved, or that cannot be read, fails: an
# empty body there could let delete-on-empty remove the previous comment.
# Usage: comment_body_file_load PATH
comment_body_file_load() {
	local path="$1" resolved temp_dir snapshot raw_copy counted raw size
	COMMENT_BODY_STATE=""
	COMMENT_BODY_SNAPSHOT=""
	COMMENT_BODY_BYTES=""
	if [[ ! -f "$path" ]]; then
		echo "::warning::Comment file not found: $(comment_body_command_value "$path")"
		COMMENT_BODY_STATE=missing
		return 0
	fi
	if ! comment_body_resolve "$path"; then
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its location cannot be resolved)"
		return 1
	fi
	resolved="$COMMENT_BODY_RESOLVED"
	case "$resolved" in
	/proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (it resolves under /proc, /sys or /dev)"
		return 1
		;;
	esac
	if [[ ! -f "$resolved" ]]; then
		echo "::warning::Comment file not found: $(comment_body_command_value "$path")"
		COMMENT_BODY_STATE=missing
		return 0
	fi
	comment_body_temp_dir
	temp_dir="$COMMENT_BODY_TEMP_DIR"
	if [[ -z "$temp_dir" ]]; then
		echo "::error::Cannot read comment file: RUNNER_TEMP is not a directory"
		return 1
	fi
	if ! raw_copy="$(mktemp "${temp_dir%/}/lgtm-ci-comment-raw.XXXXXXXXXX")"; then
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (no temporary file)"
		return 1
	fi
	if ! counted="$(mktemp "${temp_dir%/}/lgtm-ci-comment-count.XXXXXXXXXX")"; then
		rm -f -- "$raw_copy"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (no temporary file)"
		return 1
	fi
	# The one read of the caller's file, into a private copy: no pipe, so
	# nothing can close one early, and no shell code runs during the read.
	if ! env -u GH_TOKEN -u GITHUB_TOKEN LC_ALL=C head -c "$((COMMENT_BODY_RAW_MAX_BYTES + 1))" -- "$resolved" >"$raw_copy"; then
		rm -f -- "$raw_copy" "$counted"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (the read did not finish cleanly)"
		return 1
	fi
	if ! comment_body_size "$raw_copy" "$counted"; then
		rm -f -- "$raw_copy" "$counted"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its size cannot be measured)"
		return 1
	fi
	raw="$COMMENT_BODY_COUNT"
	if ((raw > COMMENT_BODY_RAW_MAX_BYTES)); then
		rm -f -- "$raw_copy" "$counted"
		COMMENT_BODY_STATE=oversized
		return 0
	fi
	if ! snapshot="$(mktemp "${temp_dir%/}/${COMMENT_BODY_SNAPSHOT_PREFIX}XXXXXXXXXX")"; then
		rm -f -- "$raw_copy" "$counted"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (no snapshot file)"
		return 1
	fi
	# NUL bytes dropped, as the earlier read dropped them; the copy goes.
	if ! LC_ALL=C tr -d '\000' <"$raw_copy" >"$snapshot"; then
		rm -f -- "$raw_copy" "$counted"
		comment_body_drop_snapshot "$snapshot"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its NUL bytes could not be dropped)"
		return 1
	fi
	rm -f -- "$raw_copy"
	if ! comment_body_size "$snapshot" "$counted"; then
		rm -f -- "$counted"
		comment_body_drop_snapshot "$snapshot"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its size cannot be measured)"
		return 1
	fi
	size="$COMMENT_BODY_COUNT"
	if ((size > COMMENT_BODY_SNAPSHOT_MAX_BYTES)); then
		local trimmed=0
		comment_body_trim_snapshot "$snapshot" "$temp_dir" "$counted" || trimmed=$?
		case "$trimmed" in
		0)
			snapshot="$COMMENT_BODY_TRIMMED"
			;;
		2)
			rm -f -- "$counted"
			comment_body_drop_snapshot "$snapshot"
			COMMENT_BODY_STATE=oversized
			COMMENT_BODY_BYTES="$raw"
			return 0
			;;
		*)
			rm -f -- "$counted"
			comment_body_drop_snapshot "$snapshot"
			echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its trailing whitespace could not be measured)"
			return 1
			;;
		esac
	fi
	rm -f -- "$counted"
	COMMENT_BODY_STATE=ok
	COMMENT_BODY_SNAPSHOT="$snapshot"
}

# Check that PATH is the snapshot the load step wrote: an absolute path with
# no `.` or `..` component, named by the load step, whose physical directory
# is RUNNER_TEMP's, a regular file, not a symlink, owned by this user. These
# checks establish location, name, type and owner; they do not authenticate
# who wrote the file (see the top of this file). Fails with one ::error.
# Usage: comment_body_snapshot_check PATH
comment_body_snapshot_check() {
	local snapshot="$1" temp_dir snapshot_dir parent
	comment_body_temp_dir
	temp_dir="$COMMENT_BODY_TEMP_DIR"
	if [[ -z "$temp_dir" ]]; then
		echo "::error::The comment file snapshot cannot be checked: RUNNER_TEMP is not a directory"
		return 1
	fi
	parent="${snapshot%/*}"
	parent="${parent:-/}"
	if [[ "$snapshot" != /* || "/${snapshot}/" == *"/./"* || "/${snapshot}/" == *"/../"* ||
		"${snapshot##*/}" != "${COMMENT_BODY_SNAPSHOT_PREFIX}"* ]] ||
		! snapshot_dir="$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P)" ||
		[[ "$snapshot_dir" != "$temp_dir" || -L "$snapshot" || ! -f "$snapshot" || ! -O "$snapshot" ]]; then
		echo "::error::The comment file snapshot is not the file the load step wrote; nothing is posted"
		return 1
	fi
}

# Read a checked snapshot into COMMENT_BODY, as the earlier read delivered a
# file: every byte less one trailing newline. Never opens any other path.
# Fails with one ::error.
# Usage: comment_body_snapshot_read PATH
comment_body_snapshot_read() {
	local body
	# The C locale: removing one trailing byte is the same in any locale, and
	# bash's suffix match in a multibyte locale takes minutes on a large body.
	local LC_ALL=C
	COMMENT_BODY=""
	if ! body="$(
		comment_body_without_token head -c "$((COMMENT_BODY_SNAPSHOT_MAX_BYTES + 1))" -- "$1" || exit 1
		printf x
	)"; then
		echo "::error::The comment file snapshot cannot be read; nothing is posted"
		return 1
	fi
	body="${body%x}"
	COMMENT_BODY="${body%$'\n'}"
}
