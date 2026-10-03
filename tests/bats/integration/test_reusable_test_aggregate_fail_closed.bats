#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for fail-closed matrix aggregate jobs (#1058)
#
# Org rulesets require the `Aggregate … Results` context of the matrix test
# reusables directly, and GitHub treats a *skipped* required check as passing.
# So the aggregate job must conclude `failure` whenever the tests did not pass:
# a failed matrix leg, a failed or cancelled `prepare`, missing summaries, and
# the single-version path alike. It may only be skipped on the explicit
# legitimate-skip paths (draft PR with draft-pr-skip, pipeline-skip). Every job
# that `needs:` the aggregate must keep running (publishing the summary) when
# it fails.
#
# Conditions are checked by evaluating the parsed `if:` expressions against
# representative contexts (tests/helpers/gha_expr.py), not by token presence,
# so a condition that can never fire (`... && false`) cannot pass.

load "../../helpers/common"

WORKFLOWS_DIR="${PROJECT_ROOT}/.github/workflows"
EVAL="${PROJECT_ROOT}/tests/helpers/gha_expr.py"
FAIL_STEP_NAME="Fail if any matrix leg failed"
PREP_STEP_NAME="Fail if matrix preparation did not succeed"

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

# Prints a job output's expression as one logical line.
_job_output() {
	_job_block "$1" "$2" | awk -v key="$3" '
		/^    outputs:$/ { in_outputs = 1; next }
		in_outputs && /^    [a-zA-Z0-9_-]+:/ { exit }
		in_outputs && $0 ~ "^      " key ": >-$" { collecting = 1; next }
		in_outputs && $0 ~ "^      " key ": " {
			sub("^      " key ": ", "")
			print
			exit
		}
		collecting && /^      [a-zA-Z0-9_-]+:/ { exit }
		collecting && NF { sub(/^[[:space:]]+/, ""); expr = expr " " $0 }
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

# Prints a step's `if:` condition (empty when the step has none).
_step_if() {
	_step_block "$1" "$2" "$3" | sed -n 's/^        if:[[:space:]]*//p'
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

# Evaluates an expression; prints true/false. Bindings: KEY=STRING, KEY:=JSON.
_eval() {
	python3 "$EVAL" "$@"
}

# Per-reusable wiring: aggregate job, upstream matrix job, multi-version input
# (empty when the reusable has no single-version path), pipeline-skip support.
_wiring() {
	case "$1" in
	reusable-test-python.yml) echo "aggregate test python-versions yes" ;;
	reusable-rust-test.yml) echo "aggregate test rust-toolchains no" ;;
	reusable-test-node.yml) echo "aggregate-tests test-vitest - no" ;;
	reusable-test-node-custom.yml) echo "aggregate-tests test - no" ;;
	*) return 1 ;;
	esac
}

# Prints the all-green pull_request context for a reusable as bindings.
_base_ctx() {
	local agg upstream multi pskip
	read -r agg upstream multi pskip < <(_wiring "$1")
	printf '%s\n' \
		"github.event_name=pull_request" \
		"github.event.pull_request.draft:=false" \
		"github.event.pull_request.head.repo.fork:=false" \
		"inputs.draft-pr-skip:=true" \
		"inputs.pipeline-skip:=false" \
		"inputs.publish-test-summary:=true" \
		"needs.prepare.result=success" \
		"needs.${upstream}.result=success" \
		"steps.aggregate.outputs.passed=true" \
		"job.status=success"
	if [[ "$multi" != "-" ]]; then
		printf '%s\n' "inputs.${multi}=3.12,3.13"
	fi
}

