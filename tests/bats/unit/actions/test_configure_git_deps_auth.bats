#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/configure-git-deps-auth.sh (#1021):
#          the opt-in, host-scoped insteadOf rewrite for private git
#          dependencies configures nothing without a token, scopes the
#          rewrite to one host, never prints the token, and cleans up.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/configure-git-deps-auth.sh"

setup() {
	setup_temp_dir
	# Isolate global git config so the real ~/.gitconfig is never touched.
	export HOME="${BATS_TEST_TMPDIR}/home"
	mkdir -p "$HOME"
	export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_DEPS_TOKEN GIT_DEPS_USERNAME
	export GIT_DEPS_HOST="github.com"
}

teardown() {
	teardown_temp_dir
}

_global_config() {
	cat "$GIT_CONFIG_GLOBAL" 2>/dev/null || true
}

@test "git-deps-auth: configure with empty token writes nothing and succeeds" {
	export GIT_DEPS_TOKEN=""

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_success
	assert_output --partial "GIT_DEPS_TOKEN not provided"
	run _global_config
	assert_output ""
}

@test "git-deps-auth: configure writes a host-scoped insteadOf and masks the token" {
	export GIT_DEPS_TOKEN="ghs_secretvalue123"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_success
	refute_output --partial "ghs_secretvalue123"
	assert_output --partial "Configured git auth for https://github.com/"

	run git config --global --get "url.https://x-access-token:ghs_secretvalue123@github.com/.insteadOf"
	assert_success
	assert_output "https://github.com/"
	# Nothing for any other host.
	run git config --global --name-only --get-regexp '^url\..*\.insteadof$'
	assert_output --regexp '^url\.https://x-access-token:[^@]+@github\.com/\.insteadof$'
}

@test "git-deps-auth: username and host inputs select the rewrite" {
	export GIT_DEPS_TOKEN="glpat-abc"
	export GIT_DEPS_HOST="gitlab.example.com"
	export GIT_DEPS_USERNAME="oauth2"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_success
	run git config --global --get "url.https://oauth2:glpat-abc@gitlab.example.com/.insteadOf"
	assert_success
	assert_output "https://gitlab.example.com/"
}

@test "git-deps-auth: configure replaces a stale entry for the same host" {
	git config --global "url.https://x-access-token:old@github.com/.insteadOf" "https://github.com/"
	export GIT_DEPS_TOKEN="new"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_success
	run git config --global --get "url.https://x-access-token:old@github.com/.insteadOf"
	assert_failure
	run git config --global --get "url.https://x-access-token:new@github.com/.insteadOf"
	assert_success
}

@test "git-deps-auth: cleanup removes only this host's rewrite" {
	git config --global "url.https://x-access-token:tok@github.com/.insteadOf" "https://github.com/"
	git config --global "url.https://oauth2:other@gitlab.example.com/.insteadOf" "https://gitlab.example.com/"

	run bash -c "STEP=cleanup bash '$SCRIPT'"
	assert_success
	assert_output --partial "Removed git auth rewrite for https://github.com/"
	refute_output --partial "tok"
	run git config --global --get "url.https://x-access-token:tok@github.com/.insteadOf"
	assert_failure
	run git config --global --get "url.https://oauth2:other@gitlab.example.com/.insteadOf"
	assert_success
}

@test "git-deps-auth: cleanup with nothing configured succeeds" {
	run bash -c "STEP=cleanup bash '$SCRIPT'"
	assert_success
}

@test "git-deps-auth: rejects a token containing URL delimiters" {
	export GIT_DEPS_TOKEN="x@evil.example/"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_failure
	assert_output --partial "::error title=GIT_DEPS_TOKEN::"
	run _global_config
	assert_output ""
}

@test "git-deps-auth: rejects a host that is not a bare host" {
	export GIT_DEPS_TOKEN="tok"
	export GIT_DEPS_HOST="github.com/owner"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_failure
	assert_output --partial "::error title=git-deps-host::"
	run _global_config
	assert_output ""
}

@test "git-deps-auth: rejects a username with delimiters" {
	export GIT_DEPS_TOKEN="tok"
	export GIT_DEPS_USERNAME="a:b"

	run bash -c "STEP=configure bash '$SCRIPT'"
	assert_failure
	assert_output --partial "::error title=git-deps-username::"
}

@test "git-deps-auth: unknown step fails" {
	run bash -c "STEP=bogus bash '$SCRIPT'"
	assert_failure
	assert_output --partial "Unknown step: bogus"
}
