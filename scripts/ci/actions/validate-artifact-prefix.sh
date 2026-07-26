#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate the artifact-prefix input of reusable-test-e2e-matrix (#739).
#
# Shard artifacts upload as "<prefix>-<suite>-<browser>-<shard>" and the merge
# job collects them with the glob "<prefix>-*". That glob only isolates one call
# of the workflow from another when no prefix is a hyphen-delimited prefix of
# another: "e2e-*" would otherwise also match "e2e-nightly-smoke-chromium-1", so
# the "e2e" call's merge would swallow the "e2e-nightly" call's shards.
#
# Banning "-" inside the prefix makes the first hyphen the unambiguous boundary
# between prefix and shard coordinates, so any two distinct accepted prefixes
# produce disjoint upload names and disjoint download globs.
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
	echo "::error::artifact-prefix must match [A-Za-z0-9_.]+ (got '${prefix}'): '-' is reserved as the separator between the prefix and the shard coordinates, so that '<prefix>-*' matches only this call's shards" >&2
	exit 1
fi

echo "Artifact prefix: ${prefix}"
echo "Shard artifacts: ${prefix}-<suite>-<browser>-<shard>"
echo "Merged report artifact: ${prefix}-merged-report"
