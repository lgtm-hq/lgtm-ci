#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Turn the caller's tag prefix into a key that is safe in an
# artifact name (#849).
#
# The hook artifacts are named per invocation so two calls of one release
# reusable in a run cannot swap diffs. Tag prefixes such as `cli/v` are
# valid for Git but artifact names reject `/`, `"`, `:`, `<`, `>`, `|`,
# `*`, `?`; the key keeps the readable part and appends a short digest so
# `cli/v` and `cli_v` stay distinct.
#
# Environment variables:
#   TAG_PREFIX    - Caller tag prefix (may be empty)
#   GITHUB_OUTPUT - Receives key=<value>

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
TAG_PREFIX="${TAG_PREFIX:-}"

readable="$(printf '%s' "$TAG_PREFIX" | tr -c 'A-Za-z0-9._-' '_')"
readable="${readable:0:32}"
digest="$(printf '%s' "$TAG_PREFIX" | shasum -a 256 | cut -c1-8)"

key="${readable:+${readable}-}${digest}"
printf 'key=%s\n' "$key" >>"$GITHUB_OUTPUT"
printf 'Artifact key for tag prefix %q: %s\n' "$TAG_PREFIX" "$key"
