#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run golden renderings under one fixed environment (#1692)
#
# A golden must render the same on a laptop and on a runner. The scripts read
# the runner's GITHUB_* and RUNNER_* variables and CI through their libraries
# (a commit link from GITHUB_SHA, a run link from GITHUB_RUN_ID, is_ci from CI
# or GITHUB_ACTIONS), and the locale and time zone through sort, date and
# Python. golden_env runs a command under `env -i` with only PATH, HOME,
# TMPDIR, a C locale, UTC and the pinned repository, run and commit below,
# plus the NAME=VALUE pairs the caller gives. kcov's trace variables are kept
# only while kcov collects (as kcov_trace_env in common.bash does), so the
# scripts are still measured; its trace goes to its own descriptor, and the
# goldens send every command's stderr to /dev/null.
#
# golden_capture runs a rendering with stdout to a file and stderr discarded,
# so nothing but the rendering is compared (a kcov trace that falls back to
# stderr included).
#
# Usage: source "${BASH_SOURCE[0]%/*}/golden_env.bash"
#        golden_env [NAME=VALUE ...] COMMAND [ARG ...]
#        golden_capture OUTPUT_FILE COMMAND [ARG ...]
#        run golden_matches GOLDEN_FILE COMMAND [ARG ...]; assert_success

#: The pinned repository, run and commit every golden renders with.
GOLDEN_ENV_PINNED=(
	GITHUB_REPOSITORY=o/r
	GITHUB_RUN_ID=42
	GITHUB_SERVER_URL=https://github.com
	GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
)

# Usage: golden_env [NAME=VALUE ...] COMMAND [ARG ...]
golden_env() {
	local name trace=()
	if [[ "${KCOV_BASH_XTRACEFD:-}" =~ ^[0-9]+$ ]]; then
		for name in BASH_ENV BASH_XTRACEFD KCOV_BASH_XTRACEFD LD_PRELOAD KCOV_BASH_USE_DEBUG_TRAP; do
			if [[ -n "${!name+set}" ]]; then
				trace+=("${name}=${!name}")
			fi
		done
	fi
	env -i ${trace[@]+"${trace[@]}"} PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
		LC_ALL=C LANG=C TZ=UTC "${GOLDEN_ENV_PINNED[@]}" "$@"
}

# Usage: golden_capture OUTPUT_FILE COMMAND [ARG ...]
golden_capture() {
	local output="$1"
	shift
	"$@" >"$output" 2>/dev/null
}

# Render with golden_capture and compare with a golden file; on a mismatch
# print the unified diff and fail.
# Usage: run golden_matches GOLDEN_FILE COMMAND [ARG ...]
golden_matches() {
	local golden="$1" rendered
	shift
	rendered="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/golden.XXXXXX")"
	if ! golden_capture "$rendered" "$@"; then
		echo "the rendering failed: $*"
		return 1
	fi
	diff -u "$golden" "$rendered"
}
