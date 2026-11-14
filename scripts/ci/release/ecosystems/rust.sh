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

# Official rustup toolchain names a caller's rust-toolchain file may pin, in
# rustup's grammar <channel>[-<date>][-<host>]: channel stable|beta|nightly
# or a release number (1.94, 1.94.0, optionally -beta[.N]), date
# YYYY-MM-DD, host a target triple (3-4 lowercase components, each starting
# with a letter: x86_64-unknown-linux-gnu, aarch64-apple-darwin). Anything
# else (a `rustup toolchain link` name, a path, spaces) is refused. rustup
# refuses to link a custom toolchain under a name that parses as an official
# one, so a name matching this is always a toolchain rustup downloads.
RUST_CHANNEL_RE='^(stable|beta|nightly|[0-9]+\.[0-9]+(\.[0-9]+)?(-beta(\.[0-9]+)?)?)'
RUST_CHANNEL_RE+='(-[0-9]{4}-[0-9]{2}-[0-9]{2})?'
RUST_CHANNEL_RE+='(-[a-z][a-z0-9_]*(-[a-z][a-z0-9_]*){2,3})?$'

# Set TOOLCHAIN from the caller's rust-toolchain file in the working
# directory (where rustup looks), or to stable when there is none. Sets
# TOOLCHAIN_FROM_FILE=true and TOOLCHAIN_FILE when a file supplied it.
# Exits with an ::error when the file names a toolchain that cannot run here.
TOOLCHAIN_FROM_FILE="false"
TOOLCHAIN_FILE=""
resolve_caller_toolchain() {
	# C locale: [a-z] in RUST_CHANNEL_RE means ASCII lowercase only.
	local channel rc=0 file LC_ALL=C
	TOOLCHAIN="stable"
	if [[ -f rust-toolchain && -f rust-toolchain.toml ]]; then
		echo "::error::[rust] Both rust-toolchain and rust-toolchain.toml exist; keep one" \
			"so the release job knows which toolchain Cargo.lock is resolved with." >&2
		exit 1
	fi
	for file in rust-toolchain.toml rust-toolchain; do
		[[ -f "$file" ]] && TOOLCHAIN_FILE="$file"
	done
	[[ -n "$TOOLCHAIN_FILE" ]] || return 0
	# -I: nothing from the checkout on sys.path (the script needs stdlib only).
	channel=$(python3 -I "$SCRIPT_DIR/read-rust-toolchain.py" "$TOOLCHAIN_FILE") || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		echo "::error::[rust] ${TOOLCHAIN_FILE} sets [toolchain] path. A toolchain supplied" \
			"by the repository cannot run in the release job, which holds the release App" \
			"token (#1545). Pin an official channel (stable, beta, nightly[-YYYY-MM-DD]" \
			"or a version such as 1.94.0, optionally with a host triple) instead." >&2
		exit 1
	fi
	if [[ "$rc" -ne 0 ]]; then
		echo "::error::[rust] Cannot read the toolchain from ${TOOLCHAIN_FILE}." >&2
		exit 1
	fi
	[[ -n "$channel" ]] || return 0
	if [[ ! "$channel" =~ $RUST_CHANNEL_RE ]]; then
		echo "::error::[rust] ${TOOLCHAIN_FILE} pins channel '${channel}', which is not an" \
			"official toolchain name (<channel>[-YYYY-MM-DD][-<host triple>], channel" \
			"stable, beta, nightly or a version such as 1.94.0). The release job runs" \
			"only official toolchains, since it holds the release App token (#1545)." >&2
		exit 1
	fi
	TOOLCHAIN="$channel"
	TOOLCHAIN_FROM_FILE="true"
}

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
	# This job holds the caller's release App token (#1451), and the updater
	# runs with the caller's checkout as the working directory (#1545). See
	# docs/workflow-contract.md (release workflows) for the full analysis.
	#
	# Toolchain: through rustup, a committed rust-toolchain.toml with
	# `path = ...` would make `cargo` the caller's own binary. The toolchain
	# is always passed as RUSTUP_TOOLCHAIN, which overrides that file: the
	# job's own RUSTUP_TOOLCHAIN when set, else the file's `channel` when it
	# is an official name (it drives MSRV-aware resolution, so it is
	# honoured), else stable. A `path` toolchain or any other channel cannot
	# run here and fails the job.
	TOOLCHAIN="${RUSTUP_TOOLCHAIN:-}"
	if [[ -z "$TOOLCHAIN" ]]; then
		resolve_caller_toolchain
	fi
	if [[ "$TOOLCHAIN_FROM_FILE" == "true" ]] && command -v rustup >/dev/null 2>&1; then
		log_info "[rust] Installing toolchain $TOOLCHAIN (from $TOOLCHAIN_FILE)"
		# From an empty directory, so rustup reads no override file.
		TC_DIR="$(mktemp -d)"
		(cd "$TC_DIR" && rustup toolchain install --profile minimal --no-self-update \
			"$TOOLCHAIN" 2>&1 | tail -5)
		rmdir "$TC_DIR"
	fi

	# cargo reads .cargo/config.toml from its working directory and every
	# parent, plus $CARGO_HOME/config.toml. It does not read one next to the
	# --manifest-path. A caller's config can run its own code even for a
	# lockfile: build.rustc / rustc-wrapper / rustc-workspace-wrapper run as
	# `rustc -vV` whenever the crate has a dependency, and [env] (applied to
	# every process cargo spawns, not only builds) can force PATH, or set
	# LD_PRELOAD / DYLD_INSERT_LIBRARIES to load a library from the checkout.
	# So cargo runs:
	#   - from an empty temporary directory, with --manifest-path, so no
	#     config from the checkout is discovered;
	#   - with CARGO_HOME a fresh empty directory, so no config.toml or
	#     credentials from the runner's cargo home apply either. The registry
	#     cache is not shared: the sparse index is fetched cold, only the
	#     entries the lockfile needs (index.crates.io, in the preset);
	#   - with RUSTC the toolchain's rustc by absolute path, so PATH does not
	#     matter, and both wrappers empty.
	# Trade-off: the caller's cargo config (source replacement, private
	# registries, [env], [resolver]) is not applied when the release
	# regenerates Cargo.lock. No registered consumer uses one.
	CARGO_ROOT="$(mktemp -d)"
	mkdir "$CARGO_ROOT/cwd" "$CARGO_ROOT/home"
	MANIFEST_ABS="$(cd "$(dirname "$CARGO_TOML")" && pwd -P)/$(basename "$CARGO_TOML")"
	if command -v rustup >/dev/null 2>&1; then
		CARGO_BIN="$(cd "$CARGO_ROOT/cwd" && RUSTUP_TOOLCHAIN="$TOOLCHAIN" rustup which cargo)"
		RUSTC_BIN="$(cd "$CARGO_ROOT/cwd" && RUSTUP_TOOLCHAIN="$TOOLCHAIN" rustup which rustc)"
	else
		CARGO_BIN="$(command -v cargo)"
		RUSTC_BIN="$(command -v rustc || true)"
	fi
	if [[ "$CARGO_BIN" != /* || "$RUSTC_BIN" != /* ]]; then
		rm -rf "$CARGO_ROOT"
		echo "::error::[rust] Cannot find cargo and rustc for toolchain ${TOOLCHAIN}." >&2
		exit 1
	fi
	log_info "[rust] Regenerating Cargo.lock with toolchain $TOOLCHAIN..."
	CARGO_RC=0
	(cd "$CARGO_ROOT/cwd" &&
		CARGO_HOME="$CARGO_ROOT/home" RUSTUP_TOOLCHAIN="$TOOLCHAIN" RUSTC="$RUSTC_BIN" \
			RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER='' \
			"$CARGO_BIN" generate-lockfile --manifest-path "$MANIFEST_ABS" 2>&1 | tail -5) ||
		CARGO_RC=$?
	rm -rf "$CARGO_ROOT"
	if [[ "$CARGO_RC" -ne 0 ]]; then
		log_error "[rust] cargo generate-lockfile failed"
		exit 1
	fi
	log_success "[rust] Cargo.lock regenerated"
fi
