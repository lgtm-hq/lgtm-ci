#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail a job whose egress-preset input names no preset (#913)
#
# Source of truth for the inline "Fail on unknown egress-preset" step that
# follows the harden-runner agent check in every reusable that takes an
# egress-preset input (#1624). harden-runner's pre hook already ran with
# whatever the preset selector resolved; an unknown name yields an empty
# baseline, which would surface later as an opaque network error. The step's
# if: decides that the name is unknown; this body only says so and fails.
#
# The step runs before any checkout, so it cannot call this file: it carries
# a generated copy. scripts/ci/bootstrap/sync_inline_blocks.py copies the
# lines between the markers below into each workflow and fails CI on drift.
# Keep the body self-contained.
#
# Environment variables:
#   EGRESS_PRESET - The caller's inputs.egress-preset (may be empty)
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin fail-unknown-egress-preset
echo "::error title=unknown egress-preset::not a preset - '${EGRESS_PRESET}'"
exit 1
# lgtm-ci-inline:end fail-unknown-egress-preset
