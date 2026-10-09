#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-workflow tooling source identity (#995)
#
# Inside a called workflow the `github` context belongs to the caller, so
# `github.workflow_sha` names the consumer's commit and a tooling checkout
# that falls back to it asks lgtm-hq/lgtm-ci for a ref it does not have.
# Reusables must identify their own source through `job.workflow_sha` /
# `job.workflow_repository` (GitHub.com context properties for the workflow
# file that defines the current job), with `inputs.tooling-ref` as an
# explicit override only.

load "../../helpers/common"

WORKFLOWS="${PROJECT_ROOT}/.github/workflows"
ACTIONS="${PROJECT_ROOT}/.github/actions"

# Workflows whose tooling checkout is deliberately pinned by a required
# tooling-ref (no job.workflow_sha default). Keep this list short and justified.
EXPLICIT_PIN_ONLY=(
	# Recovery runs newer tooling against an older release on purpose; the
	# operator must choose the tooling commit (docs/release-recovery.md).
	"reusable-release-recover.yml"
	# Its plan and resume stages (#1081) keep the same explicit pin.
	"reusable-release-recover-plan.yml"
	"reusable-release-recover-resume.yml"
)

_is_explicit_pin_only() {
	local name="$1" w
	for w in "${EXPLICIT_PIN_ONLY[@]}"; do
		[[ "$name" == "$w" ]] && return 0
	done
	return 1
}

@test "tooling identity: no workflow derives a tooling ref from github.workflow_sha" {
	run grep -lE 'ref: \$\{\{[^}]*github\.workflow_sha' "$WORKFLOWS"/*.yml
	assert_failure
	run grep -lE 'WORKFLOW_SHA: \$\{\{ github\.workflow_sha \}\}' "$WORKFLOWS"/*.yml
	assert_failure
}

@test "tooling identity: no composite action derives a tooling ref from github.workflow_sha" {
	run grep -rlE 'github\.workflow_sha' "$ACTIONS" --include=action.yml
	assert_failure
}

@test "tooling identity: every .lgtm-ci-tooling checkout names job.workflow_repository" {
	# Each `path: .lgtm-ci-tooling` in a workflow must sit in a checkout whose
	# `repository:` is the called workflow's own repository, not a literal.
	local failures=0 f
	for f in "$WORKFLOWS"/*.yml; do
		while IFS= read -r line_no; do
			local start=$((line_no - 6)) end=$((line_no + 6))
			((start < 1)) && start=1
			if ! sed -n "${start},${end}p" "$f" |
				grep -qF "repository: \${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}"; then
				echo "${f##*/}:${line_no}: tooling checkout without job.workflow_repository" >&2
				failures=$((failures + 1))
			fi
		done < <(grep -n 'path: .lgtm-ci-tooling' "$f" | cut -d: -f1)
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: reusables default the tooling ref to job.workflow_sha" {
	local failures=0 f name
	for f in "$WORKFLOWS"/reusable-*.yml; do
		name="${f##*/}"
		grep -q 'path: .lgtm-ci-tooling' "$f" || continue
		_is_explicit_pin_only "$name" && continue
		# validate-lintro-version carries a second, deliberate fallback input.
		if ! grep -qF "inputs.tooling-ref || job.workflow_sha" "$f"; then
			echo "${name}: tooling checkout does not default to job.workflow_sha" >&2
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: explicit-pin-only workflows never use job.workflow_sha as a ref" {
	local w
	for w in "${EXPLICIT_PIN_ONLY[@]}"; do
		run grep -E '(github|job)\.workflow_sha \}\}' "$WORKFLOWS/$w"
		assert_failure
	done
}

