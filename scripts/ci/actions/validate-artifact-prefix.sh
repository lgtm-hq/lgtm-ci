#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate the artifact-prefix input of the reusable test workflows
#          (reusable-test-e2e-matrix #739; the language test reusables #1091).
#
# Every artifact a call uploads is named "<prefix>-<rest>" (E2E shards:
# "<prefix>-<suite>-<browser>-<shard>"; language tests: "<prefix>-coverage",
# "<prefix>-results-<version>", ...) and its aggregate/merge job collects them
# with a glob "<prefix>-<rest>-*". Such a glob only isolates one call of the
# workflow from another when no prefix is a hyphen-delimited prefix of another:
# "e2e-*" would otherwise also match "e2e-nightly-smoke-chromium-1", so the
# "e2e" call's merge would swallow the "e2e-nightly" call's shards.
#
# Banning "-" inside the prefix makes the first hyphen the unambiguous boundary
# between prefix and the rest of the name, so any two distinct accepted
# prefixes produce disjoint upload names and disjoint download globs.
#
# Environment:
#   ARTIFACT_PREFIX (required) Prefix from the workflow input

set -euo pipefail

: "${ARTIFACT_PREFIX:=}"

prefix="$ARTIFACT_PREFIX"

if [[ -z "$prefix" ]]; then
	echo "::error::artifact-prefix must not be empty" >&2
	exit 1
fi

if [[ ! "$prefix" =~ ^[A-Za-z0-9_.]+$ ]]; then
	echo "::error::artifact-prefix must match [A-Za-z0-9_.]+ (got '${prefix}'): '-' is reserved as the separator between the prefix and the rest of the artifact name, so that '<prefix>-*' matches only this call's artifacts" >&2
	exit 1
fi

echo "Artifact prefix: ${prefix}"
echo "Artifacts upload as: ${prefix}-<name>"
echo "Download globs: ${prefix}-<name>-*"
