#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the egress presets a workflow accepts as the env block it embeds
#
# Usage:
#   bash scripts/ci/egress/render-presets.sh                      # YAML env block, every preset
#   bash scripts/ci/egress/render-presets.sh --presets a,b        # YAML env block, presets a and b
#   bash scripts/ci/egress/render-presets.sh --json [--presets a,b]  # effective map, compact JSON
#
# step-security/harden-runner installs its agent in the action pre hook, before
# any step runs, so a reusable workflow cannot read presets.sh at run time: the
# allowlist must be a literal at job start (#412/#420). This script renders
# presets from scripts/ci/lib/egress/presets.sh into the env block each
# workflow carries between its lgtm-ci-egress-presets markers:
#
#   LGTM_CI_EGRESS_PRESETS: >-                    {"<preset>":"<own hosts>",...}
#   LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS: >-    ["<preset>",...]
#   LGTM_CI_EGRESS_RESULTS_STORAGE: >-            <storage host> <storage host> ...
#
# The map holds each preset's own hosts. GitHub's results storage hosts
# (egress_github_results_storage_endpoints, 140 of them) appear once, under
# LGTM_CI_EGRESS_RESULTS_STORAGE, and the expression that indexes the map
# appends them when the selected preset is listed in
# LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS:
#
#   format('{0} {1} {2}',
#   fromJSON(env.LGTM_CI_EGRESS_PRESETS)[<selector>],
#   contains(fromJSON(env.LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS), <selector>)
#   && env.LGTM_CI_EGRESS_RESULTS_STORAGE || '',
#   inputs.allowed-endpoints)
#
# The two storage keys are rendered only when one of the presets includes the
# storage (#1623). --presets limits the block to the presets a workflow
# accepts; sync-workflow-presets.sh derives that list from the workflow.
# --without-results-storage leaves the two storage keys out (and the map
# without the storage) for a workflow with no harden-runner selector of its
# own, such as a wrapper that only forwards egress-preset to the reusables it
# calls. --json ignores it.
#
# Map and storage values are YAML `>-` folded scalars, one line per entry,
# long entries wrapped at host boundaries. YAML folding joins the lines with
# single spaces, which land either between two hosts (harden-runner splits on
# whitespace) or between JSON tokens, so each folded value is still one JSON
# document (or one host list). --json prints the effective allow-list of each
# preset (own hosts plus the storage where it applies), which is what the
# workflow expression composes; the BATS contract test checks that the two
# agree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# EGRESS_PRESETS_FILE is a test seam only; production renders the canonical file.
PRESETS_FILE="${EGRESS_PRESETS_FILE:-$REPO_ROOT/scripts/ci/lib/egress/presets.sh}"
# shellcheck source=../lib/egress/presets.sh
source "$PRESETS_FILE"

# Wrap width for the folded form. Values are indented four spaces inside the
# workflow `env:` block, so 100 keeps every line under yamllint's 120 limit.
WRAP_WIDTH="${EGRESS_RENDER_WRAP_WIDTH:-100}"

MAP_KEY="LGTM_CI_EGRESS_PRESETS"
STORAGE_PRESETS_KEY="LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS"
STORAGE_KEY="LGTM_CI_EGRESS_RESULTS_STORAGE"

usage() {
	echo "usage: $0 [--json] [--presets NAME[,NAME...]] [--without-results-storage]" >&2
	exit 2
}

mode="folded"
selected=""
with_storage=1
while (($#)); do
	case "$1" in
	--json) mode="json" ;;
	--presets)
		[[ $# -ge 2 && -n "$2" ]] || usage
		selected="$2"
		shift
		;;
	--without-results-storage) with_storage=0 ;;
	*) usage ;;
	esac
	shift
done

# Optional seams for a test presets file that predates the storage split: a
# preset without its own-hosts function renders its full list, and no preset
# uses the storage.
declare -F egress_preset_own_endpoints >/dev/null ||
	egress_preset_own_endpoints() { egress_preset_endpoints "$@"; }
declare -F egress_preset_uses_results_storage >/dev/null ||
	egress_preset_uses_results_storage() { return 1; }

