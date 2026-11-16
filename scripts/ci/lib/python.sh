#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run Python only when it is 3.11 or newer, else stop with one clear
# error line (#1428)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/python.sh"
#   run_python "$SCRIPT_DIR/check.py" --flag value   # instead of python3 ...
#   require_python || exit $?                        # check up front only
#
# Interpreter: $PYTHON when it is set and non-empty, else `python3` on PATH.
# PYTHON is the override the scripts already honour ("${PYTHON:-python3}"),
# and tests inject fake interpreters through it. A PYTHON that does not name
# an executable is an error; there is no fallback to python3, so a wrong
# override never runs some other interpreter. The interpreter is resolved
# on every call (a relative PYTHON against the current directory, a bare
# name through the PATH entries, files only, never a shell function or
# alias) and run by that resolved absolute path. A bare name is looked up
# in the absolute PATH entries only: an empty or relative entry would
# resolve against the current directory, which may be a caller's checkout.
#
# The PATH lookup itself uses only assignments, parameter expansion and
# [[ ]] tests, and hands its result back in a variable. No builtin (`type`,
# `command`, `printf`, ...) takes part, so an exported shell function of
# such a name cannot change which file is found. That is the whole of the
# claim: the probe and the error path do use builtins and external tools,
# and whoever can export functions into a job can also set PATH. A resolved
# path containing a newline or a carriage return is refused.
#
# After require_python succeeds, LGTM_CI_PYTHON_PATH holds the absolute
# path it accepted. A script that must never take its interpreter from the
# environment (the release ecosystem scripts) clears PYTHON, calls
# require_python, and sets PYTHON to that path, so every later call, after
# a cd or in a subshell, runs the same file:
#   PYTHON=""
#   require_python || exit $?
#   PYTHON="$LGTM_CI_PYTHON_PATH"
#
# Version probe: `<interpreter> -I -c <code>` with stdin from /dev/null.
# -I (isolated mode, Python 3.4+) keeps the current directory and the
# script's directory off sys.path and ignores PYTHON* variables and the
# user site, so the probe runs nothing from the caller's checkout. The code
# uses only `sys` and %-formatting, which every Python 3 understands, so
# any interpreter from 3.4 up gets the clear "too old" message; one without
# -I (Python 2, 3.0 to 3.3) gets "could not read the version", with the
# first line of what the probe wrote to stderr. A verdict that the
# interpreter is new enough is cached per resolved path in this shell, and
# subshells ( ... ) and $( ... ) inherit it, so a script that calls Python
# in a loop probes once. Call require_python before the first subshell call
# to prime the cache.
#
# run_python adds nothing around the call: no cd, no interpreter flags, no
# environment change. Arguments go through as given ("$@") and the
# interpreter's exit status is returned unchanged.
#
# Exit status of a refusal: 69 (EX_UNAVAILABLE in sysexits.h). Callers
# branch on 1, 2, 3 and 4 as domain results (hosts fail, drift found,
# unparsable manifest, ...), and Python itself exits 1 on an uncaught
# exception and 2 on a usage error, so a refusal must use none of them.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PYTHON_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PYTHON_LOADED=1

readonly LGTM_CI_PYTHON_MIN_MAJOR=3
readonly LGTM_CI_PYTHON_MIN_MINOR=11
readonly LGTM_CI_PYTHON_EXIT_UNSUPPORTED=69
readonly _LGTM_CI_PYTHON_DOC='see "Python on the runner" in docs/workflow-contract.md'
# Python 3.0 and newer; only `sys` and %-formatting.
readonly _LGTM_CI_PYTHON_PROBE='import sys; sys.stdout.write("%d.%d.%d" % tuple(sys.version_info[:3]))'

# Resolved paths already found new enough, each between newlines. Paths
# with a newline are refused before they get here, so a match is exact.
# Assigned, never taken from the environment: a value set before this file
# loads would skip the check.
_LGTM_CI_PYTHON_VERIFIED=$'\n'
# The absolute path require_python accepted last; empty after a refusal.
LGTM_CI_PYTHON_PATH=""

# Escape a value for a workflow command (::error::), so it stays on one line.
# Usage: _lgtm_ci_python_escape <text>
_lgtm_ci_python_escape() {
	local text pct='%' cr=$'\r' lf=$'\n'
	text="$1"
	text="${text//"$pct"/%25}"
	text="${text//"$cr"/%0D}"
	printf '%s' "${text//"$lf"/%0A}"
}

# Print the one-line refusal and return the refusal status.
# Usage: _lgtm_ci_python_refuse <message>
_lgtm_ci_python_refuse() {
	printf '::error::%s; lgtm-ci scripts need Python %s.%s or newer (%s)\n' \
		"$(_lgtm_ci_python_escape "$1")" "$LGTM_CI_PYTHON_MIN_MAJOR" \
		"$LGTM_CI_PYTHON_MIN_MINOR" "$_LGTM_CI_PYTHON_DOC" >&2
	return "$LGTM_CI_PYTHON_EXIT_UNSUPPORTED"
}

