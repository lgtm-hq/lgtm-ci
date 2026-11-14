#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Rust/Cargo version files
#
# Updates the version value in the [package] and/or [workspace.package]
# table of Cargo.toml. The manifest is always read and edited by
# read-cargo-manifest.py (python3 >= 3.11, stdlib tomllib only): it scans
# the TOML, strings included, so a `version = "..."` inside a multiline
# description is never edited, rewrites only the value (spacing, comments
# and line endings kept), and checks with tomllib that the parsed manifest
# changed in that value only. A manifest tomllib cannot parse fails the job;
# there is no regex fallback. TOML 1.1 syntax (an inline table over several
# lines, `version = {\n workspace = true,\n}`) only parses on Python >= 3.15
# (newer macOS images; not the Ubuntu or Windows ones), and fails elsewhere:
# write such a table on one line so it works on every runner.
# Regenerates the Cargo.lock cargo uses for that manifest when it exists:
# the one beside it, or for a workspace member the one at the workspace
# root (#1554), and checks the lock records the new version.
#
# A member whose version is inherited (`version.workspace = true`,
# `version = { workspace = true }` or any other spelling of that key, told
# from the parsed manifest) has no version of its own (#1558). Its manifest
# is left alone and the `[workspace.package] version` of the workspace root
# cargo names is bumped instead (that value only, the rest of the root
# manifest kept); cargo is then asked again that every inheriting package
# resolves to the new version, and those packages are checked in the
# regenerated lock. This needs cargo, and fails closed when the root is
# outside the checkout or has no `[workspace.package] version`.
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

# $(...) strips trailing newlines, so a cargo-toml of "Cargo.toml\n" would
# silently become another path: reject control characters outright.
if ! jq -e '(."cargo-toml" // "Cargo.toml") | type == "string"
	and (explode | any(. < 32 or . == 127) | not)' <<<"$ECOSYSTEM_CONFIG_JSON" >/dev/null; then
	echo "::error::[rust] cargo-toml must be a string path without newlines or" \
		"other control characters." >&2
	exit 1
fi
CARGO_TOML=$(echo "$ECOSYSTEM_CONFIG_JSON" | jq -r '."cargo-toml" // "Cargo.toml"')

if [[ ! -f "$CARGO_TOML" ]]; then
	log_error "Cargo.toml not found at: $CARGO_TOML"
	exit 1
fi

# Run read-cargo-manifest.py: data only (stdlib tomllib/json), with -I and
# from an empty directory so nothing from the checkout is imported.
# Usage: read_manifest <subcommand> <absolute path> [args...]
read_manifest() {
	local dir rc=0
	dir="$(mktemp -d)"
	(cd "$dir" && python3 -I "$SCRIPT_DIR/read-cargo-manifest.py" "$@") || rc=$?
	rmdir "$dir"
	return "$rc"
}

# The manifest is only ever read and edited through tomllib (Python 3.11).
PY_DIR="$(mktemp -d)"
PY_RC=0
(cd "$PY_DIR" && python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))') \
	>/dev/null 2>&1 || PY_RC=$?
rmdir "$PY_DIR"
if [[ "$PY_RC" -ne 0 ]]; then
	echo "::error::[rust] python3 >= 3.11 is required to read ${CARGO_TOML} (stdlib" \
		"tomllib); found: $(python3 --version 2>&1 || echo 'no python3')." >&2
	exit 1
fi

# The temporary copy of a manifest being rewritten, removed on any exit
# before it is renamed into place.
MANIFEST_TMP=""
remove_manifest_tmp() {
	if [[ -n "$MANIFEST_TMP" ]]; then
		rm -f "$MANIFEST_TMP"
	fi
}
trap remove_manifest_tmp EXIT