# Hosts of one preset joined by single spaces: its own hosts, or with --json
# its effective list. Fails loudly on an unknown name so a typo in
# egress_preset_names cannot render as an empty allowlist.
preset_value() {
	local preset="$1" fn="$2" hosts
	hosts="$("$fn" "$preset")" || exit 1
	[[ -n "$hosts" ]] || {
		echo "render-presets.sh: preset '$preset' rendered empty" >&2
		exit 1
	}
	printf '%s' "$hosts" | tr '\n' ' ' | sed 's/ $//'
}

names=()
while IFS= read -r name; do
	[[ -n "$name" ]] && names+=("$name")
done < <(egress_preset_names)

# --presets: keep render order (egress_preset_names), refuse unknown names.
if [[ -n "$selected" ]]; then
	all=" ${names[*]} "
	wanted=" ${selected//,/ } "
	IFS=',' read -r -a requested <<<"$selected"
	for name in "${requested[@]}"; do
		[[ -n "$name" && "$name" != *" "* && "$all" == *" $name "* ]] || {
			echo "render-presets.sh: unknown preset '$name'" >&2
			exit 1
		}
	done
	kept=()
	for name in "${names[@]}"; do
		[[ "$wanted" == *" $name "* ]] && kept+=("$name")
	done
	((${#kept[@]})) || usage
	names=("${kept[@]}")
fi

storage_names=()
for name in "${names[@]}"; do
	if ((with_storage)) && egress_preset_uses_results_storage "$name"; then
		storage_names+=("$name")
	fi
done

if [[ "$mode" == "json" ]]; then
	out="{"
	sep=""
	for name in "${names[@]}"; do
		# Resolve first so a failed preset aborts instead of rendering "".
		value="$(preset_value "$name" egress_preset_endpoints)" || exit 1
		out+="${sep}\"${name}\":\"${value}\""
		sep=","
	done
	printf '%s}\n' "$out"
	exit 0
fi

# One folded entry: `<prefix>h1 h2 ...<suffix>`, two spaces deep under its
# key. A value longer than WRAP_WIDTH continues on the next line, split only
# between hosts.
emit_entry() {
	local prefix="$1" value="$2" suffix="$3"
	local line="${prefix}" host
	local -a hosts=()
	# Split on spaces only: a wildcard host such as *.example.com:443 must
	# never undergo pathname expansion.
	IFS=' ' read -r -a hosts <<<"$value"
	for host in "${hosts[@]}"; do
		if [[ "$line" != "$prefix" && $((${#line} + 1 + ${#host})) -gt "$WRAP_WIDTH" ]]; then
			printf '  %s\n' "$line"
			line="$host"
		elif [[ "$line" == "$prefix" ]]; then
			line+="$host"
		else
			line+=" $host"
		fi
	done
	printf '  %s\n' "${line}${suffix}"
}

# The map: `{"a":"h1 h2",` / `"b":"h3 ...",` / ... / `"z":"hN"}`.
printf '%s: >-\n' "$MAP_KEY"
last=$((${#names[@]} - 1))
for i in "${!names[@]}"; do
	name="${names[$i]}"
	prefix="\"${name}\":\""
	[[ $i -eq 0 ]] && prefix="{${prefix}"
	suffix='",'
	[[ $i -eq $last ]] && suffix='"}'
	# Resolve first so a failed preset aborts instead of rendering "".
	value="$(preset_value "$name" egress_preset_own_endpoints)" || exit 1
	emit_entry "$prefix" "$value" "$suffix"
done

((${#storage_names[@]})) || exit 0

list=""
for name in "${storage_names[@]}"; do
	list+="${list:+,}\"${name}\""
done
printf '%s: >-\n' "$STORAGE_PRESETS_KEY"
printf '  [%s]\n' "$list"

storage="$(egress_github_results_storage_endpoints)" || exit 1
[[ -n "$storage" ]] || {
	echo "render-presets.sh: results storage rendered empty" >&2
	exit 1
}
printf '%s: >-\n' "$STORAGE_KEY"
emit_entry "" "$(printf '%s' "$storage" | tr '\n' ' ' | sed 's/ $//')" ""
