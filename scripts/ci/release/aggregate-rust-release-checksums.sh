#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge per-target SHA256SUMS-* files into a single SHA256SUMS manifest
#
# Usage:
#   ARTIFACT_PATH=dist scripts/ci/release/aggregate-rust-release-checksums.sh

set -euo pipefail

ARTIFACT_PATH="${ARTIFACT_PATH:-dist}"

if [[ ! -d "$ARTIFACT_PATH" ]]; then
	echo "Artifact path not found: $ARTIFACT_PATH" >&2
	exit 1
fi

shopt -s nullglob
manifests=("$ARTIFACT_PATH"/SHA256SUMS-*)

if [[ ${#manifests[@]} -eq 0 ]]; then
	echo "No per-target checksum manifests found in $ARTIFACT_PATH" >&2
	exit 1
fi

cat "${manifests[@]}" >"$ARTIFACT_PATH/SHA256SUMS"
rm -f "${manifests[@]}"
echo "Aggregated ${#manifests[@]} checksum manifest(s) into $ARTIFACT_PATH/SHA256SUMS"
