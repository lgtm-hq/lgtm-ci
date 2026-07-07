#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate `lintro review` for the reusable AI code-review workflow.
#
# STEP dispatch (env-only inputs; never interpolate untrusted GitHub context):
#   preflight  Decide whether the review should run (same-repo + key + PR guards).
#   run        Install pinned lintro[ai] from PyPI and run the review, emitting a
#              single-run state object with mechanics + sanitized findings.
#
# Trusted-install invariant: this script only installs a *pinned lintro from
# PyPI* and runs `lintro review`, which reads the PR diff via the GitHub API and
# calls the model. It never installs or executes the PR's own code (no
# `uv sync`, no `pip install .`, no build hooks), so ANTHROPIC_API_KEY is never
# in scope while PR-controlled code could execute.
#
# Environment variables (preflight):
#   EVENT_NAME   GitHub event name (pull_request / pull_request_target).
#   HEAD_REPO    github.event.pull_request.head.repo.full_name (may be empty).
#   BASE_REPO    github.repository (owner/name).
#   HAS_KEY      "true" when the anthropic-api-key secret is non-empty.
#   PR_NUMBER    Pull request number.
#
# Environment variables (run):
#   ANTHROPIC_API_KEY  Provider key (ONLY in scope for this step).
#   LINTRO_VERSION     Pinned lintro version (e.g. 0.65.0).
#   DEPTH              Review depth (clamped to 1..3).
#   STRICTNESS         focused | balanced | thorough.
#   MODEL              Optional model override (no default).
#   MAX_COST_USD       Advisory per-run cost cap (e.g. 0.50).
#   PATHS              Optional newline/comma/space-separated path prefixes.
#   PR_NUMBER          Pull request number.
#   HEAD_SHA           Head commit SHA (for the run record).
#   GITHUB_REPOSITORY  owner/name.
#   GH_TOKEN           GitHub token for `lintro review --pr`.
#   RUN_FILE           Output path for the single-run JSON object.
#   VENV_DIR           Directory for the scratch venv (default: $RUNNER_TEMP/ai-review-venv).
#   LINTRO_BIN         Test hook: use this binary instead of installing.

set -euo pipefail

: "${STEP:=run}"

# Maximum characters retained from any model-derived text field before it is
# embedded in the PR comment (prompt-injection surface bound).
readonly AI_REVIEW_TEXT_CAP="${AI_REVIEW_TEXT_CAP:-600}"
# Maximum number of findings rendered from a single run.
readonly AI_REVIEW_FINDINGS_CAP="${AI_REVIEW_FINDINGS_CAP:-30}"

