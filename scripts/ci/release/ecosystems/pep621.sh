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

if ! python3 -c 'import tomlkit' 2>/dev/null; then
	log_info "[pep621] Installing tomlkit..."
	python3 -m pip install --quiet 'tomlkit>=0.13,<1'
fi

log_info "[pep621] Updating $MANIFEST_PATH → $NEXT_VERSION"

python3 "$SCRIPT_DIR/update-python-version.py" "$MANIFEST_PATH" "$NEXT_VERSION"

ACTUAL=$(python3 "$SCRIPT_DIR/read-pyproject-field.py" "$MANIFEST_PATH" version)
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[pep621] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[pep621] $MANIFEST_PATH updated to $NEXT_VERSION"
