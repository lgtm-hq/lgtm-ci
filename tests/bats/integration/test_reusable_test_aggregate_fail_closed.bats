#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for fail-closed matrix aggregate jobs (#1058)
#
# Org rulesets require the `Aggregate … Results` context of the matrix test
# reusables directly. Exposing `passed=false` as a job output is not enough:
# the job itself must conclude `failure` when any matrix leg fails, and every
# job that `needs:` the aggregate must keep running (publishing the summary)
# when it does.

load "../../helpers/common"

WORKFLOWS_DIR="${PROJECT_ROOT}/.github/workflows"
FAIL_STEP_NAME="Fail if any matrix leg failed"

# Prints the body of a top-level job, with whole-line comments dropped so prose
# describing the contract can never satisfy an assertion about it.
_job_block() {
	local workflow="$1" job="$2"
	awk -v job="$job" '
		$0 == "  " job ":" { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:/ { exit }
		in_job && /^[[:space:]]*#/ { next }
		in_job { print }
	' "${WORKFLOWS_DIR}/${workflow}"
}

# Prints the job-level `if:` condition as one logical line, joining folded
# (`if: >-`) continuations.
_job_if() {
	_job_block "$1" "$2" | awk '
		/^    if: >-$/ { collecting = 1; next }
		/^    if: / { sub(/^    if: /, ""); print; exit }
		collecting && /^    [a-zA-Z0-9_-]+:/ { exit }
		collecting { sub(/^[[:space:]]+/, ""); expr = expr " " $0 }
		END { if (expr != "") print expr }
	'
}

# Prints the list of step names in a job, in order.
_step_names() {
	_job_block "$1" "$2" | awk '
		/^      - name: / { sub(/^      - name: /, ""); print }
	'
}

# Prints a single step (by name) from a job, with `if: >-` continuations joined
# onto one `if:` line.
_step_block() {
	_job_block "$1" "$2" | awk -v name="$3" '
		$0 == "      - name: " name { in_step = 1; print; next }
		in_step && /^      - / { exit }
		in_step && /^    [a-zA-Z0-9_-]+:/ { exit }
		in_step && /^        if: >-$/ { collecting = 1; next }
		in_step && collecting && /^        [a-zA-Z0-9_-]+:/ {
			print "        if:" expr
			collecting = 0
		}
		in_step && collecting { sub(/^[[:space:]]+/, ""); expr = expr " " $0; next }
		in_step { print }
		END { if (collecting) print "        if:" expr }
	'
}

# Prints the ids of every job whose `needs:` includes the given job.
_dependents_of() {
	awk -v dep="$2" '
		/^  [a-zA-Z0-9_-]+:$/ {
			job = $1
			sub(/:$/, "", job)
			in_needs = 0
			next
		}
		/^    needs:/ {
			line = $0
			sub(/^    needs:[[:space:]]*/, "", line)
			if (line == "") { in_needs = 1; next }
			gsub(/[][,]/, " ", line)
			n = split(line, parts, " ")
			for (i = 1; i <= n; i++) if (parts[i] == dep) print job
			next
		}
		in_needs && /^      - / {
			item = $0
			sub(/^      - /, "", item)
			if (item == dep) print job
			next
		}
		in_needs && !/^      - / { in_needs = 0 }
	' "${WORKFLOWS_DIR}/$1"
}

# Asserts the fail-closed contract for one reusable.
#   $1 workflow file, $2 aggregate job id, $3 upstream matrix job id
_assert_fail_closed() {
	local workflow="$1" agg="$2" upstream="$3"
	local block step names last expected_if

	block="$(_job_block "$workflow" "$agg")"
	[[ -n "$block" ]] || { fail "${workflow}: missing ${agg} job"; return 1; }

	step="$(_step_block "$workflow" "$agg" "$FAIL_STEP_NAME")"
	[[ -n "$step" ]] || { fail "${workflow}: ${agg} lacks '${FAIL_STEP_NAME}' step"; return 1; }

	grep -qF "needs.${upstream}.result != 'success'" <<<"$step" ||
		{ fail "${workflow}: fail step must check needs.${upstream}.result"; return 1; }
	grep -qF "steps.aggregate.outputs.passed != 'true'" <<<"$step" ||
		{ fail "${workflow}: fail step must check steps.aggregate.outputs.passed"; return 1; }
	# Pin the whole condition so the operator (`||`) and `always()` cannot drift:
	# with `&&`, a failed leg plus a passing summary would let the check pass.
	expected_if="always() && (needs.${upstream}.result != 'success' || steps.aggregate.outputs.passed != 'true')"
	grep -qxF "        if: ${expected_if}" <<<"$step" ||
		{ fail "${workflow}: fail step condition must be exactly: ${expected_if}"; return 1; }
	grep -qE '^[[:space:]]+exit 1$' <<<"$step" ||
		{ fail "${workflow}: fail step must exit 1"; return 1; }

	names="$(_step_names "$workflow" "$agg")"
	last="$(tail -n 1 <<<"$names")"
	[[ "$last" == "$FAIL_STEP_NAME" ]] ||
		{ fail "${workflow}: '${FAIL_STEP_NAME}' must be the last ${agg} step (got '${last}')"; return 1; }

	# `passed` output stays wired to both the matrix result and the summary.
	grep -qF "passed: \${{ needs.${upstream}.result == 'success' && steps.aggregate.outputs.passed == 'true' }}" \
		<<<"$block" ||
		{ fail "${workflow}: ${agg} passed output must AND needs.${upstream}.result with the aggregate verdict"; return 1; }
}

# Asserts every job that needs the aggregate still runs when it fails.
_assert_dependents_run_on_failure() {
	local workflow="$1" agg="$2"
	local dependents dep cond

	dependents="$(_dependents_of "$workflow" "$agg")"
	[[ -n "$dependents" ]] || { fail "${workflow}: expected at least one job to need ${agg}"; return 1; }

	while IFS= read -r dep; do
		cond="$(_job_if "$workflow" "$dep")"
		grep -qF 'always()' <<<"$cond" ||
			{ fail "${workflow}: ${dep} must run under always()"; return 1; }
		if grep -qF "needs.${agg}.result == 'success'" <<<"$cond"; then
			grep -qF "needs.${agg}.result == 'failure'" <<<"$cond" ||
				{ fail "${workflow}: ${dep} must also run when ${agg} fails"; return 1; }
		elif grep -qF "needs.${agg}.result" <<<"$cond"; then
			grep -qF "needs.${agg}.result != 'skipped'" <<<"$cond" ||
				{ fail "${workflow}: ${dep} gates on ${agg} in a way that may skip on failure"; return 1; }
			if grep -qF "needs.${agg}.result != 'failure'" <<<"$cond"; then
				fail "${workflow}: ${dep} excludes ${agg} failure from its gate"
				return 1
			fi
		fi
	done <<<"$dependents"
}

# Asserts the aggregate keeps the draft-PR skip so a skipped matrix never
# turns into a failed required check.
_assert_draft_skip_preserved() {
	local cond
	cond="$(_job_if "$1" "$2")"
	grep -qF 'always()' <<<"$cond" || { fail "$1: $2 must run under always()"; return 1; }
	grep -qF '!inputs.draft-pr-skip' <<<"$cond" ||
		{ fail "$1: $2 must keep the draft-pr-skip guard"; return 1; }
	grep -qF 'github.event.pull_request.draft == false' <<<"$cond" ||
		{ fail "$1: $2 must keep the draft PR guard"; return 1; }
}

# =============================================================================
# reusable-test-python.yml
# =============================================================================

@test "reusable-test-python: aggregate fails closed on matrix test failure" {
	_assert_fail_closed reusable-test-python.yml aggregate test
}

@test "reusable-test-python: jobs needing aggregate still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-python.yml aggregate
}

