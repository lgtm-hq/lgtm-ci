#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bash entry to the shared comment sanitiser (#1676). Every comment
#          renderer passes text it did not write through comment_sanitize
#          before inserting it. Modes and rules: docs/comment-sanitize.md.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/../lib/github/comment_sanitize.sh"
#   safe="$(comment_sanitize text --env TEST_SUITE_NAME)"
#   safe_url="$(comment_sanitize url --env REPORT_URL)"     # empty when unsafe
#   printf '%s' "$output" | comment_sanitize fence
#   mapfile -d '' safe < <(printf '%s\0' "${values[@]}" | comment_sanitize cell --nul)
#
# The value is read from stdin or from the environment variable named by
# --env, never from argv. MODE and the flags are constants of the caller.
#
# Python: the python3 on PATH, looked up (never run) when this file is
# sourced; the module needs nothing newer than the runner's python3 (3.10 on
# ubuntu-22.04). Without a python3, a fail-closed fallback runs and warns on
# stderr: inline modes keep only letters, digits, spaces and , ( ) + = - and
# turn every other byte into ?; report does the same line by line; url, host
# and link give nothing; markdown only breaks <!--.
#
# Numbers read from a report file or from jq go through comment_read_count or
# comment_read_decimal before any arithmetic or output. A malformed value
# becomes 0 for arithmetic, is logged, and is listed by comment_unreadable_lines
# so the comment says it is unreadable; it never reads as a clean result.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_COMMENT_SANITIZE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_COMMENT_SANITIZE_LOADED=1

_COMMENT_SANITIZE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/comment_sanitize.py"
# Looked up, not run: a script that checks its own python3 first (as
# run-lintro-audit.sh does) must not have it started by sourcing this file.
_COMMENT_SANITIZE_PYTHON=""
if command -v python3 >/dev/null 2>&1; then
	_COMMENT_SANITIZE_PYTHON="python3"
fi

# One value through the fail-closed rules; the result has no trailing newline.
# Usage: _comment_sanitize_fallback_one MODE VALUE
_comment_sanitize_fallback_one() {
	local mode="$1" value="$2"
	# The hyphen stays last so tr reads it as a literal, not a range.
	local keep='A-Za-z0-9 ,()+=-'
	# shellcheck disable=SC2016 # the backticks are literal markdown
	case "$mode" in
	url | host | link) ;;
	markdown) printf '%s' "${value//<!--/<!- -}" ;;
	fence) printf '```\n%s\n```' "$(printf '%s' "$value" | LC_ALL=C tr -c "\n${keep}" '?')" ;;
	report) printf '%s' "$value" | LC_ALL=C tr -c "\n${keep}" '?' ;;
	code | cell-code) printf '`%s`' "$(printf '%s' "$value" | LC_ALL=C tr -c "$keep" '?')" ;;
	*) printf '%s' "$value" | LC_ALL=C tr -c "$keep" '?' ;;
	esac
	return 0
}

# Fail-closed stand-in for runners without a python3. It always succeeds, so
# a renderer under `set -e` carries on with the reduced text or without a link.
# Usage: _comment_sanitize_fallback MODE [--env NAME] [--nul | --json] [--max N]
_comment_sanitize_fallback() {
	local mode="$1" env_name="" batch=""
	shift
	while (($#)); do
		case "$1" in
		--env)
			env_name="$2"
			shift 2
			;;
		--nul | --json)
			batch="$1"
			shift
			;;
		--max) shift 2 ;;
		*) shift ;;
		esac
	done
	echo "::warning::comment_sanitize: no python3 on this runner; untrusted comment text is reduced to letters and digits" >&2
	local record
	if [[ "$batch" == "--nul" ]]; then
		# A shell variable cannot hold NUL, so each record is read, reduced
		# and written with its own terminator.
		# A last record without its NUL still counts, as in the Python path.
		while IFS= read -r -d '' record || [[ -n "$record" ]]; do
			_comment_sanitize_fallback_one "$mode" "$record"
			printf '\0'
		done
		return 0
	fi
	local input
	if [[ -n "$env_name" ]]; then
		input="${!env_name-}"
	else
		input="$(
			cat
			printf x
		)"
		input="${input%x}"
	fi
	if [[ "$batch" == "--json" ]]; then
		local reduce='gsub("[^A-Za-z0-9 ,()+=-]"; "?")'
		case "$mode" in
		url | host | link) jq -c 'map("")' <<<"$input" ;;
		code | cell-code) jq -c "map(\"\\u0060\" + (${reduce}) + \"\\u0060\")" <<<"$input" ;;
		*) jq -c "map(${reduce})" <<<"$input" ;;
		esac
		return 0
	fi
	_comment_sanitize_fallback_one "$mode" "$input"
}

# Labels of the numbers a renderer could not read, in order (see below).
COMMENT_UNREADABLE=()

# Set VAR to VALUE when it is a plain number; otherwise set VAR to 0, log a
# warning naming LABEL (never the value, which may carry a workflow command)
# and append LABEL to COMMENT_UNREADABLE, so the renderer can say in the
# comment that the value is unreadable and never report it as clean. LABEL is
# a constant the renderer writes. KEEP (decimals only) is a plain lower-case
# word such as n/a that passes as it is; any other KEEP is ignored.
# Usage: comment_read_count VAR LABEL VALUE      (0 to 999999999)
#        comment_read_decimal VAR LABEL VALUE [KEEP]
comment_read_count() { _comment_read_number count "$@"; }
comment_read_decimal() { _comment_read_number decimal "$@"; }
_comment_read_number() {
	local kind="$1" var="$2" label="$3" value="${4-}" keep="${5-}"
	if [[ "$kind" == count && "$value" =~ ^[0-9]{1,9}$ ]]; then
		printf -v "$var" '%s' "$((10#$value))"
	elif [[ "$kind" == decimal && "$value" =~ ^[0-9]{1,6}(\.[0-9]{1,20})?$ ]]; then
		printf -v "$var" '%s' "$value"
	elif [[ "$kind" == decimal && "$keep" =~ ^[a-z/]{1,8}$ && "$value" == "$keep" ]]; then
		printf -v "$var" '%s' "$keep"
	else
		echo "::warning::The report's ${label} value is not a number; the comment says so" >&2
		printf -v "$var" '0'
		COMMENT_UNREADABLE+=("$label")
	fi
}

# Print one comment line per label in COMMENT_UNREADABLE, or nothing.
comment_unreadable_lines() {
	local label
	for label in "${COMMENT_UNREADABLE[@]}"; do
		printf '%s\n' "⚠️ The report's \`${label}\` value is not a number; see the job log."
	done
}

# Sanitise untrusted text for a PR comment; see the header for usage.
comment_sanitize() {
	if [[ -n "$_COMMENT_SANITIZE_PYTHON" ]]; then
		"$_COMMENT_SANITIZE_PYTHON" -I -S "$_COMMENT_SANITIZE_PY" "$@"
	else
		_comment_sanitize_fallback "$@"
	fi
}

# comment_chrome.sh exports its functions to child shells; they need these.
export _COMMENT_SANITIZE_PY _COMMENT_SANITIZE_PYTHON
export -f comment_sanitize _comment_sanitize_fallback _comment_sanitize_fallback_one
export -f comment_read_count comment_read_decimal _comment_read_number comment_unreadable_lines
