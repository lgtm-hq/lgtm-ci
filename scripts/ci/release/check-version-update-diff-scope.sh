#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Reject a version-update-hook diff that reaches outside the caller
# repository's ordinary files (#849).
#
# The diff is produced by caller code in an unprivileged job and applied by
# the privileged job, so it is untrusted input. This check runs in both: in
# the hook job as an early, readable failure for honest hooks; in the
# privileged job as the enforcement point (the hook job can rewrite anything
# in its own runner, including this script).
#
# Rejected paths (matched case-insensitively: macOS runners have
# case-insensitive filesystems, so `.GitHub/` lands in `.github/`):
#   - absolute paths and any `..` component (repository escape)
#   - .github/**            (workflows, composite actions, CODEOWNERS: a
#                            version PR never needs them and the App token
#                            may auto-merge the PR)
#   - .lgtm-ci-tooling/**   (the tooling checkout is not caller content)
#   - .git/**
# Rejected entries: symlinks (mode 120000) and gitlinks (160000), which
# would let the PR point at content outside the diff.
#
# Environment variables:
#   DIFF_PATH - Path to the unified diff (may be empty)
#
# Exit: 0 when the diff is empty or in scope; 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"

: "${DIFF_PATH:?DIFF_PATH is required}"

if [[ ! -f "$DIFF_PATH" ]]; then
	log_error "diff not found: ${DIFF_PATH}"
	exit 1
fi

if [[ ! -s "$DIFF_PATH" ]]; then
	log_info "version-update diff is empty; nothing to check"
	exit 0
fi

# Collect every path the diff touches. `--numstat -z` emits raw (unquoted)
# names; a rename contributes both the old and the new path. git refuses to
# parse a malformed patch here, which is also a rejection.
numstat="$(mktemp)"
trap 'rm -f "$numstat"' EXIT
if ! git apply --numstat -z -- "$DIFF_PATH" >"$numstat"; then
	log_error "git could not parse ${DIFF_PATH}; refusing to apply"
	exit 1
fi

paths=()
while IFS= read -r -d '' field; do
	# numstat -z records are "added<TAB>deleted<TAB>path\0" or, for renames,
	# "added<TAB>deleted<TAB>\0old\0new\0". Strip the counts and keep names.
	if [[ "$field" == *$'\t'* ]]; then
		field="${field#*$'\t'}"
		field="${field#*$'\t'}"
	fi
	[[ -n "$field" ]] && paths+=("$field")
done <"$numstat"

# `--numstat` prints only the destination of a rename/copy, so the source
# is read from the headers: it is a touched path too (moving a workflow
# file out of .github/workflows/ deletes it there). git C-quotes names with
# unusual bytes; those are not decoded here, so a quoted source is rejected
# rather than compared half-decoded.
while IFS= read -r source; do
	source="${source#rename from }"
	source="${source#copy from }"
	if [[ "$source" == \"* ]]; then
		printf '::error title=version-update-script out of scope::%s - %s\n' \
			"$source" "rename/copy source with escaped characters is not supported" >&2
		exit 1
	fi
	[[ -n "$source" ]] && paths+=("$source")
done < <(grep -E '^(rename|copy) from ' "$DIFF_PATH" || true)

if [[ "${#paths[@]}" -eq 0 ]]; then
	log_error "could not list the paths touched by ${DIFF_PATH}"
	exit 1
fi

violations=0
shopt -s nocasematch
for path in "${paths[@]}"; do
	reason=""
	case "$path" in
	/*) reason="absolute path" ;;
	.. | ../* | */.. | */../*) reason="escapes the repository" ;;
	.github | .github/*) reason=".github/ is out of scope for a version-update hook" ;;
	.lgtm-ci-tooling | .lgtm-ci-tooling/*) reason="lgtm-ci tooling checkout is not caller content" ;;
	.git | .git/*) reason="git metadata" ;;
	esac
	if [[ -n "$reason" ]]; then
		printf '::error title=version-update-script out of scope::%s - %s\n' "$path" "$reason" >&2
		violations=$((violations + 1))
	fi
done
shopt -u nocasematch

# Symlinks and submodule pointers are entries, not content; refuse them.
while IFS= read -r mode_line; do
	printf '::error title=version-update-script out of scope::%s - %s\n' \
		"$mode_line" "symlinks and gitlinks are not allowed in a version-update diff" >&2
	violations=$((violations + 1))
done < <(grep -E '^(new file mode|new mode|old mode|index [0-9a-f.]+ ) ?(120000|160000)$' "$DIFF_PATH" || true)

if [[ "$violations" -gt 0 ]]; then
	log_error "version-update-script diff touches ${violations} out-of-scope path(s); refusing to apply"
	exit 1
fi

log_info "version-update diff in scope (${#paths[@]} path(s))"
