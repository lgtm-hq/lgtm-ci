#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Detect silent coverage loss after Bash ANSI-C quoted xtrace output.

load "../../helpers/common"

setup() {
	setup_temp_dir
	command -v kcov >/dev/null 2>&1 || skip "kcov is not installed"
}

teardown() {
	teardown_temp_dir
}

@test "kcov: covers code after ANSI-C quoted strings with escaped apostrophes" {
	local probe="$BATS_TEST_TMPDIR/probe.sh"
	cat >"$probe" <<'EOF'
#!/usr/bin/env bash
# Bash 5.3 traces this like Bats 1.14's saved_traps=$(trap -p INT ERR DEBUG).
saved_traps=$(printf "line\n\047quoted\047")
printf 'after ANSI-C quote\n'
printf 'still covered\n'
EOF

	# Isolate this collector from an outer coverage run's injected preamble
	# and trace FD. The fixture still uses the runner's actual Bash version.
	run env -u BASH_ENV -u BASH_XTRACEFD -u LD_PRELOAD -u KCOV_BASH_USE_DEBUG_TRAP \
		timeout --kill-after=2s 30s kcov --cobertura \
		--include-path="$probe" "$BATS_TEST_TMPDIR/coverage" "$probe"
	assert_success
	assert_output --partial 'after ANSI-C quote'
	assert_output --partial 'still covered'

	# Test execution can succeed even when kcov silently discards these hits.
	run python3 - "$BATS_TEST_TMPDIR/coverage/cov.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
lines = {int(line.attrib["number"]): int(line.attrib["hits"])
         for line in root.findall(".//class/lines/line")}
for number in (4, 5):
    assert lines.get(number, 0) > 0, f"executed line {number} lost coverage: {lines}"
PY
	assert_success
}
