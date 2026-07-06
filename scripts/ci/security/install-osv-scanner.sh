#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-osv-scanner.sh — Download and verify osv-scanner binary.
#
# Usage:
#   install-osv-scanner.sh [version]
#
# Resolves version as: $1 > $OSV_VERSION env var > 2.3.5 (hardcoded default).
# Resolves install dir as: $INSTALL_DIR env var > /usr/local/bin > ~/.local/bin.

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
Usage: install-osv-scanner.sh [version]

Download and verify the osv-scanner release binary.

Version: $1 > $OSV_VERSION > 2.3.5
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

OSV_VERSION="${1:-${OSV_VERSION:-2.3.5}}"

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
CHECKSUMS_URL="${BASE_URL}/osv-scanner_SHA256SUMS"
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
curl "${_LGTM_CI_CURL_ARGS[@]}" "$CHECKSUMS_URL" -o "${WORKDIR}/SHA256SUMS"

CHECKSUMS_SIG_URL="${BASE_URL}/osv-scanner_SHA256SUMS.sig"
CHECKSUMS_CERT_URL="${BASE_URL}/osv-scanner_SHA256SUMS.pem"
if curl "${_LGTM_CI_CURL_ARGS[@]}" "$CHECKSUMS_SIG_URL" -o "${WORKDIR}/SHA256SUMS.sig" 2>/dev/null &&
	curl "${_LGTM_CI_CURL_ARGS[@]}" "$CHECKSUMS_CERT_URL" -o "${WORKDIR}/SHA256SUMS.pem" 2>/dev/null; then
	if command -v cosign >/dev/null 2>&1; then
		log_info "Verifying SHA256SUMS sigstore signature..."
		cosign verify-blob \
			--signature "${WORKDIR}/SHA256SUMS.sig" \
			--certificate "${WORKDIR}/SHA256SUMS.pem" \
			--certificate-identity-regexp='https://github\.com/google/osv-scanner/.*' \
			--certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
			"${WORKDIR}/SHA256SUMS"
		log_success "SHA256SUMS signature verified"
	else
		log_warn "cosign not found; skipping SHA256SUMS signature verification"
	fi
else
	log_info "Release does not publish SHA256SUMS sigstore assets; verifying binary checksum only"
fi

EXPECTED=$(
	awk -v fn="osv-scanner_${PLATFORM}" '$2 == fn { print $1; exit }' "${WORKDIR}/SHA256SUMS"
)
if [[ -z "$EXPECTED" ]]; then
	log_error "No checksum entry for osv-scanner_${PLATFORM} in SHA256SUMS"
	exit 1
fi

printf '%s  osv-scanner\n' "$EXPECTED" | (
	cd "${WORKDIR}" && sha256sum -c -
)
log_success "SHA256 verified: ${EXPECTED}"

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
