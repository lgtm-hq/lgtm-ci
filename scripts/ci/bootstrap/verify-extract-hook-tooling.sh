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
# TARBALL is opened once: it must be a regular, non-symlink file, and it is
# copied into a fresh private directory under RUNNER_TEMP. The digest check,
# the member listing and the extraction all read that copy, so a FIFO or a
# file swapped in between cannot pass the check with one archive and extract
# another. Members that are absolute, contain a .. component, or are links of
# any kind are refused (the tooling holds no links). mkdir fails when the
# caller's checkout already holds .lgtm-ci-tooling, so a planted tree is never
# mixed with the verified one. Hashes with sha256sum when present, else
# shasum -a 256.
#
# Environment variables:
#   TARBALL         - Path to the tarball (from pack-hook-tooling.sh or
#                     stash-tooling-checkout.sh)
#   EXPECTED_DIGEST - Its SHA-256 as the packing step output it (64 lowercase
#                     hex chars)
#   RUNNER_TEMP     - Parent of the private copy, which is removed on exit
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin verify-extract-hook-tooling
refuse() {
  echo "::error::$*"
  exit 1
}
[[ "$EXPECTED_DIGEST" =~ ^[0-9a-f]{64}$ ]] || refuse "no tooling digest"
[[ -f "$TARBALL" && ! -L "$TARBALL" ]] || refuse "${TARBALL} is not a regular file"
private="$(mktemp -d "${RUNNER_TEMP:?}/tooling-verify.XXXXXX")"
trap 'rm -rf -- "$private"' EXIT
copy="${private}/tooling.tar.gz"
cp -- "$TARBALL" "$copy"
[[ -f "$copy" && ! -L "$copy" ]] || refuse "${TARBALL} did not copy as a regular file"
if command -v sha256sum > /dev/null 2>&1; then
  actual="$(sha256sum < "$copy")"
else
  actual="$(shasum -a 256 < "$copy")"
fi
[[ "${actual%% *}" == "$EXPECTED_DIGEST" ]] || refuse "${TARBALL}: digest check FAILED"
echo "${TARBALL}: OK"
names="$(tar -tzf "$copy")"
if grep -Eq '^/|(^|/)\.\.(/|$)' <<< "$names"; then
  refuse "${TARBALL} has an absolute or .. member"
fi
listing="$(tar -tvzf "$copy")"
if grep -q '^[hl]' <<< "$listing"; then
  refuse "${TARBALL} has a link member"
fi
mkdir .lgtm-ci-tooling
tar -xzf "$copy" --no-same-owner -C .lgtm-ci-tooling
# lgtm-ci-inline:end verify-extract-hook-tooling