# Simulates the aggregate job of a reusable in a scenario. Prints one line:
#   run=<bool> prep=<bool|-> fail=<bool|-> passed=<bool|->
# `prep`/`fail` are whether the prepare-guard / final fail step fire; `passed`
# is the job's `passed` output. Steps after a firing prepare guard are skipped,
# so the final step is evaluated with job.status=failure and no step outputs.
#   $1 workflow, $@ binding overrides
_simulate() {
	local workflow="$1"
	shift
	local agg upstream multi pskip line
	read -r agg upstream multi pskip < <(_wiring "$workflow")
	local -a ctx
	ctx=()
	while IFS= read -r line; do ctx+=("$line"); done < <(_base_ctx "$workflow")
	ctx+=("$@")

	local runs prep fail passed
	runs="$(_eval "$(_job_if "$workflow" "$agg")" "${ctx[@]}")"
	if [[ "$runs" != "true" ]]; then
		echo "run=false prep=- fail=- passed=-"
		return 0
	fi
	prep="$(_eval "$(_step_if "$workflow" "$agg" "$PREP_STEP_NAME")" "${ctx[@]}")"
	if [[ "$prep" == "true" ]]; then
		ctx+=("job.status=failure" "steps.aggregate.outputs.passed=")
	fi
	fail="$(_eval "$(_step_if "$workflow" "$agg" "$FAIL_STEP_NAME")" "${ctx[@]}")"
	# Job outputs are value expressions: no implicit success() wrapper.
	passed="$(_eval --value "$(_job_output "$workflow" "$agg" passed)" "${ctx[@]}")"
	echo "run=${runs} prep=${prep} fail=${fail} passed=${passed}"
}

# Asserts the structural fail-closed contract for one reusable.
_assert_fail_closed() {
	local workflow="$1"
	local agg upstream multi pskip
	read -r agg upstream multi pskip < <(_wiring "$workflow")
	local block step names last expected_if actual_if

	block="$(_job_block "$workflow" "$agg")"
	[[ -n "$block" ]] || { fail "${workflow}: missing ${agg} job"; return 1; }

	step="$(_step_block "$workflow" "$agg" "$FAIL_STEP_NAME")"
	[[ -n "$step" ]] || { fail "${workflow}: ${agg} lacks '${FAIL_STEP_NAME}' step"; return 1; }
	grep -qE '^[[:space:]]+exit 1$' <<<"$step" ||
		{ fail "${workflow}: fail step must exit 1"; return 1; }

	# Pin the whole condition (whitespace-insensitive) so `always()` and the
	# `||` cannot drift: with `&&`, a failed leg plus a passing summary would
	# let the check pass.
	if [[ "$multi" == "-" ]]; then
		expected_if="always() && (needs.${upstream}.result != 'success' || steps.aggregate.outputs.passed != 'true')"
	else
		expected_if="always() && (needs.${upstream}.result != 'success' || (inputs.${multi} != '' && steps.aggregate.outputs.passed != 'true'))"
	fi
	actual_if="$(_step_if "$workflow" "$agg" "$FAIL_STEP_NAME")"
	[[ "${actual_if//[[:space:]]/}" == "${expected_if//[[:space:]]/}" ]] ||
		{ fail "${workflow}: fail step condition must be exactly: ${expected_if} (got: ${actual_if})"; return 1; }

	names="$(_step_names "$workflow" "$agg")"
	last="$(tail -n 1 <<<"$names")"
	[[ "$last" == "$FAIL_STEP_NAME" ]] ||
		{ fail "${workflow}: '${FAIL_STEP_NAME}' must be the last ${agg} step (got '${last}')"; return 1; }

	# The prepare guard must come right after harden-runner, before any
	# checkout or artifact download, so a broken prepare fails fast.
	[[ "$(_step_if "$workflow" "$agg" "$PREP_STEP_NAME")" == "needs.prepare.result != 'success'" ]] ||
		{ fail "${workflow}: '${PREP_STEP_NAME}' must gate on needs.prepare.result != 'success'"; return 1; }
	[[ "$(sed -n 2p <<<"$names")" == "$PREP_STEP_NAME" ]] ||
		{ fail "${workflow}: '${PREP_STEP_NAME}' must directly follow Harden runner"; return 1; }
	grep -qE '^[[:space:]]+exit 1$' <<<"$(_step_block "$workflow" "$agg" "$PREP_STEP_NAME")" ||
		{ fail "${workflow}: prepare guard must exit 1"; return 1; }

	# The aggregate must not depend on prepare having succeeded to run at all.
	if grep -qF "needs.prepare.result == 'success'" <<<"$(_job_if "$workflow" "$agg")"; then
		fail "${workflow}: ${agg} must not be skipped when prepare fails"
		return 1
	fi
}