# Set the string version of each <table> (package, workspace.package) in
# <file> to NEXT_VERSION: read-cargo-manifest.py writes the edited manifest
# to a copy beside it (same filesystem, same mode), having checked that the
# parsed manifest changed in those values only, and the copy is renamed
# over <file>. Usage: rewrite_manifest <absolute file> <table>...
rewrite_manifest() {
	local file="$1"
	shift
	MANIFEST_TMP="$(mktemp "$(dirname "$file")/.Cargo.toml.XXXXXX")" || return 1
	cp -p "$file" "$MANIFEST_TMP" || return 1
	read_manifest set-version "$file" "$NEXT_VERSION" "$@" >"$MANIFEST_TMP" || return
	mv "$MANIFEST_TMP" "$file" || return 1
	MANIFEST_TMP=""
}

# Fail the job for a manifest the reader could not handle (exit <rc>).
# Usage: manifest_error <rc> <manifest>
manifest_error() {
	if [[ "$1" -eq 4 ]]; then
		echo "::error::[rust] Cannot parse $2 with python3's tomllib, so its version" \
			"cannot be read or set. TOML 1.1 syntax, such as an inline table over" \
			"several lines (version = {<newline> workspace = true,<newline>}), needs" \
			"Python >= 3.15 to parse: write that table on one line." >&2
	else
		echo "::error::[rust] Cannot set the version in $2 (see the error above);" \
			"nothing was changed." >&2
	fi
	exit 1
}

