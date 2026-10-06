#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate `lintro review --post` for reusable-ai-review.yml.
#
# STEP dispatch (env-only inputs; never interpolate untrusted GitHub context):
#   preflight  Same-repo PR guard. Does not inspect credentials or invent a
#              provider — those are gated by resolve-ai-review-provider.sh.
#   locate     Find the newest completed run in THIS repo that uploaded a
#              lintro-review-state-pr-<N>-* artifact. Conclusion is
#              irrelevant (an INCOMPLETE red round is the resume source).
#              Empty run-id is a no-op, not a failure (#893).
#   run        Install pinned lintro[ai] from PyPI and run
#              `lintro review --pr --post`. Exit-code contract (lintro):
#                0  review produced, no P1 findings
#                1  review produced, P1 findings / changes-requested
#                2  no review produced (provider/lintro failure)
#              Coverage-at-HEAD below 100% is INCOMPLETE and always
#              reddens the check (lintro exit codes stay 0/1/2).
#              The call is bounded by GNU timeout to the cap's remainder; a
#              review the bound ended (124, or 137 after --kill-after) is
#              `timed-out` and neutral unless BLOCKING (#1098). A diff above
#              MAX_DIFF_LINES is `skipped-size` and never runs the model.
#              Both warn and post (update in place) a PR comment.
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
#   LINTRO_REVIEW_STATE_DIR  Coverage artifact directory (default:
#                            ai-review-state).
#   JOB_TIMEOUT_MINUTES      Job cap. The review is bounded to what remains
#                            of it from JOB_STARTED_AT minus a 240s margin,
#                            so the job — not the runner — owns the outcome.
#   JOB_STARTED_AT           Epoch from preflight's started-at output.
#   REVIEW_TIMEOUT_SECONDS   Test hook: explicit bound, skips the derivation.
#   REVIEW_KILL_AFTER_SECONDS  Test hook: timeout --kill-after (default 30).
#   MAX_DIFF_LINES           Skip the review when additions+deletions exceed
#                            this. 0 (default) disables the gate.
#
# Environment variables (locate):
#   GITHUB_REPOSITORY  owner/name of the *consuming* repo (provenance).
#   PR_NUMBER          Pull request number encoded in the artifact name.
#   GITHUB_RUN_ID      Current run; excluded so we never resume from self.
#   GH_TOKEN           Workflow token (needs actions: read).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"

: "${STEP:=run}"

# lintro review exit codes (lintro.ai.review.error_contract.REVIEW_ERROR_EXIT_CODE).
readonly REVIEW_STATUS_CLEAN=0
readonly REVIEW_STATUS_FINDINGS=1
readonly REVIEW_STATUS_ERROR=2
# GNU timeout: 124 after SIGTERM, 137 after --kill-after escalated to KILL.
readonly REVIEW_STATUS_TIMED_OUT=124
readonly REVIEW_STATUS_KILLED=137
# Seconds reserved out of the job cap. The anchor is preflight, which runs
# after harden-runner and the checkouts (~15s on the evidence run, #1097),
# so the margin must absorb those plus everything after the bound fires:
# kill-after grace (30s), up to four 20s gh calls, artifact upload, and
# post hooks (~110s worst case). 240s leaves ~2 minutes for slow checkouts.
readonly REVIEW_CAP_MARGIN_SECONDS=240
readonly REVIEW_NOTICE_MARKER="<!-- lintro-ai-review-incomplete -->"
# GNU timeout -v writes this to its own stderr when its deadline fires — the
# only evidence that distinguishes the wrapper's 124/137 from lintro's own.
# The wrapper's stderr is kept apart from lintro's (see the run step) so a
# partial lintro line cannot hide it and lintro cannot spoof it.
readonly REVIEW_TIMEOUT_EVIDENCE='timeout: sending signal [A-Z0-9]+ to command '
readonly REVIEW_DEFAULT_HINT="Split the PR, or re-run once it is smaller, to get a full review."

emit_output() {
	set_github_output "$1" "$2"
}

# gh with a short bound so a stuck API call cannot eat the cap margin.
bounded_gh() {
	command -v gh >/dev/null 2>&1 || return 1
	if command -v timeout >/dev/null 2>&1; then
		timeout 20 gh "$@"
	else
		gh "$@"
	fi
}

