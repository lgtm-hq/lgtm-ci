#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compose a post-pr-comment body that keeps earlier runs in a
# collapsible "Previous runs" archive under the latest result (#1346)
#
# Pure: no network. The existing comment body (empty when there is none) is
# read on stdin, the composed body is written to stdout.
#
# Environment variables:
#   NEW_BODY_FILE   - File holding the new result body (required)
#   MARKER_TAG      - Marker line that opens the comment (required)
#   HISTORY_LIMIT   - Earlier runs kept (default 3; 0 = unlimited within the cap)
#   HISTORY_SUMMARY - Optional one-line text shown on this run's archived entry
#   HISTORY_NOW     - Timestamp to stamp (default: current time, ISO 8601 UTC)
#   HEAD_SHA        - Commit the result is for
#   RUN_ID          - Workflow run id (the ordering and replacement key)
#   RUN_ATTEMPT     - Workflow run attempt
#   RUN_NUMBER      - Workflow run number (display only)
#   RUN_URL         - URL of this run (…/actions/runs/<RUN_ID>); links for
#                     archived runs are derived from it
#   HISTORY_MAX_BYTES - Byte budget for the whole body (default 60000)
#
# Layout of a composed body (only the lgtm-ci:history:* sentinels are parsed):
#
#   <marker>
#   <!-- lgtm-ci:history:latest sha=… run=… attempt=… number=… at=…[ summary=…] -->
#   <latest body>
#
#   ---
#
#   <details><summary>🕘 Previous runs (<count>)</summary>
#
#   <!-- lgtm-ci:history:start -->
#   <!-- lgtm-ci:history:entry sha=… run=… attempt=… number=… at=… -->
#   <details><summary>Run #… · <sha> · <at> · <link>[ · <summary>]</summary>
#   …
#   </details>
#   <!-- lgtm-ci:history:end -->
#
#   > ✂️ <k> older runs not listed (size limit)
#
#   </details>
#
# The optional summary= field of the latest stamp carries HISTORY_SUMMARY
# (base64) so the entry rendered when that result is archived can show it.

set -euo pipefail

# Byte semantics for every length below; multibyte text passes through as bytes.
export LC_ALL=C
# Bash 5.2 expands & in ${var//pattern/replacement} to the match; the HTML
# escaping below needs a literal &.
shopt -u patsub_replacement 2>/dev/null || true

: "${NEW_BODY_FILE:?NEW_BODY_FILE is required}"
: "${MARKER_TAG:?MARKER_TAG is required}"
HISTORY_LIMIT="${HISTORY_LIMIT:-3}"
HISTORY_SUMMARY="${HISTORY_SUMMARY:-}"
HISTORY_MAX_BYTES="${HISTORY_MAX_BYTES:-60000}"
HEAD_SHA="${HEAD_SHA:-unknown}"
RUN_ID="${RUN_ID:-0}"
RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
RUN_NUMBER="${RUN_NUMBER:-0}"
RUN_URL="${RUN_URL:-}"

for pair in "HISTORY_LIMIT=$HISTORY_LIMIT" "HISTORY_MAX_BYTES=$HISTORY_MAX_BYTES" \
	"RUN_ID=$RUN_ID" "RUN_ATTEMPT=$RUN_ATTEMPT" "RUN_NUMBER=$RUN_NUMBER"; do
	if [[ ! "${pair#*=}" =~ ^[0-9]+$ ]]; then
		echo "::error::post-pr-comment-history: ${pair%%=*} must be a non-negative integer, got '${pair#*=}'" >&2
		exit 1
	fi
done
if [[ ! -f "$NEW_BODY_FILE" ]]; then
	echo "::error::post-pr-comment-history: NEW_BODY_FILE not found: ${NEW_BODY_FILE}" >&2
	exit 1
fi
# Sentinel fields are space-delimited; a value with whitespace would not parse back.
[[ -n "$HEAD_SHA" && "$HEAD_SHA" =~ ^[^[:space:]]+$ ]] || HEAD_SHA="unknown"
HISTORY_NOW="${HISTORY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$HISTORY_NOW" =~ ^[^[:space:]]+$ ]] || HISTORY_NOW="unknown"

