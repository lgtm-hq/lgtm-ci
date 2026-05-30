#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage flat Node.js coverage HTML for Model B Pages bundling.

set -euo pipefail

: "${WORKING_DIRECTORY:=.}"
: "${PAGES_COVERAGE_SOURCE_SUBPATH:=coverage}"
: "${PAGES_COVERAGE_STAGING_DIR:=pages-coverage-html}"

source_dir="${WORKING_DIRECTORY}/${PAGES_COVERAGE_SOURCE_SUBPATH}"

if [[ ! -d "$source_dir" ]]; then
	echo "Pages coverage source directory missing: ${source_dir}" >&2
	exit 1
fi

if [[ ! -f "${source_dir}/index.html" ]]; then
	echo "Pages coverage HTML missing index.html under ${source_dir}" >&2
	exit 1
fi

rm -rf "${PAGES_COVERAGE_STAGING_DIR}"
mkdir -p "${PAGES_COVERAGE_STAGING_DIR}"
cp -a "${source_dir}/." "${PAGES_COVERAGE_STAGING_DIR}/"
echo "Staged ${source_dir} -> ${PAGES_COVERAGE_STAGING_DIR}/"
