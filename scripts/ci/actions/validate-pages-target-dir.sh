#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate the pages-target-dir input of reusable-test-e2e-matrix (#754).
#
# The value names the subdirectory of the GitHub Pages site the merged Playwright
# report is deployed into, so it is interpolated straight into a deploy
# destination path. That makes this a security control, not a spelling check: an
# absolute path or a ".." segment would let a caller write the report outside the
# directory the publish job is supposed to own — over a sibling publisher's tree,
# or over the site root itself.
#
# It is deliberately NOT derived from artifact-prefix. A Pages directory is
# URL-visible and has no glob-disjointness requirement, so it neither wants the
# prefix's "no hyphen" restriction nor should it silently move a caller's
# published URL when that caller sets artifact-prefix for artifact reasons alone.
#
# Environment:
#   PAGES_TARGET_DIR (required) Target directory from the workflow input

set -euo pipefail

: "${PAGES_TARGET_DIR:=}"

target_dir="$PAGES_TARGET_DIR"

if [[ -z "$target_dir" ]]; then
	echo "::error::pages-target-dir must not be empty (use '.' for the site root)" >&2
	exit 1
fi

if [[ "$target_dir" == /* ]]; then
	echo "::error::pages-target-dir must be a relative path (got '${target_dir}'): a leading '/' would deploy outside the Pages site directory" >&2
	exit 1
fi

# Segment-wise, so a legitimate name that merely contains dots (pw..smoke is not
# a traversal) is not rejected while every real ".." hop is.
IFS='/' read -r -a target_dir_segments <<<"$target_dir"
for segment in "${target_dir_segments[@]}"; do
	if [[ "$segment" == ".." ]]; then
		echo "::error::pages-target-dir must not contain '..' segments (got '${target_dir}'): traversal would deploy outside the Pages site directory" >&2
		exit 1
	fi
done

# Allowlist rather than a denylist: backslashes, whitespace, shell and glob
# metacharacters, '~' and control characters all have no place in a URL-visible
# Pages directory, and enumerating what to ban is the losing half of that game.
if [[ ! "$target_dir" =~ ^[A-Za-z0-9._/-]+$ ]]; then
	echo "::error::pages-target-dir must match [A-Za-z0-9._/-]+ (got '${target_dir}'): it becomes part of the published report URL" >&2
	exit 1
fi

echo "Pages target dir: ${target_dir}"
echo "Merged report deploys to: <pages-site>/${target_dir}"
