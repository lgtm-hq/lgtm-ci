#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/remove_stale_suppressions.py

load "../../../helpers/common"

REMOVE_SCRIPT="${PROJECT_ROOT}/scripts/ci/security/remove_stale_suppressions.py"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR"
}

teardown() {
	teardown_temp_dir
}

@test "remove-stale-suppressions: preserves non-IgnoredVulns sections" {
	cat >".osv-scanner.toml" <<'EOF'
# Suppression config
[PackageOverrides]
path = "vendor/"

[[IgnoredVulns]]
id = "GHSA-stale-1111"
ignoreUntil = 2099-12-31
reason = "resolved"

[[IgnoredVulns]]
id = "GHSA-active-2222"
ignoreUntil = 2099-12-31
reason = "still present"
EOF

	run bash -c "export REMOVE_IDS_JSON='[\"GHSA-stale-1111\"]'; python3 '$REMOVE_SCRIPT' .osv-scanner.toml"
	assert_success
	assert_output --partial "Removed: GHSA-stale-1111"
	run grep -F '[PackageOverrides]' .osv-scanner.toml
	assert_success
	run grep -F 'GHSA-active-2222' .osv-scanner.toml
	assert_success
	run grep -q 'GHSA-stale-1111' .osv-scanner.toml
	assert_failure
}

@test "remove-stale-suppressions: keeps comments inside retained blocks" {
	cat >".osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-3333"
reason = "resolved upstream"

[[IgnoredVulns]]
# still relevant
id = "GHSA-active-4444"
reason = "active"
EOF

	run bash -c "export REMOVE_IDS_JSON='[\"GHSA-stale-3333\"]'; python3 '$REMOVE_SCRIPT' .osv-scanner.toml"
	assert_success
	run grep -F '# still relevant' .osv-scanner.toml
	assert_success
	run grep -F 'GHSA-active-4444' .osv-scanner.toml
	assert_success
}