SENTINEL="<!-- lgtm-ci:history"
START_LINE="${SENTINEL}:start -->"
END_LINE="${SENTINEL}:end -->"
LATEST_RE='^<!-- lgtm-ci:history:latest sha=([^ ]+) run=([0-9]+) attempt=([0-9]+) number=([0-9]+) at=([^ ]+)( summary=([A-Za-z0-9+/=]+))? -->$'
ENTRY_RE='^<!-- lgtm-ci:history:entry sha=([^ ]+) run=([0-9]+) attempt=([0-9]+) number=([0-9]+) at=([^ ]+) -->$'
ARCHIVE_RE='^<details><summary>🕘 Previous runs \([0-9]+\)</summary>$'

# Break only the four history sentinels so a body cannot forge archive
# structure. Every other <!-- lgtm-ci:… --> marker is left as written.
neutralise() {
	local text="$1" kind
	for kind in latest start end entry; do
		text="${text//"${SENTINEL}:${kind}"/"< !-- lgtm-ci:history:${kind}"}"
	done
	printf '%s' "$text"
}

# Strip trailing newlines and blank lines.
trim_trailing() {
	local text="$1"
	printf '%s' "${text%"${text##*[![:space:]]}"}"
}

html_escape() {
	local text="$1"
	text="${text//&/&amp;}"
	text="${text//</&lt;}"
	text="${text//>/&gt;}"
	printf '%s' "$text"
}

# One display line, at most 200 characters (counted by jq, so multibyte
# characters are not split).
clean_summary() {
	jq -Rrs 'gsub("[\r\n\t]+"; " ") | gsub("^ +| +$"; "") | .[0:200]' <<<"$1"
}

encode_summary() {
	[[ -n "$1" ]] || return 0
	jq -Rsj '@base64' < <(printf '%s' "$1")
}

decode_summary() {
	[[ -n "$1" ]] || return 0
	jq -Rsj '@base64d' < <(printf '%s' "$1") 2>/dev/null || true
}

stamp_line() { # sha run attempt number at summary_b64
	local line="${SENTINEL}:latest sha=$1 run=$2 attempt=$3 number=$4 at=$5"
	[[ -n "$6" ]] && line+=" summary=$6"
	printf '%s -->' "$line"
}

RUNS_BASE=""
if [[ -n "$RUN_URL" ]]; then
	RUNS_BASE="${RUN_URL%/"$RUN_ID"}"
	RUNS_BASE="${RUNS_BASE%/}"
fi

# Render one archived entry: sentinel line, then a <details> block.
render_entry() { # sha run attempt number at summary body
	local sha="$1" run="$2" attempt="$3" number="$4" at="$5" summary="$6" body="$7"
	local title
	if [[ "$run" == "0" ]]; then
		title="earlier run (unstamped)"
	else
		title="Run #${number} · ${sha:0:7} · ${at}"
		if [[ -n "$RUNS_BASE" ]]; then
			title+=" · <a href=\"${RUNS_BASE}/${run}/attempts/${attempt}\">workflow run</a>"
		fi
		if ((10#$attempt > 1)); then
			title+=" · attempt ${attempt}"
		fi
		if [[ -n "$summary" ]]; then
			title+=" · $(html_escape "$summary")"
		fi
	fi
	printf '%s:entry sha=%s run=%s attempt=%s number=%s at=%s -->\n' \
		"$SENTINEL" "$sha" "$run" "$attempt" "$number" "$at"
	printf '<details><summary>%s</summary>\n\n%s\n\n</details>' \
		"$title" "$(trim_trailing "$(neutralise "$body")")"
}

# -----------------------------------------------------------------------------
# Incoming result
# -----------------------------------------------------------------------------
new_body="$(cat "$NEW_BODY_FILE")"
new_body="$(trim_trailing "$(neutralise "$new_body")")"
new_summary="$(clean_summary "$HISTORY_SUMMARY")"
RUN_ID=$((10#$RUN_ID))
RUN_ATTEMPT=$((10#$RUN_ATTEMPT))
RUN_NUMBER=$((10#$RUN_NUMBER))

# -----------------------------------------------------------------------------
# Parse the existing comment
# -----------------------------------------------------------------------------
existing="$(
	cat
	printf x
)"
existing="${existing%x}"
existing="${existing//$'\r'/}"

# Archive entries: parallel arrays indexed by insertion order. Entries added
# by this run are inserted first so they win ties on replacement.
E_RUN=()
E_ATTEMPT=()
E_BLOCK=()

add_entry() { # run attempt block
	E_RUN+=("$1")
	E_ATTEMPT+=("$2")
	E_BLOCK+=("$3")
}

has_latest=false
L_SHA="" L_RUN=0 L_ATTEMPT=0 L_NUMBER=0 L_AT="" L_SUMMARY_B64="" L_BODY=""
unstamped_body=""
parsed_blocks=()
parsed_runs=()
parsed_attempts=()

if [[ -n "$(trim_trailing "$existing")" ]]; then
	mapfile -t lines <<<"$existing"
	i=0
	n=${#lines[@]}
	if [[ "${lines[0]}" == "$MARKER_TAG" ]]; then
		i=1
	fi
	if ((i < n)) && [[ "${lines[i]}" =~ $LATEST_RE ]]; then
		has_latest=true
		L_SHA="${BASH_REMATCH[1]}"
		L_RUN=$((10#${BASH_REMATCH[2]}))
		L_ATTEMPT=$((10#${BASH_REMATCH[3]}))
		L_NUMBER=$((10#${BASH_REMATCH[4]}))
		L_AT="${BASH_REMATCH[5]}"
		L_SUMMARY_B64="${BASH_REMATCH[7]:-}"
		i=$((i + 1))
		latest_lines=()
		while ((i < n)) && [[ "${lines[i]}" != "$START_LINE" ]]; do
			latest_lines+=("${lines[i]}")
			i=$((i + 1))
		done
		if ((i < n)); then
			# Drop the archive wrapper the composer wrote before the start
			# sentinel: blank lines, the <details> opener, blank lines, ---.
			while ((${#latest_lines[@]} > 0)) && [[ -z "${latest_lines[-1]//[[:space:]]/}" ]]; do
				unset 'latest_lines[-1]'
			done
			if ((${#latest_lines[@]} > 0)) && [[ "${latest_lines[-1]}" =~ $ARCHIVE_RE ]]; then
				unset 'latest_lines[-1]'
				while ((${#latest_lines[@]} > 0)) && [[ -z "${latest_lines[-1]//[[:space:]]/}" ]]; do
					unset 'latest_lines[-1]'
				done
				if ((${#latest_lines[@]} > 0)) && [[ "${latest_lines[-1]}" == "---" ]]; then
					unset 'latest_lines[-1]'
				fi
			fi
			i=$((i + 1))
			current=-1
			while ((i < n)) && [[ "${lines[i]}" != "$END_LINE" ]]; do
				if [[ "${lines[i]}" =~ $ENTRY_RE ]]; then
					current=${#parsed_blocks[@]}
					parsed_runs+=("$((10#${BASH_REMATCH[2]}))")
					parsed_attempts+=("$((10#${BASH_REMATCH[3]}))")
					parsed_blocks+=("${lines[i]}")
				elif ((current >= 0)); then
					parsed_blocks[current]+=$'\n'"${lines[i]}"
				fi
				i=$((i + 1))
			done
		fi
		if ((${#latest_lines[@]} > 0)); then
			L_BODY="$(printf '%s\n' "${latest_lines[@]}")"
		fi
		L_BODY="$(trim_trailing "$L_BODY")"
	else
		# Posted before history was enabled: archive the whole body once.
		unstamped_body="$(printf '%s\n' "${lines[@]:i}")"
	fi
fi

# -----------------------------------------------------------------------------
# Decide the latest result and what gets archived
# -----------------------------------------------------------------------------
new_summary_b64="$(encode_summary "$new_summary")"
OUT_STAMP=""
OUT_BODY=""
OUT_RUN=0

promote_incoming() {
	OUT_STAMP="$(stamp_line "$HEAD_SHA" "$RUN_ID" "$RUN_ATTEMPT" "$RUN_NUMBER" "$HISTORY_NOW" "$new_summary_b64")"
	OUT_BODY="$new_body"
	OUT_RUN=$RUN_ID
}

if [[ "$has_latest" == "true" ]]; then
	if ((L_RUN > RUN_ID)); then
		# An older run finished last: keep the newer latest, archive this one.
		OUT_STAMP="$(stamp_line "$L_SHA" "$L_RUN" "$L_ATTEMPT" "$L_NUMBER" "$L_AT" "$L_SUMMARY_B64")"
		OUT_BODY="$L_BODY"
		OUT_RUN=$L_RUN
		add_entry "$RUN_ID" "$RUN_ATTEMPT" "$(render_entry "$HEAD_SHA" "$RUN_ID" "$RUN_ATTEMPT" \
			"$RUN_NUMBER" "$HISTORY_NOW" "$new_summary" "$new_body")"
	elif ((L_RUN == RUN_ID && L_ATTEMPT > RUN_ATTEMPT)); then
		# A stale attempt of the run already shown: nothing to add.
		OUT_STAMP="$(stamp_line "$L_SHA" "$L_RUN" "$L_ATTEMPT" "$L_NUMBER" "$L_AT" "$L_SUMMARY_B64")"
		OUT_BODY="$L_BODY"
		OUT_RUN=$L_RUN
	else
		promote_incoming
		if ((L_RUN != RUN_ID)); then
			add_entry "$L_RUN" "$L_ATTEMPT" "$(render_entry "$L_SHA" "$L_RUN" "$L_ATTEMPT" \
				"$L_NUMBER" "$L_AT" "$(decode_summary "$L_SUMMARY_B64")" "$L_BODY")"
		fi
	fi
else
	promote_incoming
	if [[ -n "$(trim_trailing "$unstamped_body")" ]]; then
		add_entry 0 0 "$(render_entry unknown 0 0 0 unknown "" "$unstamped_body")"
	fi
fi

for idx in "${!parsed_blocks[@]}"; do
	add_entry "${parsed_runs[idx]}" "${parsed_attempts[idx]}" \
		"$(trim_trailing "${parsed_blocks[idx]}")"
done

# -----------------------------------------------------------------------------
# Replace by run id, order by run id descending (run=0 last), apply the limit
# -----------------------------------------------------------------------------
declare -A best=()
for idx in "${!E_RUN[@]}"; do
	run="${E_RUN[idx]}"
	if ((run == 0)); then
		continue
	fi
	if ((run == OUT_RUN)); then
		# The latest section already shows this run.
		E_RUN[idx]=-1
		continue
	fi
	held="${best[$run]:-}"
	if [[ -z "$held" ]] || ((E_ATTEMPT[idx] > E_ATTEMPT[held])); then
		best[$run]=$idx
	fi
done

ordered=()
if ((${#E_RUN[@]} > 0)); then
	while IFS=$'\t' read -r _run idx; do
		ordered+=("$idx")
	done < <(
		for idx in "${!E_RUN[@]}"; do
			run="${E_RUN[idx]}"
			if ((run == 0)) || { ((run > 0)) && [[ "${best[$run]:-}" == "$idx" ]]; }; then
				printf '%s\t%s\n' "$run" "$idx"
			fi
		done | sort -t $'\t' -k1,1nr -k2,2n
	)
fi

if ((HISTORY_LIMIT > 0 && ${#ordered[@]} > HISTORY_LIMIT)); then
	ordered=("${ordered[@]:0:HISTORY_LIMIT}")
fi

# -----------------------------------------------------------------------------
# Compose under the byte budget
# -----------------------------------------------------------------------------
compose() { # dropped_count entry_index...
	local dropped="$1"
	shift
	local out="${MARKER_TAG}"$'\n'"${OUT_STAMP}"$'\n'"${OUT_BODY}"
	if (($# == 0 && dropped == 0)); then
		printf '%s' "$out"
		return
	fi
	out+=$'\n\n---\n\n'"<details><summary>🕘 Previous runs ($#)</summary>"$'\n\n'"${START_LINE}"
	local idx
	for idx in "$@"; do
		out+=$'\n'"${E_BLOCK[idx]}"$'\n'
	done
	out+=$'\n'"${END_LINE}"$'\n'
	if ((dropped > 0)); then
		out+=$'\n'"> ✂️ ${dropped} older runs not listed (size limit)"$'\n'
	fi
	out+=$'\n</details>'
	printf '%s' "$out"
}

kept=()
dropped=0
for idx in "${ordered[@]}"; do
	candidate="$(compose "$dropped" "${kept[@]}" "$idx")"
	if ((${#candidate} <= HISTORY_MAX_BYTES)); then
		kept+=("$idx")
	else
		dropped=$((dropped + 1))
	fi
done

body="$(compose "$dropped" "${kept[@]}")"
# The note and count can grow the body after the last fit check.
while ((${#body} > HISTORY_MAX_BYTES && ${#kept[@]} > 0)); do
	unset 'kept[-1]'
	dropped=$((dropped + 1))
	body="$(compose "$dropped" "${kept[@]}")"
done

printf '%s\n' "$body"
