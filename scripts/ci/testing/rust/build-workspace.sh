#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compile the Rust workspace (debug and release).

set -euo pipefail

cargo build --workspace --all-features
cargo build --workspace --release
