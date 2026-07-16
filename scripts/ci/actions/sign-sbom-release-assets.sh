#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Cosign-sign SBOM release assets (keyless OIDC) with optional gating.
#
# Required environment variables:
#   SBOM_DIR - Directory containing SBOM files to sign
#
# Optional environment variables:
#   SIGN - When false/0/no/off, skip signing and exit 0 (default: true)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

: "${SBOM_DIR:?SBOM_DIR is required}"
SIGN="${SIGN:-true}"

case "$(printf '%s' "${SIGN}" | tr '[:upper:]' '[:lower:]')" in
false | 0 | no | off)
	log_info "Skipping SBOM signing (sign=${SIGN})"
	set_github_output "signed-count" "0"
	set_github_output "skipped" "true"
	exit 0
	;;
esac

if [[ ! -d "${SBOM_DIR}" ]]; then
	echo "::error::SBOM directory not found: ${SBOM_DIR}" >&2
	exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
	die "cosign not found. Install via sigstore/cosign-installer action."
fi

mapfile -t sbom_files < <(
	find "${SBOM_DIR}" -type f \
		\( -name '*.json' -o -name '*.xml' -o -name '*.spdx' \) \
		! -name '*.bundle' ! -name '*.sig' ! -name '*.pem' ! -name '.*' |
		sort
)

if [[ ${#sbom_files[@]} -eq 0 ]]; then
	echo "::error::No SBOM files found to sign in ${SBOM_DIR}" >&2
	exit 1
fi

log_info "Signing ${#sbom_files[@]} SBOM file(s) with Cosign keyless signing"

signed_count=0
for sbom_file in "${sbom_files[@]}"; do
	bundle_file="${sbom_file}.bundle"
	log_info "Signing: ${sbom_file}"
	cosign sign-blob --yes --bundle="${bundle_file}" "${sbom_file}"
	if [[ ! -f "${bundle_file}" ]]; then
		log_error "Failed to create signature bundle: ${bundle_file}"
		exit 1
	fi
	signed_count=$((signed_count + 1))
	log_success "Signed: $(basename "${sbom_file}")"
done

log_success "Successfully signed ${signed_count} SBOM file(s)"
set_github_output "signed-count" "${signed_count}"
set_github_output "skipped" "false"
