#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Expose steps.pages-upload.outcome as a job output for downstream jobs.

set -euo pipefail

echo "outcome=${PAGES_UPLOAD_OUTCOME:-}" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
