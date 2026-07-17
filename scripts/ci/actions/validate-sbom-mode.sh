#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate reusable-sbom mode inputs before generate/sign/upload.
#
# Required environment variables:
#   MODE - Workflow mode: report | release-assets (default: report)
#
# Optional environment variables:
#   RELEASE_TAG - Required when MODE=release-assets
#   FORMATS     - Validated early when MODE=release-assets and non-empty

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

MODE="${MODE:-report}"

case "${MODE}" in
report) ;;
release-assets)
	if [[ -z "${RELEASE_TAG:-}" ]]; then
		echo "::error::release-tag is required when mode is release-assets" >&2
		exit 1
	fi
	if [[ -n "${FORMATS:-}" ]]; then
		# Fail the cheap validate job on unsupported formats instead of
		# surfacing the error later inside the release-assets job.
		STEP=parse-formats FORMATS="${FORMATS}" \
			bash "${SCRIPT_DIR}/generate-sbom-release-assets.sh" >/dev/null
	fi
	;;
*)
	echo "::error::Invalid mode '${MODE}' (expected report or release-assets)" >&2
	exit 1
	;;
esac

echo "SBOM mode validated: ${MODE}"
