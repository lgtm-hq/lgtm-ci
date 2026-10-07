#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-osv-scanner.sh — Download and verify osv-scanner binary.
#
# Usage:
#   install-osv-scanner.sh [version]
#
# Resolves version as: $1 > $OSV_VERSION env var > DEFAULT_OSV_SCANNER_VERSION
# (scripts/ci/versions.env).
# Resolves install dir as: $INSTALL_DIR env var > /usr/local/bin > ~/.local/bin.
#
# Verification (#1096): the downloaded binary must match the sha256 committed
# in scripts/ci/versions.env (DEFAULT_OSV_SCANNER_SHA256_<PLATFORM>). The
# upstream SHA256SUMS and its Sigstore signature are checked at pin time by
# scripts/ci/maintenance/refresh-tool-digests.sh, not here, so nothing fetched
# from the release decides whether the binary is installed. Overriding the
# version requires the matching OSV_SCANNER_SHA256_<PLATFORM> env var (or
# LGTM_CI_ALLOW_UNVERIFIED=1, see scripts/ci/lib/supply_chain.sh).

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
Usage: install-osv-scanner.sh [version]

Download the osv-scanner release binary and verify it against the sha256
committed in scripts/ci/versions.env.

Version: $1 > $OSV_VERSION > DEFAULT_OSV_SCANNER_VERSION (versions.env)
Digest:  $OSV_SCANNER_SHA256_<PLATFORM> > DEFAULT_OSV_SCANNER_SHA256_<PLATFORM>
Install dir: $INSTALL_DIR > /usr/local/bin > ~/.local/bin
EOF
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/fs.sh
source "$LIB_DIR/fs.sh"
# shellcheck source=../lib/network/download.sh
source "$LIB_DIR/network/download.sh"
# shellcheck source=../lib/supply_chain.sh
source "$LIB_DIR/supply_chain.sh"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

OSV_VERSION="${1:-${OSV_VERSION:-$DEFAULT_OSV_SCANNER_VERSION}}"

OS=$(uname -s)
if [[ "$OS" != "Linux" ]]; then
	log_error "osv-scanner install supports Linux runners only (detected: $OS)"
	exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
x86_64) PLATFORM="linux_amd64" ;;
aarch64 | arm64) PLATFORM="linux_arm64" ;;
*)
	log_error "Unsupported architecture: $ARCH"
	exit 1
	;;
esac

BASE_URL="https://github.com/google/osv-scanner/releases/download/v${OSV_VERSION}"
BINARY_URL="${BASE_URL}/osv-scanner_${PLATFORM}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
if [[ ! -w "$INSTALL_DIR" ]]; then
	INSTALL_DIR="${HOME}/.local/bin"
	mkdir -p "$INSTALL_DIR"
fi
# NOTE: create_temp_dir installs its cleanup trap inside the command-
# substitution subshell, so `dir=$(create_temp_dir)` deletes the directory the
# instant the subshell exits (see tests/bats/unit/lib/test_fs.bats). This
# installer needs the directory to survive for the whole download+verify flow,
# so create it directly in this shell and register cleanup on THIS shell's EXIT.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci-osv.XXXXXXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

log_info "Installing osv-scanner v${OSV_VERSION}..."

# Build hardened curl args via the shared builder so these security-tool
# downloads honor the same TLS floor AND the opt-in LGTM_CI_CA_BUNDLE /
# LGTM_CI_PINNED_PUBKEY knobs as every other download path. Fail closed if a
# custom CA bundle is configured but unreadable.
_lgtm_ci_build_curl_args 300 || exit 1

curl "${_LGTM_CI_CURL_ARGS[@]}" "$BINARY_URL" -o "${WORKDIR}/osv-scanner"

supply_chain_verify_sha256 "${WORKDIR}/osv-scanner" \
	"OSV_SCANNER_SHA256_$(supply_chain_var_suffix "$PLATFORM")" \
	"$OSV_VERSION" "$DEFAULT_OSV_SCANNER_VERSION"

chmod +x "${WORKDIR}/osv-scanner"
mv "${WORKDIR}/osv-scanner" "${INSTALL_DIR}/osv-scanner"

"${INSTALL_DIR}/osv-scanner" --version
log_success "osv-scanner v${OSV_VERSION} installed to ${INSTALL_DIR}"

if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
	export PATH="${INSTALL_DIR}:${PATH}"
	if [[ -n "${GITHUB_PATH:-}" ]]; then
		echo "$INSTALL_DIR" >>"$GITHUB_PATH"
	fi
fi
