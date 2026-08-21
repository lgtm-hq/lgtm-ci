#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/resolve-ai-review-provider.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/resolve-ai-review-provider.sh"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
	cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
	teardown_temp_dir
}

@test "resolve: empty inputs stay unresolved (no default provider)" {
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "resolved=false"
	assert_output --partial "provider="
	assert_output --partial "needs-cli=false"
	refute_output --partial "provider=anthropic"
}

@test "resolve: input wins over var and config" {
	cat >"${BATS_TEST_TMPDIR}/.lintro-config.yaml" <<'YAML'
ai:
  provider: cursor
  transport: cli
YAML
	PROVIDER_INPUT="openai" TRANSPORT_INPUT="api" \
		VAR_PROVIDER="cursor" VAR_TRANSPORT="cli" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/.lintro-config.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=openai"
	assert_output --partial "transport=api"
	assert_output --partial "credential-env=OPENAI_API_KEY"
	assert_output --partial "needs-cli=false"
	assert_output --partial "resolved=true"
}

@test "resolve: var wins over config when input is empty" {
	cat >"${BATS_TEST_TMPDIR}/.lintro-config.yaml" <<'YAML'
ai:
  provider: anthropic
  transport: api
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" \
		VAR_PROVIDER="cursor" VAR_TRANSPORT="cli" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/.lintro-config.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "credential-env=CURSOR_API_KEY"
	assert_output --partial "cli-binary=agent"
	assert_output --partial "needs-cli=true"
}

@test "resolve: config is used when input and var are empty" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai:
  provider: anthropic
  transport: cli
tools:
  ruff:
    enabled: true
YAML
	PROVIDER_INPUT="" VAR_PROVIDER="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=anthropic"
	assert_output --partial "transport=cli"
	assert_output --partial "credential-env=CLAUDE_CODE_OAUTH_TOKEN"
	assert_output --partial "cli-binary=claude"
}

@test "resolve: extra-endpoints are provider-scoped" {
	PROVIDER_INPUT="cursor" TRANSPORT_INPUT="cli" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "downloads.cursor.com:443"
	refute_output --partial "api.anthropic.com"
	refute_output --partial "api.openai.com"
}

@test "resolve: anthropic api extra-endpoints exclude npm hosts" {
	PROVIDER_INPUT="anthropic" TRANSPORT_INPUT="api" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "api.anthropic.com:443"
	refute_output --partial "registry.npmjs.org"
}
