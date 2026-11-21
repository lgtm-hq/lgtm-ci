#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Well-formed coverage, test-result and security inputs render as
# main's scripts did through every entry point no other golden covers (#1692)

load "../../../helpers/common"
load "../../../helpers/entrypoint_golden"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "entry points: well-formed reports convert, summarise, badge, parse and format as on main (#1692)" {
	run golden_matches "${PROJECT_ROOT}/tests/fixtures/entrypoint-golden/well-formed.main.txt" \
		entrypoint_golden_render "${BATS_TEST_TMPDIR}/golden"
	assert_success
}

@test "entry points: lcov, nyc, pycobertura, lcov_cobertura and coverage on PATH are hidden from the golden (#1692 review)" {
	# Each stand-in fails loudly, so a converter that is not hidden changes
	# what the golden records.
	local stub="${BATS_TEST_TMPDIR}/stub-bin" tool
	mkdir -p "$stub"
	for tool in lcov nyc pycobertura lcov_cobertura coverage; do
		printf '#!/usr/bin/env bash\necho "stub %s" >&2\nexit 97\n' "$tool" >"${stub}/${tool}"
		chmod +x "${stub}/${tool}"
	done
	# stdout only, never through run: under kcov the traced shell's trace can
	# reach stderr, and run would capture it.
	local hidden found
	hidden="$(env PATH="${stub}:${PATH}" bash -c 'source "$1"; _entrypoint_golden_path "$2"' \
		_ "${PROJECT_ROOT}/tests/helpers/entrypoint_golden.bash" "${BATS_TEST_TMPDIR}/probe" 2>/dev/null)"
	[[ -n "$hidden" && "$hidden" != *"$stub"* ]]
	found="$(env PATH="$hidden" bash -c 'command -v lcov nyc pycobertura lcov_cobertura coverage' 2>/dev/null || true)"
	[[ -z "$found" ]]
	PATH="${stub}:${PATH}" run golden_matches "${PROJECT_ROOT}/tests/fixtures/entrypoint-golden/well-formed.main.txt" \
		entrypoint_golden_render "${BATS_TEST_TMPDIR}/golden"
	assert_success
}
