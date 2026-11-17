#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Move the lgtm-ci tooling checkout out of the workspace before PR
# creation, and record its digest (#1622).
#
# reusable-release-version-pr.yml's version-pr job takes the tooling out of
# the workspace so "Create or update version PR" cannot commit it. It used to
# delete the checkout and fetch it again afterwards, but with the tooling App
# credential that second fetch would need a token minted more than an hour
# earlier in a long job. So the tooling is packed into a tarball under
# RUNNER_TEMP instead, its SHA-256 goes to a step output (which no later step
# can rewrite), and the checkout is removed. Afterwards the workflow-owned
# generated block verify-extract-hook-tooling (source
# scripts/ci/bootstrap/verify-extract-hook-tooling.sh) checks the digest and
# extracts it back: a tarball changed in between is refused, and the check
# never runs code from the tree it checks. A tarball, as for the hook
# tooling, because it keeps the scripts' executable bits.
#
# Everything in the checkout is packed except .git, which no later step reads.
# Nothing is removed until the tarball and its digest are written, and an
# existing stash directory is never reused.
#
# Environment variables:
#   GITHUB_WORKSPACE - Workspace holding .lgtm-ci-tooling
#   RUNNER_TEMP      - Directory for the tarball; written to
#                      $RUNNER_TEMP/tooling-stash/tooling.tar.gz
#   GITHUB_OUTPUT    - Receives digest=<sha256> and path=<tarball>

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

fail() {
	printf '::error title=tooling stash::%s\n' "$*"
	exit 1
}

tooling="${GITHUB_WORKSPACE}/.lgtm-ci-tooling"
[[ -d "$tooling" && ! -L "$tooling" ]] || fail "no tooling checkout at ${tooling}"

shopt -s dotglob nullglob
entries=()
for entry in "$tooling"/*; do
	name="${entry##*/}"
	[[ "$name" == ".git" ]] || entries+=("$name")
done
shopt -u dotglob nullglob
((${#entries[@]} > 0)) || fail "the tooling checkout at ${tooling} is empty"

out_dir="${RUNNER_TEMP}/tooling-stash"
tarball="${out_dir}/tooling.tar.gz"
mkdir -- "$out_dir" || fail "${out_dir} already exists; refusing to reuse it"
# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble entries.
COPYFILE_DISABLE=1 tar -czf "$tarball" -C "$tooling" -- "${entries[@]}"

digest="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute the digest of ${tarball}"
{
	printf 'digest=%s\n' "$digest"
	printf 'path=%s\n' "$tarball"
} >>"$GITHUB_OUTPUT"

rm -rf -- "$tooling"
printf 'Moved the lgtm-ci tooling checkout to %s (sha256 %s)\n' "$tarball" "$digest"
