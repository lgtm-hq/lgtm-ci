#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/python.sh (run_python, require_python; #1428)
#
# Each case writes a small script file that sources the library, so kcov
# sees the library through a real file (no `bash -c` under `set -u`). Fake
# interpreters are bash scripts written by tests/helpers/fake_python.bash.

load "../../../helpers/common"
load "../../../helpers/fake_python"

setup() {
	BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$BIN"
	unset PYTHON
	PROBES="${BATS_TEST_TMPDIR}/probes"
	export PROBES
}

# Run <body> in a fresh bash that has sourced the library.
# Usage: run_with_lib <body>
run_with_lib() {
	local script="${BATS_TEST_TMPDIR}/driver.sh"
	{
		printf 'set -euo pipefail\n'
		printf 'source %q\n' "${LIB_DIR}/python.sh"
		printf '%s\n' "$1"
	} >"$script"
	# $BASH: the callers may leave PATH without a bash on it.
	run "$BASH" "$script"
}

# Like run_with_lib, with environment entries (NAME=value) for the new bash,
# such as exported functions (BASH_FUNC_name%%=...).
# Usage: run_with_lib_env <body> <NAME=value>...
run_with_lib_env() {
	local script="${BATS_TEST_TMPDIR}/driver.sh" body="$1"
	shift
	{
		printf 'set -euo pipefail\n'
		printf 'source %q\n' "${LIB_DIR}/python.sh"
		printf '%s\n' "$body"
	} >"$script"
	run env "$@" "$BASH" "$script"
}

# A fake interpreter at <path> that logs each version probe to $PROBES,
# answers it with [version] and otherwise runs <body>.
# Usage: logging_fake <path> <body> [version]
logging_fake() {
	local path="$1" body="$2" version="${3:-3.12.0}"
	{
		printf '#!/usr/bin/env bash\n'
		printf '[[ "${1:-}" == -I && "${2:-}" == -c ]] && echo "probe $*" >>"$PROBES"\n'
		fake_python_probe_answer "$version"
		printf '%s\n' "$body"
	} >"$path"
	chmod +x "$path"
}

@test "run_python: Python 3.10 is refused with one ::error:: line naming both versions" {
	write_fake_python "${BIN}/python3" 'echo "script ran"' 3.10.12
	PATH="${BIN}:${PATH}" run_with_lib 'run_python script.py'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --regexp '^::error::'
	assert_output --partial "Python 3.10.12 at ${BIN}/python3 is too old"
	assert_output --partial "need Python 3.11 or newer"
	assert_output --partial "docs/workflow-contract.md"
	refute_output --partial "script ran"
}

@test "run_python: Python 2.99, 3.6 and 3.9 are refused the same way" {
	local version
	for version in 3.6.15 3.9.6 2.99.0; do
		write_fake_python "${BIN}/python3" 'echo "script ran"' "$version"
		PATH="${BIN}:${PATH}" run_with_lib 'run_python script.py'
		assert_failure 69
		assert_output --partial "Python ${version} at "
		refute_output --partial "script ran"
	done
}

@test "run_python: Python 3.11, 3.12, 3.15 and 4.0 are accepted" {
	local version
	for version in 3.11.0 3.12.3 3.15.0 4.0.0; do
		write_fake_python "${BIN}/python3" 'echo "script ran $*"' "$version"
		PATH="${BIN}:${PATH}" run_with_lib 'run_python script.py'
		assert_success
		assert_output "script ran script.py"
	done
}

@test "run_python: the real interpreter runs" {
	run_with_lib 'run_python -c "import sys; print(sys.version_info >= (3, 11))"'
	assert_success
	assert_output "True"
}

@test "run_python: no python3 on PATH is refused" {
	PATH="${BIN}" run_with_lib 'run_python script.py'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --regexp '^::error::python3 not found on PATH'
	assert_output --partial "need Python 3.11 or newer"
}

@test "run_python: PYTHON wins over python3 on PATH" {
	write_fake_python "${BIN}/python3" 'echo "path python"' 3.12.0
	write_fake_python "${BATS_TEST_TMPDIR}/chosen" 'echo "chosen python"' 3.12.0
	PATH="${BIN}:${PATH}" PYTHON="${BATS_TEST_TMPDIR}/chosen" run_with_lib 'run_python x'
	assert_success
	assert_output "chosen python"
}