# -----------------------------------------------------------------------------
# Sanitize a single untrusted (model-derived) string for safe Markdown embed:
#   - neutralize @mentions so the bot cannot ping users from injected text
#   - neutralize HTML comment delimiters so injected text cannot break out of
#     (or forge) the embedded state comment
#   - collapse newlines and cap length
# Reads stdin, writes sanitized text to stdout.
# -----------------------------------------------------------------------------
ai_review_sanitize() {
	local text
	text="$(cat)"
	# Neutralize HTML comment delimiters (state-marker breakout / forgery).
	text="${text//<!--/<!‑‑}"
	text="${text//-->/‑‑>}"
	# Collapse CR/LF to spaces so a finding stays on one logical line.
	text="${text//$'\r'/ }"
	text="${text//$'\n'/ }"
	# Neutralize @mentions: wrap `@name` in backticks (no notification, readable).
	# shellcheck disable=SC2016 # sed replacement is intentionally literal.
	text="$(printf '%s' "$text" | sed -E 's/@([A-Za-z0-9_][A-Za-z0-9_-]*)/`@\1`/g')"
	# Cap length.
	if ((${#text} > AI_REVIEW_TEXT_CAP)); then
		text="${text:0:AI_REVIEW_TEXT_CAP}…"
	fi
	printf '%s' "$text"
}

emit_output() {
	local key="$1" value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
	fi
}

# -----------------------------------------------------------------------------
# STEP: preflight
# -----------------------------------------------------------------------------
if [[ "$STEP" == "preflight" ]]; then
	should_run=true
	skip_reason=""

	case "${EVENT_NAME:-}" in
	pull_request | pull_request_target) ;;
	*)
		should_run=false
		skip_reason="not-a-pr"
		;;
	esac

	if [[ "$should_run" == "true" ]]; then
		head_repo="${HEAD_REPO:-}"
		if [[ -n "$head_repo" && "$head_repo" != "${BASE_REPO:-}" ]]; then
			should_run=false
			skip_reason="fork"
		fi
	fi

	if [[ "$should_run" == "true" && "${HAS_KEY:-false}" != "true" ]]; then
		should_run=false
		skip_reason="no-key"
	fi

	emit_output "should-run" "$should_run"
	emit_output "skip-reason" "$skip_reason"
	echo "preflight: should-run=${should_run} skip-reason=${skip_reason:-<none>}"
	exit 0
fi

# -----------------------------------------------------------------------------
# STEP: run
# -----------------------------------------------------------------------------
if [[ "$STEP" == "run" ]]; then
	: "${RUN_FILE:?RUN_FILE is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"

	depth="${DEPTH:-1}"
	if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
		depth=1
	fi
	if ((depth < 1)); then depth=1; fi
	if ((depth > 3)); then depth=3; fi

	strictness="${STRICTNESS:-balanced}"
	model="${MODEL:-}"
	max_cost="${MAX_COST_USD:-0.50}"
	head_sha="${HEAD_SHA:-}"

	# --- Resolve the lintro binary (install pinned lintro[ai] unless overridden) -
	lintro_bin="${LINTRO_BIN:-}"
	if [[ -z "$lintro_bin" ]]; then
		: "${LINTRO_VERSION:?LINTRO_VERSION is required}"
		venv_dir="${VENV_DIR:-${RUNNER_TEMP:-/tmp}/ai-review-venv}"
		echo "Installing lintro[ai]==${LINTRO_VERSION} from PyPI (pinned, trusted)…"
		uv venv "$venv_dir" >/dev/null
		uv pip install --python "$venv_dir" "lintro[ai]==${LINTRO_VERSION}" >/dev/null
		lintro_bin="$venv_dir/bin/lintro"
	fi

	# --- Force ai.enabled and optional model via a generated config -------------
	# Written into the disposable CI checkout only; merges with any existing
	# .lintro-config.yaml so consumer review settings are preserved.
	if [[ "${AI_REVIEW_SKIP_CONFIG:-false}" != "true" ]]; then
		config_python="${VENV_PYTHON:-${venv_dir:-}/bin/python}"
		[[ -x "$config_python" ]] || config_python="python3"
		AI_REVIEW_MODEL="$model" "$config_python" - <<'PY'
import os
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit(0)

path = Path(".lintro-config.yaml")
data = {}
if path.exists():
    loaded = yaml.safe_load(path.read_text()) or {}
    if isinstance(loaded, dict):
        data = loaded

ai = data.get("ai")
if not isinstance(ai, dict):
    ai = {}
ai["enabled"] = True
model = os.environ.get("AI_REVIEW_MODEL", "").strip()
if model:
    ai["model"] = model
data["ai"] = ai
path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
	fi

	# --- Build review arguments -------------------------------------------------
	args=(review --pr "$PR_NUMBER" --repo "$GITHUB_REPOSITORY"
		--depth "$depth" --strictness "$strictness" --output json)
	if [[ -n "${PATHS:-}" ]]; then
		# Split on newline, comma, or whitespace; pass each as a --path prefix.
		while IFS= read -r path_token; do
			[[ -n "$path_token" ]] && args+=(--path "$path_token")
		done < <(printf '%s' "$PATHS" | tr ',\r\n' '   ' | tr ' ' '\n')
	fi

	out_file="$(mktemp)"
	err_file="$(mktemp)"
	start_epoch="$(date +%s)"
	set +e
	ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" GH_TOKEN="${GH_TOKEN:-}" \
		"$lintro_bin" "${args[@]}" >"$out_file" 2>"$err_file"
	exit_code=$?
	set -e
	end_epoch="$(date +%s)"
	duration=$((end_epoch - start_epoch))

	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# --- Classify outcome -------------------------------------------------------
	# Success signal = valid review JSON on stdout (has .metadata). Exit code is
	# overloaded (1 == P1 findings OR provider error), so it is NOT the primary
	# signal. Provider-error subtype uses a narrow, documented interim heuristic
	# on the stable AIError message prefixes pending py-lintro's structured error
	# contract (lgtm-hq/py-lintro#1095).
	status="error"
	if jq -e '.metadata' "$out_file" >/dev/null 2>&1; then
		status="ok"
	fi

	if [[ "$status" == "ok" ]]; then
		model="$(jq -r '.metadata.model // "unknown"' "$out_file")"
		provider="$(jq -r '.metadata.provider // "unknown"' "$out_file")"
		in_tok="$(jq -r '.metadata.token_usage.prompt // 0' "$out_file")"
		out_tok="$(jq -r '.metadata.token_usage.completion // 0' "$out_file")"
		total_tok="$(jq -r '.metadata.token_usage.total // ((.metadata.token_usage.prompt // 0) + (.metadata.token_usage.completion // 0))' "$out_file")"
		cost="$(jq -r '.metadata.cost_estimate_usd // 0' "$out_file")"
		summary_raw="$(jq -r '.summary // ""' "$out_file")"
		summary="$(printf '%s' "$summary_raw" | ai_review_sanitize)"
		p1="$(jq -r '[.findings[]? | select(.severity=="P1")] | length' "$out_file")"
		p2="$(jq -r '[.findings[]? | select(.severity=="P2")] | length' "$out_file")"
		p3="$(jq -r '[.findings[]? | select(.severity=="P3")] | length' "$out_file")"

		# Sanitize each finding's untrusted text fields, cap the count.
		findings_json="$(jq -c --argjson cap "$AI_REVIEW_FINDINGS_CAP" \
			'[.findings[]? | {severity, category, file, line, title, description, cause, fix}] | .[:$cap]' \
			"$out_file")"
		sanitized_findings='[]'
		count="$(printf '%s' "$findings_json" | jq 'length')"
		for ((i = 0; i < count; i++)); do
			f="$(printf '%s' "$findings_json" | jq -c ".[$i]")"
			s_title="$(printf '%s' "$f" | jq -r '.title // ""' | ai_review_sanitize)"
			s_desc="$(printf '%s' "$f" | jq -r '.description // ""' | ai_review_sanitize)"
			s_file="$(printf '%s' "$f" | jq -r '.file // ""' | ai_review_sanitize)"
			s_cat="$(printf '%s' "$f" | jq -r '.category // ""' | ai_review_sanitize)"
			sev="$(printf '%s' "$f" | jq -r '.severity // "P3"')"
			line="$(printf '%s' "$f" | jq -r '.line // 0')"
			sanitized_findings="$(jq -c \
				--arg sev "$sev" --arg cat "$s_cat" --arg file "$s_file" \
				--argjson line "${line:-0}" --arg title "$s_title" --arg desc "$s_desc" \
				'. + [{severity:$sev, category:$cat, file:$file, line:$line, title:$title, description:$desc}]' \
				<<<"$sanitized_findings")"
		done

		over_budget=false
		if awk -v c="$cost" -v m="$max_cost" 'BEGIN{exit !(c+0 > m+0)}'; then
			over_budget=true
			echo "::warning::AI review run cost \$${cost} exceeds max-cost-usd \$${max_cost}"
		fi

		jq -n \
			--arg sha "$head_sha" --arg time "$timestamp" --arg model "$model" \
			--arg provider "$provider" --argjson in_tok "${in_tok:-0}" \
			--argjson out_tok "${out_tok:-0}" --argjson total_tok "${total_tok:-0}" \
			--argjson cost "${cost:-0}" --argjson depth "$depth" \
			--argjson duration "$duration" --argjson p1 "${p1:-0}" \
			--argjson p2 "${p2:-0}" --argjson p3 "${p3:-0}" \
			--arg summary "$summary" --argjson findings "$sanitized_findings" \
			--argjson over_budget "$over_budget" \
			'{sha:$sha, time:$time, model:$model, provider:$provider,
			  input_tokens:$in_tok, output_tokens:$out_tok, total_tokens:$total_tok,
			  cost_usd:$cost, depth:$depth, duration_s:$duration, status:"ok",
			  error_kind:"", error:"", p1:$p1, p2:$p2, p3:$p3,
			  summary:$summary, findings:$findings, over_budget:$over_budget}' \
			>"$RUN_FILE"
		emit_output "status" "ok"
		echo "AI review ok: model=${model} tokens=${total_tok} cost=\$${cost} P1=${p1} P2=${p2} P3=${p3}"
		exit 0
	fi

	# --- Error path: classify subtype (interim heuristic) -----------------------
	err_text="$(tr '[:upper:]' '[:lower:]' <"$err_file")"
	error_kind="transient"
	error_msg="Provider unavailable (5xx/timeout) — transient, will retry next run."
	if grep -Eq 'authentication|invalid.*key|401|unauthorized' <<<"$err_text"; then
		error_kind="auth"
		error_msg="Anthropic API returned 401 (invalid or missing API key). Check the ANTHROPIC_API_KEY secret."
	elif grep -Eq 'insufficient|credit|quota|402|billing' <<<"$err_text"; then
		error_kind="quota"
		error_msg="No credits — the Anthropic account has insufficient credits."
	elif grep -Eq 'rate.?limit|429|too many requests' <<<"$err_text"; then
		error_kind="rate_limit"
		error_msg="Rate limited (429) — try again shortly."
	fi

	# Record the effective model even on error (org-configured or override) so the
	# per-model cumulative counts stay complete.
	err_model="${model:-unknown}"
	[[ -n "$err_model" ]] || err_model="unknown"

	jq -n \
		--arg sha "$head_sha" --arg time "$timestamp" --arg model "$err_model" \
		--argjson depth "$depth" --argjson duration "$duration" \
		--arg error_kind "$error_kind" --arg error "$error_msg" \
		'{sha:$sha, time:$time, model:$model, provider:"anthropic",
		  input_tokens:0, output_tokens:0, total_tokens:0, cost_usd:0,
		  depth:$depth, duration_s:$duration, status:"error",
		  error_kind:$error_kind, error:$error, p1:0, p2:0, p3:0,
		  summary:"", findings:[], over_budget:false}' \
		>"$RUN_FILE"
	emit_output "status" "error"
	echo "::warning::AI review error (${error_kind}): ${error_msg}"
	echo "lintro exit=${exit_code}; stderr head:"
	head -c 500 "$err_file" || true
	exit 0
fi

echo "run-ai-review.sh: unknown STEP '$STEP'" >&2
exit 1
