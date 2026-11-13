#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Refuse a tooling checkout that diverges from the workflow's own
# commit (#1368).
#
# A reusable workflow's YAML is always the version at `job.workflow_sha`. When
# a caller passes `tooling-ref` (deprecated, #995) that resolves to another
# commit, the new YAML runs against old scripts, and a script the YAML expects
# can be missing (an external consumer at v0.87.0 hit exit 127 this way). Stop
# before any tooling script runs, unless the caller opted into the GHES/mirror
# escape hatch.
#
# Source of truth for two callers. checkout-and-harden stages this file from
# its bootstrap checkout at job.workflow_sha and runs it. The inline "Refuse a
# diverging tooling-ref" steps in the reusables carry a generated copy of the
# lines between the markers below (#1450): the guard is workflow-owned, so the
# tree it judges never supplies its own verdict.
# scripts/ci/bootstrap/sync_inline_blocks.py copies that body into each
# workflow and fails CI on drift. Keep the body self-contained.
#
# Environment variables:
#   TOOLING_REF_OVERRIDE - The caller's raw `inputs.tooling-ref` (may be empty)
#   WORKFLOW_SHA         - job.workflow_sha (empty on GHES, nothing to compare)
#   ALLOW_DIVERGENCE     - "true" downgrades the failure to a warning
#   TOOLING_DIR          - Tooling checkout directory (default .lgtm-ci-tooling)
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

# lgtm-ci-inline:begin refuse-diverging-tooling-ref
# Workflow-owned: the tooling tree under judgment never supplies this guard.
set -euo pipefail

override="${TOOLING_REF_OVERRIDE:-}"
if [[ -z "${override}" ]]; then
  exit 0
fi

workflow_sha="${WORKFLOW_SHA:-}"
if [[ -z "${workflow_sha}" ]]; then
  notice="job.workflow_sha is unavailable on this platform;"
  notice+=" skipping the divergence check for tooling-ref ${override}"
  echo "::notice title=tooling-ref divergence::${notice}"
  exit 0
fi

tooling_dir="${TOOLING_DIR:-.lgtm-ci-tooling}"
if ! tooling_sha="$(git -C "${tooling_dir}" rev-parse HEAD 2> /dev/null)"; then
  echo "::error title=tooling-ref divergence::could not resolve HEAD" \
    "of the tooling checkout at ${tooling_dir}"
  exit 1
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [[ "$(lower "${tooling_sha}")" == "$(lower "${workflow_sha}")" ]]; then
  exit 0
fi

detail="tooling-ref ${override} resolved to ${tooling_sha},"
detail+=" but this workflow runs at ${workflow_sha} (job.workflow_sha)"
if [[ "${ALLOW_DIVERGENCE:-}" == "true" ]]; then
  echo "::warning title=tooling-ref divergence::${detail};" \
    "continuing because tooling-ref-allow-divergence is true (GHES/mirror escape hatch)"
  exit 0
fi

echo "::error title=tooling-ref divergence::${detail}." \
  "Workflow YAML at one commit would run scripts from another." \
  "tooling-ref is deprecated (#995): remove tooling-ref so tooling follows the workflow pin." \
  "GHES or mirror callers that must diverge can set tooling-ref-allow-divergence: true."
exit 1
# lgtm-ci-inline:end refuse-diverging-tooling-ref
