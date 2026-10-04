#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Emit a deprecation warning when a caller still passes an explicit
# `tooling-ref`. Reusable workflows now resolve their own source through
# `job.workflow_sha` / `job.workflow_repository` (#995), so the input is only
# an override for development or GHES, not a requirement.
#
# Environment variables:
#   TOOLING_REF_OVERRIDE - The raw `inputs.tooling-ref` value (may be empty)
#   WORKFLOW_SHA         - job.workflow_sha, for the message (optional)

set -euo pipefail

override="${TOOLING_REF_OVERRIDE:-}"
if [[ -z "${override}" ]]; then
	exit 0
fi

resolved="${WORKFLOW_SHA:-}"
msg="tooling-ref is no longer required; remove it to track the workflow pin automatically"
if [[ -n "${resolved}" && "${override}" != "${resolved}" ]]; then
	msg="${msg} (override ${override} differs from workflow pin ${resolved})"
fi
echo "::warning title=tooling-ref override::${msg}"
