#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install a pinned cargo-cross release for rust-binaries CI.

set -euo pipefail

# renovate: datasource=crate depName=cross
DEFAULT_CROSS_VERSION="0.2.5"
CROSS_VERSION="${CROSS_VERSION:-$DEFAULT_CROSS_VERSION}"

echo "Installing cross ${CROSS_VERSION}..."
cargo install cross --locked --version "$CROSS_VERSION"
