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
	assert_line "provider="
	assert_line "transport="
	assert_line "credential-env="
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

@test "resolve: config-only provider under block egress fails loudly" {
	cat >"${BATS_TEST_TMPDIR}/.lintro-config.yaml" <<'YAML'
ai:
  provider: cursor
  transport: cli
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		EGRESS_POLICY="block" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/.lintro-config.yaml" \
		run bash "$SCRIPT"
	assert_failure
	assert_output --partial "harden-runner cannot see"
	assert_output --partial "LINTRO_AI_PROVIDER"
}

@test "resolve: config-only provider is allowed under audit egress" {
	cat >"${BATS_TEST_TMPDIR}/.lintro-config.yaml" <<'YAML'
ai:
  provider: cursor
  transport: cli
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		EGRESS_POLICY="audit" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/.lintro-config.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "resolved=true"
}

@test "resolve: var-visible provider passes the block-egress guard" {
	PROVIDER_INPUT="" TRANSPORT_INPUT="" \
		VAR_PROVIDER="cursor" VAR_TRANSPORT="cli" \
		EGRESS_POLICY="block" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "resolved=true"
}

@test "resolve: quoted block-style child keys are unquoted before matching" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai:
  "provider": cursor
  "transport": cli
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		EGRESS_POLICY="audit" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "resolved=true"
}

@test "resolve: quoted flow-mapping keys are unquoted before matching" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
"ai": {"provider": cursor, "transport": cli}
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		EGRESS_POLICY="audit" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "resolved=true"
}

@test "resolve: flow-style ai mapping is read when input and var are empty" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai: {provider: cursor, transport: cli}
tools:
  ruff:
    enabled: true
YAML
	PROVIDER_INPUT="" TRANSPORT_INPUT="" VAR_PROVIDER="" VAR_TRANSPORT="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "credential-env=CURSOR_API_KEY"
	assert_output --partial "cli-binary=agent"
	assert_output --partial "needs-cli=true"
	assert_output --partial "resolved=true"
}

@test "resolve: quoted flow-style ai mapping and trailing comment" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai: { provider: "openai", transport: 'api' }  # review
YAML
	PROVIDER_INPUT="" VAR_PROVIDER="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=openai"
	assert_output --partial "transport=api"
	assert_output --partial "credential-env=OPENAI_API_KEY"
	assert_output --partial "needs-cli=false"
}

@test "resolve: wrapped flow-style ai mapping" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai: {
  provider: anthropic,
  transport: cli
}
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

@test "resolve: mixed-case config values are normalized" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai:
  provider: Cursor
  transport: CLI
YAML
	PROVIDER_INPUT="" VAR_PROVIDER="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "resolved=true"
}

@test "resolve: mixed-case overlay is rejected" {
	PROVIDER_INPUT="Anthropic" TRANSPORT_INPUT="cli" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_failure
	assert_output --partial "PROVIDER_INPUT must be lowercase"
}

@test "resolve: unsupported pair stays unresolved" {
	PROVIDER_INPUT="cursor" TRANSPORT_INPUT="api" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/missing.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "resolved=false"
	assert_line "provider=cursor"
	assert_line "transport=api"
	assert_line "credential-env="
	assert_output --partial "needs-cli=false"
}

@test "resolve: block ai heading with trailing comment" {
	cat >"${BATS_TEST_TMPDIR}/cfg.yaml" <<'YAML'
ai: # review settings
  provider: cursor
  transport: cli
YAML
	PROVIDER_INPUT="" VAR_PROVIDER="" \
		CONFIG_PATH="${BATS_TEST_TMPDIR}/cfg.yaml" \
		run bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_OUTPUT"
	assert_output --partial "provider=cursor"
	assert_output --partial "transport=cli"
	assert_output --partial "credential-env=CURSOR_API_KEY"
}
