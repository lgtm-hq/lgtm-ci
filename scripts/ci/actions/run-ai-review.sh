#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate `lintro review --post` for reusable-ai-review.yml.
#
# STEP dispatch (env-only inputs; never interpolate untrusted GitHub context):
#   preflight  Same-repo PR guard. Does not inspect credentials or invent a
#              provider — those are gated by resolve-ai-review-provider.sh.
#   run        Install pinned lintro[ai] from PyPI and run
#              `lintro review --pr --post`. Exit-code contract (lintro):
#                0  review produced, no P1 findings
#                1  review produced, P1 findings / changes-requested
#                2  no review produced (provider/lintro failure)
#
# Trusted-install invariant: this script only installs a *pinned lintro from
# PyPI* and runs `lintro review`, which reads the PR diff via the GitHub API
# and calls the model. It never installs or executes the PR's own code (no
# `uv sync`, no `pip install .`, no build hooks). Provider credentials and
# the App token are in scope only for this step.
#
# Override plumbing: inputs are mapped to LINTRO_AI_* by the workflow. This
# script does not resolve provider/transport and does not write a config
# fallback.
#
# Environment variables (preflight):
#   EVENT_NAME   GitHub event name (pull_request / pull_request_target).
#   HEAD_REPO    github.event.pull_request.head.repo.full_name (may be empty).
#   BASE_REPO    github.repository (owner/name).
#   PR_NUMBER    Pull request number.
#
# Environment variables (run):
#   LINTRO_VERSION     Pinned lintro version.
#   PYTHON_VERSION     CPython for the scratch venv (default: 3.12).
#   PR_NUMBER          Pull request number.
#   GITHUB_REPOSITORY  owner/name.
#   GH_TOKEN           Workflow token for `gh` / `lintro review --pr` fetch.
#   GITHUB_TOKEN       App token for `--post` (lintro-review[bot] only).
#   BLOCKING           "true" when a no-review or changes-requested outcome
#                      should fail the job.
#   VENV_DIR           Scratch venv (default: $RUNNER_TEMP/ai-review-venv).
#   LINTRO_BIN         Test hook: use this binary instead of installing.
#   LINTRO_AI_*        Pass-through overlays (set by the workflow).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"

: "${STEP:=run}"

# lintro review exit codes (lintro.ai.review.error_contract.REVIEW_ERROR_EXIT_CODE).
readonly REVIEW_STATUS_CLEAN=0
readonly REVIEW_STATUS_FINDINGS=1
readonly REVIEW_STATUS_ERROR=2

emit_output() {
	set_github_output "$1" "$2"
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

	if [[ "$should_run" == "true" && -z "${PR_NUMBER:-}" ]]; then
		should_run=false
		skip_reason="not-a-pr"
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
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"

	blocking="${BLOCKING:-false}"
	lintro_bin="${LINTRO_BIN:-}"
	if [[ -z "$lintro_bin" ]]; then
		: "${LINTRO_VERSION:?LINTRO_VERSION is required}"
		venv_dir="${VENV_DIR:-${RUNNER_TEMP:-/tmp}/ai-review-venv}"
		python_version="${PYTHON_VERSION:-3.12}"
		echo "Installing lintro[ai]==${LINTRO_VERSION} from PyPI (pinned, trusted)…"
		uv venv --python "$python_version" "$venv_dir" >/dev/null
		uv pip install --python "$venv_dir" "lintro[ai]==${LINTRO_VERSION}" >/dev/null
		lintro_bin="$venv_dir/bin/lintro"
	fi

	args=(review --pr "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --post --output json)

	out_file="$(mktemp)"
	err_file="$(mktemp)"
	trap 'rm -f "$out_file" "$err_file"' EXIT

	set +e
	"$lintro_bin" "${args[@]}" >"$out_file" 2>"$err_file"
	exit_code=$?
	set -e

	# Combined log so the classifier and humans see the same stream.
	cat "$out_file"
	cat "$err_file" >&2

	outcome="reviewed"
	verdict=""
	error_kind=""
	if [[ "$exit_code" -eq "$REVIEW_STATUS_ERROR" ]]; then
		outcome="no-review"
		error_kind="$(jq -r '.error.kind // empty' "$out_file" 2>/dev/null || true)"
	elif [[ "$exit_code" -eq "$REVIEW_STATUS_FINDINGS" ]]; then
		outcome="findings"
		verdict="$(jq -r '.verdict // .metadata.verdict // empty' "$out_file" 2>/dev/null || true)"
	elif [[ "$exit_code" -eq "$REVIEW_STATUS_CLEAN" ]]; then
		outcome="reviewed"
		verdict="$(jq -r '.verdict // .metadata.verdict // empty' "$out_file" 2>/dev/null || true)"
	else
		outcome="broken"
	fi

	emit_output "outcome" "$outcome"
	emit_output "exit-code" "$exit_code"
	emit_output "verdict" "$verdict"
	emit_output "error-kind" "$error_kind"

	echo "ai-review: outcome=${outcome} exit=${exit_code} verdict=${verdict:-<none>} error-kind=${error_kind:-<none>} blocking=${blocking}"

	fail_job=false
	if [[ "$outcome" == "broken" ]]; then
		echo "::error::lintro review exited ${exit_code} (unexpected; not the documented 0/1/2 contract)"
		fail_job=true
	elif [[ "$outcome" == "no-review" ]]; then
		echo "::warning::lintro review produced no review (exit 2${error_kind:+; kind=${error_kind}})"
		if [[ "$blocking" == "true" ]]; then
			fail_job=true
		fi
	elif [[ "$outcome" == "findings" ]]; then
		echo "::notice::lintro review produced findings (exit 1${verdict:+; verdict=${verdict}})"
		if [[ "$blocking" == "true" ]]; then
			# Changes-requested is the blocking signal. P1 findings (exit 1)
			# without an explicit verdict are treated as changes-requested.
			verdict_lc="$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')"
			if [[ -z "$verdict_lc" || "$verdict_lc" == "changes_requested" || "$verdict_lc" == "changes-requested" ]]; then
				fail_job=true
			fi
		fi
	fi

	if [[ "$fail_job" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

echo "run-ai-review.sh: unknown STEP '$STEP'" >&2
exit 1
