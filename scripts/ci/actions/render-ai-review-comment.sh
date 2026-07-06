#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Maintain the sticky Lintro AI Review PR comment (fetch/parse existing
#          state, append this run, recompute cumulative, and render the body).
#
# The single sticky comment embeds machine-readable state in a trailing HTML
# comment (`<!-- lintro-ai-review-state: {...} -->`) so cumulative data survives
# across runs without external storage. History is bounded to the last MAX_RUNS.
#
# STEP dispatch (env-only inputs):
#   fetch-state  Read the existing sticky comment (by state marker) and write the
#                embedded {"runs":[...]} JSON to STATE_FILE ({"runs":[]} if none).
#   render       Append RUN_FILE (or a skip note), recompute cumulative, and
#                write the comment body to OUTPUT_FILE.
#
# Environment variables (fetch-state):
#   GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, STATE_FILE
#
# Environment variables (render):
#   STATE_FILE   Existing state JSON ({"runs":[...]}).
#   RUN_FILE     This run's object (omit when SKIP_REASON is set).
#   SKIP_REASON  no-key | fork | not-a-pr (render a skip note, do not append).
#   OUTPUT_FILE  Destination for the rendered comment body.
#   MAX_RUNS     Bounded history size (default 20).

set -euo pipefail

: "${STEP:=render}"

readonly AI_REVIEW_STATE_MARKER="<!-- lintro-ai-review-state:"

# Portable thousands grouping (BSD + GNU): 48210 -> 48,210
ai_review_commas() {
	awk -v n="${1:-0}" 'BEGIN {
		s = sprintf("%d", n); out = "";
		while (length(s) > 3) {
			out = "," substr(s, length(s) - 2) out;
			s = substr(s, 1, length(s) - 3);
		}
		print s out;
	}'
}

# Format a USD amount with two decimals (tiny nonzero -> <$0.01).
ai_review_cost() {
	awk -v c="${1:-0}" 'BEGIN {
		if (c > 0 && c < 0.005) { printf "<$0.01"; }
		else { printf "$%.2f", c; }
	}'
}

# -----------------------------------------------------------------------------
# STEP: fetch-state
# -----------------------------------------------------------------------------
if [[ "$STEP" == "fetch-state" ]]; then
	: "${STATE_FILE:?STATE_FILE is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"

	body=""
	if [[ -n "${GH_TOKEN:-}" ]]; then
		body="$(gh api \
			-H "Accept: application/vnd.github+json" \
			"/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
			2>/dev/null |
			jq -r --arg marker "$AI_REVIEW_STATE_MARKER" \
				'[.[] | select(.body | contains($marker))] | last | .body // ""' || echo "")"
	fi

	state='{"runs":[]}'
	if [[ -n "$body" && "$body" == *"$AI_REVIEW_STATE_MARKER"* ]]; then
		# Extract the JSON between the marker and the closing `-->`.
		candidate="${body#*"$AI_REVIEW_STATE_MARKER"}"
		candidate="${candidate%%-->*}"
		if printf '%s' "$candidate" | jq -e '.runs' >/dev/null 2>&1; then
			state="$(printf '%s' "$candidate" | jq -c '{runs: (.runs // [])}')"
		fi
	fi
	printf '%s\n' "$state" >"$STATE_FILE"
	echo "fetch-state: $(printf '%s' "$state" | jq '.runs | length') prior run(s)"
	exit 0
fi

