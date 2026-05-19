#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Prepare the Rust toolchain for coverage collection.

set -euo pipefail

rustup toolchain install stable --profile minimal
rustup default stable
