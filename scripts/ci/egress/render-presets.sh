#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Render the canonical egress presets as the JSON map reusable workflows embed
#
# Usage:
#   bash scripts/ci/egress/render-presets.sh          # YAML folded-scalar lines
#   bash scripts/ci/egress/render-presets.sh --json   # compact single-line JSON
#
# step-security/harden-runner installs its agent in the action pre hook, before
# any step runs, so a reusable workflow cannot read presets.sh at run time: the
# allowlist must be a literal at job start (#412/#420). This script renders
# every preset from scripts/ci/lib/egress/presets.sh into one JSON object
# ({"<preset>":"<host:port> <host:port> ..."}) that each workflow carries in
# `env.LGTM_CI_EGRESS_PRESETS` and indexes with
# `fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || '<default>']`.
#
# Default output is the body of a YAML `>-` folded scalar, one line per entry,
# long entries wrapped at host boundaries. YAML folding joins the lines with
# single spaces, which land either between two hosts (harden-runner splits on
# whitespace) or between JSON tokens, so the folded value is still the same
# JSON document `--json` prints. sync-workflow-presets.sh writes these lines
# into the workflows; the BATS contract test re-renders and diffs them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# EGRESS_PRESETS_FILE is a test seam only; production renders the canonical file.
PRESETS_FILE="${EGRESS_PRESETS_FILE:-$REPO_ROOT/scripts/ci/lib/egress/presets.sh}"
# shellcheck source=../lib/egress/presets.sh
source "$PRESETS_FILE"

# Wrap width for the folded form. Entries are indented four spaces inside the
# workflow `env:` block, so 100 keeps every line under yamllint's 120 limit.
WRAP_WIDTH="${EGRESS_RENDER_WRAP_WIDTH:-100}"

mode="folded"
case "${1:-}" in
"") ;;
--json) mode="json" ;;
*)
	echo "usage: $0 [--json]" >&2
	exit 2
	;;
esac

# Hosts of one preset joined by single spaces. Fails loudly on an unknown name
# so a typo in egress_preset_names cannot render as an empty allowlist.
preset_value() {
	local preset="$1" hosts
	hosts="$(egress_preset_endpoints "$preset")" || exit 1
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

if [[ "$mode" == "json" ]]; then
	out="{"
	sep=""
	for name in "${names[@]}"; do
		# Resolve first so a failed preset aborts instead of rendering "".
		value="$(preset_value "$name")" || exit 1
		out+="${sep}\"${name}\":\"${value}\""
		sep=","
	done
	printf '%s}\n' "$out"
	exit 0
fi

# Folded form: `{"a":"h1 h2",` / `"b":"h3 ...",` / ... / `"z":"hN"}`. A value
# longer than WRAP_WIDTH continues on the next line, split only between hosts.
emit_entry() {
	local prefix="$1" value="$2" suffix="$3"
	local line="${prefix}" host
	local -a hosts=()
	# Split on spaces only: wildcard hosts such as *.blob.core.windows.net:443
	# must never undergo pathname expansion.
	IFS=' ' read -r -a hosts <<<"$value"
	for host in "${hosts[@]}"; do
		if [[ "$line" != "$prefix" && $((${#line} + 1 + ${#host})) -gt "$WRAP_WIDTH" ]]; then
			printf '%s\n' "$line"
			line="$host"
		elif [[ "$line" == "$prefix" ]]; then
			line+="$host"
		else
			line+=" $host"
		fi
	done
	printf '%s\n' "${line}${suffix}"
}

last=$((${#names[@]} - 1))
for i in "${!names[@]}"; do
	name="${names[$i]}"
	prefix="\"${name}\":\""
	[[ $i -eq 0 ]] && prefix="{${prefix}"
	suffix='",'
	[[ $i -eq $last ]] && suffix='"}'
	# Resolve first so a failed preset aborts instead of rendering "".
	value="$(preset_value "$name")" || exit 1
	emit_entry "$prefix" "$value" "$suffix"
done
