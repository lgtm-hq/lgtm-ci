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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${ECOSYSTEM_CONFIG_JSON:="{}"}"

CARGO_TOML=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."cargo-toml" // "Cargo.toml"')

if [[ ! -f "$CARGO_TOML" ]]; then
	log_error "Cargo.toml not found at: $CARGO_TOML"
	exit 1
fi

log_info "[rust] Updating $CARGO_TOML → $NEXT_VERSION"

# Update version in [workspace.package] or [package] section only.
# The awk script tracks which TOML section we're in and only replaces
# the version line when inside [package] or [workspace.package].
# Portable awk: avoid ERE (workspace\.)? which fails on BSD awk
write_file_atomic "$CARGO_TOML" awk -v new_version="$NEXT_VERSION" '
/^\[package\]/ || /^\[workspace\.package\]/ { in_package=1 }
/^\[/ && !/^\[package\]/ && !/^\[workspace\.package\]/ { in_package=0 }
in_package && /^version[[:space:]]*=/ {
	print "version = \"" new_version "\""
	next
}
{ print }
' "$CARGO_TOML"

# Verify the write
ACTUAL=$(awk -F'"' '
/^\[package\]/ || /^\[workspace\.package\]/ { in_pkg=1 }
/^\[/ && !/^\[package\]/ && !/^\[workspace\.package\]/ { in_pkg=0 }
in_pkg && /^version[[:space:]]*=/ { print $2; exit }
' "$CARGO_TOML")

if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[rust] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[rust] $CARGO_TOML updated to $NEXT_VERSION"

# Regenerate Cargo.lock if it exists (derive path from Cargo.toml location)
MANIFEST_DIR=$(dirname "$CARGO_TOML")
LOCKFILE="${MANIFEST_DIR}/Cargo.lock"

# Regenerate Cargo.lock requires a Rust toolchain.
# The calling workflow (reusable-release-version-pr.yml) installs Rust
# via dtolnay/rust-toolchain when the rust ecosystem is declared.
if [[ -f "$LOCKFILE" ]]; then
	if ! command -v cargo >/dev/null 2>&1; then
		log_error "[rust] cargo not found — the calling workflow must install Rust"
		exit 1
	fi
	log_info "[rust] Regenerating Cargo.lock..."
	cargo generate-lockfile --manifest-path "$CARGO_TOML" 2>&1 | tail -5
	log_success "[rust] Cargo.lock regenerated"
fi
