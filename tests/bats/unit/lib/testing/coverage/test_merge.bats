#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/coverage/merge.sh

load "../../../../../helpers/common"
load "../../../../../helpers/mocks"

setup() {
	[[ -n "$LIB_DIR" ]] || { echo "LIB_DIR is not set; cannot source library files" >&2; return 1; }
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# merge_lcov_files tests - lcov available path
# =============================================================================

@test "merge_lcov_files: returns 1 when no output specified" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && merge_lcov_files ""'
	assert_failure
}

@test "merge_lcov_files: returns 1 when no input files specified" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && merge_lcov_files "out.lcov"'
	assert_failure
}

@test "merge_lcov_files: uses lcov when available" {
	mock_command_record "lcov" ""
	local file1="${BATS_TEST_TMPDIR}/a.lcov"
	local file2="${BATS_TEST_TMPDIR}/b.lcov"
	local outfile="${BATS_TEST_TMPDIR}/merged.lcov"
	cat >"$file1" <<'EOF'
TN:
SF:/src/a.js
DA:1,1
LF:1
LH:1
end_of_record
EOF
	cp "$file1" "$file2"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && merge_lcov_files \"$outfile\" \"$file1\" \"$file2\""
	assert_success
	# Verify lcov was called with expected arguments
	assert_file_exists "${BATS_TEST_TMPDIR}/mock_calls_lcov"
	local lcov_args
	lcov_args=$(cat "${BATS_TEST_TMPDIR}/mock_calls_lcov")
	[[ "$lcov_args" == *"$outfile"* ]] || fail "lcov_args missing outfile: $lcov_args"
	[[ "$lcov_args" == *"$file1"* ]] || fail "lcov_args missing file1: $lcov_args"
	[[ "$lcov_args" == *"$file2"* ]] || fail "lcov_args missing file2: $lcov_args"
}

@test "merge_lcov_files: awk fallback concatenates and deduplicates" {
	# Hide lcov from PATH
	local file1="${BATS_TEST_TMPDIR}/a.lcov"
	local file2="${BATS_TEST_TMPDIR}/b.lcov"
	local outfile="${BATS_TEST_TMPDIR}/merged.lcov"
	cat >"$file1" <<'EOF'
TN:
SF:/src/a.js
DA:1,1
DA:2,0
LF:2
LH:1
end_of_record
EOF
	cat >"$file2" <<'EOF'
TN:
SF:/src/a.js
DA:1,2
DA:2,1
LF:2
LH:2
end_of_record
EOF

	# Use subshell where lcov is not available
	run bash -c "
		$(stub_hide_lcov)
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		merge_lcov_files \"$outfile\" \"$file1\" \"$file2\"
	"
	assert_success
	assert_file_exists "$outfile"

	# Verify merged content: single SF block with summed DA counts
	local merged
	merged=$(cat "$outfile")

	# Only one SF:/src/a.js block (deduplicated)
	local sf_count
	sf_count=$(grep -c '^SF:' "$outfile")
	assert_equal "1" "$sf_count"

	# DA:1 summed: 1+2=3
	assert_file_contains "$outfile" "DA:1,3"
	# DA:2 summed: 0+1=1
	assert_file_contains "$outfile" "DA:2,1"

	# Recalculated LF/LH: 2 lines found, 2 lines hit (both >0 after merge)
	assert_file_contains "$outfile" "LF:2"
	assert_file_contains "$outfile" "LH:2"

	# Only one end_of_record (single SF block)
	local eor_count
	eor_count=$(grep -c '^end_of_record' "$outfile")
	assert_equal "1" "$eor_count"
}

@test "merge_lcov_files: awk fallback rejects branch/function records" {
	local file1="${BATS_TEST_TMPDIR}/a.lcov"
	local outfile="${BATS_TEST_TMPDIR}/merged.lcov"
	cat >"$file1" <<'EOF'
TN:
SF:/src/a.js
FN:1,myFunc
FNDA:1,myFunc
DA:1,1
LF:1
LH:1
end_of_record
EOF

	run bash -c "
		$(stub_hide_lcov)
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		merge_lcov_files \"$outfile\" \"$file1\" 2>&1
	"
	assert_failure
	assert_output --partial "branch/function coverage records"
}

@test "merge_lcov_files: skips missing input files" {
	mock_command_record "lcov" ""
	local file1="${BATS_TEST_TMPDIR}/exists.lcov"
	local outfile="${BATS_TEST_TMPDIR}/merged.lcov"
	echo "TN:" >"$file1"
	echo "end_of_record" >>"$file1"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && merge_lcov_files \"$outfile\" \"$file1\" \"/nonexistent/file.lcov\""
	assert_success
	# Verify lcov was called with existing file but not the missing one
	assert_file_exists "${BATS_TEST_TMPDIR}/mock_calls_lcov"
	local lcov_args
	lcov_args=$(cat "${BATS_TEST_TMPDIR}/mock_calls_lcov")
	[[ "$lcov_args" == *"$file1"* ]]
	[[ "$lcov_args" != *"/nonexistent/file.lcov"* ]]
}