# Asserts a scenario's simulated outcome.
#   $1 workflow, $2 expected line, $@ binding overrides
_expect() {
	local workflow="$1" expected="$2"
	shift 2
	local actual
	actual="$(_simulate "$workflow" "$@")" || { fail "${workflow}: simulation failed"; return 1; }
	[[ "$actual" == "$expected" ]] ||
		{ fail "${workflow}: [$*] expected '${expected}', got '${actual}'"; return 1; }
}

# Runs the scenario matrix every reusable must satisfy.
_assert_scenarios() {
	local workflow="$1"
	local agg upstream multi pskip
	read -r agg upstream multi pskip < <(_wiring "$workflow")
	local up="needs.${upstream}.result"

	# All green: runs, nothing fires, passed.
	_expect "$workflow" "run=true prep=false fail=false passed=true" || return 1
	# A failed leg fails the check.
	_expect "$workflow" "run=true prep=false fail=true passed=false" \
		"${up}=failure" "steps.aggregate.outputs.passed=false" || return 1
	# A cancelled leg fails the check.
	_expect "$workflow" "run=true prep=false fail=true passed=false" \
		"${up}=cancelled" "steps.aggregate.outputs.passed=" || return 1
	# Lost or empty summaries (no aggregate verdict) fail the check.
	_expect "$workflow" "run=true prep=false fail=true passed=false" \
		"steps.aggregate.outputs.passed=" || return 1
	# Failed / cancelled prepare: the matrix is skipped, the check must fail.
	_expect "$workflow" "run=true prep=true fail=true passed=false" \
		"needs.prepare.result=failure" "${up}=skipped" || return 1
	_expect "$workflow" "run=true prep=true fail=true passed=false" \
		"needs.prepare.result=cancelled" "${up}=skipped" || return 1
	# Legitimate skip: draft PR with draft-pr-skip.
	_expect "$workflow" "run=false prep=- fail=- passed=-" \
		"github.event.pull_request.draft:=true" \
		"needs.prepare.result=skipped" "${up}=skipped" || return 1
	# Draft PR without draft-pr-skip still gates.
	_expect "$workflow" "run=true prep=false fail=true passed=false" \
		"github.event.pull_request.draft:=true" "inputs.draft-pr-skip:=false" \
		"${up}=failure" "steps.aggregate.outputs.passed=false" || return 1
	# Push events (no pull_request payload) gate.
	_expect "$workflow" "run=true prep=false fail=true passed=false" \
		"github.event_name=push" "github.event.pull_request.draft:=null" \
		"${up}=failure" "steps.aggregate.outputs.passed=false" || return 1
	_expect "$workflow" "run=true prep=false fail=false passed=true" \
		"github.event_name=push" "github.event.pull_request.draft:=null" || return 1

	if [[ "$pskip" == "yes" ]]; then
		_expect "$workflow" "run=false prep=- fail=- passed=-" \
			"inputs.pipeline-skip:=true" \
			"needs.prepare.result=skipped" "${up}=skipped" || return 1
	fi

	if [[ "$multi" != "-" ]]; then
		# Single-version calls: the summary steps are skipped (no verdict
		# output), so the test job result alone decides.
		_expect "$workflow" "run=true prep=false fail=false passed=true" \
			"inputs.${multi}=" "steps.aggregate.outputs.passed=" || return 1
		_expect "$workflow" "run=true prep=false fail=true passed=false" \
			"inputs.${multi}=" "steps.aggregate.outputs.passed=" "${up}=failure" || return 1
		_expect "$workflow" "run=true prep=true fail=true passed=false" \
			"inputs.${multi}=" "steps.aggregate.outputs.passed=" \
			"needs.prepare.result=failure" "${up}=skipped" || return 1
	fi
}

