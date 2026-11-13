#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install the pinned, SHA-256-verified Trivy release and publish it on GITHUB_PATH
#
# Source of truth for the inline "Install verified Trivy" steps in the Docker
# reusables (#1450). Those steps stay inline because they are workflow-owned:
# on GHES the tooling tree is caller-selected and must not control Trivy's
# checksums. scripts/ci/bootstrap/sync_inline_blocks.py copies the lines
# between the markers below into each workflow and fails CI on drift. Keep the
# body self-contained: the inline copy runs with nothing else on disk.
#
# Required environment variables: RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP, GITHUB_PATH
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

# lgtm-ci-inline:begin install-verified-trivy
# Workflow-owned acquisition must work with older caller-selected tooling-ref trees.
set -euo pipefail
version=0.76.2
# Digests match the v0.76.2 release assets and its checksums.txt.
if [[ ${RUNNER_OS:?} != Linux ]]; then
  echo '::error::The Docker Trivy installer requires a Linux runner' >&2
  exit 1
fi
case ${RUNNER_ARCH:?} in
  X64)
    archive_arch=64bit
    checksum=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
    ;;
  ARM64)
    archive_arch=ARM64
    checksum=ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3
    ;;
  *)
    echo '::error::Unsupported Docker Trivy runner architecture' >&2
    exit 1
    ;;
esac
workdir=$(mktemp -d "${RUNNER_TEMP:?}/trivy-download.XXXXXX")
trap 'rm -rf "$workdir"' EXIT
archive="trivy_${version}_Linux-${archive_arch}.tar.gz"
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 120 \
  --output "$workdir/$archive" \
  "https://github.com/aquasecurity/trivy/releases/download/v${version}/$archive"
printf '%s  %s\n' "$checksum" "$workdir/$archive" | sha256sum --check --strict
tar -xzf "$workdir/$archive" -C "$workdir" trivy
install_dir="${RUNNER_TEMP}/lgtm-ci-trivy-${version}/bin"
mkdir -p "$install_dir"
install -m 0755 "$workdir/trivy" "$install_dir/trivy"
"$install_dir/trivy" --version
printf '%s\n' "$install_dir" >> "${GITHUB_PATH:?}"
# lgtm-ci-inline:end install-verified-trivy