@test "reusable-test-python: aggregate keeps skip guards" {
	_assert_draft_skip_preserved reusable-test-python.yml aggregate
	run _job_if reusable-test-python.yml aggregate
	assert_output --partial '!inputs.pipeline-skip'
}

# =============================================================================
# reusable-rust-test.yml
# =============================================================================

@test "reusable-rust-test: aggregate fails closed on matrix test failure" {
	_assert_fail_closed reusable-rust-test.yml aggregate test
}

@test "reusable-rust-test: jobs needing aggregate still run when it fails" {
	_assert_dependents_run_on_failure reusable-rust-test.yml aggregate
}

@test "reusable-rust-test: aggregate keeps skip guards" {
	_assert_draft_skip_preserved reusable-rust-test.yml aggregate
}

# =============================================================================
# reusable-test-node.yml
# =============================================================================

@test "reusable-test-node: aggregate-tests fails closed on matrix test failure" {
	_assert_fail_closed reusable-test-node.yml aggregate-tests test-vitest
}

@test "reusable-test-node: jobs needing aggregate-tests still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-node.yml aggregate-tests
}

@test "reusable-test-node: aggregate-tests keeps skip guards" {
	_assert_draft_skip_preserved reusable-test-node.yml aggregate-tests
}

# =============================================================================
# reusable-test-node-custom.yml
# =============================================================================