# Asserts every job that needs the aggregate still runs when it fails.
_assert_dependents_run_on_failure() {
	local workflow="$1"
	local agg upstream multi pskip
	read -r agg upstream multi pskip < <(_wiring "$workflow")
	local dependents dep cond result line
	local -a ctx

	dependents="$(_dependents_of "$workflow" "$agg")"
	[[ -n "$dependents" ]] || { fail "${workflow}: expected at least one job to need ${agg}"; return 1; }

	ctx=()
	while IFS= read -r line; do ctx+=("$line"); done < <(_base_ctx "$workflow")
	ctx+=("needs.${agg}.result=failure" "needs.${upstream}.result=failure")

	while IFS= read -r dep; do
		cond="$(_job_if "$workflow" "$dep")"
		result="$(_eval "$cond" "${ctx[@]}")" ||
			{ fail "${workflow}: cannot evaluate ${dep} condition: ${cond}"; return 1; }
		[[ "$result" == "true" ]] ||
			{ fail "${workflow}: ${dep} must also run when ${agg} fails"; return 1; }
	done <<<"$dependents"
}

# Simulates against a modified copy of a workflow; $2 is a sed script.
_with_mutated() {
	local workflow="$1" script="$2"
	shift 2
	local dir
	dir="$(mktemp -d)"
	sed "$script" "${PROJECT_ROOT}/.github/workflows/${workflow}" >"${dir}/${workflow}"
	WORKFLOWS_DIR="$dir" "$@"
	local rc=$?
	rm -rf "$dir"
	return "$rc"
}

# =============================================================================
# Per-reusable contract
# =============================================================================

@test "reusable-test-python: aggregate fails closed (structure)" {
	_assert_fail_closed reusable-test-python.yml
}

@test "reusable-test-python: aggregate fails closed (scenarios)" {
	_assert_scenarios reusable-test-python.yml
}

@test "reusable-test-python: jobs needing aggregate still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-python.yml
}

@test "reusable-rust-test: aggregate fails closed (structure)" {
	_assert_fail_closed reusable-rust-test.yml
}

@test "reusable-rust-test: aggregate fails closed (scenarios)" {
	_assert_scenarios reusable-rust-test.yml
}

@test "reusable-rust-test: jobs needing aggregate still run when it fails" {
	_assert_dependents_run_on_failure reusable-rust-test.yml
}

@test "reusable-rust-test: aggregate has no pipeline-skip guard (no such input)" {
	run grep -qE '^      pipeline-skip:' "${WORKFLOWS_DIR}/reusable-rust-test.yml"
	assert_failure
	run _job_if reusable-rust-test.yml aggregate
	refute_output --partial 'pipeline-skip'
}

@test "reusable-test-python: aggregate keeps its pipeline-skip guard" {
	run _job_if reusable-test-python.yml aggregate
	assert_output --partial '!inputs.pipeline-skip'
}

@test "reusable-test-node: aggregate-tests fails closed (structure)" {
	_assert_fail_closed reusable-test-node.yml
}

@test "reusable-test-node: aggregate-tests fails closed (scenarios)" {
	_assert_scenarios reusable-test-node.yml
}

@test "reusable-test-node: jobs needing aggregate-tests still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-node.yml
}

@test "reusable-test-node-custom: aggregate-tests fails closed (structure)" {
	_assert_fail_closed reusable-test-node-custom.yml
}

