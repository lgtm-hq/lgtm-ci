#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate the reusable-build-artifact strategy matrix (#760).
#
# Builds a GitHub Actions include-matrix from either an arbitrary caller MATRIX
# or a legacy comma-separated VERSIONS list, then resolves a runner per entry
# through RUNNER_MAP (mirroring reusable-docker's platforms + runner-map pair).
#
# Backwards compatibility: with MATRIX and RUNNER_MAP unset, the emitted matrix
# is byte-identical to what generate-version-matrix.sh produced for the same
# VERSIONS/VERSION_KEY, so existing Node callers keep their job names and
# required-check contexts.
#
# Environment:
#   VERSION_KEY       (optional) Matrix field holding the toolchain version,
#                     e.g. node-version, python-version, rust-toolchain. Empty
#                     for toolchain: none.
#   VERSIONS          (optional) Comma-separated versions used when MATRIX is
#                     empty.
#   TOOLCHAIN_VERSION (optional) Version injected into MATRIX entries that do
#                     not carry VERSION_KEY themselves.
#   MATRIX            (optional) JSON array of objects, or an object with an
#                     "include" array.
#   RUNNER_MAP        (optional) JSON object mapping a matrix value to a runner
#                     label. Defaults to {}.
#   RUNNER_MAP_KEY    (optional) Matrix field used as the RUNNER_MAP lookup key.
#                     Empty auto-detects when entries have exactly one field.
#   DEFAULT_RUNNER    (required) Runner label for entries with no mapping.
#   GITHUB_OUTPUT     (required) Writes matrix=

set -euo pipefail

: "${VERSION_KEY:=}"
: "${VERSIONS:=}"
: "${TOOLCHAIN_VERSION:=}"
: "${MATRIX:=}"
: "${RUNNER_MAP:=}"
: "${RUNNER_MAP_KEY:=}"
if [[ -z "${RUNNER_MAP//[[:space:]]/}" ]]; then
	RUNNER_MAP="{}"
fi
: "${DEFAULT_RUNNER:?DEFAULT_RUNNER is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

export VERSION_KEY VERSIONS TOOLCHAIN_VERSION MATRIX RUNNER_MAP RUNNER_MAP_KEY
export DEFAULT_RUNNER

python3 - <<'PY'
"""Resolve the reusable-build-artifact strategy matrix."""

from __future__ import annotations

import json
import os
import sys


def fail(message: str) -> None:
    """Print a workflow error and exit non-zero.

    Args:
        message: Human-readable failure reason.
    """
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


version_key = os.environ["VERSION_KEY"].strip()
raw_versions = os.environ["VERSIONS"].strip()
toolchain_version = os.environ["TOOLCHAIN_VERSION"].strip()
raw_matrix = os.environ["MATRIX"].strip()
raw_runner_map = os.environ["RUNNER_MAP"].strip() or "{}"
runner_map_key = os.environ["RUNNER_MAP_KEY"].strip()
default_runner = os.environ["DEFAULT_RUNNER"].strip()
github_output = os.environ["GITHUB_OUTPUT"]

if not default_runner:
    fail("DEFAULT_RUNNER must not be empty")

try:
    runner_map = json.loads(raw_runner_map)
except json.JSONDecodeError as exc:
    fail(f"runner-map must be a JSON object: {exc}")

if not isinstance(runner_map, dict):
    fail("runner-map must be a JSON object, e.g. {\"x86_64-apple-darwin\":\"macos-15\"}")

for map_key, map_value in runner_map.items():
    if not isinstance(map_value, str) or not map_value.strip():
        fail(f"runner-map value for '{map_key}' must be a non-empty string")

entries: list[dict[str, str]] = []

if raw_matrix:
    try:
        parsed = json.loads(raw_matrix)
    except json.JSONDecodeError as exc:
        fail(f"matrix must be valid JSON: {exc}")

    if isinstance(parsed, dict):
        parsed = parsed.get("include")

    if not isinstance(parsed, list) or not parsed:
        fail(
            "matrix must be a non-empty JSON array of objects, or an object "
            'with a non-empty "include" array',
        )

    for index, entry in enumerate(parsed):
        if not isinstance(entry, dict) or not entry:
            fail(f"matrix entry #{index + 1} must be a non-empty JSON object")
        normalised: dict[str, str] = {}
        for key, value in entry.items():
            if isinstance(value, (dict, list)) or value is None:
                fail(
                    f"matrix entry #{index + 1} field '{key}' must be a scalar "
                    "(string, number or boolean)",
                )
            normalised[key] = value if isinstance(value, str) else json.dumps(value)
        entries.append(normalised)
else:
    versions = [version.strip() for version in raw_versions.split(",") if version.strip()]
    if version_key:
        if not versions:
            fail("no toolchain versions resolved and no matrix provided")
        # Preserve order while deduplicating.
        entries = [{version_key: version} for version in dict.fromkeys(versions)]
    else:
        # toolchain: none with no matrix is a single build leg. GitHub needs at
        # least one matrix field per entry, so the runner is the leg label.
        entries = [{}]

# Caller-authored fields drive runner-map auto-detection: an injected toolchain
# version must not turn a single-field matrix into an ambiguous one.
caller_keys = {key for entry in entries for key in entry}

# Inject the toolchain version into entries that do not carry it, so every leg
# has a uniform shape (GitHub derives job-name suffixes from matrix fields).
if version_key and any(version_key not in entry for entry in entries):
    if not toolchain_version:
        fail(
            f"matrix entries must set '{version_key}', or set toolchain-version "
            "as the default for legs that omit it",
        )
    for entry in entries:
        entry.setdefault(version_key, toolchain_version)

needs_runner = bool(runner_map) or any(not entry for entry in entries)

if needs_runner:
    lookup_key = runner_map_key
    if runner_map and not lookup_key:
        if len(caller_keys) != 1:
            fail(
                "runner-map needs runner-map-key when matrix entries have "
                f"multiple fields (found: {', '.join(sorted(caller_keys)) or 'none'})",
            )
        lookup_key = next(iter(caller_keys))

    for index, entry in enumerate(entries):
        if "runner" in entry:
            continue
        if not runner_map:
            entry["runner"] = default_runner
            continue
        if lookup_key not in entry:
            fail(
                f"matrix entry #{index + 1} has no '{lookup_key}' field to look "
                "up in runner-map",
            )
        value = entry[lookup_key]
        runner = runner_map.get(value)
        if runner is None:
            print(
                f"::notice::No runner-map entry for {lookup_key}={value}; "
                f"using default runner {default_runner}",
            )
            runner = default_runner
        entry["runner"] = runner

# Preserve order while dropping duplicate legs.
unique: dict[str, dict[str, str]] = {}
for entry in entries:
    unique.setdefault(json.dumps(entry, sort_keys=True), entry)
entries = list(unique.values())

matrix = {"include": entries}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")

print(f"Build matrix legs: {len(entries)}")
for entry in entries:
    print(f"  - {json.dumps(entry)}")
PY