# -----------------------------------------------------------------------------
# STEP: render
# -----------------------------------------------------------------------------
if [[ "$STEP" == "render" ]]; then
	: "${OUTPUT_FILE:?OUTPUT_FILE is required}"
	state_file="${STATE_FILE:-}"
	max_runs="${MAX_RUNS:-20}"

	existing='{"runs":[]}'
	if [[ -n "$state_file" && -f "$state_file" ]]; then
		if jq -e '.runs' "$state_file" >/dev/null 2>&1; then
			existing="$(jq -c '{runs: (.runs // [])}' "$state_file")"
		fi
	fi

	skip_reason="${SKIP_REASON:-}"

	if [[ -z "$skip_reason" ]]; then
		: "${RUN_FILE:?RUN_FILE is required when SKIP_REASON is unset}"
		run_obj="$(jq -c '.' "$RUN_FILE")"
		# Append this run and bound history to the last MAX_RUNS.
		new_state="$(jq -c --argjson run "$run_obj" --argjson max "$max_runs" \
			'.runs += [$run] | .runs |= (if length > $max then .[length-$max:] else . end)' \
			<<<"$existing")"
	else
		new_state="$existing"
	fi

	compact_state="$(jq -c '.' <<<"$new_state")"

	# --- Cumulative aggregates (ok runs contribute tokens/cost; errors add 0) ---
	read -r total_in total_out total_combined run_count < <(
		jq -r '
			[.runs[] | select(.status=="ok")] as $ok
			| [ ($ok | map(.input_tokens) | add // 0),
			    ($ok | map(.output_tokens) | add // 0),
			    ($ok | map(.total_tokens) | add // 0),
			    (.runs | length) ]
			| @tsv' <<<"$new_state"
	)
	total_cost="$(jq -r '[.runs[] | select(.status=="ok") | .cost_usd] | add // 0' <<<"$new_state")"
	models_str="$(jq -r '
		.runs | group_by(.model) | sort_by(-length)
		| map("`\(.[0].model) ×\(length)`") | join(", ")' <<<"$new_state")"
	[[ -n "$models_str" ]] || models_str="_none yet_"

	# --- Assemble body ----------------------------------------------------------
	{
		echo "## 🔎 Lintro AI Review"
		echo
		printf '**Cumulative (this PR):** %s tokens (%s in / %s out) · ~%s · %s runs · models: %s\n' \
			"$(ai_review_commas "$total_combined")" \
			"$(ai_review_commas "$total_in")" \
			"$(ai_review_commas "$total_out")" \
			"$(ai_review_cost "$total_cost")" \
			"$run_count" \
			"$models_str"
		echo
		echo "---"

		if [[ -n "$skip_reason" ]]; then
			case "$skip_reason" in
			no-key)
				echo "### Latest — ⚠️ skipped"
				echo
				echo "No \`ANTHROPIC_API_KEY\` is available to this run. Forward the lgtm-hq org secret (\`anthropic-api-key: \${{ secrets.ANTHROPIC_API_KEY }}\` or \`secrets: inherit\`) to enable AI review."
				;;
			fork)
				echo "### Latest — ℹ️ skipped (fork)"
				echo
				echo "AI review does not run on fork pull requests (no access to repository secrets)."
				;;
			*)
				echo "### Latest — ℹ️ skipped"
				echo
				echo "AI review was skipped for this event."
				;;
			esac
		else
			# Latest run header + findings + mechanics.
			latest_status="$(jq -r '.status' <<<"$run_obj")"
			if [[ "$latest_status" == "error" ]]; then
				err_msg="$(jq -r '.error' <<<"$run_obj")"
				case "$(jq -r '.error_kind' <<<"$run_obj")" in
				auth) echo "### Latest — ❌ Review skipped" ;;
				quota) echo "### Latest — ❌ No credits" ;;
				rate_limit) echo "### Latest — ⚠️ Rate limited" ;;
				*) echo "### Latest — ⚠️ Provider unavailable" ;;
				esac
				echo
				echo "$err_msg"
			else
				p1="$(jq -r '.p1' <<<"$run_obj")"
				p2="$(jq -r '.p2' <<<"$run_obj")"
				p3="$(jq -r '.p3' <<<"$run_obj")"
				echo "### Latest — 🔴 ${p1} · 🟠 ${p2} · 🟡 ${p3}"
				echo
				summary="$(jq -r '.summary // ""' <<<"$run_obj")"
				[[ -n "$summary" ]] && {
					echo "$summary"
					echo
				}
				if [[ "$(jq -r '.over_budget' <<<"$run_obj")" == "true" ]]; then
					echo "> ⚠️ This run's estimated cost exceeded the configured \`max-cost-usd\` cap."
					echo
				fi
				# Findings list (severity badge · file:line · title).
				jq -r '.findings[]? |
					(if .severity=="P1" then "🔴" elif .severity=="P2" then "🟠" else "🟡" end) as $b
					| "- \($b) **\(.title)** — `\(.file):\(.line)`" +
					  (if (.description // "") != "" then "\n  <sub>\(.description)</sub>" else "" end)' \
					<<<"$run_obj"
				echo
			fi

			# Per-run mechanics line.
			jq -r '"<sub>run: `\(.model)` · \(.total_tokens) tok " +
				"(\(.input_tokens) in / \(.output_tokens) out) · " +
				"~$\(.cost_usd) · depth \(.depth) · \(.duration_s)s</sub>"' <<<"$run_obj"
			echo
		fi

		# --- Previous runs (collapsible) ---
		prev_count="$(jq -r '.runs | length | (. - 1)' <<<"$new_state")"
		if [[ -z "$skip_reason" ]] && ((prev_count > 0)); then
			echo
			echo "<details><summary>⏱ Previous runs (${prev_count})</summary>"
			echo
			# All but the last run, most-recent first.
			jq -r '
				.runs[:-1] | reverse | .[] |
				(.sha[0:7] // "-------") as $sha
				| (.time // "") as $t
				| if .status=="error"
				  then "- `\($sha)` \($t) — `\(.model)` · ❌ error: \(.error_kind)"
				  else "- `\($sha)` \($t) — `\(.model)` · \(.total_tokens) tok · ~$\(.cost_usd) · 🔴\(.p1) 🟠\(.p2) 🟡\(.p3)"
				  end' <<<"$new_state"
			echo
			echo "</details>"
		fi

		echo
		echo "<sub>🤖 automated · not a substitute for human review</sub>"
		printf '%s %s -->\n' "$AI_REVIEW_STATE_MARKER" "$compact_state"
	} >"$OUTPUT_FILE"

	echo "render: wrote comment body ($(wc -c <"$OUTPUT_FILE") bytes; ${run_count} cumulative runs)"
	exit 0
fi

echo "render-ai-review-comment.sh: unknown STEP '$STEP'" >&2
exit 1
