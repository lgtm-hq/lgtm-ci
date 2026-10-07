#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install a pinned cargo-xwin release for the MSVC Windows leg of
#          rust-binaries CI (#1076).
#
# cargo-xwin drives clang-cl against a Windows SDK and CRT that xwin fetches
# from Microsoft (aka.ms, download.visualstudio.microsoft.com), so an MSVC
# target builds on a Linux runner under block-mode egress. The version comes
# from scripts/ci/versions.env (CARGO_XWIN_VERSION overrides). On x86_64 and
# aarch64 Linux the upstream release archive is downloaded and verified
# against the sha256 committed in versions.env before `cargo-xwin` lands in
# $CARGO_HOME/bin (#1096). Other hosts fall back to `cargo install --locked`,
# where crates.io is the trust root and no committed archive digest applies;
# that line carries an `# unverified-fallback:` marker for the installer
# contract test and is documented in docs/workflow-contract.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/network/download.sh
source "$LIB_DIR/network/download.sh"
# shellcheck source=../lib/supply_chain.sh
source "$LIB_DIR/supply_chain.sh"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

CARGO_XWIN_VERSION="${CARGO_XWIN_VERSION:-$DEFAULT_CARGO_XWIN_VERSION}"

case "$(uname -s)/$(uname -m)" in
Linux/x86_64) target="x86_64-unknown-linux-musl" ;;
Linux/aarch64 | Linux/arm64) target="aarch64-unknown-linux-musl" ;;
*) target="" ;;
esac

if [[ -z "$target" ]]; then
	echo "::notice::no committed digest for cargo-xwin on $(uname -s)/$(uname -m); installing from crates.io with --locked"
	echo "Installing cargo-xwin ${CARGO_XWIN_VERSION}..."
	# unverified-fallback: no committed archive digest for this host; crates.io is the trust root (registry checksums, --locked graph)
	cargo install cargo-xwin --locked --version "$CARGO_XWIN_VERSION"
	exit 0
fi

archive="cargo-xwin-v${CARGO_XWIN_VERSION}.${target}.tar.gz"
url="https://github.com/rust-cross/cargo-xwin/releases/download/v${CARGO_XWIN_VERSION}/${archive}"
bin_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci-cargo-xwin.XXXXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "Installing cargo-xwin ${CARGO_XWIN_VERSION} from ${url}..."
if ! download_with_retries "$url" "${tmp}/${archive}"; then
	echo "::error::failed to download ${url}" >&2
	exit 1
fi
supply_chain_verify_sha256 "${tmp}/${archive}" \
	"CARGO_XWIN_SHA256_$(supply_chain_var_suffix "$target")" \
	"$CARGO_XWIN_VERSION" "$DEFAULT_CARGO_XWIN_VERSION"

tar -xzf "${tmp}/${archive}" -C "$tmp"
if [[ ! -f "${tmp}/cargo-xwin" ]]; then
	echo "::error::${archive} does not contain a cargo-xwin binary" >&2
	exit 1
fi
mkdir -p "$bin_dir"
install -m 0755 "${tmp}/cargo-xwin" "${bin_dir}/cargo-xwin"
echo "cargo-xwin ${CARGO_XWIN_VERSION} installed to ${bin_dir}"
