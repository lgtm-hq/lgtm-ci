#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write the egress presets each workflow accepts into that workflow (or check them)
#
# Usage:
#   bash scripts/ci/egress/sync-workflow-presets.sh             # rewrite in place
#   bash scripts/ci/egress/sync-workflow-presets.sh --check     # exit 1 on drift
#   bash scripts/ci/egress/sync-workflow-presets.sh --accepted FILE  # FILE's declared presets
#   bash scripts/ci/egress/sync-workflow-presets.sh --derived FILE   # presets FILE selects
#
# Each reusable workflow carries its preset map as env values between two
# marker comments, normally at workflow level, after a declaration of the
# presets it accepts:
#
#   env:
#     # lgtm-ci-egress-accepts: github-minimal,release-version-pr
#     # lgtm-ci-egress-presets:begin
#     LGTM_CI_EGRESS_PRESETS: >-
#       {"github-minimal":"github.com:443 ...",
#       ...
#     # lgtm-ci-egress-presets:end
#
# The declaration is the source of truth for what the workflow embeds (#1623):
# the block body is exactly the output of `render-presets.sh --presets
# <declared>` indented to the markers (with --without-results-storage when the
# workflow selects from the map nowhere, see render-presets.sh). Any other
# egress-preset name finds no entry and fails the unknown-preset guard. The
# markers normally sit at workflow-level env (two spaces);
# reusable-scorecards.yml carries them in a job-level env because the
# Scorecard API rejects a workflow-level env (#1173).
#
# The declaration must equal the set derived from the workflow itself
# (--derived prints it), or both modes fail for that workflow:
#   - every quoted preset name inside a fromJSON(env.LGTM_CI_EGRESS_PRESETS)[...]
#     selector, including one split over several lines, and
#   - the default of every input such a selector reads, and of egress-preset
#     (a wrapper that only forwards egress-preset to the reusables it calls
#     selects nothing itself).
# So a deliberate change to the accepted set is one reviewed edit of the
# declaration, and a layout change that hides a selector or a default from the
# derivation is caught rather than silently narrowing or widening the map.
#
# The description of egress-preset and of every input a selector reads must
# name the declared set as `Accepted presets: a, b.` (whitespace and line
# breaks aside), so the caller-facing documentation cannot drift either.
#
# Workflows without the markers are skipped (and listed in --check so a new
# reusable cannot ship without the map). The BATS contract test runs
# `--check`; after editing scripts/ci/lib/egress/presets.sh, a declaration or
# an egress-preset default, run this script and add the workflow changes to
# the same change.

set -euo pipefail
# Byte order for every sort: declarations must sort the same on any machine.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

BEGIN_MARK="# lgtm-ci-egress-presets:begin"
END_MARK="# lgtm-ci-egress-presets:end"
DECLARE_MARK="# lgtm-ci-egress-accepts:"
SELECTOR_RE="fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[[^]]*\]"
NAME_LIST_RE="^[a-z][a-z-]*(,[a-z][a-z-]*)*$"

usage() {
	echo "usage: $0 [--check | --accepted FILE | --derived FILE]" >&2
	exit 2
}

# The value of one key of one workflow_call input (default or description),
# whatever its indentation, folded to a single line with single spaces. A
# block scalar (`>-`, `|`) is read to the end of its indentation. Prints
# nothing when the input or the key is absent.
input_field() {
	awk -v want="$2" -v field="$3" '
		function indent(s) { match(s, /^ */); return RLENGTH }
		function emit(v) { gsub(/[ \t]+/, " ", v); sub(/^ /, "", v); sub(/ $/, "", v); print v; exit }
		/^[ \t]*$/ { if (inblock) value = value " "; next }
		inblock {
			if (indent($0) > field_ind) { value = value " " $0; next }
			emit(value)
		}
		on && indent($0) <= key_ind { exit }
		on && $0 ~ "^ *" field ":" {
			field_ind = indent($0)
			v = $0
			sub("^ *" field ":[ ]*", "", v)
			if (v ~ /^[>|][-+]?$/) { inblock = 1; value = ""; next }
			gsub(/^"|"$/, "", v)
			emit(v)
		}
		!on && $0 ~ "^ *" want ":[ ]*$" { on = 1; key_ind = indent($0) }
		END { if (inblock) emit(value) }
	' "$1"
}

# The whole workflow on one line, so a selector split across lines is still
# one match.
selectors() {
	tr '\n' ' ' <"$1" | tr -s ' ' | grep -oE "$SELECTOR_RE" || true
}

# The inputs whose description must name the accepted presets: every input a
# selector reads, and egress-preset when the workflow declares it.
preset_inputs() {
	{
		grep -oE "inputs\.[a-z][a-z-]*" <<<"$(selectors "$1")" | sed 's/^inputs\.//' || true
		grep -qE "^ *egress-preset:[ ]*$" "$1" && echo egress-preset
	} | sort -u
}

