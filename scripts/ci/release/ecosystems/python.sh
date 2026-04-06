#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Python version files
#
# Updates [project].version in pyproject.toml using a tomlkit-based
# Python script (preserves formatting and comments), and updates
# the __version__ dunder in __init__.py.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   pyproject - Path to pyproject.toml (default: ./pyproject.toml)
#   init      - Path to __init__.py with __version__ (default: auto-derived)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:="{}"}"

PYPROJECT=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.pyproject // "pyproject.toml"')
INIT_FILE=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '.init // ""')

# =============================================================================
# Update pyproject.toml
# =============================================================================

if [[ ! -f "$PYPROJECT" ]]; then
	log_error "pyproject.toml not found at: $PYPROJECT"
	exit 1
fi

# Ensure tomlkit is available (only after confirming we need it)
if ! python3 -c 'import tomlkit' 2>/dev/null; then
	log_info "[python] Installing tomlkit..."
	python3 -m pip install --quiet 'tomlkit>=0.13,<1'
fi

log_info "[python] Updating $PYPROJECT → $NEXT_VERSION"

# Use the tomlkit-based updater script (preserves formatting)
python3 "$SCRIPT_DIR/update-python-version.py" "$PYPROJECT" "$NEXT_VERSION"

# Verify the write
ACTUAL=$(python3 "$SCRIPT_DIR/read-pyproject-field.py" "$PYPROJECT" version)

if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[python] pyproject.toml verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[python] $PYPROJECT updated to $NEXT_VERSION"

# =============================================================================
# Update __init__.py __version__ dunder
# =============================================================================

# Derive init file path from package name if not explicitly set
if [[ -z "$INIT_FILE" ]]; then
	PKG_NAME=$(python3 "$SCRIPT_DIR/read-pyproject-field.py" "$PYPROJECT" name)
	# PEP 503 normalization: lowercase and dashes to underscores
	PKG_NAME="${PKG_NAME//-/_}"
	PKG_NAME=$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]')

	if [[ -z "$PKG_NAME" ]]; then
		log_warn "[python] Could not derive package name from $PYPROJECT — skipping __init__.py"
		exit 0
	fi

	# Check common locations
	PYPROJECT_DIR=$(dirname "$PYPROJECT")
	for candidate in \
		"${PYPROJECT_DIR}/${PKG_NAME}/__init__.py" \
		"${PYPROJECT_DIR}/src/${PKG_NAME}/__init__.py"; do
		if [[ -f "$candidate" ]] && grep -q '^__version__[[:space:]]*=' "$candidate"; then
			INIT_FILE="$candidate"
			break
		fi
	done

	if [[ -z "$INIT_FILE" ]]; then
		log_warn "[python] No __init__.py with __version__ found for $PKG_NAME — skipping"
		exit 0
	fi
fi

if [[ ! -f "$INIT_FILE" ]]; then
	log_error "__init__.py not found at: $INIT_FILE"
	exit 1
fi

# Verify the file actually has a __version__ assignment before we sed it,
# otherwise the sed is a silent no-op and we'd only catch it at verification.
if ! grep -qE '^__version__[[:space:]]*=' "$INIT_FILE"; then
	log_error "[python] $INIT_FILE has no __version__ assignment to update"
	exit 1
fi

log_info "[python] Updating $INIT_FILE → $NEXT_VERSION"

write_file_atomic "$INIT_FILE" \
	sed "s|^__version__[[:space:]]*=.*|__version__ = \"$NEXT_VERSION\"|" "$INIT_FILE"

# Verify the write
ACTUAL=$(awk '/^__version__[[:space:]]*=/ { gsub(/.*["'"'"']/, ""); gsub(/["'"'"'].*/, ""); print; exit }' "$INIT_FILE")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[python] __init__.py verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[python] $INIT_FILE updated to $NEXT_VERSION"
