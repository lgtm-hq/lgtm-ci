#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: The comment body file of post-pr-comment (#1716): a bounded
# snapshot taken by a step that holds no token, and the checks the post step
# makes before it reads that snapshot.
#
# The caller's path is opened only by comment_body_file_load, which runs in
# the load step: that step's environment carries no GH_TOKEN, no GITHUB_TOKEN
# and no other secret, and the readers it starts run with both token
# variables removed besides. The post step, which holds the token, reads only
# the snapshot the load step wrote, after checking that it is that file.
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
# stops after a fraction of a second. A file over it is oversized.
readonly COMMENT_BODY_RAW_MAX_BYTES=$((64 * 1024 * 1024))
# Snapshot names, inside RUNNER_TEMP.
readonly COMMENT_BODY_SNAPSHOT_PREFIX="lgtm-ci-comment-body."

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
# from its environment.
# Usage: comment_body_without_token COMMAND [ARG...]
comment_body_without_token() {
	env -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

# Snapshot the caller's comment file into RUNNER_TEMP. Sets
# COMMENT_BODY_STATE (ok, missing or oversized), COMMENT_BODY_SNAPSHOT (the
# snapshot path, for ok) and COMMENT_BODY_BYTES (the file's size in bytes,
# for oversized, when it is known). NUL bytes are dropped on the way, as the
# earlier read dropped them; everything else is copied as it is.
#
# Path rule, as before: a regular file after symlinks are followed; a
# missing path, a directory, a FIFO or a device logs "Comment file not found"
# and counts as missing (an empty body). A path that resolves under /proc,
# /sys or /dev, or that cannot be read, fails: an empty body there could let
# delete-on-empty remove the previous comment.
# Usage: comment_body_file_load PATH
comment_body_file_load() {
	local path="$1" resolved snapshot raw size statuses
	COMMENT_BODY_STATE=""
	COMMENT_BODY_SNAPSHOT=""
	COMMENT_BODY_BYTES=""
	if [[ ! -f "$path" ]]; then
		echo "::warning::Comment file not found: $(comment_body_command_value "$path")"
		COMMENT_BODY_STATE=missing
		return 0
	fi
	if ! resolved="$(realpath -- "$path" 2>/dev/null)" || [[ "$resolved" != /* ]]; then
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its location cannot be resolved)"
		return 1
	fi
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
	if [[ -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
		echo "::error::Cannot read comment file: RUNNER_TEMP is not a directory"
		return 1
	fi
	# The raw size, up to the cap.
	raw="$(comment_body_without_token head -c "$((COMMENT_BODY_RAW_MAX_BYTES + 1))" -- "$resolved" | wc -c | tr -d '[:space:]')" || raw=""
	if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path")"
		return 1
	fi
	if ((raw > COMMENT_BODY_RAW_MAX_BYTES)); then
		COMMENT_BODY_STATE=oversized
		return 0
	fi
	if ! snapshot="$(mktemp "${RUNNER_TEMP%/}/${COMMENT_BODY_SNAPSHOT_PREFIX}XXXXXXXXXX")"; then
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (no snapshot file)"
		return 1
	fi
	# The last head may stop reading early; the readers before it then end on
	# SIGPIPE (141), which is not a failure.
	set +o pipefail
	comment_body_without_token head -c "$COMMENT_BODY_RAW_MAX_BYTES" -- "$resolved" |
		tr -d '\000' | head -c "$((COMMENT_BODY_SNAPSHOT_MAX_BYTES + 1))" >"$snapshot"
	statuses="${PIPESTATUS[*]}"
	set -o pipefail
	if [[ ! "$statuses" =~ ^(0|141)\ (0|141)\ 0$ ]]; then
		rm -f "$snapshot"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path")"
		return 1
	fi
	size="$(wc -c <"$snapshot" | tr -d '[:space:]')" || size=""
	if [[ ! "$size" =~ ^[0-9]+$ ]]; then
		rm -f "$snapshot"
		echo "::error::Cannot read comment file: $(comment_body_command_value "$path") (its size cannot be measured)"
		return 1
	fi
	if ((size > COMMENT_BODY_SNAPSHOT_MAX_BYTES)); then
		rm -f "$snapshot"
		COMMENT_BODY_STATE=oversized
		COMMENT_BODY_BYTES="$raw"
		return 0
	fi
	COMMENT_BODY_STATE=ok
	COMMENT_BODY_SNAPSHOT="$snapshot"
}

# Read the snapshot the load step wrote into COMMENT_BODY, as the earlier
# read delivered a file: every byte less one trailing newline. The snapshot
# must be the load step's: directly inside RUNNER_TEMP, named by it, a
# regular file, not a symlink, owned by this user. Never opens any other
# path. The snapshot is removed once read. Fails with one ::error otherwise.
# Usage: comment_body_snapshot_read PATH
comment_body_snapshot_read() {
	local snapshot="$1" temp_dir snapshot_dir parent body
	COMMENT_BODY=""
	if [[ -z "${RUNNER_TEMP:-}" ]] || ! temp_dir="$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P)"; then
		echo "::error::The comment file snapshot cannot be checked: RUNNER_TEMP is not a directory"
		return 1
	fi
	parent="${snapshot%/*}"
	parent="${parent:-/}"
	if [[ "$snapshot" != /* || "${snapshot##*/}" != "${COMMENT_BODY_SNAPSHOT_PREFIX}"* ]] ||
		! snapshot_dir="$(cd "$parent" 2>/dev/null && pwd -P)" ||
		[[ "$snapshot_dir" != "$temp_dir" || -L "$snapshot" || ! -f "$snapshot" || ! -O "$snapshot" ]]; then
		echo "::error::The comment file snapshot is not the file the load step wrote; nothing is posted"
		return 1
	fi
	if ! body="$(
		comment_body_without_token head -c "$((COMMENT_BODY_SNAPSHOT_MAX_BYTES + 1))" -- "$snapshot" || exit 1
		printf x
	)"; then
		echo "::error::The comment file snapshot cannot be read; nothing is posted"
		return 1
	fi
	rm -f "$snapshot"
	body="${body%x}"
	COMMENT_BODY="${body%$'\n'}"
}
