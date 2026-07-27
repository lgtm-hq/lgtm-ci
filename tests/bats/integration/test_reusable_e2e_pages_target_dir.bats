#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the Pages deploy path of the report publisher
#          (#754, carried through the #770 split)
#
# #739/PR #752 namespaced reusable-test-e2e-matrix's *artifacts*. Its publish
# job still deployed to a hardcoded `target-dir: playwright`, so two calls in
# one run that both published wrote to the same Pages directory and the second
# overwrote the first. `pages-target-dir` closed that half.
#
# #770 then moved the publish job into reusable-publish-test-results-pages.yml,
# so the deploy path these tests describe now lives there — input name,
# validator and all. The assertions follow the behaviour rather than the file:
# the same facts must hold, on whichever workflow performs the deploy. The last
# two additionally pin that the deprecated input left behind on the matrix
# workflow is genuinely inert.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-test-results-pages.yml"
E2E_MATRIX="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
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

# Required, not defaulted: the Pages directory is URL-visible, so a default
# would silently publish a half-migrated caller's report over the site root.
@test "publisher: pages-target-dir is a required string input" {
	run awk '/^      pages-target-dir:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "type: string"
	assert_output --partial "required: true"
	refute_output --partial "default:"
}

# A caller migrating off reusable-test-e2e-matrix passes the pages-target-dir it
# used to pass there and must land on exactly the same published path.
@test "publisher: passing playwright deploys to the pre-split Pages path" {
	local rendered
	rendered="$(_render_target_dir \
		"$(_publish_with_value "Publish to GitHub Pages" target-dir)" playwright)"

	[ "$rendered" = "playwright" ] || {
		echo "published Pages path changed: ${rendered}" >&2
		return 1
	}
}

# Likewise for the coverage producer, whose publish job hardcoded `coverage`.
@test "publisher: passing coverage deploys to the pre-split coverage path" {
	local rendered
	rendered="$(_render_target_dir \
		"$(_publish_with_value "Publish to GitHub Pages" target-dir)" coverage)"

	[ "$rendered" = "coverage" ] || {
		echo "published coverage path changed: ${rendered}" >&2
		return 1
	}
}

@test "publisher: the publish target-dir is built from the input" {
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
@test "publisher: no hardcoded target-dir survives" {
	run grep -nE '^\s*target-dir:\s*[^$[:space:]]' "$WORKFLOW"
	assert_failure
}

# The whole point of the input: two calls given distinct values must land in
# distinct Pages directories, with neither a prefix of the other's tree.
@test "publisher: distinct values deploy to distinct paths" {
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

# `pages-target-dir` must stay a separate input, not an alias of the artifact
# name: the Pages path is URL-visible and deriving it would move a caller's
# published URL the moment they renamed an artifact for artifact reasons.
@test "publisher: artifact-name alone does not move the Pages path" {
	local template rendered
	template="$(_publish_with_value "Publish to GitHub Pages" target-dir)"
	rendered="${template//'${{ inputs.artifact-name }}'/e2e-nightly-merged-report}"
	rendered="$(_render_target_dir "$rendered" playwright)"

	[ "$rendered" = "playwright" ] || {
		echo "setting artifact-name moved the Pages path to: ${rendered}" >&2
		return 1
	}
}

# The value is interpolated into a deploy destination, so it must be validated
# before anything is downloaded or staged.
@test "publisher: the publish job validates pages-target-dir" {
	# Both facts must hold for the *same* step: tracked independently, a
	# validator step with no env plus an unrelated step carrying the env would
	# satisfy the assertion while the script ran with an empty value.
	run awk '
		/^  publish:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  publish:$/ { exit }
		in_job && /^      - name: / { step_script = 0; step_wired = 0 }
		in_job && /validate-pages-target-dir\.sh$/ { step_script = 1 }
		in_job && /PAGES_TARGET_DIR: \$\{\{ inputs\.pages-target-dir \}\}$/ { step_wired = 1 }
		step_script && step_wired { ok = 1 }
		END { exit !ok }
	' "$WORKFLOW"
	assert_success
}

# A rejected value must never reach the deploy. The split removed the
# setup -> merge -> publish gate chain that used to provide this, so the
# ordering inside the publish job is now what enforces it: the validator step
# must come before the download and the deploy, and a failing step aborts the
# job. Asserted on step order, not on presence, so moving the validator below
# the deploy fails here.
@test "publisher: validation precedes the download and the deploy" {
	run awk '
		/^  publish:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  publish:$/ { exit }
		in_job && /^      - name: / { n += 1 }
		in_job && /^      - name: Validate Pages target dir$/ { validate = n }
		in_job && /^      - name: Download report artifact$/ { download = n }
		in_job && /^      - name: Publish to GitHub Pages$/ { deploy = n }
		END { exit !(validate && download && deploy && validate < download && download < deploy) }
	' "$WORKFLOW"
	assert_success
	# No continue-on-error would let a rejected value sail past the validator.
	run grep -q 'continue-on-error' "$WORKFLOW"
	assert_failure
}

# The input left behind on the matrix workflow must be genuinely inert: still
# accepted, since an unknown input to a reusable workflow is a hard
# startup_failure, but read by nothing except the deprecation warning.
@test "reusable-test-e2e-matrix: pages-target-dir is accepted but inert" {
	run awk '/^      pages-target-dir:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$E2E_MATRIX"
	assert_success
	assert_output --partial "DEPRECATED"

	run grep -c 'inputs\.pages-target-dir' "$E2E_MATRIX"
	assert_success
	[ "$output" -eq 1 ]
	run grep -q 'INPUT_VALUE: ${{ inputs.pages-target-dir }}' "$E2E_MATRIX"
	assert_success
}

@test "reusable-test-e2e-matrix: setting a deprecated publish input warns" {
	local input
	for input in publish-results pages-target-dir publish-egress-preset \
		publish-allowed-endpoints; do
		run awk -v name="          INPUT_NAME: ${input}" '
			$0 == name { found = 1 }
			END { exit !found }
		' "$E2E_MATRIX"
		assert_success
	done
	run grep -q 'warn-deprecated-workflow-input.sh' "$E2E_MATRIX"
	assert_success
}

# The validator is the security control behind the deploy path; the workflow
# default and the traversal/absolute rejections are asserted here against the
# real script so the wiring above is not vacuous.
@test "publisher: the validator accepts the migrated values and rejects escapes" {
	run env PAGES_TARGET_DIR="playwright" bash "$TARGET_DIR_VALIDATOR"
	assert_success

	run env PAGES_TARGET_DIR="coverage" bash "$TARGET_DIR_VALIDATOR"
	assert_success

	run env PAGES_TARGET_DIR="../../etc" bash "$TARGET_DIR_VALIDATOR"
	assert_failure

	run env PAGES_TARGET_DIR="/etc/playwright" bash "$TARGET_DIR_VALIDATOR"
	assert_failure
}

@test "docs document pages-target-dir and where it moved" {
	run grep -q "pages-target-dir" "${PROJECT_ROOT}/docs/workflows/testing.md"
	assert_success
	run grep -q "pages-target-dir" "${PROJECT_ROOT}/docs/pages-publishing.md"
	assert_success
	run grep -q "reusable-publish-test-results-pages" \
		"${PROJECT_ROOT}/docs/workflows/testing.md"
	assert_success
}
