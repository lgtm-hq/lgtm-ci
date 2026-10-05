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
# Rejected paths:
#   - absolute paths and any `..` component (repository escape)
#   - .github/workflows/**  (a version PR must never carry workflow edits)
#   - .lgtm-ci-tooling/**   (the tooling checkout is not caller content)
#   - .git/**
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

# numstat lists only the destination of a rename/copy; the source is a
# touched path too (moving a workflow file out of .github/workflows/ deletes
# it there). Headers quote unusual names in C style; strip the quotes.
while IFS= read -r source; do
	source="${source#rename from }"
	source="${source#copy from }"
	if [[ "$source" == \"*\" ]]; then
		source="${source#\"}"
		source="${source%\"}"
	fi
	[[ -n "$source" ]] && paths+=("$source")
done < <(grep -E '^(rename|copy) from ' "$DIFF_PATH" || true)

if [[ "${#paths[@]}" -eq 0 ]]; then
	log_error "could not list the paths touched by ${DIFF_PATH}"
	exit 1
fi

violations=0
for path in "${paths[@]}"; do
	reason=""
	case "$path" in
	/*) reason="absolute path" ;;
	.. | ../* | */.. | */../*) reason="escapes the repository" ;;
	.github/workflows/*) reason="workflow files are out of scope for a version-update hook" ;;
	.lgtm-ci-tooling/*) reason="lgtm-ci tooling checkout is not caller content" ;;
	.git | .git/*) reason="git metadata" ;;
	esac
	if [[ -n "$reason" ]]; then
		printf '::error title=version-update-script out of scope::%s - %s\n' "$path" "$reason" >&2
		violations=$((violations + 1))
	fi
done

if [[ "$violations" -gt 0 ]]; then
	log_error "version-update-script diff touches ${violations} out-of-scope path(s); refusing to apply"
	exit 1
fi

log_info "version-update diff in scope (${#paths[@]} path(s))"
