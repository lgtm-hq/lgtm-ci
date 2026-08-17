#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/merge-cobertura.py (#874)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/merge-cobertura.py"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"
	export OUT="${BATS_TEST_TMPDIR}/merged.xml"
}

teardown() {
	teardown_temp_dir
}

# Write a minimal kcov-style Cobertura document.
write_cobertura() {
	local dest="$1"
	shift
	python3 - "$dest" "$@" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

dest = Path(sys.argv[1])
# Remaining args: filename,line,hits  filename,line,hits ...
files: dict[str, dict[int, int]] = {}
for spec in sys.argv[2:]:
    filename, number, hits = spec.split(",", 2)
    files.setdefault(filename, {})[int(number)] = int(hits)

coverage = ET.Element("coverage", {"line-rate": "0", "branch-rate": "0"})
packages = ET.SubElement(coverage, "packages")
package = ET.SubElement(packages, "package", {"name": "pkg"})
classes = ET.SubElement(package, "classes")
for filename, lines in files.items():
    class_elem = ET.SubElement(
        classes,
        "class",
        {"filename": filename, "name": Path(filename).name},
    )
    lines_elem = ET.SubElement(class_elem, "lines")
    for number, hits in lines.items():
        ET.SubElement(
            lines_elem,
            "line",
            {"number": str(number), "hits": str(hits)},
        )
dest.write_bytes(
    ET.tostring(coverage, encoding="utf-8", xml_declaration=True),
)
PY
}

@test "merge-cobertura.py: disjoint files are unioned" {
	write_cobertura "${BATS_TEST_TMPDIR}/a.xml" \
		"scripts/ci/lib/a.sh,1,3" \
		"scripts/ci/lib/a.sh,2,0"
	write_cobertura "${BATS_TEST_TMPDIR}/b.xml" \
		"scripts/ci/lib/b.sh,1,1"

	run python3 "${SCRIPT}" --output "${OUT}" \
		"${BATS_TEST_TMPDIR}/a.xml" \
		"${BATS_TEST_TMPDIR}/b.xml"
	assert_success
	assert_line "67"
	grep -qx 'coverage-percent=67' "${GITHUB_OUTPUT}"
	run grep -F 'scripts/ci/lib/a.sh' "${OUT}"
	assert_success
	run grep -F 'scripts/ci/lib/b.sh' "${OUT}"
	assert_success
}

@test "merge-cobertura.py: overlapping files keep max hits" {
	write_cobertura "${BATS_TEST_TMPDIR}/a.xml" \
		"scripts/ci/lib/a.sh,1,1" \
		"scripts/ci/lib/a.sh,2,0"
	write_cobertura "${BATS_TEST_TMPDIR}/b.xml" \
		"scripts/ci/lib/a.sh,1,5" \
		"scripts/ci/lib/a.sh,2,2"

	run python3 "${SCRIPT}" --output "${OUT}" \
		"${BATS_TEST_TMPDIR}/a.xml" \
		"${BATS_TEST_TMPDIR}/b.xml"
	assert_success
	assert_line "100"
	run grep -E 'number="1"[^>]*hits="5"|hits="5"[^>]*number="1"' "${OUT}"
	assert_success
	run grep -E 'number="2"[^>]*hits="2"|hits="2"[^>]*number="2"' "${OUT}"
	assert_success
}

@test "merge-cobertura.py: single input is a passthrough of line hits" {
	write_cobertura "${BATS_TEST_TMPDIR}/a.xml" \
		"scripts/ci/lib/a.sh,1,4" \
		"scripts/ci/lib/a.sh,2,0" \
		"scripts/ci/lib/a.sh,3,1"

	run python3 "${SCRIPT}" --output "${OUT}" "${BATS_TEST_TMPDIR}/a.xml"
	assert_success
	assert_line "67"
	run grep -F 'scripts/ci/lib/a.sh' "${OUT}"
	assert_success
}

@test "merge-cobertura.py: rounds half-up to the nearest integer percent" {
	# 1 covered of 2 lines = 50%
	write_cobertura "${BATS_TEST_TMPDIR}/a.xml" \
		"foo.sh,1,1" \
		"foo.sh,2,0"

	run python3 "${SCRIPT}" --output "${OUT}" "${BATS_TEST_TMPDIR}/a.xml"
	assert_success
	assert_line "50"
}

@test "merge-cobertura.py: missing input exits 2" {
	run python3 "${SCRIPT}" --output "${OUT}" "${BATS_TEST_TMPDIR}/missing.xml"
	assert_failure 2
	assert_output --partial "not found"
}

@test "merge-cobertura.py: does not expand DTD entities" {
	cat >"${BATS_TEST_TMPDIR}/xxe.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE coverage [
  <!ENTITY injected SYSTEM "file:///etc/passwd">
]>
<coverage>
  <packages>
    <package name="pkg">
      <classes>
        <class filename="&injected;" name="x">
          <lines>
            <line number="1" hits="1" />
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
EOF
	run python3 "${SCRIPT}" --output "${OUT}" "${BATS_TEST_TMPDIR}/xxe.xml"
	assert_success
	run grep -F '/etc/passwd' "${OUT}"
	assert_failure
	run grep -E 'filename="(&amp;|&)injected;"' "${OUT}"
	assert_success
}

@test "merge-coverage step discovers cov.xml per shard directory" {
	local cov_dir="${BATS_TEST_TMPDIR}/shard-coverage"
	mkdir -p "${cov_dir}/shell-coverage-shard-0"
	mkdir -p "${cov_dir}/shell-coverage-shard-1"
	write_cobertura "${cov_dir}/shell-coverage-shard-0/cov.xml" \
		"a.sh,1,1"
	write_cobertura "${cov_dir}/shell-coverage-shard-1/cobertura.xml" \
		"b.sh,1,0"

	run env \
		STEP=merge-coverage \
		SHARD_COVERAGE_DIR="${cov_dir}" \
		MERGED_COVERAGE_FILE="${OUT}" \
		GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/run-bats-tests.sh"
	assert_success
	# 1 of 2 -> 50%
	grep -qx 'coverage-percent=50' "${GITHUB_OUTPUT}"
	assert_file_exists "${OUT}"
}