# The presets one workflow selects or defaults to, sorted, comma-separated.
# Empty when it selects none.
derived_presets() {
	local workflow="$1" name default
	local -a found=()
	while IFS= read -r name; do
		[[ -n "$name" ]] && found+=("$name")
	done < <(grep -oE "'[a-z][a-z-]*'" <<<"$(selectors "$workflow")" | tr -d "'" | sort -u)
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		default="$(input_field "$workflow" "$name" default)"
		[[ -n "$default" ]] && found+=("$default")
	done < <(preset_inputs "$workflow")
	((${#found[@]})) || return 0
	printf '%s\n' "${found[@]}" | sort -u | paste -sd, -
}

# The declared presets of one workflow, exactly as written. Fails (with a
# reason on stderr) unless there is exactly one declaration and it is a
# sorted, duplicate-free, comma-separated list of names.
declared_presets() {
	local workflow="$1" lines value
	lines="$(grep -E "^ *${DECLARE_MARK}" "$workflow" || true)"
	if [[ -z "$lines" ]]; then
		echo "no '${DECLARE_MARK}' line" >&2
		return 1
	fi
	if [[ "$(wc -l <<<"$lines" | tr -d ' ')" -ne 1 ]]; then
		echo "more than one '${DECLARE_MARK}' line" >&2
		return 1
	fi
	value="${lines#*"${DECLARE_MARK}"}"
	value="${value# }"
	if [[ ! "$value" =~ $NAME_LIST_RE ]]; then
		echo "'${value}' is not a comma-separated list of preset names" >&2
		return 1
	fi
	if [[ "$value" != "$(tr ',' '\n' <<<"$value" | sort -u | paste -sd, -)" ]]; then
		echo "'${value}' is not sorted and duplicate-free" >&2
		return 1
	fi
	printf '%s\n' "$value"
}

# The inputs whose description does not name the declared set.
stale_descriptions() {
	local workflow="$1" declared="$2" want name text
	want="Accepted presets: ${declared//,/, }."
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		text="$(input_field "$workflow" "$name" description)"
		[[ "$text" == *"$want"* ]] || printf '%s\n' "$name"
	done < <(preset_inputs "$workflow")
}

check=0
case "${1:-}" in
"") ;;
--check) check=1 ;;
--accepted)
	[[ $# -eq 2 ]] || usage
	declared_presets "$2"
	exit
	;;
--derived)
	[[ $# -eq 2 ]] || usage
	derived_presets "$2"
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
undeclared=()
mismatched=()
undescribed=()
# Every reusable must carry the map. A caller workflow that hardens its own
# jobs (external-consumer-canary.yml, #1074) opts in by carrying the markers;
# callers without them are simply not synced.
for workflow in "$WORKFLOWS_DIR"/*.yml; do
	name="$(basename "$workflow")"
	if ! grep -qF "$BEGIN_MARK" "$workflow" || ! grep -qF "$END_MARK" "$workflow"; then
		[[ "$name" == reusable-*.yml ]] && missing+=("$name")
		continue
	fi

	derived="$(derived_presets "$workflow")"
	if [[ -z "$derived" ]]; then
		empty+=("$name")
		continue
	fi
	if ! accepted="$(declared_presets "$workflow" 2>"$tmpdir/why")"; then
		undeclared+=("$name ($(cat "$tmpdir/why"))")
		continue
	fi
	# Fail closed: a declaration that disagrees with the workflow is never
	# rendered, in either mode.
	if [[ "$accepted" != "$derived" ]]; then
		mismatched+=("$name (declares ${accepted}, selects or defaults to ${derived})")
		continue
	fi
	stale="$(stale_descriptions "$workflow" "$accepted" | paste -sd, -)"
	[[ -z "$stale" ]] || undescribed+=("$name: ${stale} (want 'Accepted presets: ${accepted//,/, }.')")

	rendered="$tmpdir/rendered"
	# A workflow that indexes the map nowhere (a wrapper that only forwards
	# egress-preset) gets no results storage hosts: nothing would read them.
	storage_flag=()
	[[ -n "$(selectors "$workflow")" ]] || storage_flag=(--without-results-storage)
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

report() {
	local message="$1"
	shift
	(($#)) || return 0
	echo "sync-workflow-presets: ${message}:" >&2
	printf '  %s\n' "$@" >&2
	status=1
}

if ((${#missing[@]})); then
	echo "sync-workflow-presets: no ${BEGIN_MARK} / ${END_MARK} markers in: ${missing[*]}" >&2
	status=1
fi
if ((${#empty[@]})); then
	echo "sync-workflow-presets: no egress preset selected or defaulted in: ${empty[*]}" >&2
	status=1
fi
report "no valid '${DECLARE_MARK}' declaration" ${undeclared[@]+"${undeclared[@]}"}
report "declared presets differ from the presets the workflow selects or defaults to" \
	${mismatched[@]+"${mismatched[@]}"}
report "preset input descriptions do not name the declared presets" \
	${undescribed[@]+"${undescribed[@]}"}
if ((${#drifted[@]})); then
	echo "sync-workflow-presets: embedded preset map differs from render-presets.sh in: ${drifted[*]}" >&2
	echo "run: bash scripts/ci/egress/sync-workflow-presets.sh" >&2
	status=1
fi
exit "$status"
