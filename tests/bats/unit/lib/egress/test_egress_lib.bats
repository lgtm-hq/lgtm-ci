#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/lib/egress.sh aggregator

load "../../../../helpers/common"

EGRESS_LIB="${PROJECT_ROOT}/scripts/ci/lib/egress.sh"

@test "egress.sh: loads presets and resolves github-minimal" {
	run bash -c "source '$EGRESS_LIB' && egress_preset_endpoints github-minimal"
	assert_success
	assert_output --partial 'github.com:443'
}

@test "egress.sh: second source is a no-op when already loaded" {
	run bash -c "source '$EGRESS_LIB' && source '$EGRESS_LIB' && egress_preset_endpoints github-minimal"
	assert_success
	assert_output --partial 'api.github.com:443'
}

@test "egress preset playwright: includes Ubuntu apt mirrors for --with-deps" {
	run bash -c "source '$EGRESS_LIB' && egress_preset_endpoints playwright"
	assert_success
	assert_output --partial 'archive.ubuntu.com:80'
	assert_output --partial 'security.ubuntu.com:80'
}

@test "egress_dedupe_endpoint_lines: keeps first occurrence order" {
	run bash -c "
		source '$EGRESS_LIB'
		egress_dedupe_endpoint_lines \$'b:2\na:1\nb:2\na:1\n'
	"
	assert_success
	assert_output $'b:2\na:1'
}

@test "egress_merge_endpoint_lines: merges and dedupes lists" {
	run bash -c "
		source '$EGRESS_LIB'
		egress_merge_endpoint_lines \$'x:1\ny:2\n' \$'y:2\nz:3\n'
	"
	assert_success
	assert_output $'x:1\ny:2\nz:3'
}
