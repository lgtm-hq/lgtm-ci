#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify the packed hook tooling tarball's digest and extract it
#
# Source of truth for two inline steps in reusable-release-version-pr.yml:
# "Verify and extract lgtm-ci tooling" in the version-update-hook job
# (#1451, #1450), and "Restore tooling for post-PR steps" in the version-pr
# job, which puts back the tooling that scripts/ci/release/
# stash-tooling-checkout.sh moved out before PR creation (#1622). It stays
# inline because the tooling is not on disk yet: this is what puts it there,
# so it must not run code from the tarball it checks.
# scripts/ci/bootstrap/sync_inline_blocks.py copies the lines between the
# markers below into each workflow and fails CI on drift. Keep the body
# self-contained.
#
# mkdir fails when the caller's checkout already holds .lgtm-ci-tooling, so a
# planted tree is never mixed with the verified one.
#
# Environment variables:
#   TARBALL         - Path to the tarball (from pack-hook-tooling.sh or
#                     stash-tooling-checkout.sh)
#   EXPECTED_DIGEST - Its SHA-256 as the packing step output it (64 lowercase
#                     hex chars)
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
