#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Rust/Cargo version files
#
# Updates the version field in the [workspace.package] or [package] section
# of Cargo.toml using awk (scoped to avoid touching dependency versions).
# Regenerates Cargo.lock if present.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3)
#
# Optional (via ECOSYSTEM_CONFIG_JSON):
#   cargo-toml - Path to Cargo.toml (default: ./Cargo.toml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:={}}"

CARGO_TOML=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."cargo-toml" // "Cargo.toml"')

if [[ ! -f "$CARGO_TOML" ]]; then
	log_error "Cargo.toml not found at: $CARGO_TOML"
	exit 1
fi

log_info "[rust] Updating $CARGO_TOML → $NEXT_VERSION"

# Update version in [workspace.package] or [package] section only.
# The awk script tracks which TOML section we're in and only replaces
# the version line when inside [package] or [workspace.package].
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

awk -v new_version="$NEXT_VERSION" '
/^\[(workspace\.)?package\]/ { in_package=1 }
/^\[/ && !/^\[(workspace\.)?package\]/ { in_package=0 }
in_package && /^version[[:space:]]*=/ {
	print "version = \"" new_version "\""
	next
}
{ print }
' "$CARGO_TOML" >"$TMPFILE"

mv "$TMPFILE" "$CARGO_TOML"
trap - EXIT

# Verify the write
ACTUAL=$(awk '
/^\[(workspace\.)?package\]/ { in_pkg=1 }
/^\[/ && !/^\[(workspace\.)?package\]/ { in_pkg=0 }
in_pkg && /^version[[:space:]]*=/ {
	gsub(/.*"/, "", $0); gsub(/".*/, "", $0); print; exit
}
' "$CARGO_TOML")

if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[rust] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[rust] $CARGO_TOML updated to $NEXT_VERSION"

# Regenerate Cargo.lock if it exists
if [[ -f "Cargo.lock" ]]; then
	if command -v cargo >/dev/null 2>&1; then
		log_info "[rust] Regenerating Cargo.lock..."
		cargo generate-lockfile 2>&1 | tail -5
		log_success "[rust] Cargo.lock regenerated"
	else
		log_warn "[rust] cargo not found — installing Rust toolchain..."
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal 2>&1 | tail -3
		# shellcheck source=/dev/null
		source "$HOME/.cargo/env"
		log_info "[rust] Regenerating Cargo.lock..."
		cargo generate-lockfile 2>&1 | tail -5
		log_success "[rust] Cargo.lock regenerated"
	fi
fi