MANIFEST_ABS="$CARGO_TOML"
[[ "$MANIFEST_ABS" == /* ]] || MANIFEST_ABS="$PWD/$CARGO_TOML"

# A member whose [package] version is `version.workspace = true` (or
# `version = { workspace = true }`, in any spelling) has no version of its
# own: it inherits the root's [workspace.package] version (#1558), which is
# bumped instead once cargo has named the root (below). Always decided on
# the parsed manifest, never on how its lines look.
INHERITED="false"
SOURCE_RC=0
VERSION_SOURCE="$(read_manifest version-source "$MANIFEST_ABS")" || SOURCE_RC=$?
if [[ "$SOURCE_RC" -ne 0 ]]; then
	manifest_error "$SOURCE_RC" "$CARGO_TOML"
fi
if [[ "$VERSION_SOURCE" == "workspace" ]]; then
	INHERITED="true"
fi

if [[ "$INHERITED" == "true" ]]; then
	log_info "[rust] $CARGO_TOML inherits its version from [workspace.package];" \
		"bumping the workspace root"
else
	log_info "[rust] Updating $CARGO_TOML → $NEXT_VERSION"
	# Every string version in [package] and [workspace.package] (a root
	# manifest can have both), as the line rewrite before it did.
	TABLES_RC=0
	TABLES="$(read_manifest literal-tables "$MANIFEST_ABS")" || TABLES_RC=$?
	if [[ "$TABLES_RC" -ne 0 ]]; then
		manifest_error "$TABLES_RC" "$CARGO_TOML"
	fi
	TABLE_LIST=()
	while read -r TABLE; do
		TABLE_LIST+=("$TABLE")
	done <<<"$TABLES"
	REWRITE_RC=0
	rewrite_manifest "$MANIFEST_ABS" "${TABLE_LIST[@]}" || REWRITE_RC=$?
	if [[ "$REWRITE_RC" -ne 0 ]]; then
		manifest_error "$REWRITE_RC" "$CARGO_TOML"
	fi
	log_success "[rust] $CARGO_TOML updated to $NEXT_VERSION"
fi

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

# True when <string> holds a newline or another control character.
# Usage: has_control <string>
has_control() {
	local LC_ALL=C
	[[ "$1" == *[[:cntrl:]]* ]]
}

# Set REPLY to the absolute path of directory <dir>, resolved with
# `pwd <-L|-P>`, keeping any trailing newline $(...) would strip (the
# callers reject such paths). Usage: dir_path <-L|-P> <dir>
dir_path() {
	local out
	out="$(cd "$2" 2>/dev/null && pwd "$1" && printf x)" || return 1
	REPLY="${out%$'\n'x}"
}

dir_path -P . || exit 1
CHECKOUT="$REPLY"

# True when the canonical path <path> is the checkout or inside it.
# Usage: inside_checkout <path>
inside_checkout() {
	[[ "$1" == "$CHECKOUT" || "$1" == "$CHECKOUT"/* ]]
}

# True when a Cargo.lock sits beside the manifest or in a directory above
# it, up to the checkout (the working directory). Only consulted when cargo
# is not installed, to tell whether the job needed it; with cargo the lock
# is found through the workspace root cargo reports (#1554). The walk never
# leaves the checkout, so a manifest outside it has no candidate.
lockfile_candidate() {
	local dir
	dir="$(cd "$(dirname "$CARGO_TOML")" && pwd -P)"
	while inside_checkout "$dir"; do
		[[ -f "$dir/Cargo.lock" ]] && return 0
		[[ "$dir" == "$CHECKOUT" ]] && return 1
		dir="$(dirname "$dir")"
	done
	return 1
}

# Print the first Cargo.lock anywhere in the checkout, skipping .git,
# ./target and the release tooling's own checkout when it sits inside the
# caller's. Prints "(unreadable)" when the search fails, so a caller that
# fails closed on any output does so. Usage: checkout_lockfile
checkout_lockfile() {
	local prune=(-path ./.git -o -path ./target)
	if dir_path -P "$SCRIPT_DIR/../../../.." && [[ "$REPLY" == "$CHECKOUT"/* ]]; then
		prune+=(-o -path "./${REPLY#"$CHECKOUT"/}")
	fi
	find . \( "${prune[@]}" \) -prune -o -name Cargo.lock -print -quit 2>/dev/null ||
		echo "(unreadable)"
}

# Run the toolchain's cargo isolated from the caller's configuration (see
# the comment where CARGO_ROOT is set). Usage: isolated_cargo <args...>
isolated_cargo() {
	(cd "$CARGO_ROOT/cwd" &&
		CARGO_HOME="$CARGO_ROOT/home" RUSTUP_TOOLCHAIN="$TOOLCHAIN" RUSTC="$RUSTC_BIN" \
			RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER='' "$CARGO_BIN" "$@")
}

# Print the version a Cargo.lock records for the local (source-less)
# package <name>, one line per match. Usage: locked_version <lock> <name>
locked_version() {
	awk -v want="$2" '
	function flush() {
		if (name == want && !src) print ver
		name = ""; ver = ""; src = 0
	}
	/^\[/ { flush(); next }
	/^name = "/ { split($0, a, "\""); name = a[2] }
	/^version = "/ { split($0, a, "\""); ver = a[2] }
	/^source = / { src = 1 }
	END { flush() }
	' "$1"
}

# Regenerating Cargo.lock requires a Rust toolchain.
# The calling workflow (reusable-release-version-pr.yml) installs Rust
# via dtolnay/rust-toolchain when the rust ecosystem is declared. Without
# cargo the step can only tell whether a lock sits beside the manifest or
# above it in the checkout; with none there, nothing needs cargo.
if ! command -v cargo >/dev/null 2>&1; then
	if [[ "$INHERITED" == "true" ]]; then
		log_error "[rust] cargo not found — it names the workspace root whose" \
			"[workspace.package] version ${CARGO_TOML} inherits"
		exit 1
	fi
	if lockfile_candidate; then
		log_error "[rust] cargo not found — the calling workflow must install Rust"
		exit 1
	fi
	log_info "[rust] cargo not found and no Cargo.lock above ${CARGO_TOML}; skipping"
	exit 0
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
# Finding the workspace root (`cargo metadata --no-deps`) runs the same
# way: it only parses manifests, but it must not read the config either.
#
# Paths: cargo is given the lexical paths it reports and accepts (the
# manifest's directory with symlinks kept, then the workspace_root it
# reports). Workspace membership is checked on those, so a member listed
# as `alias` where alias -> real, or `package.workspace = "../alias"` with
# alias -> ws, only resolves through them. Physical paths (symlinks
# followed) serve only to check that the root and its lock are inside the
# checkout. Any path holding a newline or other control character fails
# the job instead, as $(...) and line-based tools would mangle it.
CARGO_ROOT="$(mktemp -d)"
mkdir "$CARGO_ROOT/cwd" "$CARGO_ROOT/home"
if ! dir_path -L "$(dirname "$CARGO_TOML")" || has_control "$REPLY" ||
	has_control "$CHECKOUT"; then
	rm -rf "$CARGO_ROOT"
	echo "::error::[rust] The path of ${CARGO_TOML} or of the checkout holds a newline" \
		"or another control character." >&2
	exit 1
fi
MANIFEST="${REPLY%/}/${CARGO_TOML##*/}"
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

# Fail with an ::error and leave every lock untouched. Usage: lock_error <msg...>
lock_error() {
	rm -rf "$CARGO_ROOT"
	echo "::error::[rust] $*" >&2
	exit 1
}

# The lock cargo uses is the one at the workspace root: the manifest's
# own directory for a standalone crate or the workspace root manifest,
# the root above it for a member (#1554), or a sibling directory for a
# member whose package.workspace points there. cargo is always asked,
# since a lock outside the manifest's ancestors is otherwise missed.
METADATA_RC=0
METADATA="$(isolated_cargo metadata --no-deps --format-version 1 \
	--manifest-path "$MANIFEST" 2>"$CARGO_ROOT/metadata.err")" || METADATA_RC=$?
WORKSPACE_ROOT=""
ROOT_STATE="missing"
if [[ "$METADATA_RC" -eq 0 ]]; then
	ROOT_STATE="$(jq -r '.workspace_root
		| if type != "string" then "missing"
		  elif explode | any(. < 32 or . == 127) then "control"
		  else "ok" end' <<<"$METADATA" 2>/dev/null || echo missing)"
fi
if [[ "$ROOT_STATE" == "control" ]]; then
	lock_error "cargo reports a workspace root for ${CARGO_TOML} that holds a newline" \
		"or another control character; the release does not handle such a path."
fi
if [[ "$ROOT_STATE" == "ok" ]]; then
	WORKSPACE_ROOT="$(jq -r '.workspace_root' <<<"$METADATA")"
fi
if [[ "$WORKSPACE_ROOT" != /* ]]; then
	tail -5 "$CARGO_ROOT/metadata.err" >&2 || true
	if [[ "$INHERITED" == "true" ]]; then
		lock_error "cargo cannot determine the workspace of ${CARGO_TOML}, whose" \
			"[package] version is inherited from it (version.workspace = true), so the" \
			"release cannot bump it."
	fi
	# The lock could be anywhere cargo would have pointed (a sibling
	# workspace, say), so any Cargo.lock in the checkout may be the one
	# left stale: fail. Only a checkout without one warns and goes on.
	ANY_LOCK="$(checkout_lockfile)"
	if [[ -z "$ANY_LOCK" ]]; then
		rm -rf "$CARGO_ROOT"
		echo "::warning::[rust] cargo cannot determine the workspace of ${CARGO_TOML}" \
			"and the checkout holds no Cargo.lock; not regenerating a lock." >&2
		exit 0
	fi
	lock_error "cargo cannot determine the workspace of ${CARGO_TOML}, so the release" \
		"cannot tell whether ${ANY_LOCK#./} or another Cargo.lock in the checkout" \
		"needs regenerating."
fi
# cargo reports the root lexically (package.workspace joined to the
# manifest's directory), so a symlink in the checkout could point it
# anywhere. Containment is checked on the physical path; cargo itself is
# still given the lexical one (see the comment where CARGO_ROOT is set).
dir_path -P "$WORKSPACE_ROOT" ||
	lock_error "The workspace root of ${CARGO_TOML} (${WORKSPACE_ROOT}) is not a directory."
REAL_ROOT="$REPLY"
if has_control "$REAL_ROOT"; then
	lock_error "The workspace root of ${CARGO_TOML} (${WORKSPACE_ROOT}) resolves to a" \
		"path holding a newline or another control character."
fi
if ! inside_checkout "$REAL_ROOT"; then
	lock_error "The workspace root of ${CARGO_TOML} (${WORKSPACE_ROOT}, physically" \
		"${REAL_ROOT}) is outside the checkout (${CHECKOUT}); the release only updates" \
		"files in it."
fi
# Residual TOCTOU: these checks do not pin the lock. Something swapping
# the root or its Cargo.lock for a symlink between here and cargo's write
# would redirect the write; that needs a writer already running in the
# job, which the isolated flow (no caller code runs; the input is static
# repository content) does not provide.
LOCKFILE="${REAL_ROOT}/Cargo.lock"
if [[ -L "$LOCKFILE" ]]; then
	# cargo writes through the link, so its target must be in the checkout.
	LOCK_TARGET="$(realpath "$LOCKFILE" 2>/dev/null && printf x)" || LOCK_TARGET=""
	LOCK_TARGET="${LOCK_TARGET%$'\n'x}"
	if [[ "$LOCK_TARGET" != /* ]] || has_control "$LOCK_TARGET" ||
		! inside_checkout "$LOCK_TARGET"; then
		lock_error "${LOCKFILE} is a symlink to '${LOCK_TARGET}', outside the checkout" \
			"(${CHECKOUT}); the release only updates files in it."
	fi
fi
# Local packages whose locked version must now be NEXT_VERSION: the one
# the manifest declares, or for a virtual workspace root manifest the
# members that inherit [workspace.package] version (now NEXT_VERSION).
BUMPED="$(jq -r --arg m "$MANIFEST" --arg v "$NEXT_VERSION" '
	[.packages[] | select(.manifest_path == $m) | .name] as $own
	| if ($own | length) > 0 then $own[]
	  else .packages[] | select(.version == $v) | .name end' <<<"$METADATA")"

# A member inheriting its version (#1558): bump [workspace.package] version
# in the root manifest cargo named, inside the checkout (checked above), as
# a data-only edit of that one value (rewrite_manifest). Then ask cargo
# again and check every package that inherits it now resolves to
# NEXT_VERSION; those are the packages the regenerated lock must record at.
if [[ "$INHERITED" == "true" ]]; then
	ROOT_TOML="$(realpath "${REAL_ROOT}/Cargo.toml" 2>/dev/null && printf x)" || ROOT_TOML=""
	ROOT_TOML="${ROOT_TOML%$'\n'x}"
	if [[ "$ROOT_TOML" != /* ]] || has_control "$ROOT_TOML" ||
		! inside_checkout "$ROOT_TOML" || [[ ! -f "$ROOT_TOML" ]]; then
		lock_error "The workspace root manifest ${REAL_ROOT}/Cargo.toml (resolving to" \
			"'${ROOT_TOML}') is not a file inside the checkout (${CHECKOUT}); the release" \
			"only updates files in it."
	fi
	ROOT_RC=0
	OLD_VERSION="$(read_manifest workspace-version "$ROOT_TOML")" || ROOT_RC=$?
	if [[ "$ROOT_RC" -eq 5 ]]; then
		lock_error "${CARGO_TOML} inherits its version (version.workspace = true), but" \
			"the workspace root ${ROOT_TOML} has no [workspace.package] version to bump."
	fi
	if [[ "$ROOT_RC" -eq 0 ]]; then
		rewrite_manifest "$ROOT_TOML" workspace.package || ROOT_RC=$?
	fi
	if [[ "$ROOT_RC" -ne 0 ]]; then
		rm -rf "$CARGO_ROOT"
		manifest_error "$ROOT_RC" "$ROOT_TOML"
	fi
	log_success "[rust] ${ROOT_TOML} [workspace.package] version ${OLD_VERSION}" \
		"→ ${NEXT_VERSION} (inherited by ${CARGO_TOML})"

	METADATA_RC=0
	isolated_cargo metadata --no-deps --format-version 1 --manifest-path "$MANIFEST" \
		>"$CARGO_ROOT/metadata.json" 2>"$CARGO_ROOT/metadata.err" || METADATA_RC=$?
	OWN_VERSION="$(jq -r --arg m "$MANIFEST" \
		'[.packages[] | select(.manifest_path == $m) | .version] | first // ""' \
		"$CARGO_ROOT/metadata.json" 2>/dev/null || true)"
	INHERITING=""
	if [[ "$METADATA_RC" -eq 0 && "$OWN_VERSION" == "$NEXT_VERSION" ]]; then
		INHERITING_RC=0
		INHERITING="$(read_manifest inheriting "$CARGO_ROOT/metadata.json")" ||
			INHERITING_RC=$?
		if [[ "$INHERITING_RC" -ne 0 ]]; then
			lock_error "Cannot list the packages that inherit [workspace.package]" \
				"version from cargo metadata (read-cargo-manifest.py exit" \
				"${INHERITING_RC}; see the error above)."
		fi
	fi
	if [[ -z "$INHERITING" ]]; then
		tail -5 "$CARGO_ROOT/metadata.err" >&2 || true
		lock_error "After bumping ${ROOT_TOML}, cargo resolves ${CARGO_TOML} to" \
			"'${OWN_VERSION}', expected ${NEXT_VERSION}."
	fi
	BUMPED=""
	BUMPED_LIST=""
	while read -r PKG PKG_VERSION; do
		if [[ "$PKG_VERSION" != "$NEXT_VERSION" ]]; then
			lock_error "After bumping ${ROOT_TOML}, cargo resolves ${PKG}, which inherits" \
				"[workspace.package] version, to '${PKG_VERSION}', expected ${NEXT_VERSION}."
		fi
		BUMPED+="${PKG}"$'\n'
		BUMPED_LIST+="${BUMPED_LIST:+, }${PKG}"
	done <<<"$INHERITING"
	log_info "[rust] Packages inheriting the version: ${BUMPED_LIST}"
fi
if [[ ! -f "$LOCKFILE" ]]; then
	rm -rf "$CARGO_ROOT"
	log_info "[rust] No Cargo.lock at the workspace root ${REAL_ROOT}; skipping"
	exit 0
fi

# A member that requires the released package with a version, such as
# `lib = { path = "../lib", version = "0.1.0" }`, no longer matches once
# lib is bumped past it, and cargo refuses the lock. The release fails
# here rather than ship the stale lock it used to; relax or bump that
# requirement in the same change.
log_info "[rust] Regenerating ${LOCKFILE} with toolchain $TOOLCHAIN..."
CARGO_RC=0
isolated_cargo generate-lockfile --manifest-path "${WORKSPACE_ROOT%/}/Cargo.toml" \
	2>&1 |
	tail -5 || CARGO_RC=$?
rm -rf "$CARGO_ROOT"
if [[ "$CARGO_RC" -ne 0 ]]; then
	log_error "[rust] cargo generate-lockfile failed"
	exit 1
fi
# Each bumped package must be locked at NEXT_VERSION. Other local packages
# of the same name (a path dependency outside the workspace, say) may
# keep their own versions.
while IFS= read -r PKG; do
	[[ -n "$PKG" ]] || continue
	LOCKED="$(locked_version "$LOCKFILE" "$PKG")"
	if ! grep -Fxq -- "$NEXT_VERSION" <<<"$LOCKED"; then
		echo "::error::[rust] ${LOCKFILE} records ${PKG} at '${LOCKED//$'\n'/, }'," \
			"expected ${NEXT_VERSION}." >&2
		exit 1
	fi
done <<<"$BUMPED"
log_success "[rust] Cargo.lock regenerated (${LOCKFILE})"