# Find <name> in the absolute PATH entries and leave the first regular
# executable file in _LGTM_CI_PYTHON_FOUND (empty when there is none). An
# empty or relative entry is skipped: it would resolve against the current
# directory. Assignments and [[ ]] only, and the result goes back in a
# variable, not through printf and a command substitution.
# Usage: _lgtm_ci_python_which <name>
_lgtm_ci_python_which() {
	local name rest dir found more
	name="$1"
	rest="${PATH-}"
	found=""
	more=1
	_LGTM_CI_PYTHON_FOUND=""
	while [[ -n "$more" ]]; do
		if [[ "$rest" == *:* ]]; then
			dir="${rest%%:*}"
			rest="${rest#*:}"
		else
			dir="$rest"
			more=""
		fi
		if [[ "$dir" == /* && -f "$dir/$name" && -x "$dir/$name" ]]; then
			found="$dir/$name"
			more=""
		fi
	done
	_LGTM_CI_PYTHON_FOUND="$found"
}

# Check that the interpreter exists and is Python 3.11 or newer. On success
# LGTM_CI_PYTHON_PATH holds its absolute path; on failure it is empty, one
# ::error:: line goes to stderr and the status is 69.
# Usage: require_python
require_python() {
	local name path out err errfile rc
	# Plain assignments after `local`: the values never depend on it.
	name="${PYTHON:-python3}"
	path=""
	out=""
	err=""
	rc=0
	LGTM_CI_PYTHON_PATH=""
	if [[ "$name" == */* ]]; then
		path="$name"
		if [[ ! -f "$path" || ! -x "$path" ]]; then
			_lgtm_ci_python_refuse "PYTHON=${name} is not an executable file, so no Python was found"
			return
		fi
	else
		_lgtm_ci_python_which "$name"
		path="$_LGTM_CI_PYTHON_FOUND"
		if [[ -z "$path" ]]; then
			if [[ -n "${PYTHON:-}" ]]; then
				_lgtm_ci_python_refuse "PYTHON=${name} is not on PATH, so no Python was found"
			else
				_lgtm_ci_python_refuse "python3 not found on PATH, so no Python was found"
			fi
			return
		fi
	fi
	[[ "$path" == /* ]] || path="$PWD/$path"
	# The cache keeps one path per line: a newline would let one path stand
	# for another, so such a path is never probed or cached.
	if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
		_lgtm_ci_python_refuse "The interpreter path ${path} contains a newline or carriage return"
		return
	fi

	if [[ "$_LGTM_CI_PYTHON_VERIFIED" == *$'\n'"$path"$'\n'* ]]; then
		LGTM_CI_PYTHON_PATH="$path"
		return 0
	fi

	# stderr goes to a file so a failed probe can say why; without a
	# temporary file the probe still runs, only without that detail.
	errfile="$(mktemp 2>/dev/null)" || errfile=""
	out="$("$path" -I -c "$_LGTM_CI_PYTHON_PROBE" </dev/null 2>"${errfile:-/dev/null}")" || rc=$?
	if [[ -n "$errfile" ]]; then
		IFS= read -r err <"$errfile" || true
		rm -f "$errfile"
	fi
	if ((rc != 0)) || [[ ! "$out" =~ ^([0-9]{1,4})\.([0-9]{1,4})\.([0-9]{1,4})$ ]]; then
		if [[ -n "$err" ]]; then
			err=", error '${err:0:120}'"
		fi
		_lgtm_ci_python_refuse "Could not read the Python version of ${path} (probe exit ${rc}, output '${out:0:60}'${err})"
		return
	fi
	if ((10#${BASH_REMATCH[1]} < LGTM_CI_PYTHON_MIN_MAJOR || (\
		10#${BASH_REMATCH[1]} == LGTM_CI_PYTHON_MIN_MAJOR && \
		10#${BASH_REMATCH[2]} < LGTM_CI_PYTHON_MIN_MINOR))); then
		_lgtm_ci_python_refuse "Python ${out} at ${path} is too old"
		return
	fi
	_LGTM_CI_PYTHON_VERIFIED+="${path}"$'\n'
	LGTM_CI_PYTHON_PATH="$path"
}

# Run Python with the given arguments after require_python accepted it.
# Returns the interpreter's exit status unchanged, or 69 from the refusal.
# Usage: run_python [interpreter arguments...]
run_python() {
	if require_python; then
		"$LGTM_CI_PYTHON_PATH" "$@"
	else
		return "$LGTM_CI_PYTHON_EXIT_UNSUPPORTED"
	fi
}
