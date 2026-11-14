#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Python version files
#
# Updates [project].version in pyproject.toml using a tomlkit-based
# Python script (preserves formatting and comments), rewrites the
# own-package version in uv.lock when present, and updates the
# __version__ dunder in __init__.py.
#
# Runs in the version-PR job, which holds the caller's release App token
# (#1451), with the caller's checkout as the working directory. Nothing
# here may import or execute code from that checkout (#1545); see the
# python3 calls and the uv.lock section below.
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

# `python3 -c` and `python3 -m` put the working directory first on sys.path,
# and the working directory is the caller's checkout: a committed tomlkit.py
# or pip.py would run there (#1545). Run them from an empty directory instead
# (not -I, which would also hide a user-site tomlkit and break pip's
# --user fallback). The `python3 "$SCRIPT_DIR/x.py"` calls below put the
# lgtm-ci script directory first, not the working directory. Same helper as
# pep621.sh.
python3_outside_workspace() {
	local dir rc=0
	dir="$(mktemp -d)"
	(cd "$dir" && python3 "$@") || rc=$?
	rmdir "$dir"
	return "$rc"
}

# Ensure tomlkit is available (only after confirming we need it)
if ! python3_outside_workspace -c 'import tomlkit' 2>/dev/null; then
	log_info "[python] Installing tomlkit..."
	python3_outside_workspace -m pip install --quiet 'tomlkit>=0.13,<1'
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
# Re-lock uv.lock (own-package version)
# =============================================================================

# Without this, uv-based consumers drift: pyproject.toml carries the new
# version while uv.lock keeps the previous one for the project's own
# package (see lgtm-ci issue #376).

PYPROJECT_DIR=$(dirname "$PYPROJECT")

PROJECT_NAME=$(python3 "$SCRIPT_DIR/read-pyproject-field.py" "$PYPROJECT" name)

# uv records package names in uv.lock in PEP 503 normalized form:
# lowercase, with runs of '-', '_', '.' collapsed to a single dash.
LOCK_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g')

# Locate the lockfile: uv workspaces keep a single uv.lock at the
# workspace root, so check beside pyproject.toml first, then walk up
# parent directories (bounded by the git repository root — or the
# working directory outside a checkout — mirroring uv's own
# project-root discovery). A parent lockfile is only used when it
# locks this project as a local (workspace member) package — an
# unrelated root uv.lock must never be rewritten.
UV_LOCK=""
SEARCH_DIR=$(cd "$PYPROJECT_DIR" && pwd)
STOP_DIR=$(git -C "$SEARCH_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ -f "$SEARCH_DIR/uv.lock" ]]; then
	UV_LOCK="$SEARCH_DIR/uv.lock"
else
	while [[ -n "$LOCK_NAME" && "$SEARCH_DIR" == "$STOP_DIR"/* ]]; do
		SEARCH_DIR=$(dirname "$SEARCH_DIR")
		if [[ -f "$SEARCH_DIR/uv.lock" ]]; then
			# Nearest ancestor lockfile decides: accept it only when
			# it carries this project as a local package.
			LOCAL_VERSION=$(python3 "$SCRIPT_DIR/read-uv-lock-version.py" \
				"$SEARCH_DIR/uv.lock" "$LOCK_NAME" --local-only \
				--project-dir "$PYPROJECT_DIR" 2>/dev/null || true)
			if [[ -n "$LOCAL_VERSION" ]]; then
				UV_LOCK="$SEARCH_DIR/uv.lock"
			else
				log_info "[python] Ignoring $SEARCH_DIR/uv.lock — $LOCK_NAME is not a local package there"
			fi
			break
		fi
	done
fi

if [[ -n "$UV_LOCK" ]]; then
	if [[ -z "$PROJECT_NAME" ]]; then
		log_error "[python] Could not read project name from $PYPROJECT for uv.lock update"
		exit 1
	fi

	# Rewrite only the own-package version entry with tomlkit. For a
	# version-only bump this is the change 'uv lock' would make, since
	# dependencies are untouched; it does not re-resolve anything. The
	# entry is the one whose local source is this project's directory, and
	# version-pinned references to it follow; anything ambiguous fails
	# without writing.
	#
	# 'uv lock' is deliberately not run here (#1545). In the caller's
	# checkout it executes caller-controlled code in this token-holding
	# job: it queries a committed .venv/bin/python, and it calls the
	# project's build backend (backend-path may point into the checkout)
	# for any workspace member with dynamic metadata. '--no-build' does not
	# stop the latter: it covers source distributions, not the project's
	# own members. The rewrite was already the path taken wherever uv is
	# absent or its lock could not reach the index.
	log_info "[python] Updating own-package version in $UV_LOCK"
	python3 "$SCRIPT_DIR/update-uv-lock-version.py" "$UV_LOCK" "$LOCK_NAME" "$NEXT_VERSION" \
		--project-dir "$PYPROJECT_DIR"

	# Verify the own-package entry now carries the new version
	ACTUAL=$(python3 "$SCRIPT_DIR/read-uv-lock-version.py" "$UV_LOCK" "$LOCK_NAME" \
		--project-dir "$PYPROJECT_DIR")
	if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
		log_error "[python] uv.lock verification failed: expected $NEXT_VERSION, got $ACTUAL"
		exit 1
	fi

	log_success "[python] $UV_LOCK updated to $NEXT_VERSION"
else
	log_info "[python] No uv.lock found — skipping re-lock"
fi

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
ACTUAL=$(awk '/^__version__[[:space:]]*=/ {
		gsub(/^__version__[[:space:]]*=[[:space:]]*["'"'"']/, "")
		gsub(/["'"'"'].*/, "")
		print
		exit
	}' "$INIT_FILE")
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[python] __init__.py verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[python] $INIT_FILE updated to $NEXT_VERSION"
