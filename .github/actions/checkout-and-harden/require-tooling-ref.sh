#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail the job when checkout-and-harden receives an empty tooling-ref.
#
# The calling reusable workflow resolves `inputs.tooling-ref || job.workflow_sha`.
# Both are empty only on GitHub Enterprise Server (no job.workflow_* context)
# when the caller did not pass tooling-ref; checking out the tooling default
# branch there would run unpinned tooling, so stop here (#995).

set -euo pipefail

echo "::error title=tooling-ref required::checkout-and-harden received an empty tooling-ref." \
	"job.workflow_sha is unavailable on this platform; pass tooling-ref (the same SHA as the" \
	"reusable workflow pin) explicitly."
exit 1
