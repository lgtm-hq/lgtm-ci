#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify the packed hook tooling tarball's digest and extract it
#
# Source of truth for the inline "Verify and extract lgtm-ci tooling" steps in
# the release twins' version-update-hook job (#1451, #1450). Those steps stay
# inline because the tooling does not exist yet: this is what puts it on disk.
# scripts/ci/bootstrap/sync_inline_blocks.py copies the lines between the
# markers below into each workflow and fails CI on drift. Keep the body
# self-contained.
#
# mkdir fails when the caller's checkout already holds .lgtm-ci-tooling, so a
# planted tree is never mixed with the verified one.
#
# Environment variables:
#   TARBALL         - Path to hook-tooling.tar.gz (from pack-hook-tooling.sh)
#   EXPECTED_DIGEST - prepare's tooling-digest output (64 lowercase hex chars)
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin verify-extract-hook-tooling
[[ "$EXPECTED_DIGEST" =~ ^[0-9a-f]{64}$ ]] || {
  echo "::error::no tooling digest"
  exit 1
}
printf '%s  %s\n' "$EXPECTED_DIGEST" "$TARBALL" | shasum -a 256 -c -
mkdir .lgtm-ci-tooling
tar -xzf "$TARBALL" --no-same-owner -C .lgtm-ci-tooling
# lgtm-ci-inline:end verify-extract-hook-tooling
