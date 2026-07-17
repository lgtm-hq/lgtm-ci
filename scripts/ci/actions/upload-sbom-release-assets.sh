#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Upload downloaded SBOM artifact files to a GitHub Release.
#
# Required environment variables:
#   GH_TOKEN          - Token for gh release upload
#   RELEASE_TAG       - Release tag to attach assets to
#   ARTIFACT_NAME     - Artifact name (for error messages)
#   SBOM_ARTIFACT_DIR - Directory containing downloaded SBOM files

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"
: "${SBOM_ARTIFACT_DIR:?SBOM_ARTIFACT_DIR is required}"

if [[ ! -d "${SBOM_ARTIFACT_DIR}" ]]; then
	echo "::error::SBOM artifact directory not found: ${SBOM_ARTIFACT_DIR}" >&2
	exit 1
fi

mapfile -t files < <(find "${SBOM_ARTIFACT_DIR}" -type f ! -name '.*' | sort)
if [[ ${#files[@]} -eq 0 ]]; then
	echo "::error::No SBOM files found in downloaded artifact '${ARTIFACT_NAME}'" >&2
	exit 1
fi

gh release upload "${RELEASE_TAG}" "${files[@]}" --clobber
echo "Uploaded ${#files[@]} SBOM file(s) to release ${RELEASE_TAG}"
