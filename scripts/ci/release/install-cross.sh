#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install a pinned cargo-cross release for rust-binaries CI.
#
# The version comes from scripts/ci/versions.env (CROSS_VERSION overrides).
# On x86_64 Linux and x86_64 macOS the upstream release archive is downloaded
# and verified against the sha256 committed in versions.env before `cross`
# lands in $CARGO_HOME/bin (#1096). Other hosts fall back to
# `cargo install --locked`, where crates.io is the trust root; that path is
# listed in scripts/ci/maintenance/unverified-installers.allowlist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/network/download.sh
source "$LIB_DIR/network/download.sh"
# shellcheck source=../lib/supply_chain.sh
source "$LIB_DIR/supply_chain.sh"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

CROSS_VERSION="${CROSS_VERSION:-$DEFAULT_CROSS_VERSION}"

case "$(uname -s)/$(uname -m)" in
Linux/x86_64) target="x86_64-unknown-linux-gnu" ;;
Darwin/x86_64) target="x86_64-apple-darwin" ;;
*) target="" ;;
esac

if [[ -z "$target" ]]; then
	echo "::notice::no committed digest for cross on $(uname -s)/$(uname -m); installing from crates.io with --locked"
	echo "Installing cross ${CROSS_VERSION}..."
	cargo install cross --locked --version "$CROSS_VERSION"
	exit 0
fi

archive="cross-${target}.tar.gz"
url="https://github.com/cross-rs/cross/releases/download/v${CROSS_VERSION}/${archive}"
bin_dir="${CARGO_HOME:-$HOME/.cargo}/bin"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci-cross.XXXXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "Installing cross ${CROSS_VERSION} from ${url}..."
if ! download_with_retries "$url" "${tmp}/${archive}"; then
	echo "::error::failed to download ${url}" >&2
	exit 1
fi
supply_chain_verify_sha256 "${tmp}/${archive}" \
	"CROSS_SHA256_$(supply_chain_var_suffix "$target")" \
	"$CROSS_VERSION" "$DEFAULT_CROSS_VERSION"

tar -xzf "${tmp}/${archive}" -C "$tmp"
if [[ ! -f "${tmp}/cross" ]]; then
	echo "::error::${archive} does not contain a cross binary" >&2
	exit 1
fi
mkdir -p "$bin_dir"
install -m 0755 "${tmp}/cross" "${bin_dir}/cross"
# cross ships cross-util alongside the main binary; install it when present.
if [[ -f "${tmp}/cross-util" ]]; then
	install -m 0755 "${tmp}/cross-util" "${bin_dir}/cross-util"
fi
echo "cross ${CROSS_VERSION} installed to ${bin_dir}"
