#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate reusable-sbom mode inputs before generate/sign/upload.
#
# Required environment variables:
#   MODE - Workflow mode: report | release-assets (default: report)
#
# Optional environment variables:
#   RELEASE_TAG - Required when MODE=release-assets

set -euo pipefail

MODE="${MODE:-report}"

case "${MODE}" in
report) ;;
release-assets)
	if [[ -z "${RELEASE_TAG:-}" ]]; then
		echo "::error::release-tag is required when mode is release-assets" >&2
		exit 1
	fi
	;;
*)
	echo "::error::Invalid mode '${MODE}' (expected report or release-assets)" >&2
	exit 1
	;;
esac

echo "SBOM mode validated: ${MODE}"
