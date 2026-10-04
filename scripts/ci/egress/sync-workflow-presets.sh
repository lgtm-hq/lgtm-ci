#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write the rendered egress preset map into every reusable workflow (or check it)
#
# Usage:
#   bash scripts/ci/egress/sync-workflow-presets.sh           # rewrite in place
#   bash scripts/ci/egress/sync-workflow-presets.sh --check   # exit 1 on drift
#
# Each reusable workflow carries the preset map as a workflow-level env value
# between two marker comments:
#
#   env:
#     # lgtm-ci-egress-presets:begin
#     LGTM_CI_EGRESS_PRESETS: >-
#       {"github-minimal":"github.com:443 ...",
#       ...
#     # lgtm-ci-egress-presets:end
#
# The block body is exactly the output of render-presets.sh indented by four
# spaces. Workflows without the markers are skipped (and listed in --check so
# a new reusable cannot ship without the map). The BATS contract test runs
# `--check`; after editing scripts/ci/lib/egress/presets.sh, run this script
# and commit the workflow changes with it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

BEGIN_MARK="# lgtm-ci-egress-presets:begin"
END_MARK="# lgtm-ci-egress-presets:end"
ENV_KEY="LGTM_CI_EGRESS_PRESETS"
INDENT="    "

check=0
case "${1:-}" in
"") ;;
--check) check=1 ;;
*)
	echo "usage: $0 [--check]" >&2
	exit 2
	;;
esac

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
{
	printf '  %s: >-\n' "$ENV_KEY"
	bash "$SCRIPT_DIR/render-presets.sh" | sed "s/^/${INDENT}/"
} >"$rendered"

status=0
missing=()
drifted=()
for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
	name="$(basename "$workflow")"
	if ! grep -qF "$BEGIN_MARK" "$workflow" || ! grep -qF "$END_MARK" "$workflow"; then
		missing+=("$name")
		continue
	fi

	# Splice: everything before the begin marker, the marker, the rendered
	# block, the end marker, everything after it.
	updated="$(mktemp)"
	awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v body="$rendered" '
		index($0, begin) { print; while ((getline line < body) > 0) print line; close(body); skipping = 1; next }
		index($0, end) { skipping = 0 }
		!skipping { print }
	' "$workflow" >"$updated"

	if cmp -s "$workflow" "$updated"; then
		rm -f "$updated"
		continue
	fi
	if ((check)); then
		drifted+=("$name")
		rm -f "$updated"
	else
		mv "$updated" "$workflow"
		echo "updated $name"
	fi
done

if ((${#missing[@]})); then
	echo "sync-workflow-presets: no ${BEGIN_MARK} / ${END_MARK} markers in: ${missing[*]}" >&2
	status=1
fi
if ((${#drifted[@]})); then
	echo "sync-workflow-presets: embedded preset map differs from render-presets.sh in: ${drifted[*]}" >&2
	echo "run: bash scripts/ci/egress/sync-workflow-presets.sh" >&2
	status=1
fi
exit "$status"
