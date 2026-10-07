#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge per-matrix Node.js coverage artifacts into a deterministic tree.
#
# Environment:
#   ARTIFACTS_DIR     Directory the artifacts were downloaded into, one
#                     subdirectory per artifact (default: node-coverage-artifacts)
#   ARTIFACT_PREFIX   The artifact-prefix the producing reusable-test-node.yml
#                     call ran with (#1091); artifacts are named
#                     <prefix>-coverage-<version> (default: node)
#   OUTPUT_DIR        Merged tree destination (default: coverage-report)
#   WORKING_DIRECTORY Working directory the producer used (default: .)

set -euo pipefail

: "${ARTIFACTS_DIR:=node-coverage-artifacts}"
: "${ARTIFACT_PREFIX:=node}"
: "${OUTPUT_DIR:=coverage-report}"
: "${WORKING_DIRECTORY:=.}"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
	echo "Coverage artifacts directory does not exist: $ARTIFACTS_DIR" >&2
	exit 1
fi

base_dir="$OUTPUT_DIR"
if [[ "$WORKING_DIRECTORY" != "." && "$WORKING_DIRECTORY" != "" ]]; then
	base_dir="${OUTPUT_DIR}/${WORKING_DIRECTORY}"
fi

mkdir -p "$base_dir"

found=false
for artifact_dir in "$ARTIFACTS_DIR"/"${ARTIFACT_PREFIX}"-coverage-*; do
	[[ -d "$artifact_dir" ]] || continue
	found=true
	version_dir="$(basename "$artifact_dir")"
	source_dir="$artifact_dir"
	if [[ -d "${artifact_dir}/${WORKING_DIRECTORY}" ]]; then
		source_dir="${artifact_dir}/${WORKING_DIRECTORY}"
	fi

	mkdir -p "${base_dir}/${version_dir}"
	cp -R "${source_dir}/." "${base_dir}/${version_dir}/"
done

if [[ "$found" != "true" ]]; then
	echo "No ${ARTIFACT_PREFIX}-coverage-* artifacts found in $ARTIFACTS_DIR" >&2
	exit 1
fi
