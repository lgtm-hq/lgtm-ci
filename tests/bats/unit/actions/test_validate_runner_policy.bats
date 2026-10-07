#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for validate-runner-policy tier × runner combinations

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-runner-policy.sh"

setup() {
	setup_github_env
}

teardown() {
	teardown_github_env
}

_run_policy() {
	local tier="$1"
	local egress="$2"
	local environment="$3"
	local os="$4"
	run env \
		TIER="$tier" \
		EGRESS_POLICY="$egress" \
		RUNNER_ENVIRONMENT="$environment" \
		RUNNER_OS="$os" \
		bash "$SCRIPT"
}

@test "strict: block on GitHub-hosted Linux enforces egress" {
	_run_policy strict block github-hosted Linux
	assert_success
	run get_github_output "enforce-egress"
	assert_output "true"
	run get_github_output "effective-policy"
	assert_output "block"
	run get_github_output "tier-warning"
	assert_output ""
}

@test "strict: block on GitHub-hosted Windows fails with remediation" {
	_run_policy strict block github-hosted Windows
	assert_failure
	assert_output --partial "strict tier requires block-mode egress"
	assert_output --partial "GitHub-hosted Windows"
}

@test "strict: block on GitHub-hosted macOS fails" {
	_run_policy strict block github-hosted macOS
	assert_failure
	assert_output --partial "GitHub-hosted macOS"
}

@test "strict: block on self-hosted macOS enforces egress" {
	_run_policy strict block self-hosted macOS
	assert_success
	run get_github_output "enforce-egress"
	assert_output "true"
}

@test "strict: audit rejected on all runners" {
	_run_policy strict audit github-hosted Linux
	assert_failure
	assert_output --partial "audit' is not permitted"
}

@test "hardened: block on GitHub-hosted Windows skips with warning" {
	_run_policy hardened block github-hosted Windows
	assert_success
	run get_github_output "enforce-egress"
	assert_output "false"
	run get_github_output "effective-policy"
	assert_output "none"
	run get_github_output "tier-warning"
	assert_output --partial "hardened tier"
}

@test "hardened: block on GitHub-hosted Linux enforces egress" {
	_run_policy hardened block github-hosted Linux
	assert_success
	run get_github_output "enforce-egress"
	assert_output "true"
}

@test "hardened: audit rejected" {
	_run_policy hardened audit github-hosted Linux
	assert_failure
	assert_output --partial "audit' is not permitted"
}

@test "permissive: audit skips enforcement with advisory" {
	_run_policy permissive audit github-hosted Linux
	assert_success
	run get_github_output "enforce-egress"
	assert_output "false"
	run get_github_output "tier-warning"
	assert_output --partial "permissive tier"
}

@test "permissive: block on GitHub-hosted Windows skips" {
	_run_policy permissive block github-hosted Windows
	assert_success
	run get_github_output "enforce-egress"
	assert_output "false"
}

@test "permissive: block on self-hosted Linux skips with advisory" {
	_run_policy permissive block self-hosted Linux
	assert_success
	run get_github_output "enforce-egress"
	assert_output "false"
	run get_github_output "tier-warning"
	assert_output --partial "self-hosted"
}

@test "permissive: block on GitHub-hosted Linux enforces with advisory" {
	_run_policy permissive block github-hosted Linux
	assert_success
	run get_github_output "enforce-egress"
	assert_output "true"
	run get_github_output "effective-policy"
	assert_output "block"
}

@test "validate-runner-policy: rejects unknown tier" {
	_run_policy invalid block github-hosted Linux
	assert_failure
	assert_output --partial "unknown tier"
}

@test "validate-runner-policy: rejects unknown egress-policy" {
	_run_policy strict invalid github-hosted Linux
	assert_failure
	assert_output --partial "unknown egress-policy"
}

@test "validate-runner-policy: rejects invalid RUNNER_ENVIRONMENT" {
	run env \
		TIER=strict \
		EGRESS_POLICY=block \
		RUNNER_ENVIRONMENT=invalid \
		RUNNER_OS=Linux \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "invalid RUNNER_ENVIRONMENT"
}

@test "validate-runner-policy: rejects invalid RUNNER_OS" {
	run env \
		TIER=strict \
		EGRESS_POLICY=block \
		RUNNER_ENVIRONMENT=github-hosted \
		RUNNER_OS=FreeBSD \
		bash "$SCRIPT"
	assert_failure
	assert_output --partial "invalid RUNNER_OS"
}

@test "action metadata: no action.yml embeds an expression in an input description" {
	# GitHub validates action.yml as a template: a `${{ runner.* }}` inside a
	# description fails the whole action with "Unrecognized named-value:
	# 'runner'" before any step runs. Every reusable-build-rust-binaries leg
	# failed at Validate runner policy this way (#1076).
	# Outside runs: and outputs:, only an input `default:` may carry an
	# expression, and only over the github/inputs contexts; a `${{` on any
	# other metadata line (name, author, descriptions folded or not) or a
	# runner/steps/env/job reference fails template validation.
	run bash -c "for f in '${PROJECT_ROOT}'/.github/actions/*/action.yml; do awk -v f=\"\$f\" '/^(runs|outputs):/{skip=1;next} /^[a-z]/{skip=0} !skip&&/\\\$\\{\\{/&&!(/^ +default: /&&!/\\\$\\{\\{ *(runner|steps|env|job|matrix)\\./){print f\":\"NR\": \"\$0}' \"\$f\"; done"
	assert_success
	assert_output ""
}

@test "action metadata: the inputs-block scan catches a folded description and a runner default" {
	local d="${BATS_TEST_TMPDIR}/actions/x"
	mkdir -p "$d"
	printf 'name: x\ninputs:\n  a:\n    description: >-\n      Pass\n      ${{ runner.os }}\n  b:\n    default: ${{ runner.os }}\n  c:\n    default: ${{ github.repository }}\nruns:\n  using: composite\n  steps:\n    - run: echo ${{ runner.os }}\n      shell: bash\n' >"${d}/action.yml"
	run bash -c "for f in '${BATS_TEST_TMPDIR}'/actions/*/action.yml; do awk -v f=\"\$f\" '/^(runs|outputs):/{skip=1;next} /^[a-z]/{skip=0} !skip&&/\\\$\\{\\{/&&!(/^ +default: /&&!/\\\$\\{\\{ *(runner|steps|env|job|matrix)\\./){print f\":\"NR\": \"\$0}' \"\$f\"; done"
	assert_output --partial ':6:'
	assert_output --partial ':8:'
	refute_output --partial ':10:'
	refute_output --partial ':14:'
}