@test "reusable-test-node-custom: aggregate-tests fails closed (scenarios)" {
	_assert_scenarios reusable-test-node-custom.yml
}

@test "reusable-test-node-custom: jobs needing aggregate-tests still run when it fails" {
	_assert_dependents_run_on_failure reusable-test-node-custom.yml
}

@test "python/rust: single-version calls skip the summary download and aggregation" {
	local wf input step
	for wf in reusable-test-python.yml:python-versions reusable-rust-test.yml:rust-toolchains; do
		input="${wf#*:}"
		wf="${wf%%:*}"
		for step in "Download matrix test summaries" "Aggregate matrix test summaries"; do
			run _eval "$(_step_if "$wf" aggregate "$step")" "inputs.${input}=" "job.status=success"
			assert_output "false"
			run _eval "$(_step_if "$wf" aggregate "$step")" "inputs.${input}=1.0,2.0" "job.status=success"
			assert_output "true"
		done
	done
}

# =============================================================================
# Self-checks: the assertions must reject fail-open shapes.
# =============================================================================

@test "self-check: rejects an aggregate without the fail step" {
	run _with_mutated reusable-test-python.yml \
		"/- name: ${FAIL_STEP_NAME}/,\$d" \
		_assert_fail_closed reusable-test-python.yml
	assert_failure
	assert_output --partial "lacks '${FAIL_STEP_NAME}' step"
}

@test "self-check: rejects a fail step wired to the wrong upstream job" {
	run _with_mutated reusable-test-node.yml \
		"s/needs\.test-vitest\.result != 'success'/needs.test.result != 'success'/" \
		_assert_fail_closed reusable-test-node.yml
	assert_failure
	assert_output --partial "fail step condition must be exactly"
}

@test "self-check: rejects a fail step joined with && instead of ||" {
	run _with_mutated reusable-test-node-custom.yml \
		"s/!= 'success' || steps\.aggregate/!= 'success' \&\& steps.aggregate/" \
		_assert_fail_closed reusable-test-node-custom.yml
	assert_failure
	assert_output --partial "fail step condition must be exactly"
}

@test "self-check: rejects an aggregate skipped when prepare fails" {
	run _with_mutated reusable-rust-test.yml \
		"/^  aggregate:/,/^    runs-on:/ s/^      always()\$/      always() \&\& needs.prepare.result == 'success'/" \
		_assert_scenarios reusable-rust-test.yml
	assert_failure
	assert_output --partial "needs.prepare.result=failure"
}

@test "self-check: rejects an aggregate skipped for single-version calls" {
	run _with_mutated reusable-test-python.yml \
		"/^  aggregate:/,/^    runs-on:/ s/^      always()\$/      always() \&\& inputs.python-versions != ''/" \
		_assert_scenarios reusable-test-python.yml
	assert_failure
	assert_output --partial "inputs.python-versions="
}

@test "self-check: rejects a never-true aggregate condition" {
	run _with_mutated reusable-test-node.yml \
		"/^  aggregate-tests:/,/^    runs-on:/ s/^      always()\$/      always() \&\& false/" \
		_assert_scenarios reusable-test-node.yml
	assert_failure
	assert_output --partial "expected 'run=true"
}

@test "self-check: rejects publish gated on success-or-skipped only" {
	run _with_mutated reusable-test-python.yml \
		"/needs\.aggregate\.result == 'failure'/d" \
		_assert_dependents_run_on_failure reusable-test-python.yml
	assert_failure
	assert_output --partial "must also run when aggregate fails"
}

@test "self-check: rejects a dependent that excludes aggregate failure" {
	run _with_mutated reusable-test-node.yml \
		"s/&& needs\.aggregate-tests\.result != 'skipped'/& \&\& needs.aggregate-tests.result != 'failure'/" \
		_assert_dependents_run_on_failure reusable-test-node.yml
	assert_failure
	assert_output --partial "must also run when aggregate-tests fails"
}
