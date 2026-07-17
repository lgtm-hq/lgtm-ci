#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/notify/fields.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

run_fields_json() {
	local raw="$1"
	run bash -c 'source "$LIB_DIR/notify/fields.sh" && notify_fields_json "$1"' _ "$raw"
}

@test "notify_fields_json: empty input yields empty array" {
	run_fields_json ""
	assert_success
	assert_output "[]"
}

@test "notify_fields_json: whitespace-only input yields empty array" {
	run_fields_json $'  \n\t\n'
	assert_success
	assert_output "[]"
}

@test "notify_fields_json: parses KEY=VALUE lines" {
	run_fields_json $'Environment=production\nVersion=1.2.3'
	assert_success
	assert_output '[{"name":"Environment","value":"production"},{"name":"Version","value":"1.2.3"}]'
}

@test "notify_fields_json: parses simple YAML KEY: VALUE lines" {
	run_fields_json $'Environment: production\nVersion: 1.2.3'
	assert_success
	assert_output '[{"name":"Environment","value":"production"},{"name":"Version","value":"1.2.3"}]'
}

@test "notify_fields_json: accepts YAML list items" {
	run_fields_json $'- Environment=production'
	assert_success
	assert_output '[{"name":"Environment","value":"production"}]'
}

@test "notify_fields_json: splits on the first separator in the line" {
	run_fields_json $'Query: a=b\nExpr=x:y'
	assert_success
	assert_output '[{"name":"Query","value":"a=b"},{"name":"Expr","value":"x:y"}]'
}

@test "notify_fields_json: preserves = in values and skips comments" {
	run_fields_json $'# a comment\nQuery=a=b\n\nRef=main'
	assert_success
	assert_output '[{"name":"Query","value":"a=b"},{"name":"Ref","value":"main"}]'
}

@test "notify_fields_json: trims surrounding whitespace" {
	run_fields_json $'  Environment =  production  '
	assert_success
	assert_output '[{"name":"Environment","value":"production"}]'
}

@test "notify_fields_json: JSON-escapes special characters" {
	run_fields_json 'Note=say "hi"'
	assert_success
	assert_output '[{"name":"Note","value":"say \"hi\""}]'
}

@test "notify_fields_json: fails on a line without separator" {
	run_fields_json 'not-a-field'
	assert_failure
	assert_output --partial "invalid fields line"
}

@test "notify_fields_json: fails on an empty key" {
	run_fields_json '=value'
	assert_failure
	assert_output --partial "empty key"
}