@test "tooling identity: job context is never used at a nested reusable call site" {
	# `job` is unavailable in jobs.<id>.with; the nested reusable resolves its
	# own job.workflow_sha, so callers pass only the override through.
	local failures=0 f
	for f in "$WORKFLOWS"/*.yml; do
		if awk '
			/^    uses: \.\/\.github\/workflows\// { in_call = 1; next }
			in_call && /^  [a-z]/ { in_call = 0 }
			in_call && /^[[:space:]]*#/ { next }
			in_call && /job\.workflow_(sha|repository)/ { bad = 1 }
			END { exit !bad }
		' "$f"; then
			echo "${f##*/}: job.workflow_* inside a nested reusable call" >&2
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: every checkout-and-harden call passes the resolved ref, repository and override" {
	local failures=0 f
	for f in "$WORKFLOWS"/*.yml; do
		if awk '
			/uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/checkout-and-harden$/ { in_call = 1; ref = repo = ovr = 0; next }
			in_call && /^      - / { if (!(ref && repo && ovr)) bad = 1; in_call = 0 }
			in_call && /tooling-ref: \$\{\{ inputs\.tooling-ref != .. && inputs\.tooling-ref \|\| job\.workflow_sha \}\}/ { ref = 1 }
			in_call && /tooling-repository: \$\{\{ job\.workflow_repository \|\| .lgtm-hq\/lgtm-ci. \}\}/ { repo = 1 }
			in_call && /tooling-ref-override: \$\{\{ inputs\.tooling-ref \}\}/ { ovr = 1 }
			END { if (in_call && !(ref && repo && ovr)) bad = 1; exit !bad }
		' "$f"; then
			echo "${f##*/}: checkout-and-harden call missing resolved tooling inputs" >&2
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: every job.workflow_repository use falls back to lgtm-hq/lgtm-ci for GHES" {
	# job.workflow_* is GitHub.com only; on GHES the property is empty and an
	# empty repository input would make checkout default to the caller's repo.
	run grep -rlF 'job.workflow_repository }}' "$WORKFLOWS" "$ACTIONS"
	assert_failure
}

@test "tooling identity: every job.workflow_sha ref fallback ends in the loud sentinel" {
	# GHES has no job context; without the sentinel an empty ref makes
	# actions/checkout fetch the tooling default branch (unpinned tooling).
	run grep -rlE "^[[:space:]]+ref: \\$\\{\\{ inputs\\.tooling-ref != '' && inputs\\.tooling-ref \\|\\| job\\.workflow_sha \\}\\}" "$WORKFLOWS"
	assert_failure
	run grep -rlF "|| job.workflow_sha || 'tooling-ref-required' }}" "$WORKFLOWS"
	assert_success
}

@test "tooling identity: inline warn steps are guarded for tooling-refs that predate the script" {
	local failures=0 f
	for f in "$WORKFLOWS"/reusable-*.yml "$ACTIONS"/*/action.yml; do
		grep -q 'warn-tooling-ref-override.sh' "$f" || continue
		if ! grep -qF "hashFiles('.lgtm-ci-tooling/scripts/ci/actions/warn-tooling-ref-override.sh') != ''" "$f"; then
			echo "${f##*/}: warn step not guarded with hashFiles" >&2
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: reusables that skip checkout-and-harden warn on tooling-ref override" {
	local failures=0 f name
	for f in "$WORKFLOWS"/reusable-*.yml; do
		name="${f##*/}"
		grep -q 'path: .lgtm-ci-tooling' "$f" || continue
		_is_explicit_pin_only "$name" && continue
		[[ "$name" == "reusable-validate-lintro-version.yml" ]] && continue
		grep -q 'actions/checkout-and-harden' "$f" && continue
		if ! grep -qF 'warn-tooling-ref-override.sh' "$f"; then
			echo "${name}: no tooling-ref override warning step" >&2
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}

@test "tooling identity: lgtm-ci's own callers do not pin tooling-ref to github.sha" {
	run grep -lF 'tooling-ref: ${{ github.sha }}' "$WORKFLOWS"/*.yml
	assert_failure
}

@test "tooling identity: direct remote actions keep a literal repository and github.action_ref" {
	# prepare-pypi-upload is consumed as `uses: lgtm-hq/lgtm-ci/.github/actions/...@sha`
	# from the caller's own workflow; there job.workflow_* would be the caller.
	local action="${ACTIONS}/prepare-pypi-upload/action.yml"
	run grep -F 'repository: lgtm-hq/lgtm-ci' "$action"
	assert_success
	run grep -F 'github.action_ref' "$action"
	assert_success
	run grep -F 'job.workflow' "$action"
	assert_failure
}
