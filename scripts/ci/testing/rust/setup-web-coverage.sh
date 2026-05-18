#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Prepare the package manager for web coverage collection.

set -euo pipefail

BUN_VERSION="${BUN_VERSION:-1.3.13}"
npm install --global "bun@${BUN_VERSION}"
bun --version
