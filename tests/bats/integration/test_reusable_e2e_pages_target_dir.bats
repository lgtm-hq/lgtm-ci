#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-e2e-matrix's Pages deploy path (#754)
#
# #739/PR #752 namespaced this workflow's *artifacts*. The publish job still
# deployed to a hardcoded `target-dir: playwright`, so two calls in one run that
# both set `publish-results: true` wrote to the same Pages directory and the
# second overwrote the first. `pages-target-dir` closes that half.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
TARGET_DIR_VALIDATOR="${PROJECT_ROOT}/scripts/ci/actions/validate-pages-target-dir.sh"

# Raw value of `key` under the `with:` block of the named step, read out of the
# real YAML so these assertions cannot drift from the workflow.
#
# Fails loudly when the step or key is absent: returning an empty string with
# status 0 would let the comparisons below pass vacuously against '' == '' the
# moment a step is renamed or its indentation drifts.
_publish_with_value() {
	local step_name="$1" with_key="$2" value
	value="$(awk -v step="      - name: ${step_name}" -v key="          ${with_key}: " '
		$0 == step { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && index($0, key) == 1 { print substr($0, length(key) + 1); exit }
	' "$WORKFLOW")"
	if [[ -z "$value" ]]; then
		echo "no '${with_key}:' under step '${step_name}' in ${WORKFLOW}" >&2
		return 1
	fi
	printf '%s' "$value"
}

_render_target_dir() {
	local template="$1" value="$2"
	printf '%s' "${template//'${{ inputs.pages-target-dir }}'/$value}"
}

@test "reusable-test-e2e-matrix: pages-target-dir defaults to playwright" {
	run awk '/^      pages-target-dir:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "playwright"'
	assert_output --partial "type: string"
	assert_output --partial "required: false"
}

# A caller passing nothing must deploy to exactly today's path. This is a
# backwards-compatible input addition, not a change of the published URL.
@test "reusable-test-e2e-matrix: the default deploys to today's Pages path" {
	local rendered
	rendered="$(_render_target_dir \
		"$(_publish_with_value "Publish to GitHub Pages" target-dir)" playwright)"

	[ "$rendered" = "playwright" ] || {
		echo "published Pages path changed: ${rendered}" >&2
		return 1
	}
}

@test "reusable-test-e2e-matrix: the publish target-dir is built from the input" {
	local template
	template="$(_publish_with_value "Publish to GitHub Pages" target-dir)"

	[ "$template" = '${{ inputs.pages-target-dir }}' ] || {
		echo "publish target-dir is not the input verbatim: ${template}" >&2
		return 1
	}
}

# The hardcoded value must be gone, not merely shadowed: a surviving literal
# `target-dir: playwright` anywhere in this workflow would silently keep one
# call pinned to the shared directory.
@test "reusable-test-e2e-matrix: no hardcoded target-dir survives" {
	run grep -nE '^\s*target-dir:\s*[^$[:space:]]' "$WORKFLOW"
	assert_failure
}

# The whole point of the input: two calls given distinct values must land in
# distinct Pages directories, with neither a prefix of the other's tree.
@test "reusable-test-e2e-matrix: distinct values deploy to distinct paths" {
	local template a b
	template="$(_publish_with_value "Publish to GitHub Pages" target-dir)"
	a="$(_render_target_dir "$template" playwright)"
	b="$(_render_target_dir "$template" e2e-nightly)"

	[ "$a" != "$b" ] || {
		echo "distinct pages-target-dir values produced the same path: ${a}" >&2
		return 1
	}
	case "$b" in
	"${a}"/*)
		echo "${b} is nested inside ${a}" >&2
		return 1
		;;
	esac
	case "$a" in
	"${b}"/*)
		echo "${a} is nested inside ${b}" >&2
		return 1
		;;
	esac
}

# `pages-target-dir` must stay a separate input, not an alias of
# `artifact-prefix`: the Pages path is URL-visible and deriving it would move a
# caller's published URL the moment they set a prefix for artifact reasons.
@test "reusable-test-e2e-matrix: artifact-prefix alone does not move the Pages path" {
	local template rendered
	template="$(_publish_with_value "Publish to GitHub Pages" target-dir)"
	# A caller that namespaces artifacts only, leaving pages-target-dir at its
	# default: substituting artifact-prefix must be a no-op on the deploy path.
	rendered="${template//'${{ inputs.artifact-prefix }}'/e2e_nightly}"
	rendered="$(_render_target_dir "$rendered" playwright)"

	[ "$rendered" = "playwright" ] || {
		echo "setting artifact-prefix moved the Pages path to: ${rendered}" >&2
		return 1
	}
}

# The value is interpolated into a deploy destination, so it must be validated
# before anything runs — and in the job every other job depends on.
@test "reusable-test-e2e-matrix: the setup job validates pages-target-dir" {
	# Both facts must hold for the *same* step: tracked independently, a
	# validator step with no env plus an unrelated step carrying the env would
	# satisfy the assertion while the script ran with an empty value.
	run awk '
		/^  setup:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  setup:$/ { exit }
		in_job && /^      - name: / { step_script = 0; step_wired = 0 }
		in_job && /validate-pages-target-dir\.sh$/ { step_script = 1 }
		in_job && /PAGES_TARGET_DIR: \$\{\{ inputs\.pages-target-dir \}\}$/ { step_wired = 1 }
		step_script && step_wired { ok = 1 }
		END { exit !ok }
	' "$WORKFLOW"
	assert_success
}

# A rejected value must never reach the deploy. `publish` requires a successful
# `merge`, and `merge` requires a successful `setup`, so a validation failure
# transitively blocks the Pages write rather than deploying the rejected path.
@test "reusable-test-e2e-matrix: a rejected value cannot reach the deploy" {
	run awk '
		/^  merge:$/ { job = "merge" }
		/^  publish:$/ { job = "publish" }
		job == "merge" && /^    if: / && /needs\.setup\.result == .success./ { merge_gated = 1 }
		job == "publish" && /^    needs: merge$/ { publish_needs_merge = 1 }
		job == "publish" && /^    if: / && /needs\.merge\.result == .success./ { publish_gated = 1 }
		END { exit !(merge_gated && publish_needs_merge && publish_gated) }
	' "$WORKFLOW"
	assert_success
}

# The validator is the security control behind the deploy path; the workflow
# default and the traversal/absolute rejections are asserted here against the
# real script so the wiring above is not vacuous.
@test "reusable-test-e2e-matrix: the validator accepts the default and rejects escapes" {
	run env PAGES_TARGET_DIR="playwright" bash "$TARGET_DIR_VALIDATOR"
	assert_success

	run env PAGES_TARGET_DIR="../../etc" bash "$TARGET_DIR_VALIDATOR"
	assert_failure

	run env PAGES_TARGET_DIR="/etc/playwright" bash "$TARGET_DIR_VALIDATOR"
	assert_failure
}

@test "reusable-test-e2e-matrix: docs document pages-target-dir" {
	run grep -q "pages-target-dir" "${PROJECT_ROOT}/docs/workflows/testing.md"
	assert_success
}