# additions+deletions for the PR via the workflow token; empty on failure
# (gh prints an error envelope on stdout for 404s, so validate the shape).
pr_diff_lines() {
	local lines
	lines="$(
		bounded_gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
			--jq '.additions + .deletions' 2>/dev/null || true
	)"
	[[ "$lines" =~ ^[0-9]+$ ]] && printf '%s\n' "$lines"
	return 0
}

# Warn, add a step-summary line, and post (or update in place) a best-effort
# PR comment as the bot (App token) so the author sees why no review landed.
# Never fails. $3 is "true" when the job is about to fail (blocking); $4
# replaces the default "split the PR" hint when size is not the cause.
notice_review_not_completed() {
	local reason="$1" diff_lines="${2:-}" failing="${3:-false}" hint="${4:-$REVIEW_DEFAULT_HINT}"
	local size="${diff_lines:+ (diff: ${diff_lines} lines)}"
	local effect="This check is neutral; required checks still gate the merge."
	if [[ "$failing" == "true" ]]; then
		effect="This check fails because the workflow runs with blocking: true."
	fi
	local body="AI review did not complete: ${reason}${size}. ${effect} ${hint}"
	echo "::warning::${body}"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		echo "> :warning: ${body}" >>"$GITHUB_STEP_SUMMARY"
	fi
	[[ -n "${GITHUB_TOKEN:-}" ]] || return 0
	local comments="repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"
	local comment_body="${REVIEW_NOTICE_MARKER}
:warning: ${body}"
	# Update in place only a comment the bot itself wrote: anyone can post
	# the marker, and a PATCH on their comment would 403. The endpoint is
	# oldest-first only (it ignores direction=), so page through under the
	# 20s bound; the filter runs per page and head keeps the first hit.
	local existing
	existing="$(
		GH_TOKEN="$GITHUB_TOKEN" MARKER="$REVIEW_NOTICE_MARKER" \
			bounded_gh api --paginate "${comments}?per_page=100" \
			--jq 'map(select(.user.type == "Bot" and (.body | startswith(env.MARKER)))) | .[0].id // empty' 2>/dev/null |
			head -n1 || true
	)"
	if [[ "$existing" =~ ^[0-9]+$ ]]; then
		GH_TOKEN="$GITHUB_TOKEN" bounded_gh api --method PATCH \
			"repos/${GITHUB_REPOSITORY}/issues/comments/${existing}" \
			-f body="$comment_body" >/dev/null 2>&1 && return 0
	fi
	GH_TOKEN="$GITHUB_TOKEN" bounded_gh api --method POST "$comments" \
		-f body="$comment_body" >/dev/null 2>&1 ||
		echo "::warning::could not post the not-completed comment on PR #${PR_NUMBER}"
}

# Record a not-completed outcome (lintro did not run, so exit-code is 0),
# notify, and exit per the blocking rule. Shared by the size gate and the
# no-budget path; a review that ran and timed out reports its real code.
conclude_not_completed() {
	local outcome="$1" reason="$2" diff_lines="${3:-}" blocking="${4:-false}" hint="${5:-}"
	emit_output "outcome" "$outcome"
	emit_output "exit-code" "0"
	emit_output "verdict" ""
	emit_output "error-kind" ""
	echo "ai-review: outcome=${outcome} ${reason} blocking=${blocking}"
	notice_review_not_completed "$reason" "$diff_lines" "$blocking" "${hint:-$REVIEW_DEFAULT_HINT}"
	if [[ "$blocking" == "true" ]]; then
		exit 1
	fi
	exit 0
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
	# Epoch anchor for the run step's review budget (#1098): the job cap
	# counts from job start, and the steps between here and the review
	# (CLI install, artifact download, lintro install) eat into it.
	emit_output "started-at" "$(date +%s)"
	echo "preflight: should-run=${should_run} skip-reason=${skip_reason:-<none>}"
	exit 0
fi

# -----------------------------------------------------------------------------
# STEP: locate
# -----------------------------------------------------------------------------
if [[ "$STEP" == "locate" ]]; then
	# Fail-safe: never redden the job. Empty run-id skips download.
	# Artifacts are listed on the consuming repo — not lgtm-ci — so
	# provenance is the caller's workflow run (#893). Newest completed
	# trusted run wins; conclusion is irrelevant.
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"
	run_id=""
	if command -v gh >/dev/null 2>&1; then
		current_run_id="${GITHUB_RUN_ID:-}"
		for _attempt in 1 2 3; do
			candidate_ids="$(
				PR_NUMBER="$PR_NUMBER" CURRENT_RUN_ID="$current_run_id" \
					gh api --paginate \
					"repos/${GITHUB_REPOSITORY}/actions/artifacts?per_page=100" \
					--jq '
						[.artifacts[]
						 | select(.expired|not)
						 | select(.name | test("^lintro-review-state-pr-" + env.PR_NUMBER + "-"))
						 | select(
								(env.CURRENT_RUN_ID | length) == 0
								or .workflow_run.id != (env.CURRENT_RUN_ID | tonumber)
							)
						| {id: .workflow_run.id, created_at}
						]
						| unique_by(.id)
						| sort_by(.created_at)
						| reverse
						| .[].id
					' 2>/dev/null || true
			)"
			if [[ -n "$candidate_ids" ]]; then
				while IFS= read -r cand; do
					[[ -z "$cand" ]] && continue
					status="$(
						gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${cand}" \
							--jq '.status' 2>/dev/null || true
					)"
					if [[ "$status" == "completed" ]]; then
						run_id="$cand"
						break
					fi
				done <<<"$candidate_ids"
			fi
			if [[ -n "$run_id" ]]; then
				break
			fi
			sleep 0.25
		done
	fi
	emit_output "run-id" "${run_id}"
	echo "locate: run-id=${run_id:-<none>}"
	exit 0