@test "merge_lcov_files: single file input works" {
	mock_command_record "lcov" ""
	local file1="${BATS_TEST_TMPDIR}/single.lcov"
	local outfile="${BATS_TEST_TMPDIR}/merged.lcov"
	echo "TN:" >"$file1"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && merge_lcov_files \"$outfile\" \"$file1\""
	assert_success
}

# =============================================================================
# merge_istanbul_files tests
# =============================================================================

@test "merge_istanbul_files: returns 1 when no output specified" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && merge_istanbul_files ""'
	assert_failure
}

@test "merge_istanbul_files: returns 1 when no input files specified" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && merge_istanbul_files "out.json"'
	assert_failure
}

@test "merge_istanbul_files: uses nyc when available" {
	mock_command_record "nyc" ""
	local file1="${BATS_TEST_TMPDIR}/cov1.json"
	local outfile="${BATS_TEST_TMPDIR}/merged.json"
	echo '{}' >"$file1"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && merge_istanbul_files \"$outfile\" \"$file1\""
	assert_success
	# Verify nyc was called with merge subcommand and output path
	assert_file_exists "${BATS_TEST_TMPDIR}/mock_calls_nyc"
	local nyc_args
	nyc_args=$(cat "${BATS_TEST_TMPDIR}/mock_calls_nyc")
	[[ "$nyc_args" == *"merge"* ]]
	[[ "$nyc_args" == *"$outfile"* ]]
}

@test "merge_istanbul_files: single file fallback copies without nyc" {
	local file1="${BATS_TEST_TMPDIR}/cov1.json"
	local outfile="${BATS_TEST_TMPDIR}/merged.json"
	echo '{"test": true}' >"$file1"

	run bash -c "
		command() {
			case \"\$*\" in *nyc*) return 1;; esac
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		merge_istanbul_files \"$outfile\" \"$file1\"
	"
	assert_success
	# Verify file was copied with correct contents
	assert_file_exists "$outfile"
	local copied
	copied=$(cat "$outfile")
	[[ "$copied" == '{"test": true}' ]] || fail "expected '{\"test\": true}', got '$copied'"
}

@test "merge_istanbul_files: multi-file without nyc returns error" {
	local file1="${BATS_TEST_TMPDIR}/cov1.json"
	local file2="${BATS_TEST_TMPDIR}/cov2.json"
	local outfile="${BATS_TEST_TMPDIR}/merged.json"
	echo '{}' >"$file1"
	echo '{}' >"$file2"

	run bash -c "
		command() {
			case \"\$*\" in *nyc*) return 1;; esac
			builtin command \"\$@\"
		}
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		merge_istanbul_files \"$outfile\" \"$file1\" \"$file2\" 2>&1
	"
	assert_failure
	assert_output --partial "nyc is required"
}

# =============================================================================
# convert_coverage tests
# =============================================================================

@test "convert_coverage: returns 1 for missing input file" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && convert_coverage "/nonexistent" "out.lcov" "cobertura" "lcov"'
	assert_failure
}

@test "convert_coverage: same format copies file" {
	local input="${BATS_TEST_TMPDIR}/input.lcov"
	local outfile="${BATS_TEST_TMPDIR}/output.lcov"
	echo "TN:" >"$input"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && convert_coverage \"$input\" \"$outfile\" \"lcov\" \"lcov\""
	assert_success
	assert_file_exists "$outfile"
}

@test "convert_coverage: unsupported conversion returns 1" {
	local input="${BATS_TEST_TMPDIR}/input.txt"
	echo "data" >"$input"

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && convert_coverage \"$input\" \"${BATS_TEST_TMPDIR}/output\" \"unknown\" \"unknown2\""
	assert_failure
}

@test "convert_coverage: auto-detects format" {
	local input="${BATS_TEST_TMPDIR}/coverage.info"
	local outfile="${BATS_TEST_TMPDIR}/output.info"
	cat >"$input" <<'EOF'
TN:
SF:/src/a.js
DA:1,1
LF:1
LH:1
end_of_record
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && convert_coverage \"$input\" \"$outfile\" \"auto\" \"lcov\""
	assert_success
	assert_file_exists "$outfile"
}

