#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write the egress presets each workflow accepts into that workflow (or check them)
#
# Usage:
#   bash scripts/ci/egress/sync-workflow-presets.sh             # rewrite in place
#   bash scripts/ci/egress/sync-workflow-presets.sh --check     # exit 1 on drift
#   bash scripts/ci/egress/sync-workflow-presets.sh --accepted FILE  # print FILE's accepted presets
#
# Each reusable workflow carries its preset map as env values between two
# marker comments, normally at workflow level:
#
#   env:
#     # lgtm-ci-egress-presets:begin
#     LGTM_CI_EGRESS_PRESETS: >-
#       {"github-results":"github.com:443 ...",
#       ...
#     # lgtm-ci-egress-presets:end
#
# The block body is exactly the output of
# `render-presets.sh --presets <accepted>` indented to the markers (with
# --without-results-storage when the workflow selects from the map nowhere,
# see render-presets.sh). The
# markers normally sit at workflow-level env (two spaces);
# reusable-scorecards.yml carries them in a job-level env because the
# Scorecard API rejects a workflow-level env (#1173).
#
# A workflow embeds only the presets it accepts (#1623), so any other
# egress-preset name finds no entry and fails the unknown-preset guard, as an
# unknown name always has. The accepted presets are read from the workflow
# itself, so they cannot drift from what it selects:
#   - every quoted preset name inside a fromJSON(env.LGTM_CI_EGRESS_PRESETS)[...]
#     selector, and
#   - the default of every input such a selector reads, and of egress-preset
#     (a wrapper that only forwards egress-preset to the reusables it calls
#     selects nothing itself).
#
# Workflows without the markers are skipped (and listed in --check so a new
# reusable cannot ship without the map). The BATS contract test runs
# `--check`; after editing scripts/ci/lib/egress/presets.sh or an
# egress-preset default, run this script and add the workflow changes to the
# same change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

BEGIN_MARK="# lgtm-ci-egress-presets:begin"
END_MARK="# lgtm-ci-egress-presets:end"
SELECTOR_RE="fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[[^]]*\]"

usage() {
	echo "usage: $0 [--check | --accepted FILE]" >&2
	exit 2
}

# The default of one workflow_call input, or nothing when it has none.
input_default() {
	awk -v want="      $2:" '
		$0 == want { on = 1; next }
		on && /^        default:/ { sub(/^        default:[ ]*/, ""); gsub(/"/, ""); print; exit }
		on && /^      [a-z-]+:$/ { exit }
	' "$1"
}

# The presets one workflow accepts, comma-separated, in no particular order
# (render-presets.sh restores render order). Empty when it selects none.
accepted_presets() {
	local workflow="$1" selectors name default
	local -a found=()
	selectors="$(grep -oE "$SELECTOR_RE" "$workflow" || true)"
	while IFS= read -r name; do
		[[ -n "$name" ]] && found+=("$name")
	done < <(grep -oE "'[a-z][a-z-]*'" <<<"$selectors" | tr -d "'" | sort -u)
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		default="$(input_default "$workflow" "$name")"
		[[ -n "$default" ]] && found+=("$default")
	done < <({
		grep -oE "inputs\.[a-z][a-z-]*" <<<"$selectors" | sed 's/^inputs\.//' || true
		grep -qxF "      egress-preset:" "$workflow" && echo egress-preset
	} | sort -u)
	((${#found[@]})) || return 0
	printf '%s\n' "${found[@]}" | sort -u | paste -sd, -
}

check=0
case "${1:-}" in
"") ;;
--check) check=1 ;;
--accepted)
	[[ $# -eq 2 ]] || usage
	accepted_presets "$2"
	exit 0
	;;
*) usage ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

status=0
missing=()
drifted=()
empty=()
# Every reusable must carry the map. A caller workflow that hardens its own
# jobs (external-consumer-canary.yml, #1074) opts in by carrying the markers;
# callers without them are simply not synced.
for workflow in "$WORKFLOWS_DIR"/*.yml; do
	name="$(basename "$workflow")"
	if ! grep -qF "$BEGIN_MARK" "$workflow" || ! grep -qF "$END_MARK" "$workflow"; then
		[[ "$name" == reusable-*.yml ]] && missing+=("$name")
		continue
	fi

	accepted="$(accepted_presets "$workflow")"
	if [[ -z "$accepted" ]]; then
		empty+=("$name")
		continue
	fi
	rendered="$tmpdir/rendered"
	# A workflow that indexes the map nowhere (a wrapper that only forwards
	# egress-preset) gets no results storage hosts: nothing would read them.
	storage_flag=()
	grep -qE "$SELECTOR_RE" "$workflow" || storage_flag=(--without-results-storage)
	bash "$SCRIPT_DIR/render-presets.sh" --presets "$accepted" ${storage_flag[@]+"${storage_flag[@]}"} >"$rendered"

	# Splice: everything before the begin marker, the marker, the rendered
	# block (indented to the marker), the end marker, everything after it.
	updated="$tmpdir/updated"
	awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v body="$rendered" '
		index($0, begin) {
			print
			match($0, /^[ ]*/)
			ind = substr($0, 1, RLENGTH)
			while ((getline line < body) > 0) print ind line
			close(body)
			skipping = 1
			next
		}
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
if ((${#empty[@]})); then
	echo "sync-workflow-presets: no egress preset selected or defaulted in: ${empty[*]}" >&2
	status=1
fi
if ((${#drifted[@]})); then
	echo "sync-workflow-presets: embedded preset map differs from render-presets.sh in: ${drifted[*]}" >&2
	echo "run: bash scripts/ci/egress/sync-workflow-presets.sh" >&2
	status=1
fi
exit "$status"