fi

# -----------------------------------------------------------------------------
# STEP: run
# -----------------------------------------------------------------------------
if [[ "$STEP" == "run" ]]; then
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"

	blocking="${BLOCKING:-false}"

	# Size gate before any install or spend: the model will not finish a
	# diff this large inside the bound anyway (#1098). Opt-in via input;
	# the blocking rule applies as for any other no-review outcome, so the
	# author cannot dodge a blocking review by inflating the diff.
	max_diff_lines="${MAX_DIFF_LINES:-0}"
	if [[ "$max_diff_lines" =~ ^[0-9]+$ && "$max_diff_lines" -gt 0 ]]; then
		diff_lines="$(pr_diff_lines)"
		if [[ ! "$diff_lines" =~ ^[0-9]+$ ]]; then
			echo "::notice::size gate: could not read the PR diff size; reviewing anyway"
		elif [[ "$diff_lines" -gt "$max_diff_lines" ]]; then
			conclude_not_completed "skipped-size" \
				"the diff exceeds max-diff-lines=${max_diff_lines}" "$diff_lines" "$blocking"
		fi
	fi

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

	# Resume coverage is read from (and written to) this directory. The
	# workflow downloads a prior run's artifact here and uploads it after.
	export LINTRO_REVIEW_STATE_DIR="${LINTRO_REVIEW_STATE_DIR:-ai-review-state}"
	mkdir -p "${LINTRO_REVIEW_STATE_DIR}"

	args=(review --pr "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --post --output json)

	out_file="$(mktemp)"
	err_file="$(mktemp)"
	wrap_file="$(mktemp)"
	trap 'rm -f "$out_file" "$err_file" "$wrap_file"' EXIT

	# Bounded below the job cap so the step — not the runner — ends a review
	# that will not finish, and this script maps the result (#1098). A job-
	# cap cancel records a failed check and flips the PR to UNSTABLE. The
	# budget is what remains of the cap measured from preflight's anchor
	# (the install above already spent some of it), minus a fixed margin.
	# REVIEW_TIMEOUT_SECONDS is a test hook that bypasses the derivation.
	review_timeout="${REVIEW_TIMEOUT_SECONDS:-}"
	bound_source="test hook"
	if [[ ! "$review_timeout" =~ ^[1-9][0-9]*$ ]]; then
		bound_source="job cap ${JOB_TIMEOUT_MINUTES:-30}m"
		job_minutes="${JOB_TIMEOUT_MINUTES:-30}"
		[[ "$job_minutes" =~ ^[0-9]+$ ]] || job_minutes=30
		now="$(date +%s)"
		started_at="${JOB_STARTED_AT:-}"
		[[ "$started_at" =~ ^[0-9]+$ ]] || started_at="$now"
		review_timeout=$((started_at + job_minutes * 60 - now - REVIEW_CAP_MARGIN_SECONDS))
		if [[ "$review_timeout" -lt 60 ]]; then
			# Not enough cap left to get anything useful: same neutral shape
			# as a review that ran and timed out, without burning spend.
			conclude_not_completed "timed-out" \
				"only ${review_timeout}s of the ${job_minutes}-minute job cap remained before the review could start" \
				"$(pr_diff_lines)" "$blocking" \
				"Re-run the job, or raise timeout-minutes if setup is routinely this slow."
		fi
	fi
	kill_after="${REVIEW_KILL_AFTER_SECONDS:-30}"
	[[ "$kill_after" =~ ^[0-9]+$ ]] || kill_after=30
	runner=()
	if command -v timeout >/dev/null 2>&1; then
		# -v: the "sending signal" diagnostic is the evidence the deadline
		# fired (lintro's own 124/137 would otherwise look identical). LC_ALL=C
		# pins its English text; the shim below restores lintro's own locale.
		runner=(env LC_ALL=C timeout -v --kill-after="$kill_after" "$review_timeout")
		echo "ai-review: review-timeout=${review_timeout}s (${bound_source})"
	else
		echo "::warning::GNU timeout not found; the review is bounded only by the job cap"
	fi

	set +e
	# lintro's stderr goes to err_file inside the exec'd child; what reaches
	# wrap_file is the wrapper's own stderr (the -v diagnostic). exec keeps
	# lintro as the wrapper's direct child, so the signal lands on it.
	# ${arr[@]+...}: an empty array is unbound under set -u on bash < 4.4.
	# shellcheck disable=SC2016 # the shim body expands inside the child bash
	LINTRO_ERR_FILE="$err_file" LINTRO_LC_ALL="${LC_ALL:-}" ${runner[@]+"${runner[@]}"} \
		bash -c 'if [[ -n "$LINTRO_LC_ALL" ]]; then export LC_ALL="$LINTRO_LC_ALL"; else unset LC_ALL; fi; exec "$@" 2>"$LINTRO_ERR_FILE"' \
		lintro-wrapper "$lintro_bin" "${args[@]}" \
		>"$out_file" 2>"$wrap_file"
	exit_code=$?
	set -e
	bound_fired=false
	if [[ ${#runner[@]} -gt 0 ]] && grep -Eq "$REVIEW_TIMEOUT_EVIDENCE" "$wrap_file"; then
		bound_fired=true
	fi

	# Combined log so the classifier and humans see the same stream.
	cat "$out_file"
	cat "$err_file" "$wrap_file" >&2

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
	elif [[ "$bound_fired" == "true" && ("$exit_code" -eq "$REVIEW_STATUS_TIMED_OUT" || "$exit_code" -eq "$REVIEW_STATUS_KILLED") ]]; then
		outcome="timed-out"
	else
		outcome="broken"
	fi

	# INCOMPLETE reddens the check even when blocking is false. lintro's
	# exit code stays 0/1 when a partial review was produced (#2154/#893).
	if [[ "$outcome" == "reviewed" || "$outcome" == "findings" ]]; then
		coverage_complete="$(jq -r '.coverage.complete' "$out_file" 2>/dev/null || true)"
		readiness="$(jq -r '.readiness_verdict // empty' "$out_file" 2>/dev/null || true)"
		if [[ "$coverage_complete" == "false" || "$readiness" == "incomplete" ]]; then
			outcome="incomplete"
			verdict="incomplete"
		fi
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
	elif [[ "$outcome" == "timed-out" ]]; then
		# Neutral by default: a review that ran out of time is a no-review,
		# not a defect, and must not gate the merge (#1098).
		notice_review_not_completed "the review step hit its ${review_timeout}s bound" \
			"$(pr_diff_lines)" "$blocking"
		if [[ "$blocking" == "true" ]]; then
			fail_job=true
		fi
	elif [[ "$outcome" == "incomplete" ]]; then
		covered="$(jq -r '.coverage.covered_at_head // empty' "$out_file" 2>/dev/null || true)"
		eligible="$(jq -r '.coverage.eligible // empty' "$out_file" 2>/dev/null || true)"
		echo "::error::lintro review incomplete (${covered:-?}/${eligible:-?} files covered at HEAD); next round resumes"
		fail_job=true
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