@test "convert_coverage: cobertura to lcov manual conversion" {
	local input="${BATS_TEST_TMPDIR}/coverage.xml"
	local outfile="${BATS_TEST_TMPDIR}/output.lcov"
	cat >"$input" <<'EOF'
<?xml version="1.0" ?>
<coverage line-rate="0.85">
  <packages>
    <package name="lib">
      <classes>
        <class name="main.py" filename="lib/main.py" line-rate="0.90">
          <lines>
            <line number="1" hits="1"/>
            <line number="2" hits="0"/>
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
EOF

	# Hide pycobertura from PATH so the manual _convert_cobertura_to_lcov fallback is exercised
	run bash -c "
		command() { case \"\$*\" in *pycobertura*) return 1;; *) builtin command \"\$@\";; esac; }
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		convert_coverage \"$input\" \"$outfile\" \"cobertura\" \"lcov\"
	"
	assert_success
	assert_file_exists "$outfile"
}

@test "convert_coverage: istanbul to lcov manual conversion" {
	local input="${BATS_TEST_TMPDIR}/coverage.json"
	local outfile="${BATS_TEST_TMPDIR}/output.lcov"
	cat >"$input" <<'EOF'
{
  "/src/app.js": {
    "path": "/src/app.js",
    "statementMap": {
      "0": {"start": {"line": 1, "column": 0}, "end": {"line": 1, "column": 10}}
    },
    "s": {"0": 1}
  }
}
EOF

	# Hide nyc from PATH so the manual _convert_istanbul_to_lcov fallback is exercised
	run bash -c "
		command() { case \"\$*\" in *nyc*) return 1;; *) builtin command \"\$@\";; esac; }
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		convert_coverage \"$input\" \"$outfile\" \"istanbul\" \"lcov\"
	"
	assert_success
	assert_file_exists "$outfile"
}

@test "convert_coverage: lcov to cobertura without tool returns 1" {
	local input="${BATS_TEST_TMPDIR}/coverage.info"
	local outfile="${BATS_TEST_TMPDIR}/output.xml"
	echo "TN:" >"$input"

	# Hide lcov_cobertura from PATH to exercise the failure path
	run bash -c "
		command() { case \"\$*\" in *lcov_cobertura*) return 1;; *) builtin command \"\$@\";; esac; }
		source \"\$LIB_DIR/testing/coverage/merge.sh\"
		convert_coverage \"$input\" \"$outfile\" \"lcov\" \"cobertura\"
	"
	assert_failure
}

# =============================================================================
# _convert_cobertura_to_lcov tests
# =============================================================================

@test "_convert_cobertura_to_lcov: converts XML to LCOV format" {
	local input="${BATS_TEST_TMPDIR}/cob.xml"
	local output="${BATS_TEST_TMPDIR}/out.lcov"
	cat >"$input" <<'EOF'
<?xml version="1.0" ?>
<coverage>
  <packages>
    <package name="pkg">
      <classes>
        <class name="mod.py" filename="pkg/mod.py">
          <lines>
            <line number="1" hits="5"/>
            <line number="2" hits="0"/>
            <line number="3" hits="3"/>
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && _convert_cobertura_to_lcov \"$input\" \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial "SF:pkg/mod.py"
	assert_output --partial "DA:1,5"
	assert_output --partial "DA:2,0"
	assert_output --partial "end_of_record"
}

# =============================================================================
# _convert_istanbul_to_lcov tests
# =============================================================================

@test "_convert_istanbul_to_lcov: converts JSON to LCOV format" {
	local input="${BATS_TEST_TMPDIR}/istanbul.json"
	local output="${BATS_TEST_TMPDIR}/out.lcov"
	cat >"$input" <<'EOF'
{
  "/src/index.js": {
    "path": "/src/index.js",
    "statementMap": {
      "0": {"start": {"line": 1, "column": 0}, "end": {"line": 1, "column": 20}},
      "1": {"start": {"line": 2, "column": 0}, "end": {"line": 2, "column": 15}}
    },
    "s": {"0": 3, "1": 0}
  }
}
EOF

	run bash -c "source \"\$LIB_DIR/testing/coverage/merge.sh\" && _convert_istanbul_to_lcov \"$input\" \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial "SF:/src/index.js"
	assert_output --partial "DA:1,3"
	assert_output --partial "DA:2,0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "merge.sh: exports merge_lcov_files function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && declare -f merge_lcov_files >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "merge.sh: exports merge_istanbul_files function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && declare -f merge_istanbul_files >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

@test "merge.sh: exports convert_coverage function" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && declare -f convert_coverage >/dev/null && echo "ok"'
	assert_success
	assert_output "ok"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "merge.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/coverage/merge.sh"
		source "$LIB_DIR/testing/coverage/merge.sh"
		declare -f merge_lcov_files >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "merge.sh: sets _LGTM_CI_TESTING_COVERAGE_MERGE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/coverage/merge.sh" && echo "${_LGTM_CI_TESTING_COVERAGE_MERGE_LOADED}"'
	assert_success
	assert_output "1"
}