@test "run_python: a PYTHON that is not executable is refused, without falling back" {
	write_fake_python "${BIN}/python3" 'echo "path python"' 3.12.0
	PATH="${BIN}:${PATH}" PYTHON=/nonexistent/python run_with_lib 'run_python x'
	assert_failure 69
	assert_output --regexp '^::error::PYTHON=/nonexistent/python is not an executable file'
	refute_output --partial "path python"
	PATH="${BIN}:${PATH}" PYTHON=no-such-python run_with_lib 'run_python x'
	assert_failure 69
	assert_output --regexp '^::error::PYTHON=no-such-python is not on PATH'
}

@test "run_python: a relative PYTHON resolves against the current directory" {
	mkdir -p "${BATS_TEST_TMPDIR}/work/venv"
	write_fake_python "${BATS_TEST_TMPDIR}/work/venv/py" 'echo "relative ran"' 3.12.0
	cd "${BATS_TEST_TMPDIR}/work"
	PYTHON=venv/py run_with_lib 'run_python x'
	assert_success
	assert_output "relative ran"
}

@test "run_python: a probe that fails is refused as unreadable" {
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo "Unknown option: -I" >&2\nexit 2\n'
	} >"${BIN}/python3"
	chmod +x "${BIN}/python3"
	PATH="${BIN}:${PATH}" run_with_lib 'run_python x'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --regexp "^::error::Could not read the Python version of ${BIN}/python3 \(probe exit 2"
	assert_output --partial "error 'Unknown option: -I')"
}

@test "run_python: a failed probe quotes only the first stderr line, escaped and capped" {
	local long
	long="$(printf 'x%.0s' {1..300})"
	cat >"${BIN}/python3" <<EOF
#!/usr/bin/env bash
printf '100%% broken\\rhere\\nsecond line\\n' >&2
exit 1
EOF
	chmod +x "${BIN}/python3"
	PATH="${BIN}:${PATH}" run_with_lib 'run_python x'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --partial "error '100%25 broken%0Dhere')"
	refute_output --partial "second line"
	printf '#!/usr/bin/env bash\necho %s >&2\nexit 1\n' "$long" >"${BIN}/python3"
	PATH="${BIN}:${PATH}" run_with_lib 'run_python x'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --partial "error '$(printf 'x%.0s' {1..120})')"
	refute_output --partial "$(printf 'x%.0s' {1..121})"
}

@test "run_python: a path with a newline or carriage return is refused, never cached" {
	# Without the check, accepting "<dir>\n<old>" would put <old> on a line
	# of its own in the cache, and the too-old <old> would then pass.
	local old="${BATS_TEST_TMPDIR}/old/py" poison
	poison="${BATS_TEST_TMPDIR}/p"$'\n'"${old}"
	mkdir -p "$(dirname "$old")" "$(dirname "$poison")"
	write_fake_python "$old" 'echo "old ran"' 3.10.0
	write_fake_python "$poison" 'echo "poison ran"' 3.12.0
	PYTHON="$poison" OLD="$old" run_with_lib '
		status=0
		require_python || status=$?
		echo "first=$status"
		PYTHON="$OLD" run_python x'
	assert_failure 69
	assert_line --index 0 --regexp '^::error::The interpreter path .*%0A.* contains a newline or carriage return'
	assert_line --index 1 "first=69"
	assert_line --index 2 --regexp '^::error::Python 3\.10\.0 at .* is too old'
	refute_output --partial "ran"
	local cr="${BATS_TEST_TMPDIR}/c"$'\r'"py"
	write_fake_python "$cr" 'echo "cr ran"' 3.12.0
	PYTHON="$cr" run_with_lib 'run_python x'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --regexp '%0Dpy contains a newline or carriage return'
	refute_output --partial "cr ran"
}

@test "run_python: exported type, command or local functions do not change the interpreter" {
	write_fake_python "${BIN}/python3" 'echo "path python"' 3.12.0
	write_fake_python "${BATS_TEST_TMPDIR}/evil" 'echo "evil ran"' 3.12.0
	local evil="${BATS_TEST_TMPDIR}/evil"
	PATH="${BIN}:${PATH}" run_with_lib_env 'run_python x; echo "path=$LGTM_CI_PYTHON_PATH"' \
		"BASH_FUNC_type%%=() { echo ${evil}; }" \
		"BASH_FUNC_command%%=() { echo ${evil}; }" \
		"BASH_FUNC_local%%=() { :; }" \
		"path=${evil}" "name=${evil}"
	assert_success
	assert_line --index 0 "path python"
	assert_line --index 1 "path=${BIN}/python3"
	refute_output --partial "evil ran"
}

