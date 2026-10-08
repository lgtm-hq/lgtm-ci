#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for unified reusable-rust-test workflow (#168 §13)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml"

@test "reusable-rust-test: exposes coverage flag and nextest inputs" {
	run grep -qE '^      coverage:' "$WORKFLOW"
	assert_success
	run grep -qE '^      rust-toolchain:' "$WORKFLOW"
	assert_success
	run grep -qE '^      toolchain:' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.toolchain' "$WORKFLOW"
	assert_failure
	run grep -qF 'inputs.rust-toolchain' "$WORKFLOW"
	assert_success
	run grep -q 'run-rust-nextest.sh' "$WORKFLOW"
	assert_success
	run grep -q 'run-rust-nextest-coverage.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: defines both nextest paths and excludes legacy coverage comment" {
	run awk '
		/run-rust-nextest\.sh/ { nextest = 1 }
		/run-rust-nextest-coverage\.sh/ { cov = 1 }
		/generate-coverage-comment/ { bad = 1 }
		END { exit !(nextest && cov) || bad }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: runs nextest and llvm-cov nextest under mutually exclusive if conditions" {
	run awk '
		{ line[NR] = $0 }
		/run-rust-nextest\.sh/ {
			nextest_step = 1
			for (i = NR - 1; i > 0; i--) {
				if (line[i] ~ /if: \$\{\{ !inputs\.coverage \}\}/) {
					nextest_if = 1
					break
				}
				if (line[i] ~ /^      - name:/) {
					break
				}
			}
		}
		/run-rust-nextest-coverage\.sh/ {
			cov_step = 1
			for (i = NR - 1; i > 0; i--) {
				if (line[i] ~ /if: inputs\.coverage$/) {
					cov_if = 1
					break
				}
				if (line[i] ~ /^      - name:/) {
					break
				}
			}
		}
		END {
			exit !(nextest_step && cov_step && nextest_if && cov_if)
		}
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: defines test and publish-test-summary jobs" {
	run grep -q '^  test:' "$WORKFLOW"
	assert_success
	run grep -q '^  publish-test-summary:' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: delegates test summary to reusable-publish-test-summary" {
	run awk '
		/^  publish-test-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_job = 0 }
		in_job && /reusable-publish-test-summary\.yml/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-rust-test: test job has no pull-requests permission" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

# The aggregate job waits for the matrix artifact listing before aggregating
# (#803): the wait step must precede aggregation, carry the token, take its
# count from the prepare job, fill the pattern with the matrix key, and the
# one-shot download-artifact step must be gone.
@test "reusable-rust-test: aggregate waits for the matrix artifact count before aggregating" {
	run awk '
		/^  aggregate:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  aggregate:/ { in_job = 0 }
		in_job && /wait-for-artifacts\.sh/ { wait = NR }
		in_job && /aggregate-results\.sh/ { agg = NR }
		in_job && /GH_TOKEN: \$\{\{ github\.token \}\}/ { token = 1 }
		in_job && /EXPECTED_COUNT: \$\{\{ needs\.prepare\.outputs\.matrix-count \}\}/ { count = 1 }
		in_job && /MATRIX_KEY: .*'rust-toolchain'/ { key = 1 }
		in_job && /DOWNLOAD_DIR: rust-results$/ { dir = 1 }
		in_job && /format\(.\{0\}-results-\*., inputs\.artifact-prefix\)/ { pattern = 1 }
		in_job && /actions\/download-artifact@/ { dl = 1 }
		in_job && /^ *actions: read$/ { scope = 1 }
		END { exit !(wait && agg && wait < agg && token && count && key && dir && pattern && scope && !dl) }
	' "$WORKFLOW"
	assert_success
	run grep -F "matrix-count: \${{ steps.matrix.outputs.matrix-count }}" "$WORKFLOW"
	assert_success
}

# The starter profile consumers copy must put JUnit where the parser reads it.
# nextest resolves junit.path relative to the profile's store directory
# (target/nextest/ci/), so the only value that lands at
# target/nextest/ci/junit.xml is the bare file name (#1086).
@test "examples/nextest-ci.toml: ci profile junit.path is a bare file name" {
	local example="${PROJECT_ROOT}/examples/nextest-ci.toml"
	run grep -cE '^\[profile\.ci\]$' "$example"
	assert_output "1"
	run grep -cE '^\[profile\.ci\.junit\]$' "$example"
	assert_output "1"
	local junit_path
	junit_path="$(awk '
		/^\[profile\.ci\.junit\]$/ { on = 1; next }
		/^\[/ { on = 0 }
		on && /^path *=/ { sub(/^path *= */, ""); gsub(/"/, ""); print; exit }
	' "$example")"
	[[ "$junit_path" == "junit.xml" ]] || {
		echo "junit.path is '$junit_path'; expected 'junit.xml' (no directory component)"
		return 1
	}
	# The parser's default and the workflow's explicit env must both be
	# exactly the store dir + that file name.
	run grep -F ': "${JUNIT_FILE:=target/nextest/ci/junit.xml}"' \
		"${PROJECT_ROOT}/scripts/ci/testing/rust/parse-rust-test-results.sh"
	assert_success
	run grep -cE '^\s+JUNIT_FILE: target/nextest/ci/junit\.xml$' "$WORKFLOW"
	assert_output "1"
}

@test "reusable-rust-test: documents the nextest ci-profile prerequisite on its inputs" {
	run grep -c 'examples/nextest-ci.toml' "$WORKFLOW"
	[[ "$output" -ge 2 ]] || {
		echo "expected the workspace and test-script inputs to point at examples/nextest-ci.toml; got $output"
		return 1
	}
}

@test "reusable-rust-test: concurrency group is namespaced by callee and caller workflow" {
	# `github` in a called workflow is the caller's, so a group keyed on the
	# ref alone is shared across callers (#1076). The group must start with a
	# stable callee prefix, include github.workflow, and never use github.job.
	run bash -c "awk '/^    concurrency:\$/,/cancel-in-progress/ { print }' '$WORKFLOW' | tr -d '\n' | tr -s ' '"
	assert_success
	assert_output --partial 'lgtm-ci-rust-test-${{ github.repository }}-${{ github.workflow }}-${{ github.ref }}-'
	assert_output --partial "\${{ inputs.concurrency-scope || 'default' }}"
	assert_output --partial 'cancel-in-progress: true'
	refute_output --partial 'github.job'
	run grep -E 'group: *rust-test-' "$WORKFLOW"
	assert_failure
}
