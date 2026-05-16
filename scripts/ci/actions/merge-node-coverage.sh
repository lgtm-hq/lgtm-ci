#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge per-matrix Node.js coverage artifacts into a deterministic tree.

set -euo pipefail

: "${ARTIFACTS_DIR:=node-coverage-artifacts}"
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
for artifact_dir in "$ARTIFACTS_DIR"/node-coverage-*; do
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
	echo "No node-coverage-* artifacts found in $ARTIFACTS_DIR" >&2
	exit 1
fi