@test "run_python: an exported printf function cannot choose the interpreter" {
	# The lookup hands its result back in a variable. A shadowed printf may
	# break the version probe's message, so the run may be refused, but the
	# file it names is never accepted or run.
	write_fake_python "${BIN}/python3" 'echo "path python"' 3.12.0
	write_fake_python "${BATS_TEST_TMPDIR}/evil" 'echo "evil ran"' 3.12.0
	local evil="${BATS_TEST_TMPDIR}/evil"
	PATH="${BIN}:${PATH}" run_with_lib_env \
		'run_python x || true; echo "path=[$LGTM_CI_PYTHON_PATH]"' \
		"BASH_FUNC_printf%%=() { builtin printf '%s' ${evil}; }"
	assert_success
	refute_output --partial "evil ran"
	refute_line "path=[${evil}]"
}

@test "run_python: an empty or relative PATH entry never supplies python3" {
	# The current directory may be a caller's checkout: only absolute PATH
	# entries are searched, so a python3 file there is never picked up.
	mkdir -p "${BATS_TEST_TMPDIR}/checkout/tools"
	write_fake_python "${BATS_TEST_TMPDIR}/checkout/python3" 'echo "checkout ran"' 3.12.0
	write_fake_python "${BATS_TEST_TMPDIR}/checkout/tools/python3" 'echo "checkout ran"' 3.12.0
	write_fake_python "${BIN}/python3" 'echo "path python"' 3.12.0
	cd "${BATS_TEST_TMPDIR}/checkout"
	local entry
	for entry in "" "." "tools" "./tools"; do
		PATH="${entry}:${BIN}:${PATH}" run_with_lib 'run_python x; echo "path=$LGTM_CI_PYTHON_PATH"'
		assert_success
		assert_line --index 0 "path python"
		assert_line --index 1 "path=${BIN}/python3"
		refute_output --partial "checkout ran"
	done
}

@test "require_python: LGTM_CI_PYTHON_PATH is the absolute accepted path, empty after a refusal" {
	mkdir -p "${BATS_TEST_TMPDIR}/work/venv"
	write_fake_python "${BATS_TEST_TMPDIR}/work/venv/py" ':' 3.12.0
	write_fake_python "${BATS_TEST_TMPDIR}/work/venv/old" ':' 3.9.0
	cd "${BATS_TEST_TMPDIR}/work"
	run_with_lib '
		PYTHON=venv/py require_python
		echo "ok=$LGTM_CI_PYTHON_PATH"
		PYTHON=venv/old require_python 2>/dev/null || echo "refused=[$LGTM_CI_PYTHON_PATH]"'
	assert_success
	assert_line --index 0 "ok=${BATS_TEST_TMPDIR}/work/venv/py"
	assert_line --index 1 "refused=[]"
}

@test "run_python: a probe that prints garbage is refused on one line" {
	local garbage
	for garbage in 'Python 3.12.0' '3.12' '3.12.0.1' '' '3.12.0%0A' 'x'; do
		write_fake_python "${BIN}/python3" 'echo "script ran"' "$garbage"
		PATH="${BIN}:${PATH}" run_with_lib 'run_python x'
		assert_failure 69
		assert_output --regexp '^::error::Could not read the Python version'
		refute_output --partial "script ran"
	done
	# Several lines of output stay on one annotation line.
	cat >"${BIN}/python3" <<'EOF'
#!/usr/bin/env bash
printf '3.12.0\nmore\r100%%'
EOF
	chmod +x "${BIN}/python3"
	PATH="${BIN}:${PATH}" run_with_lib 'run_python x'
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --partial "output '3.12.0%0Amore%0D100%25'"
}

@test "run_python: arguments pass through exactly" {
	write_fake_python "${BIN}/python3" 'printf "<%s>\n" "$@"' 3.12.0
	PATH="${BIN}:${PATH}" run_with_lib "run_python '' -I -x 'a b' -- '*' \"\$(printf 'l1\nl2')\" '-c'"
	assert_success
	assert_output "<>
<-I>
<-x>
<a b>
<-->
<*>
<l1
l2>
<-c>"
}

@test "run_python: no arguments run the interpreter with none" {
	write_fake_python "${BIN}/python3" 'echo "argc=$#"' 3.12.0
	PATH="${BIN}:${PATH}" run_with_lib 'run_python'
	assert_success
	assert_output "argc=0"
}

@test "run_python: the interpreter's exit status comes back unchanged" {
	local code
	write_fake_python "${BIN}/python3" 'exit "$1"' 3.12.0
	for code in 0 1 2 3 4 42 69 127; do
		PATH="${BIN}:${PATH}" run_with_lib "status=0; run_python $code || status=\$?; echo \"status=\$status\""
		assert_success
		assert_output "status=${code}"
	done
}

