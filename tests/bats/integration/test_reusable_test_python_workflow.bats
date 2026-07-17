#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-python workflow coverage merge

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml"

@test "reusable-test-python: aggregate job merges per-version coverage artifacts" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /uses: actions\/upload-artifact\/merge@/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge uses python-coverage pattern" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /pattern: python-coverage-\*/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge produces python-coverage artifact" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /name: python-coverage$/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge gated on upload-coverage and coverage" {
	run awk '
		/Merge per-version coverage artifacts/ { getline; if ($0 ~ /inputs\.upload-coverage && inputs\.coverage/) found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge omits delete-merged so sources expire via retention-days" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /delete-merged:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: aggregate job grants actions write for artifact merge" {
	run awk '
		/^  aggregate:/ { in_aggregate = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_aggregate = 0 }
		in_aggregate && /actions: write/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-python: coverage merge continues on error when no artifacts exist" {
	run awk '
		/Merge per-version coverage artifacts/ { in_step = 1 }
		in_step && /continue-on-error: true/ { found = 1; exit }
		in_step && /^      - name:/ && !/Merge per-version coverage artifacts/ { exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
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
