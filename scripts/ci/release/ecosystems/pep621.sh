#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update [project].version in a PEP 621 pyproject.toml (kind: pep621)
#
# Updates only the listed pyproject.toml — does not touch __init__.py or
# uv.lock (unlike ecosystems/python.sh). Pair with version-update-script or
# additional manifests when those files must move in lockstep.
#
# Required environment variables:
#   NEXT_VERSION  - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFEST_PATH - Path to pyproject.toml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFEST_PATH:?MANIFEST_PATH is required}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
	log_error "[pep621] pyproject.toml not found at: $MANIFEST_PATH"
	exit 1
fi

# `python3 -c` and `python3 -m` put the working directory first on sys.path,
# and the working directory is the caller's checkout: a committed tomlkit.py
# or pip.py would run there (#1356). Run them from an empty directory instead
# (not -I, which would also hide a user-site tomlkit and break pip's
# --user fallback). The `python3 "$SCRIPT_DIR/x.py"` calls below put the
# lgtm-ci script directory first, not the working directory.
python3_outside_workspace() {
	local dir rc=0
	dir="$(mktemp -d)"
	(cd "$dir" && python3 "$@") || rc=$?
	rmdir "$dir"
	return "$rc"
}

if ! python3_outside_workspace -c 'import tomlkit' 2>/dev/null; then
	log_info "[pep621] Installing tomlkit..."
	python3_outside_workspace -m pip install --quiet 'tomlkit>=0.13,<1'
fi

log_info "[pep621] Updating $MANIFEST_PATH → $NEXT_VERSION"

python3 "$SCRIPT_DIR/update-python-version.py" "$MANIFEST_PATH" "$NEXT_VERSION"

ACTUAL=$(python3 "$SCRIPT_DIR/read-pyproject-field.py" "$MANIFEST_PATH" version)
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[pep621] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[pep621] $MANIFEST_PATH updated to $NEXT_VERSION"
