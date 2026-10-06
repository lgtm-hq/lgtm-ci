#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/detect.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR

	# Create project directory structure
	PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
	mkdir -p "$PROJECT_DIR"
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# detect_test_runner tests - pytest detection
# =============================================================================

@test "detect_test_runner: detects pytest from pytest.ini" {
	echo "[pytest]" >"$PROJECT_DIR/pytest.ini"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

@test "detect_test_runner: detects pytest from pyproject.toml" {
	install_fixture "detect/pyproject-pytest.toml" "$PROJECT_DIR/pyproject.toml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

@test "detect_test_runner: detects pytest from test files in tests/" {
	mkdir -p "$PROJECT_DIR/tests"
	touch "$PROJECT_DIR/tests/test_main.py"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

@test "detect_test_runner: detects pytest from *_test.py naming" {
	mkdir -p "$PROJECT_DIR/tests"
	touch "$PROJECT_DIR/tests/main_test.py"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

# =============================================================================
# detect_test_runner tests - vitest detection
# =============================================================================

@test "detect_test_runner: detects vitest from vitest.config.ts" {
	touch "$PROJECT_DIR/vitest.config.ts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_test_runner: detects vitest from vitest.config.js" {
	touch "$PROJECT_DIR/vitest.config.js"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_test_runner: detects vitest from vitest.config.mts" {
	touch "$PROJECT_DIR/vitest.config.mts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_test_runner: detects vitest from package.json dependency" {
	install_fixture "detect/package-vitest.json" "$PROJECT_DIR/package.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

# =============================================================================
# detect_test_runner tests - playwright detection
# =============================================================================

@test "detect_test_runner: detects playwright from playwright.config.ts" {
	touch "$PROJECT_DIR/playwright.config.ts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "playwright"
}

@test "detect_test_runner: detects playwright from playwright.config.js" {
	touch "$PROJECT_DIR/playwright.config.js"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "playwright"
}

@test "detect_test_runner: detects playwright from package.json dependency" {
	install_fixture "detect/package-playwright.json" "$PROJECT_DIR/package.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "playwright"
}

# =============================================================================
# detect_test_runner tests - priority and unknowns
# =============================================================================

@test "detect_test_runner: returns unknown for empty directory" {
	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_failure
	assert_output "unknown"
}

@test "detect_test_runner: pytest has priority over vitest when both present" {
	echo "[pytest]" >"$PROJECT_DIR/pytest.ini"
	touch "$PROJECT_DIR/vitest.config.ts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

@test "detect_test_runner: defaults to current directory when no arg" {
	cd "$PROJECT_DIR"
	echo "[pytest]" >pytest.ini

	run bash -c "cd \"$PROJECT_DIR\" && source \"\$LIB_DIR/testing/detect.sh\" && detect_test_runner"
	assert_success
	assert_output "pytest"
}

# =============================================================================
# detect_all_runners tests
# =============================================================================

@test "detect_all_runners: returns empty for empty directory" {
	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output ""
}

@test "detect_all_runners: detects single runner" {
	touch "$PROJECT_DIR/vitest.config.ts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_all_runners: detects multiple runners" {
	echo "[pytest]" >"$PROJECT_DIR/pytest.ini"
	touch "$PROJECT_DIR/vitest.config.ts"
	touch "$PROJECT_DIR/playwright.config.ts"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output --partial "pytest"
	assert_output --partial "vitest"
	assert_output --partial "playwright"
}

# =============================================================================
# detect_coverage_format tests
# =============================================================================

@test "detect_coverage_format: detects cobertura from xml" {
	install_fixture "detect/cobertura-empty.xml" "$PROJECT_DIR/coverage.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.xml\""
	assert_success
	assert_output "cobertura"
}

@test "detect_coverage_format: detects lcov from .info extension" {
	touch "$PROJECT_DIR/coverage.info"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.info\""
	assert_success
	assert_output "lcov"
}

@test "detect_coverage_format: detects lcov from TN: prefix" {
	echo "TN:" >"$PROJECT_DIR/lcov.data"
	echo "SF:/path/to/file.js" >>"$PROJECT_DIR/lcov.data"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/lcov.data\""
	assert_success
	assert_output "lcov"
}

@test "detect_coverage_format: detects coverage-py from .coverage file" {
	# .coverage files are binary SQLite databases from coverage.py
	touch "$PROJECT_DIR/.coverage"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/.coverage\""
	assert_success
	assert_output "coverage-py"
}

@test "detect_coverage_format: detects istanbul from json structure" {
	install_fixture "detect/istanbul-statement-map.json" "$PROJECT_DIR/coverage.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.json\""
	assert_success
	assert_output "istanbul"
}

@test "detect_coverage_format: detects html extension" {
	touch "$PROJECT_DIR/coverage.html"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.html\""
	assert_success
	assert_output "html"
}

@test "detect_coverage_format: returns unknown for nonexistent file" {
	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"/nonexistent/file\""
	assert_failure
	assert_output "unknown"
}

# =============================================================================
# detect_coverage_source tests
# =============================================================================

@test "detect_coverage_source: detects python from cobertura with .py files" {
	install_fixture "detect/cobertura-python.xml" "$PROJECT_DIR/coverage.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/coverage.xml\""
	assert_success
	assert_output "python"
}

@test "detect_coverage_source: detects javascript from istanbul format" {
	install_fixture "detect/istanbul-js.json" "$PROJECT_DIR/coverage.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/coverage.json\""
	assert_success
	assert_output "javascript"
}

@test "detect_coverage_source: detects javascript from lcov with .ts files" {
	install_fixture "detect/lcov-tsx.info" "$PROJECT_DIR/lcov.info"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/lcov.info\""
	assert_success
	assert_output "javascript"
}

@test "detect_coverage_source: returns unknown for empty file" {
	touch "$PROJECT_DIR/empty.txt"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/empty.txt\""
	assert_failure
	assert_output "unknown"
}

@test "detect_coverage_source: detects coverage-py from .coverage file" {
	touch "$PROJECT_DIR/.coverage"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/.coverage\""
	assert_success
	assert_output "python"
}

@test "detect_coverage_source: detects php from clover XML" {
	install_fixture "detect/clover-php.xml" "$PROJECT_DIR/clover.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "php"
}

@test "detect_coverage_source: detects java from clover XML" {
	install_fixture "detect/clover-java.xml" "$PROJECT_DIR/clover.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "java"
}

@test "detect_coverage_source: detects python from lcov with .py files" {
	install_fixture "detect/lcov-python.info" "$PROJECT_DIR/lcov.info"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/lcov.info\""
	assert_success
	assert_output "python"
}

@test "detect_coverage_source: returns unknown for lcov with unknown extensions" {
	install_fixture "detect/lcov-unknown.info" "$PROJECT_DIR/lcov.info"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/lcov.info\""
	assert_success
	assert_output "unknown"
}

@test "detect_coverage_source: returns unknown for nonexistent file" {
	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"/nonexistent/file\""
	assert_failure
	assert_output "unknown"
}

# =============================================================================
# detect_coverage_format tests - additional format detection
# =============================================================================

@test "detect_coverage_format: detects clover from xml" {
	install_fixture "detect/clover-empty.xml" "$PROJECT_DIR/clover.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "clover"
}

@test "detect_coverage_format: detects plain xml when no coverage markers" {
	install_fixture "detect/plain-data.xml" "$PROJECT_DIR/data.xml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/data.xml\""
	assert_success
	assert_output "xml"
}

@test "detect_coverage_format: detects coverage-py json from meta key" {
	install_fixture "detect/coverage-py-meta.json" "$PROJECT_DIR/coverage.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.json\""
	assert_success
	assert_output "coverage-py"
}

@test "detect_coverage_format: detects generic json for unknown structure" {
	install_fixture "detect/generic.json" "$PROJECT_DIR/data.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/data.json\""
	assert_success
	assert_output "json"
}

@test "detect_coverage_format: detects lcov from .lcov extension" {
	touch "$PROJECT_DIR/coverage.lcov"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.lcov\""
	assert_success
	assert_output "lcov"
}

@test "detect_coverage_format: content-based cobertura detection" {
	install_fixture "detect/cobertura-empty.xml" "$PROJECT_DIR/coverage.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "cobertura"
}

@test "detect_coverage_format: content-based clover detection" {
	install_fixture "detect/clover-empty.xml" "$PROJECT_DIR/coverage.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "clover"
}

@test "detect_coverage_format: content-based xml fallback" {
	install_fixture "detect/plain-report.xml" "$PROJECT_DIR/coverage.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "xml"
}

@test "detect_coverage_format: content-based json detection" {
	install_fixture "detect/generic-data.json" "$PROJECT_DIR/coverage.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "json"
}

@test "detect_coverage_format: SF: prefix detected as lcov" {
	echo "SF:/path/to/file.js" >"$PROJECT_DIR/coverage.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "lcov"
}

@test "detect_coverage_format: returns unknown for binary file" {
	# Avoid \x00 null bytes — bash 5.x warns "ignored null byte in input"
	# which leaks into the captured output and breaks assert_output
	printf '\x01\x02\x03\x04\x05' >"$PROJECT_DIR/binary.dat"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/binary.dat\""
	assert_failure
	assert_output "unknown"
}

# =============================================================================
# detect_all_runners tests - additional edge cases
# =============================================================================

@test "detect_all_runners: detects vitest from package.json" {
	install_fixture "detect/package-vitest.json" "$PROJECT_DIR/package.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_all_runners: detects playwright from package.json" {
	install_fixture "detect/package-playwright.json" "$PROJECT_DIR/package.json"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "playwright"
}

@test "detect_all_runners: detects pytest from pyproject.toml" {
	install_fixture "detect/pyproject-pytest.toml" "$PROJECT_DIR/pyproject.toml"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

@test "detect_all_runners: detects pytest from test files" {
	mkdir -p "$PROJECT_DIR/tests"
	touch "$PROJECT_DIR/tests/test_main.py"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "pytest"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/detect.sh: exports detect_test_runner function" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && bash -c "type detect_test_runner"'
	assert_success
}

@test "testing/detect.sh: exports detect_all_runners function" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && bash -c "type detect_all_runners"'
	assert_success
}

# =============================================================================
# validate_coverage_file tests (#1078)
# =============================================================================

@test "validate_coverage_file: accepts the line-only, full and empty LCOV fixtures" {
	for name in lcov-line-only lcov-full lcov-empty; do
		run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"\$FIXTURES_DIR/coverage/$name.info\" lcov"
		assert_success
	done
}

@test "validate_coverage_file: rejects the invalid LCOV fixture with a reason" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && validate_coverage_file "$FIXTURES_DIR/coverage/lcov-invalid.info" lcov'
	assert_failure
	assert_output --partial "invalid lcov: first record must start with TN: or SF:"
}

@test "validate_coverage_file: rejects LCOV with a header but no records" {
	local file="${BATS_TEST_TMPDIR}/header-only.info"
	echo "TN:" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" lcov"
	assert_failure
	assert_output --partial "no SF:/end_of_record records"
}

@test "validate_coverage_file: rejects truncated LCOV with no DA/LF line records" {
	local file="${BATS_TEST_TMPDIR}/truncated.info"
	printf 'TN:\nSF:a.js\nend_of_record\n' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" lcov"
	assert_failure
	assert_output --partial "no DA:/LF: line records"
}

@test "validate_coverage_file: accepts the coverage.json fixture as coverage-py" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && validate_coverage_file "$FIXTURES_DIR/coverage/coverage.json" coverage-py'
	assert_success
}

@test "validate_coverage_file: rejects unparsable JSON" {
	local file="${BATS_TEST_TMPDIR}/coverage.json"
	echo '{"totals": ' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" json"
	assert_failure
	assert_output --partial "invalid json"
}

@test "validate_coverage_file: rejects JSON that is not an object" {
	local file="${BATS_TEST_TMPDIR}/coverage.json"
	echo '[]' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" coverage-py"
	assert_failure
	assert_output --partial "not a parsable coverage report"
}

@test "validate_coverage_file: rejects unrelated JSON that is not a coverage report" {
	local file="${BATS_TEST_TMPDIR}/coverage.json"
	echo '{"unrelated": true}' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" json"
	assert_failure
	assert_output --partial "not a parsable coverage report"
}

@test "validate_coverage_file: accepts every JSON report layout the extractors read" {
	local dir="${BATS_TEST_TMPDIR}/layouts"
	mkdir -p "$dir"
	echo '{"total": {"lines": {"pct": 80}}}' >"$dir/summary.json"
	echo '{"/src/a.js": {"path": "/src/a.js", "statementMap": {}, "s": {}}}' >"$dir/final.json"
	echo '{"coverage": 92.5}' >"$dir/generic.json"

	for name in summary final generic; do
		run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$dir/$name.json\" json"
		assert_success
	done
}

@test "validate_coverage_file: accepts a coverage.py SQLite data file by header, not name" {
	local file="${BATS_TEST_TMPDIR}/.coverage"
	printf 'SQLite format 3\000data' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" coverage-py"
	assert_success
}

@test "validate_coverage_file: a .coverage-named file that is neither SQLite nor JSON is rejected" {
	local file="${BATS_TEST_TMPDIR}/.coverage"
	echo "not a database" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" coverage-py"
	assert_failure
	assert_output --partial "invalid json"
}

@test "is_coverage_py_data_file: true only for the SQLite header" {
	local data="${BATS_TEST_TMPDIR}/.coverage"
	local report="${BATS_TEST_TMPDIR}/.coverage.json"
	printf 'SQLite format 3\000data' >"$data"
	echo '{"totals": {"percent_covered": 1}}' >"$report"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && is_coverage_py_data_file \"$data\""
	assert_success
	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && is_coverage_py_data_file \"$report\""
	assert_failure
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && is_coverage_py_data_file "/nonexistent"'
	assert_failure
}

@test "validate_coverage_file: accepts Cobertura and Clover XML with a <coverage> root" {
	for fixture in coverage/sample_cobertura.xml detect/cobertura-python.xml detect/clover-php.xml; do
		run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"\$FIXTURES_DIR/$fixture\" cobertura"
		assert_success
	done
}

@test "validate_coverage_file: accepts minified XML with <coverage> on the declaration line" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	printf '<?xml version="1.0"?><coverage line-rate="0.5" branch-rate="0.5"><packages/></coverage>\n' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" cobertura"
	assert_success
}

@test "validate_coverage_file: XML check survives a huge first line under pipefail" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	{
		printf '<?xml version="1.0"?><coverage line-rate="0.5">'
		head -c 300000 /dev/zero | tr '\0' ' '
		printf '</coverage>\n'
	} >"$file"

	run bash -c "set -o pipefail; source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" cobertura"
	assert_success
}

@test "validate_coverage_file: json label does not accept a SQLite data file" {
	local file="${BATS_TEST_TMPDIR}/coverage.json"
	printf 'SQLite format 3\000data' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" json"
	assert_failure
}

@test "validate_coverage_file: rejects XML without a <coverage> root" {
	local file="${BATS_TEST_TMPDIR}/coverage.xml"
	printf '<?xml version="1.0"?>\n<testsuite tests="1"/>\n' >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" cobertura"
	assert_failure
	assert_output --partial "no <coverage> root element"
}

@test "validate_coverage_file: passes formats without a content check" {
	local file="${BATS_TEST_TMPDIR}/index.html"
	echo "<html></html>" >"$file"

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && validate_coverage_file \"$file\" html"
	assert_success
}

@test "validate_coverage_file: missing file fails" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && validate_coverage_file "/nonexistent.info" lcov'
	assert_failure
}

@test "testing/detect.sh: exports validate_coverage_file function" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && bash -c "type validate_coverage_file"'
	assert_success
}

@test "testing/detect.sh: exports detect_coverage_format function" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && bash -c "type detect_coverage_format"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/detect.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/detect.sh" && echo "${_LGTM_CI_TESTING_DETECT_LOADED}"'
	assert_success
	assert_output "1"
}
