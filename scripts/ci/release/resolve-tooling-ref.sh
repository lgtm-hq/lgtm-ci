#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the lgtm-ci tooling ref for release auto-tag workflows.
#
# Prefer an explicit TOOLING_REF override; when running inside lgtm-ci itself
# use GH_SHA so the tooling matches the triggering commit; otherwise fall back
# to WORKFLOW_SHA, the called workflow's own commit (job.workflow_sha; never
# github.workflow_sha, which names the caller's commit — #995).
#
# Required environment variables:
#   GH_REPO       - github.repository
#   GH_SHA        - github.sha
#   WORKFLOW_SHA  - job.workflow_sha (the called workflow's own commit)
# Optional:
#   TOOLING_REF   - Explicit caller override (inputs.tooling-ref)

set -euo pipefail

: "${GH_REPO:?GH_REPO is required}"
: "${GH_SHA:?GH_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# An explicit override wins and needs no workflow identity (GHES has none).
if [[ -n "${TOOLING_REF:-}" ]]; then
	echo "ref=${TOOLING_REF}" >>"${GITHUB_OUTPUT}"
	exit 0
fi
: "${WORKFLOW_SHA:?WORKFLOW_SHA is required when TOOLING_REF is empty}"

if [[ "${GH_REPO}" == "lgtm-hq/lgtm-ci" ]]; then
	echo "ref=${GH_SHA}" >>"${GITHUB_OUTPUT}"
else
	echo "ref=${WORKFLOW_SHA}" >>"${GITHUB_OUTPUT}"
fi
