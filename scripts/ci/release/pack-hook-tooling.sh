#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pack the lgtm-ci tooling the version-update-hook job runs (#1451).
#
# The hook job runs caller code, so it holds no secret and cannot check out
# a private tooling repository itself. The prepare job, which already holds
# the guarded tooling checkout, packs the paths the hook needs into a tarball
# and publishes its SHA-256; the hook job downloads the tarball, compares the
# digest and extracts it. A tarball, because upload-artifact drops the
# executable bits the hook's scripts need.
#
# Packed paths, relative to TOOLING_DIR:
#   scripts/ci - every script the hook job runs (changelog, ecosystem
#                updaters, hook validation and sandbox) and the libraries
#                they source. The hook job's harden and egress steps use no
#                tooling, and it no longer runs the divergence guard (prepare
#                ran it on the tree packed here), so
#                .github/actions/checkout-and-harden is not packed.
#
# Environment variables:
#   TOOLING_DIR   - Tooling checkout to pack (default: .lgtm-ci-tooling)
#   RUNNER_TEMP   - Directory for the tarball; written to
#                   $RUNNER_TEMP/hook-tooling/hook-tooling.tar.gz
#   GITHUB_OUTPUT - Receives digest=<sha256> and path=<tarball>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
TOOLING_DIR="${TOOLING_DIR:-.lgtm-ci-tooling}"

HOOK_TOOLING_PATHS=(scripts/ci)

[[ -d "$TOOLING_DIR" ]] || die "tooling directory not found: ${TOOLING_DIR}"
for path in "${HOOK_TOOLING_PATHS[@]}"; do
	[[ -d "${TOOLING_DIR}/${path}" ]] ||
		die "tooling path missing from ${TOOLING_DIR}: ${path}"
done

out_dir="${RUNNER_TEMP}/hook-tooling"
tarball="${out_dir}/hook-tooling.tar.gz"
mkdir -p "$out_dir"
# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble entries.
COPYFILE_DISABLE=1 tar -czf "$tarball" -C "$TOOLING_DIR" -- "${HOOK_TOOLING_PATHS[@]}"

digest="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the digest of ${tarball}"

{
	printf 'digest=%s\n' "$digest"
	printf 'path=%s\n' "$tarball"
} >>"$GITHUB_OUTPUT"
log_info "Packed ${HOOK_TOOLING_PATHS[*]} into ${tarball} (sha256 ${digest})"
