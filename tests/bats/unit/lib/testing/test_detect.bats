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
	cat >"$PROJECT_DIR/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

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
	cat >"$PROJECT_DIR/package.json" <<'EOF'
{
  "devDependencies": {
    "vitest": "^1.0.0"
  }
}
EOF

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
	cat >"$PROJECT_DIR/package.json" <<'EOF'
{
  "devDependencies": {
    "@playwright/test": "^1.40.0"
  }
}
EOF

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
	cat >"$PROJECT_DIR/coverage.xml" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85">
</coverage>
EOF

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
	cat >"$PROJECT_DIR/coverage.json" <<'EOF'
{
  "/path/to/file.js": {
    "path": "/path/to/file.js",
    "statementMap": {}
  }
}
EOF

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
	cat >"$PROJECT_DIR/coverage.xml" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85">
  <packages>
    <package name="mypackage">
      <classes>
        <class filename="mypackage/main.py">
        </class>
      </classes>
    </package>
  </packages>
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/coverage.xml\""
	assert_success
	assert_output "python"
}

@test "detect_coverage_source: detects javascript from istanbul format" {
	cat >"$PROJECT_DIR/coverage.json" <<'EOF'
{
  "/src/app.js": {
    "path": "/src/app.js",
    "statementMap": {}
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/coverage.json\""
	assert_success
	assert_output "javascript"
}

@test "detect_coverage_source: detects javascript from lcov with .ts files" {
	cat >"$PROJECT_DIR/lcov.info" <<'EOF'
TN:
SF:/src/components/App.tsx
FN:1,App
end_of_record
EOF

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
	cat >"$PROJECT_DIR/clover.xml" <<'EOF'
<?xml version="1.0" ?>
<coverage clover="true">
  <project>
    <file name="src/Controller.php">
    </file>
  </project>
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "php"
}

@test "detect_coverage_source: detects java from clover XML" {
	cat >"$PROJECT_DIR/clover.xml" <<'EOF'
<?xml version="1.0" ?>
<coverage clover="true">
  <project>
    <file name="src/Main.java">
    </file>
  </project>
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "java"
}

@test "detect_coverage_source: detects python from lcov with .py files" {
	cat >"$PROJECT_DIR/lcov.info" <<'EOF'
TN:
SF:/src/app.py
DA:1,1
LF:1
LH:1
end_of_record
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_source \"$PROJECT_DIR/lcov.info\""
	assert_success
	assert_output "python"
}

@test "detect_coverage_source: returns unknown for lcov with unknown extensions" {
	cat >"$PROJECT_DIR/lcov.info" <<'EOF'
TN:
SF:/src/app.rb
DA:1,1
LF:1
LH:1
end_of_record
EOF

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
	cat >"$PROJECT_DIR/clover.xml" <<'EOF'
<?xml version="1.0" ?>
<coverage clover="true">
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/clover.xml\""
	assert_success
	assert_output "clover"
}

@test "detect_coverage_format: detects plain xml when no coverage markers" {
	cat >"$PROJECT_DIR/data.xml" <<'EOF'
<?xml version="1.0" ?>
<data>
  <item>test</item>
</data>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/data.xml\""
	assert_success
	assert_output "xml"
}

@test "detect_coverage_format: detects coverage-py json from meta key" {
	cat >"$PROJECT_DIR/coverage.json" <<'EOF'
{"meta": {"version": "7.0", "format": 3}, "totals": {"percent_covered": 85}}
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.json\""
	assert_success
	assert_output "coverage-py"
}

@test "detect_coverage_format: detects generic json for unknown structure" {
	cat >"$PROJECT_DIR/data.json" <<'EOF'
{"key": "value"}
EOF

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
	cat >"$PROJECT_DIR/coverage.dat" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85">
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "cobertura"
}

@test "detect_coverage_format: content-based clover detection" {
	cat >"$PROJECT_DIR/coverage.dat" <<'EOF'
<?xml version="1.0" ?>
<coverage clover="true">
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "clover"
}

@test "detect_coverage_format: content-based xml fallback" {
	cat >"$PROJECT_DIR/coverage.dat" <<'EOF'
<?xml version="1.0" ?>
<report>
</report>
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_coverage_format \"$PROJECT_DIR/coverage.dat\""
	assert_success
	assert_output "xml"
}

@test "detect_coverage_format: content-based json detection" {
	cat >"$PROJECT_DIR/coverage.dat" <<'EOF'
{"some": "data"}
EOF

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
	cat >"$PROJECT_DIR/package.json" <<'EOF'
{
  "devDependencies": {
    "vitest": "^1.0.0"
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "vitest"
}

@test "detect_all_runners: detects playwright from package.json" {
	cat >"$PROJECT_DIR/package.json" <<'EOF'
{
  "devDependencies": {
    "@playwright/test": "^1.40.0"
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/detect.sh\" && detect_all_runners \"$PROJECT_DIR\""
	assert_success
	assert_output "playwright"
}

@test "detect_all_runners: detects pytest from pyproject.toml" {
	cat >"$PROJECT_DIR/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

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