@test "reusable-test-node-custom: aggregate-tests fails closed on matrix test failure" {
	_assert_fail_closed reusable-test-node-custom.yml aggregate-tests test
}

@test "reusable-test-node-custom: jobs needing aggregate-tests still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-node-custom.yml aggregate-tests
}

@test "reusable-test-node-custom: aggregate-tests keeps skip guards" {
	_assert_draft_skip_preserved reusable-test-node-custom.yml aggregate-tests
}

# =============================================================================
# Helper self-checks: the assertions must reject the pre-#1058 shape.
# =============================================================================

@test "aggregate fail-closed: contract rejects an aggregate without the fail step" {
	WORKFLOWS_DIR="$(mktemp -d)"
	awk -v name="$FAIL_STEP_NAME" '
		$0 == "      - name: " name { skip = 1; next }
		skip && /^  [a-zA-Z0-9_-]+:/ { skip = 0 }
		skip && /^      - / { skip = 0 }
		!skip { print }
	' "${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml" \
		>"${WORKFLOWS_DIR}/reusable-test-python.yml"
	run _assert_fail_closed reusable-test-python.yml aggregate test
	rm -rf "$WORKFLOWS_DIR"
	assert_failure
	assert_output --partial "lacks '${FAIL_STEP_NAME}' step"
}

@test "aggregate fail-closed: contract rejects publish gated on success-or-skipped only" {
	WORKFLOWS_DIR="$(mktemp -d)"
	grep -vF "needs.aggregate.result == 'failure'" \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml" \
		>"${WORKFLOWS_DIR}/reusable-test-python.yml"
	run _assert_dependents_run_on_failure reusable-test-python.yml aggregate
	rm -rf "$WORKFLOWS_DIR"
	assert_failure
	assert_output --partial "must also run when aggregate fails"
}

@test "aggregate fail-closed: contract rejects a fail step wired to the wrong upstream job" {
	WORKFLOWS_DIR="$(mktemp -d)"
	sed "s/needs\.test-vitest\.result != 'success'/needs.test.result != 'success'/" \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml" \
		>"${WORKFLOWS_DIR}/reusable-test-node.yml"
	run _assert_fail_closed reusable-test-node.yml aggregate-tests test-vitest
	rm -rf "$WORKFLOWS_DIR"
	assert_failure
	assert_output --partial "must check needs.test-vitest.result"
}

@test "aggregate fail-closed: contract rejects a fail step joined with && instead of ||" {
	WORKFLOWS_DIR="$(mktemp -d)"
	sed "s/!= 'success' || steps\.aggregate/!= 'success' \&\& steps.aggregate/" \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml" \
		>"${WORKFLOWS_DIR}/reusable-rust-test.yml"
	run _assert_fail_closed reusable-rust-test.yml aggregate test
	rm -rf "$WORKFLOWS_DIR"
	assert_failure
	assert_output --partial "fail step condition must be exactly"
}

@test "aggregate fail-closed: contract rejects a dependent that excludes aggregate failure" {
	WORKFLOWS_DIR="$(mktemp -d)"
	sed "s/&& needs\.aggregate-tests\.result != 'skipped'/& \&\& needs.aggregate-tests.result != 'failure'/" \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml" \
		>"${WORKFLOWS_DIR}/reusable-test-node.yml"
	run _assert_dependents_run_on_failure reusable-test-node.yml aggregate-tests
	rm -rf "$WORKFLOWS_DIR"
	assert_failure
	assert_output --partial "excludes aggregate-tests failure from its gate"
}
