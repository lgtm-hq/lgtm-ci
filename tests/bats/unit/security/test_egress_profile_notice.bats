#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/egress-profile-notice.sh (#1597)
#
# The source of the "Report egress not enforced" step that
# render-egress-profile.py writes in place of every "Verify harden-runner
# agent" step of a copy generated with the audit or none profile. It never
# runs in this repository's own workflows.
# tests/python/test_render_egress_profile.py checks that every generated copy
# equals this body.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/egress-profile-notice.sh"

setup() {
	scrub_ci_step_env
	# Keep kcov tracing through env -i, or the script is never measured.
	kcov_trace_env
	SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
}

# Run the notice on a hosted Linux runner unless the arguments override it.
_notice() {
	run env -i "${KCOV_TRACE_ENV[@]}" PATH="$PATH" GITHUB_STEP_SUMMARY="$SUMMARY" \
		RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux "$@" "$BASH" "$SCRIPT"
}

@test "audit: notice on the job and in the step summary" {
	_notice EGRESS_PROFILE=audit EGRESS_POLICY=audit
	assert_success
	assert_output --partial "::notice title=egress not enforced::Egress is not enforced in this job (audit egress profile): any step can send data to any host."
	assert_output --partial "reports resolved DNS names and connections to StepSecurity."
	refute_output --partial "::warning"
	run cat "$SUMMARY"
	assert_success
	assert_output --partial "Egress is not enforced in this job (audit egress profile)"
}

@test "none: notice that harden-runner is not run, whatever the policy" {
	for policy in "" block audit none; do
		rm -f "$SUMMARY"
		_notice EGRESS_PROFILE=none EGRESS_POLICY="$policy"
		assert_success
		assert_output "::notice title=egress not enforced::harden-runner is not run in this copy (egress profile none): there is no egress control and no egress monitoring; any step can send data to any host."
		run cat "$SUMMARY"
		assert_output --partial "harden-runner is not run in this copy (egress profile none)"
	done
}

@test "hosted macOS and Windows get the same notice" {
	for os in macOS Windows; do
		_notice RUNNER_OS="$os" EGRESS_PROFILE=audit EGRESS_POLICY=audit
		assert_success
		assert_output --partial "::notice title=egress not enforced::"
	done
}

@test "audit without a step summary file still notices" {
	run env -i "${KCOV_TRACE_ENV[@]}" PATH="$PATH" RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux \
		EGRESS_PROFILE=audit EGRESS_POLICY=audit "$BASH" "$SCRIPT"
	assert_success
	assert_output --partial "::notice title=egress not enforced::"
}

@test "audit rejects block: an audit copy cannot claim enforcement" {
	_notice EGRESS_PROFILE=audit EGRESS_POLICY=block
	assert_failure 1
	assert_output --partial "::error title=egress-policy rejected::egress-policy block"
	assert_output --partial "--profile block"
	assert [ ! -e "$SUMMARY" ]
}

@test "audit rejects an empty or unknown policy" {
	_notice EGRESS_PROFILE=audit EGRESS_POLICY=
	assert_failure 1
	assert_output --partial "egress-policy ''"
	_notice EGRESS_PROFILE=audit EGRESS_POLICY='audit; x'
	assert_failure 1
	assert_output --partial "::error title=egress-policy rejected::"
}

@test "an unknown or missing profile fails" {
	_notice EGRESS_PROFILE=block EGRESS_POLICY=block
	assert_failure 1
	assert_output --partial "::error title=unknown egress profile::"
	_notice EGRESS_POLICY=audit
	assert_failure 1
	assert_output --partial "::error title=unknown egress profile::"
}

@test "public repository on a self-hosted runner fails under every profile (#1552)" {
	for profile in audit none; do
		_notice RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=Linux REPOSITORY_PRIVATE=false \
			EGRESS_PROFILE="$profile" EGRESS_POLICY=audit
		assert_failure 1
		assert_output --partial "::error title=public repository on self-hosted runner::"
		refute_output --partial "::notice"
	done
}

@test "private, internal or payload-less repository on a self-hosted runner passes" {
	for private in true ""; do
		_notice RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=Linux \
			REPOSITORY_PRIVATE="$private" EGRESS_PROFILE=none
		assert_success
		assert_output --partial "::notice title=egress not enforced::"
	done
}

@test "an unknown runner fails before any notice" {
	_notice RUNNER_ENVIRONMENT= EGRESS_PROFILE=none
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
	_notice RUNNER_ENVIRONMENT=self-hosted RUNNER_OS= EGRESS_PROFILE=none
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
}

@test "the notice refuses exactly where the block verifier refuses (#1552)" {
	verify="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-harden-runner-agent.sh"
	run env -i "${KCOV_TRACE_ENV[@]}" PATH="$PATH" RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=Linux \
		REPOSITORY_PRIVATE=false EGRESS_POLICY=block "$BASH" "$verify"
	assert_failure 1
	assert_output --partial "::error title=public repository on self-hosted runner::"
	_notice RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=Linux REPOSITORY_PRIVATE=false \
		EGRESS_PROFILE=audit EGRESS_POLICY=audit
	assert_failure 1
	assert_output --partial "::error title=public repository on self-hosted runner::"
}