@test "run_python: under errexit a failing script stops the caller with its status" {
	write_fake_python "${BIN}/python3" 'exit 3' 3.12.0
	PATH="${BIN}:${PATH}" run_with_lib 'run_python x; echo "not reached"'
	assert_failure 3
	refute_output --partial "not reached"
}

@test "run_python: stdin reaches the script, not the probe" {
	write_fake_python "${BIN}/python3" 'cat' 3.12.0
	PATH="${BIN}:${PATH}" run_with_lib 'printf "from stdin" | run_python -'
	assert_success
	assert_output "from stdin"
}

@test "run_python: environment and working directory are those of a direct call" {
	write_fake_python "${BIN}/python3" 'pwd; env | grep -v "^_=" | LC_ALL=C sort' 3.12.0
	mkdir -p "${BATS_TEST_TMPDIR}/work"
	PATH="${BIN}:${PATH}" run_with_lib "
		cd '${BATS_TEST_TMPDIR}/work'
		export KEEP_ME='a b'
		NOT_EXPORTED=hidden
		'${BIN}/python3' >direct.txt
		run_python >helper.txt
		diff direct.txt helper.txt
		grep -qx \"KEEP_ME=a b\" helper.txt
		if grep -q NOT_EXPORTED helper.txt; then exit 9; fi
		head -n 1 helper.txt"
	assert_success
	assert_output "${BATS_TEST_TMPDIR}/work"
}

@test "run_python: the caller's working directory is unchanged afterwards" {
	write_fake_python "${BIN}/python3" ':' 3.12.0
	mkdir -p "${BATS_TEST_TMPDIR}/work"
	PATH="${BIN}:${PATH}" run_with_lib "
		cd '${BATS_TEST_TMPDIR}/work'
		run_python x
		pwd"
	assert_success
	assert_output "${BATS_TEST_TMPDIR}/work"
}

@test "run_python: the probe is -I -c and runs once per interpreter, subshells included" {
	logging_fake "${BIN}/python3" ':' 3.12.0
	logging_fake "${BATS_TEST_TMPDIR}/other" ':' 3.13.0
	PATH="${BIN}:${PATH}" run_with_lib "
		require_python
		run_python a
		run_python b
		( run_python c )
		out=\$(run_python d)
		for i in 1 2 3; do run_python loop; done
		PYTHON='${BATS_TEST_TMPDIR}/other' run_python e
		PYTHON='${BATS_TEST_TMPDIR}/other' run_python f"
	assert_success
	run grep -c '^probe -I -c ' "$PROBES"
	assert_output "2"
}

@test "run_python: a refusal is not cached as accepted" {
	logging_fake "${BIN}/python3" ':' 3.10.0
	PATH="${BIN}:${PATH}" run_with_lib "
		run_python a || true
		run_python b || true"
	assert_success
	run grep -c '^probe ' "$PROBES"
	assert_output "2"
}

@test "run_python: a verdict cache from the environment is ignored" {
	write_fake_python "${BIN}/python3" 'echo "script ran"' 3.10.12
	_LGTM_CI_PYTHON_VERIFIED=$'\n'"${BIN}/python3"$'\n' PATH="${BIN}:${PATH}" \
		run_with_lib 'run_python x'
	assert_failure 69
	refute_output --partial "script ran"
}

@test "run_python: the probe runs in isolated mode, untouched by PYTHONPATH" {
	local work="${BATS_TEST_TMPDIR}/hostile" marker="${BATS_TEST_TMPDIR}/marker"
	mkdir -p "$work"
	printf 'open("%s", "w").write("x")\n' "$marker" >"${work}/sitecustomize.py"
	# Control: without -I the interpreter does import it.
	PYTHONPATH="$work" python3 -c pass
	assert [ -e "$marker" ]
	rm -f "$marker"
	cd "$work"
	PYTHONPATH="$work" run_with_lib 'require_python'
	assert_success
	assert [ ! -e "$marker" ]
}

@test "require_python: checks without running anything" {
	write_fake_python "${BIN}/python3" 'echo "script ran"' 3.12.0
	PATH="${BIN}:${PATH}" run_with_lib 'require_python && echo ok'
	assert_success
	assert_output "ok"
}

@test "run_python: a % in the path is escaped in the annotation" {
	mkdir -p "${BATS_TEST_TMPDIR}/100%"
	write_fake_python "${BATS_TEST_TMPDIR}/100%/py" ':' 3.10.0
	PYTHON="${BATS_TEST_TMPDIR}/100%/py" run_with_lib 'run_python x'
	assert_failure 69
	assert_output --partial "100%25/py is too old"
}
