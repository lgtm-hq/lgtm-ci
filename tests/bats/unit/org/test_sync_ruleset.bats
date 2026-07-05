#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/org/sync-ruleset.sh (dry-run and payload sanitization)

load "../../../helpers/common"
load "../../../helpers/mocks"

FIXTURE_RELATIVE="json/org_ruleset_checks_py_lintro.json"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/org/sync-ruleset.sh"
	export FIXTURE="${FIXTURES_DIR}/${FIXTURE_RELATIVE}"
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "sync-ruleset: dry run succeeds and reports target endpoint" {
	run bash "$SCRIPT" "$FIXTURE"
	assert_success
	assert_output --partial "Dry run"
	assert_output --partial "orgs/lgtm-hq/rulesets/16132640"
	assert_output --partial "--apply"
}

@test "sync-ruleset: dry run strips read-only fields from the payload" {
	run bash "$SCRIPT" "$FIXTURE"
	assert_success
	refute_output --partial '"node_id"'
	refute_output --partial '"created_at"'
	refute_output --partial '"updated_at"'
	refute_output --partial '"_links"'
	refute_output --partial '"source_type"'
	refute_output --partial '"id": 16132640'
}

@test "sync-ruleset: dry run preserves required status check contexts" {
	run bash "$SCRIPT" "$FIXTURE"
	assert_success
	assert_output --partial "test-suite-coverage / 🧪 Test Suite & Coverage"
	assert_output --partial "lintro-code-quality / 🛠️ Lintro Code Quality"
	assert_output --partial "🔐 Security Audit"
}

@test "sync-ruleset: dry run does not invoke gh" {
	mock_command_record "gh"
	run bash "$SCRIPT" "$FIXTURE"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output ""
}

@test "sync-ruleset: reads payload from stdin with -" {
	run bash -c "cat '$FIXTURE' | bash '$SCRIPT' -"
	assert_success
	assert_output --partial "orgs/lgtm-hq/rulesets/16132640"
}

@test "sync-ruleset: --id overrides the payload ruleset id" {
	run bash "$SCRIPT" --id 99999 "$FIXTURE"
	assert_success
	assert_output --partial "orgs/lgtm-hq/rulesets/99999"
}

@test "sync-ruleset: LGTM_ORG overrides the target organization" {
	LGTM_ORG="other-org" run bash "$SCRIPT" "$FIXTURE"
	assert_success
	assert_output --partial "orgs/other-org/rulesets/16132640"
}

@test "sync-ruleset: resolves id from ruleset_id when id is absent" {
	local payload="${BATS_TEST_TMPDIR}/payload.json"
	jq 'del(.id) | .ruleset_id = 12345' "$FIXTURE" >"$payload"
	run bash "$SCRIPT" "$payload"
	assert_success
	assert_output --partial "orgs/lgtm-hq/rulesets/12345"
}

@test "sync-ruleset: --apply PUTs the sanitized payload via gh" {
	mock_command_record "gh"
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_success
	assert_output --partial "Updated ruleset 16132640"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "api --method PUT orgs/lgtm-hq/rulesets/16132640 --input -"
}

@test "sync-ruleset: --apply fails when gh returns an error" {
	mock_command "gh" "" 1
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_failure
	assert_output --partial "Failed to update orgs/lgtm-hq/rulesets/16132640"
}

@test "sync-ruleset: fails on missing payload file" {
	run bash "$SCRIPT" "${BATS_TEST_TMPDIR}/does-not-exist.json"
	assert_failure
	assert_output --partial "Payload file not found"
}

@test "sync-ruleset: fails on invalid JSON payload" {
	local payload="${BATS_TEST_TMPDIR}/bad.json"
	echo "not json" >"$payload"
	run bash "$SCRIPT" "$payload"
	assert_failure
	assert_output --partial "not a valid JSON object"
}

@test "sync-ruleset: fails when no ruleset id can be resolved" {
	local payload="${BATS_TEST_TMPDIR}/no-id.json"
	jq 'del(.id)' "$FIXTURE" >"$payload"
	run bash "$SCRIPT" "$payload"
	assert_failure
	assert_output --partial "Could not resolve a numeric ruleset id"
}

@test "sync-ruleset: fails with usage when no path argument given" {
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Usage:"
}
