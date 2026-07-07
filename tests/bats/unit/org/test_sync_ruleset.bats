#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/org/sync-ruleset.sh (dry-run and payload sanitization)

load "../../../helpers/common"
load "../../../helpers/mocks"

FIXTURE_RELATIVE="json/org_ruleset_example.json"

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
	assert_output --partial "orgs/lgtm-hq/rulesets/9999999"
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
	refute_output --partial '"id": 9999999'
}

@test "sync-ruleset: dry run preserves required status check contexts" {
	run bash "$SCRIPT" "$FIXTURE"
	assert_success
	assert_output --partial "tests / Example Tests"
	assert_output --partial "quality / Example Quality"
	assert_output --partial "🔐 Example Security Audit"
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
	assert_output --partial "orgs/lgtm-hq/rulesets/9999999"
}

@test "sync-ruleset: --id overrides the payload ruleset id" {
	run bash "$SCRIPT" --id 99999 "$FIXTURE"
	assert_success
	assert_output --partial "orgs/lgtm-hq/rulesets/99999"
}

@test "sync-ruleset: LGTM_ORG overrides the target organization" {
	LGTM_ORG="other-org" run bash "$SCRIPT" "$FIXTURE"
	assert_success
	assert_output --partial "orgs/other-org/rulesets/9999999"
}

@test "sync-ruleset: resolves id from ruleset_id when id is absent" {
	local payload="${BATS_TEST_TMPDIR}/payload.json"
	jq 'del(.id) | .ruleset_id = 12345' "$FIXTURE" >"$payload"
	run bash "$SCRIPT" "$payload"
	assert_success
	assert_output --partial "orgs/lgtm-hq/rulesets/12345"
}

@test "sync-ruleset: --apply PUTs the sanitized payload via gh" {
	mock_command_multi "gh" '
	"api orgs/lgtm-hq/rulesets/9999999 --jq .name")
		echo "checks-example"
		;;
	*)
		echo "$@" >>"'"${BATS_TEST_TMPDIR}"'/mock_calls_gh"
		;;'
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_success
	assert_output --partial "Updated ruleset 9999999"
	run cat "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_output --partial "api --method PUT orgs/lgtm-hq/rulesets/9999999 --input -"
}

@test "sync-ruleset: --apply fails when the identity check GET fails" {
	mock_command "gh" "" 1
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_failure
	assert_output --partial "Failed to fetch live ruleset orgs/lgtm-hq/rulesets/9999999"
}

@test "sync-ruleset: --apply refuses when live ruleset name mismatches payload" {
	mock_command "gh" "checks-mismatch"
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_failure
	assert_output --partial "Ruleset identity mismatch"
	assert_output --partial "checks-mismatch"
}

@test "sync-ruleset: --apply fails when the PUT returns an error" {
	mock_command_multi "gh" '
	"api orgs/lgtm-hq/rulesets/9999999 --jq .name")
		echo "checks-example"
		;;
	*)
		exit 1
		;;'
	run bash "$SCRIPT" --apply "$FIXTURE"
	assert_failure
	assert_output --partial "Failed to update orgs/lgtm-hq/rulesets/9999999"
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
