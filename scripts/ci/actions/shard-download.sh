#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Keep the shell-tests aggregate's retried shard artifact downloads
#          in one predictable layout, and fold their attempts into one
#          outcome (#1562).
#
# The aggregate downloads each shard artifact family (TAPs, coverage) with
# actions/download-artifact, merge-multiple: false, retried up to twice. The
# pinned action extracts into DIR/<artifact-name> when several artifacts
# match, but straight into DIR when exactly one matches. Two attempts writing
# into the same DIR could then leave artifact A in DIR/A (attempt 1) and
# artifact B at the root of DIR (attempt 2). The completion check finds both
# manifests recursively, but the coverage merge only visits subdirectories,
# so B's coverage was silently dropped and the merged percentage was wrong.
#
# Usage:
#   shard-download.sh reset DIR [SECONDS]
#       Back off SECONDS (default 0), then empty DIR, so the next attempt
#       starts from nothing and no artifact of a failed attempt survives.
#   shard-download.sh finalize DIR
#       After the last attempt. Folds the attempts' outcomes (environment
#       below) into one and writes `outcome=<value>` to GITHUB_OUTPUT. When
#       the only artifact landed at the root of DIR (a shard completion
#       manifest, shard-complete.json, sits directly in DIR), moves every
#       root entry into DIR/single-artifact so every artifact is a
#       subdirectory, as the consumers expect. A root manifest plus another
#       manifest at any depth below it is a mixed layout that no single
#       attempt produces, and a failed move leaves DIR half-moved: instead of
#       guessing, the outcome is then `failure`, so the consumers fail closed
#       as on a failed download. Without a root manifest DIR is left alone.
#
# Environment (finalize):
#   DOWNLOAD_OUTCOME          steps.<first attempt>.outcome
#   DOWNLOAD_RETRY_1_OUTCOME  steps.<retry 1>.outcome
#   DOWNLOAD_RETRY_2_OUTCOME  steps.<retry 2>.outcome
#   GITHUB_OUTPUT             Step output file (required)
#
# The folded outcome is `success` when any attempt succeeded, else the last
# attempt's outcome (`failure`, or `skipped` when the first was cancelled),
# and `failure` when that is empty.

set -euo pipefail

SINGLE_ARTIFACT_DIR="single-artifact"
# Written by shard-completion.py (MANIFEST_NAME) at the top of each coverage artifact.
MANIFEST_NAME="shard-complete.json"

usage() {
	echo "Usage: shard-download.sh reset DIR [SECONDS]" >&2
	echo "       shard-download.sh finalize DIR" >&2
	exit 2
}

# Refuse a DIR whose removal could reach outside the download directory.
check_dir_arg() {
	local dir="$1"
	if [[ -z "$dir" || "$dir" == "/" || "$dir" == "." || "$dir" == ".." ]]; then
		echo "::error::shard-download: refusing download directory '${dir}'" >&2
		exit 2
	fi
}

# Print the final outcome of up to three download attempts.
fold_outcome() {
	local first="$1" retry_1="$2" retry_2="$3"
	if [[ "$first" == "success" || "$retry_1" == "success" || "$retry_2" == "success" ]]; then
		echo "success"
	else
		echo "${retry_2:-failure}"
	fi
}

cmd_reset() {
	local dir="$1" seconds="${2:-0}"
	check_dir_arg "$dir"
	if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
		echo "::error::shard-download: SECONDS must be a non-negative integer, got: ${seconds}" >&2
		exit 2
	fi
	if [[ "$seconds" -gt 0 ]]; then
		sleep "$seconds"
	fi
	rm -rf -- "$dir"
	mkdir -p -- "$dir"
	echo "shard-download: cleared ${dir} for the next attempt"
}

# Move the content of DIR into DIR/single-artifact when one artifact was
# extracted at the root. Detection is content-based, not by name: the action
# matches its pattern with minimatch (braces, extglobs), which bash globs do
# not reproduce. Called in a condition, so errexit is off here: every command
# is checked explicitly. Returns 1 on a mixed layout or a failed move.
normalize_layout() {
	local dir="$1"
	local -a entries=()
	[[ -d "$dir" ]] || return 0
	[[ -e "$dir/$MANIFEST_NAME" ]] || return 0
	shopt -s nullglob dotglob
	entries=("$dir"/*)
	shopt -u nullglob dotglob
	# A second manifest at ANY depth below the root means more than one shard
	# is present: wrapping them together would let merge read only one report.
	local nested
	if ! nested="$(find "$dir" -mindepth 2 -name "$MANIFEST_NAME" -print -quit)"; then
		echo "::error::shard-download: cannot scan ${dir} for nested manifests" >&2
		return 1
	fi
	if [[ -n "$nested" ]]; then
		echo "::error::shard-download: ${dir} has a ${MANIFEST_NAME} at its root and" \
			"at ${nested#"$dir"/} (a download attempt was not cleared);" \
			"not using it" >&2
		return 1
	fi
	if ! mkdir -- "$dir/$SINGLE_ARTIFACT_DIR"; then
		echo "::error::shard-download: cannot create ${dir}/${SINGLE_ARTIFACT_DIR}" >&2
		return 1
	fi
	if ! mv -- "${entries[@]}" "$dir/$SINGLE_ARTIFACT_DIR/"; then
		echo "::error::shard-download: cannot move the root artifact of ${dir}" \
			"into ${SINGLE_ARTIFACT_DIR}/" >&2
		return 1
	fi
	echo "shard-download: moved the single artifact at the root of ${dir}" \
		"into ${SINGLE_ARTIFACT_DIR}/"
}

cmd_finalize() {
	local dir="$1" outcome
	check_dir_arg "$dir"
	: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
	outcome="$(fold_outcome "${DOWNLOAD_OUTCOME:-}" "${DOWNLOAD_RETRY_1_OUTCOME:-}" \
		"${DOWNLOAD_RETRY_2_OUTCOME:-}")"
	if ! normalize_layout "$dir"; then
		outcome="failure"
	fi
	echo "outcome=${outcome}" >>"$GITHUB_OUTPUT"
	echo "shard-download: ${dir} final outcome ${outcome}"
}

[[ $# -ge 1 ]] || usage
case "$1" in
reset)
	[[ $# -ge 2 && $# -le 3 ]] || usage
	cmd_reset "$2" "${3:-0}"
	;;
finalize)
	[[ $# -eq 2 ]] || usage
	cmd_finalize "$2"
	;;
*)
	usage
	;;
esac
