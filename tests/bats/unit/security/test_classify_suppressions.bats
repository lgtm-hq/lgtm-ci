#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/classify-suppressions.py

load "../../../helpers/common"

CLASSIFY_SCRIPT="${PROJECT_ROOT}/scripts/ci/security/classify-suppressions.py"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR"
}

teardown() {
	teardown_temp_dir
}

@test "classify-suppressions: classifies active stale and expired entries" {
	cat >".osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-active-1111"
ignoreUntil = 2099-12-31
reason = "still present"

[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"

[[IgnoredVulns]]
id = "GHSA-expired-3333"
ignoreUntil = 2020-01-01
reason = "past due"
EOF

	local probe_json
	probe_json=$(
		cat <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "vulnerabilities": [
            { "id": "GHSA-active-1111" }
          ]
        }
      ]
    }
  ]
}
EOF
	)

	run bash -c "printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["GHSA-active-1111"]'
	assert_output --partial '"stale": ["GHSA-stale-2222"]'
	assert_output --partial '"expired": ["GHSA-expired-3333"]'
}

@test "classify-suppressions: honors CONFIG_PATH override" {
	mkdir -p config
	cat >"config/custom.toml" <<'EOF'
[[IgnoredVulns]]
id = "CVE-2024-00001"
ignoreUntil = 2099-06-01
reason = "custom path"
EOF

	local probe_json='{"results":[{"packages":[{"vulnerabilities":[{"id":"CVE-2024-00001"}]}]}]}'

	run bash -c "export CONFIG_PATH=config/custom.toml; printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["CVE-2024-00001"]'
}

@test "classify-suppressions: treats missing ignoreUntil as permanent suppression" {
	cat >".osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-permanent-stale"
reason = "no expiry date"

[[IgnoredVulns]]
id = "GHSA-permanent-active"
reason = "no expiry date"
EOF

	local probe_json='{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-permanent-active"}]}]}]}'

	run bash -c "printf '%s' '$probe_json' | python3 '$CLASSIFY_SCRIPT'"
	assert_success
	assert_output --partial '"active": ["GHSA-permanent-active"]'
	assert_output --partial '"stale": ["GHSA-permanent-stale"]'
	assert_output --partial '"expired": []'
}

@test "classify-suppressions: fails on empty probe output" {
	cat >".osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-only-1111"
ignoreUntil = 2099-12-31
reason = "probe missing"
EOF

	run bash -c "printf '' | python3 '$CLASSIFY_SCRIPT'"
	assert_failure
}
