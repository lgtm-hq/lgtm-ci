#!/usr/bin/env bash
# Prepare lychee-action CLI args from lgtm-ci build-lychee-args output.
# SPDX-License-Identifier: MIT
set -euo pipefail

: "${RAW_ARGS:?RAW_ARGS is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${LYCHEE_ROOT_DIR:?LYCHEE_ROOT_DIR is required}"

LYCHEE_ROOT_DIR="${LYCHEE_ROOT_DIR#"${LYCHEE_ROOT_DIR%%[![:space:]]*}"}"
LYCHEE_ROOT_DIR="${LYCHEE_ROOT_DIR%"${LYCHEE_ROOT_DIR##*[![:space:]]}"}"

# When callers pass comma-separated lychee-paths, use the first entry only.
if [[ "$LYCHEE_ROOT_DIR" == *","* ]]; then
	LYCHEE_ROOT_DIR="${LYCHEE_ROOT_DIR%%,*}"
	LYCHEE_ROOT_DIR="${LYCHEE_ROOT_DIR#"${LYCHEE_ROOT_DIR%%[![:space:]]*}"}"
	LYCHEE_ROOT_DIR="${LYCHEE_ROOT_DIR%"${LYCHEE_ROOT_DIR##*[![:space:]]}"}"
fi

read -r -a tokens <<<"$RAW_ARGS"
filtered=()
skip_next=false
for token in "${tokens[@]}"; do
	if [[ "$skip_next" == true ]]; then
		skip_next=false
		continue
	fi
	case "$token" in
	--format | --output) skip_next=true ;;
	--format=* | --output=*) ;;
	*) filtered+=("$token") ;;
	esac
done
filtered+=(--root-dir "${LYCHEE_ROOT_DIR}")

# Caller-supplied args: written under the shared random delimiter (#1675).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"
set_github_output_multiline "args" "${filtered[*]}"
