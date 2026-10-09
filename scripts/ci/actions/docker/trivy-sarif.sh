#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Hand the validate path's Trivy SARIF from the read-only build job to
#          the facade's code-scanning upload job (#1081)
#
# The per-platform build job of reusable-docker-multiplatform-validate.yml
# holds contents: read only, so it cannot upload SARIF to code scanning. It
# stages one artifact per scanned leg instead, and the facade's
# upload-scan-results job (security-events: write) uploads it. Every scanned
# leg uploads an artifact, so a missing one is a real failure rather than a
# silent skip:
#
#   MODE=stage   (build job, always() when scan is on) copy SARIF_FILE into
#                STAGE_DIR, or write STAGE_DIR/no-sarif.txt when Trivy did
#                not produce one (the build or the scan failed first).
#   MODE=locate  (upload job, after the artifact was downloaded) find the
#                SARIF in DOWNLOAD_DIR. Writes `found=true` and `path=...` to
#                GITHUB_OUTPUT, or `found=false` with a notice when the leg
#                staged the no-sarif marker. Anything else fails.
#
# Required environment variables:
#   MODE        - stage | locate
#   SARIF_NAME  - SARIF file name, e.g. trivy-results-linux-amd64.sarif
# MODE=stage:
#   STAGE_DIR   - Directory uploaded as the leg's artifact
#   SARIF_FILE  - Path Trivy wrote the SARIF to (may be missing)
# MODE=locate:
#   DOWNLOAD_DIR - Directory the artifact was extracted into

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"

: "${MODE:?MODE is required (stage or locate)}"
: "${SARIF_NAME:?SARIF_NAME is required}"

MARKER="no-sarif.txt"

case "$MODE" in
stage)
	: "${STAGE_DIR:?STAGE_DIR is required}"
	: "${SARIF_FILE:?SARIF_FILE is required}"
	mkdir -p "$STAGE_DIR"
	if [[ -s "$SARIF_FILE" ]]; then
		cp "$SARIF_FILE" "$STAGE_DIR/$SARIF_NAME"
		echo "Staged $SARIF_NAME for the code-scanning upload"
	else
		printf 'Trivy produced no SARIF for this leg (build or scan failed first).\n' \
			>"$STAGE_DIR/$MARKER"
		echo "::warning::No SARIF at ${SARIF_FILE}; staged ${MARKER} so the upload job skips this leg explicitly"
	fi
	;;
locate)
	: "${DOWNLOAD_DIR:?DOWNLOAD_DIR is required}"
	sarif="$(find "$DOWNLOAD_DIR" -type f -name "$SARIF_NAME" -print -quit 2>/dev/null || true)"
	marker="$(find "$DOWNLOAD_DIR" -type f -name "$MARKER" -print -quit 2>/dev/null || true)"
	if [[ -n "$sarif" ]]; then
		set_github_output "found" "true"
		set_github_output "path" "$sarif"
		echo "Found $sarif"
	elif [[ -n "$marker" ]]; then
		set_github_output "found" "false"
		echo "::notice::This leg staged no SARIF (build or scan failed first); nothing to upload"
	else
		echo "::error::Neither ${SARIF_NAME} nor ${MARKER} found under ${DOWNLOAD_DIR}" >&2
		exit 1
	fi
	;;
*)
	echo "::error::MODE must be stage or locate, got '${MODE}'" >&2
	exit 2
	;;
esac
