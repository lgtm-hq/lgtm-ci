#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fake Python interpreters for scripts that run Python through
# run_python (scripts/ci/lib/python.sh, #1428)
#
# run_python first asks the interpreter for its version
# (`<interpreter> -I -c '...sys.version_info...'`) and refuses anything older
# than 3.11. A fake interpreter has to answer that probe like a real one;
# every other call reaches the body the test gives.
#
# Usage: in a .bats file:
#   load "../../helpers/fake_python"
#   write_fake_python "${BATS_TEST_TMPDIR}/fake-python" 'exit 1'
#   write_fake_python "${BATS_TEST_TMPDIR}/old-python" 'exit 0' 3.10.12

# Print the lines that answer the version probe with <version>.
# Usage: fake_python_probe_answer [version]
fake_python_probe_answer() {
	local version="${1-3.12.0}"
	# shellcheck disable=SC2016 # the lines are code for the fake, expanded there
	printf '%s\n' \
		'if [[ "${1:-}" == -I && "${2:-}" == -c && "${3:-}" == *sys.version_info* ]]; then' \
		"	printf '%s' '${version}'" \
		'	exit 0' \
		'fi'
}

# Write an executable bash script at <path> that answers the version probe
# with [version] (default 3.12.0) and otherwise runs <body>.
# Usage: write_fake_python <path> <body> [version]
write_fake_python() {
	local path="$1" body="$2" version="${3-3.12.0}"
	{
		printf '#!/usr/bin/env bash\n'
		fake_python_probe_answer "$version"
		printf '%s\n' "$body"
	} >"$path"
	chmod +x "$path"
}
