#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the lgtm-ci tooling ref for release auto-tag workflows.
#
# Prefer an explicit TOOLING_REF override; when running inside lgtm-ci itself
# use GH_SHA so the tooling matches the triggering commit; otherwise fall back
# to WORKFLOW_SHA (the reusable workflow ref consumers are pinned to).
#
# Required environment variables:
#   GH_REPO       - github.repository
#   GH_SHA        - github.sha
#   WORKFLOW_SHA  - github.workflow_sha
# Optional:
#   TOOLING_REF   - Explicit caller override (inputs.tooling-ref)

set -euo pipefail

: "${GH_REPO:?GH_REPO is required}"
: "${GH_SHA:?GH_SHA is required}"
: "${WORKFLOW_SHA:?WORKFLOW_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ -n "${TOOLING_REF:-}" ]]; then
	echo "ref=${TOOLING_REF}" >>"${GITHUB_OUTPUT}"
elif [[ "${GH_REPO}" == "lgtm-hq/lgtm-ci" ]]; then
	echo "ref=${GH_SHA}" >>"${GITHUB_OUTPUT}"
else
	echo "ref=${WORKFLOW_SHA}" >>"${GITHUB_OUTPUT}"
fi
