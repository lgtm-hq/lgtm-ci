#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bash entry to the comment-fields parser and renderer (#1677).
#          A caller's `Label: value` lines become a block in every comment
#          the shared poster writes. Rules: docs/comment-fields.md.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/../lib/github/comment_fields.sh"
#   COMMENT_FIELDS_RUN_URL="$run_url" comment_fields render --env COMMENT_FIELDS \
#     --style block --out "$block_file" --stamp "$stamp_file"
#   line="$(STAMP="$b64" comment_fields history --env STAMP)"
#
# The input is read from the environment variable named by --env, never from
# argv. render writes the block to --out and the history stamp to --stamp and
# prints the job log lines (one ::warning annotation when a line is not
# shown); it exits 0 whatever the input holds, so a bad line never fails the
# step. history prints the compact line of an archived run.
#
# Python: the python3 the sanitiser entry found. Without one, render writes a
# fixed note that the fields could not be read, with a warning, and history
# prints nothing.

[[ -n "${_LGTM_CI_GITHUB_COMMENT_FIELDS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_COMMENT_FIELDS_LOADED=1

# shellcheck source=comment_sanitize.sh
source "$(dirname "${BASH_SOURCE[0]}")/comment_sanitize.sh"

_COMMENT_FIELDS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/comment_fields.py"

# Fail-closed stand-in for runners without a python3: a constant note in the
# requested style, an empty stamp, one warning. Always succeeds.
# Usage: _comment_fields_fallback render|history [--style S] [--out F] [--stamp F] [--env N]
_comment_fields_fallback() {
	local command="$1" style="block" out="" stamp=""
	shift
	while (($# > 1)); do
		case "$1" in
		--style) style="$2" ;;
		--out) out="$2" ;;
		--stamp) stamp="$2" ;;
		esac
		shift 2
	done
	[[ "$command" == "render" ]] || return 0
	local note="⚠️ \`comment-fields\` could not be read: this runner has no python3"
	local block
	case "$style" in
	compact) block="$note" ;;
	table) block="| ⚠️ \`comment-fields\` |"$'\n'"|---|"$'\n'"| could not be read: this runner has no python3 |" ;;
	*) block="> ${note}" ;;
	esac
	if [[ -n "$out" ]]; then
		printf '%s' "$block" >"$out"
	else
		printf '%s' "$block"
	fi
	[[ -z "$stamp" ]] || : >"$stamp"
	echo "::warning title=comment-fields::comment-fields could not be read: this runner has no python3; no field is shown" >&2
	return 0
}

# Parse and render comment-fields; see the header for usage.
comment_fields() {
	if [[ -n "$_COMMENT_SANITIZE_PYTHON" ]]; then
		"$_COMMENT_SANITIZE_PYTHON" -I -S "$_COMMENT_FIELDS_PY" "$@"
	else
		_comment_fields_fallback "$@"
	fi
}
