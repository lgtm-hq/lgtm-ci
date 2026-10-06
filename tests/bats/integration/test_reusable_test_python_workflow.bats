#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the reusable-test-python workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml"
VALIDATOR="${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

# =============================================================================
# Aggregate job reachability (#756, #1058)
#
# The `aggregate` job runs for every non-skipped call so its required check
# fails closed (#1058), but its summary steps (download + aggregate) run only
# with a non-empty `python-versions`. `prepare` runs the compat/coverage
# contract validator, which rejects `coverage: true` alongside a non-empty
# `python-versions` (#345), so the matrix summary path never sees coverage.
# The single-version path gates on the test job result alone; coverage is
# verdicted inside the test job. So no step in `aggregate` is gated on
# `inputs.coverage`, and the job touches no coverage artifacts. That is what
# orphaned the old `Merge per-version coverage artifacts` step, which is why
# these assertions exist rather than a bare "the step is gone" check.
# =============================================================================

# Prints the body of a top-level job, with whole-line comments dropped so prose
# describing the contract can never satisfy an assertion about it.
_job_block() {
	awk -v job="$1" '
		$0 == "  " job ":" { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:/ { exit }
		in_job && /^[[:space:]]*#/ { next }
		in_job { print }
	' "$WORKFLOW"
}

# Prints every `if:` condition in a job as one logical line, joining folded
# (`if: >-`) continuations. Without this a multi-line condition hides from a
# line-at-a-time grep — which is exactly how a dead gate could slip back in.
_job_if_expressions() {
	_job_block "$1" | awk '
		function flush() {
			if (collecting) {
				print expr
				collecting = 0
			}
		}
		/^[[:space:]]*if:/ {
			flush()
			indent = match($0, /[^ ]/)
			expr = $0
			sub(/^[[:space:]]*if:[[:space:]]*/, "", expr)
			if (expr ~ /^[>|][-+]?[0-9]*$/) {
				expr = ""
			}
			collecting = 1
			next
		}
		collecting {
			if (match($0, /[^ ]/) > indent) {
				line = $0
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
				expr = expr " " line
				next
			}
			flush()
		}
		END { flush() }
	'
}

# Prints the shell commands a job actually executes (`run:` scalars and their
# folded continuations), so "is this script invoked?" cannot be satisfied by a
# comment or an `env:` value.
_job_run_commands() {
	_job_block "$1" | grep -E "^[[:space:]]*(run:|bash )"
}

@test "reusable-test-python: aggregate summary steps run only for a non-empty python-versions" {
	# Read off the `if:` expressions themselves, not any line that happens to
	# mention the input. The job-level gate must not require the input (#1058:
	# single-version calls still get a failing check); the download and
	# aggregate steps must, so the matrix-only path stays matrix-only.
	run _job_if_expressions aggregate
	assert_success
	[[ "${lines[0]}" == *"always()"* ]] || fail "aggregate job if must start with always()"
	[[ "${lines[0]}" != *"inputs.python-versions"* ]] ||
		fail "aggregate job must run for single-version calls too"
	# Structural: read each step's own step-level `if:` (any position within
	# the step, not a fixed line window after its name).
	local step cond
	for step in "Wait for and download matrix test summaries" "Aggregate matrix test summaries"; do
		cond="$(_job_block aggregate | awk -v name="$step" '
			$0 == "      - name: " name { in_step = 1; next }
			in_step && (/^      - / || /^    [a-zA-Z0-9_-]+:/) { exit }
			in_step && /^        if: / { sub(/^        if: /, ""); print; exit }
		')"
		[[ "$cond" == "inputs.python-versions != ''" ]] ||
			fail "step '${step}' must be gated on inputs.python-versions != '' (got: '${cond}')"
	done
}

@test "reusable-test-python: prepare runs the compat/coverage contract validator" {
	# Must be an executed `run:` step, not a mention in a comment or an env var.
	run _job_run_commands prepare
	assert_success
	assert_line --partial "validate-test-compat-coverage-contract.sh"
}

@test "reusable-test-python: the validator still rejects matrix plus coverage" {
	# Pins the premise the reachability rule rests on. Relaxing the validator
	# flips this test, forcing a deliberate review of what becomes reachable
	# in `aggregate` rather than silently re-enabling a dead path.
	run env \
		MULTI_VERSIONS="3.12,3.14" \
		COVERAGE="true" \
		PUBLISH_TEST_SUMMARY="false" \
		PLATFORM="Python" \
		bash "$VALIDATOR"
	assert_failure
	assert_output --partial "coverage: true"
}

@test "reusable-test-python: no aggregate step is gated on inputs.coverage" {
	# The reachability rule itself. Any such step would be dead code — the
	# combination that reaches it fails `prepare` first.
	run _job_if_expressions aggregate
	assert_success
	refute_output --partial "inputs.coverage"
}

@test "reusable-test-python: aggregate job touches no coverage artifacts" {
	# Broader than "no upload-artifact/merge": any coverage artifact handling
	# here — a merge action, a download, a hand-rolled script — would sit on the
	# same unreachable path, so the whole job must stay clear of the name.
	run _job_block aggregate
	assert_success
	refute_output --partial "python-coverage"
	refute_output --partial "upload-artifact/merge"
}

@test "reusable-test-python: the coverage upload uses the flat python-coverage name" {
	# Positive half: the name downstream consumers actually download
	# (reusable-test-python-publish.yml, py-lintro's Pages staging) is the
	# literal `python-coverage`, not a runtime-parameterised expression.
	run grep -Eq '^ +name: python-coverage$' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: no per-version coverage artifact name survives" {
	# Negative half: per-version coverage artifacts existed only to feed the
	# merge, and the compat/coverage contract meant they were never produced.
	run grep -n "python-coverage-" "$WORKFLOW"
	assert_failure
}

# The aggregate job polls the REST artifact listing before aggregating (#803),
# and GITHUB_TOKEN only reaches `GET /actions/runs/{id}/artifacts` with
# `actions: read`. A reusable workflow's permission request is validated
# statically, so this is a documented caller requirement; it must stay at
# `read` — `write` was the over-grant #730 removed, and nothing here mutates.
@test "reusable-test-python: aggregate job requests exactly actions: read" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /^ *actions: read$/ { found = 1 }
		in_aggregate && /^ *actions: write$/ { write = 1 }
		END { exit !(found && !write) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: aggregate waits for the matrix artifact count before aggregating" {
	# The wait step must precede aggregation, carry the token, and take its
	# expected count from the prepare job rather than a literal.
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /wait-for-artifacts\.sh/ { wait = NR }
		in_aggregate && /aggregate-results\.sh/ { agg = NR }
		in_aggregate && /GH_TOKEN: \$\{\{ github\.token \}\}/ { token = 1 }
		in_aggregate && /EXPECTED_COUNT: \$\{\{ needs\.prepare\.outputs\.matrix-count \}\}/ { count = 1 }
		in_aggregate && /MATRIX_KEY: python-version$/ { key = 1 }
		in_aggregate && /DOWNLOAD_DIR: python-results$/ { dir = 1 }
		in_aggregate && /\x27python-results-\*\x27/ { pattern = 1 }
		in_aggregate && /actions\/download-artifact@/ { dl = 1 }
		END { exit !(wait && agg && wait < agg && token && count && key && dir && pattern && !dl) }
	' "$WORKFLOW"
	assert_success
	run grep -F "matrix-count: \${{ steps.matrix.outputs.matrix-count }}" "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: artifact steps omit findBy so they use the runtime token" {
	# Whole-line comments are stripped first: the permissions block explains the
	# contract in prose, and that explanation must not satisfy its own
	# assertion. Only whole-line comments — stripping from every `#` would also
	# blank out quoted content and could hide a real `findBy`.
	run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -q "findBy"' _ "$WORKFLOW"
	assert_failure
}

@test "reusable-test-python: publish-test-summary maps pytest formats to comment semantics" {
	run awk '
		/^  publish-test-summary:/ {
			in_publish = 1
			in_cov = 0
			passthrough = 0
			has_coverage_py = 0
			has_cobertura = 0
			has_lcov = 0
		}
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_publish = 0 }
		in_publish && /coverage-format:/ { in_cov = 1 }
		in_publish && in_cov && /coverage-py/ { has_coverage_py = 1 }
		in_publish && in_cov && /cobertura/ { has_cobertura = 1 }
		in_publish && in_cov && /'\''lcov'\'' && '\''lcov'\''/ { has_lcov = 1 }
		in_publish && in_cov && /coverage-format: \$\{\{ inputs\.coverage-format \}\}/ { passthrough = 1 }
		END { exit !(has_coverage_py && has_cobertura && has_lcov && !passthrough) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: workflow outputs fall back when pipeline-skip is set" {
	run awk '
		/^jobs:/ { done = 1 }
		!done && /^    outputs:/ { in_outputs = 1 }
		!done && in_outputs && /^      [a-z-]+:/ { total++ }
		!done && in_outputs && /inputs\.pipeline-skip && '\''0'\'' \|\|/ { zero++ }
		!done && in_outputs && /inputs\.pipeline-skip && '\''true'\'' \|\|/ { green++ }
		END { exit !(total == 5 && zero == 4 && green == 1) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: passed output reports true when pipeline-skip is set" {
	run awk '
		/^      passed:/ { in_passed = 1 }
		in_passed && /inputs\.pipeline-skip && '\''true'\'' \|\|/ { found = 1 }
		in_passed && /^jobs:/ { exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: pipeline-skip guards prepare, test, aggregate, and summary jobs" {
	run awk '
		function job_if_has_pipeline_skip(job,    in_job, if_line, found) {
			in_job = 0
			found = 0
			while ((getline line < FILENAME) > 0) {
				if (line ~ "^  " job ":") {
					in_job = 1
					continue
				}
				if (in_job && line ~ /^  [a-zA-Z0-9_-]+:/) {
					break
				}
				if (in_job && line ~ /^    if:/) {
					if_line = line
					while ((getline line < FILENAME) > 0 && line ~ /^      /) {
						if_line = if_line line
					}
					if (if_line ~ /!inputs\.pipeline-skip &&/ ||
						if_line ~ /&&[ ]*!inputs\.pipeline-skip/) {
						found = 1
					}
					break
				}
			}
			close(FILENAME)
			return found
		}
		BEGIN {
			FILENAME = ARGV[1]
			if (!job_if_has_pipeline_skip("prepare") ||
				!job_if_has_pipeline_skip("test") ||
				!job_if_has_pipeline_skip("aggregate") ||
				!job_if_has_pipeline_skip("publish-test-summary")) {
				exit 1
			}
		}
	' "$WORKFLOW"
	assert_success
}
