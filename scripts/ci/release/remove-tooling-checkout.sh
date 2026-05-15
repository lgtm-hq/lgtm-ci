#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Remove the temporary lgtm-ci tooling checkout before PR creation.

set -euo pipefail

rm -rf .lgtm-ci-tooling
printf 'Removed temporary lgtm-ci tooling checkout\n'
