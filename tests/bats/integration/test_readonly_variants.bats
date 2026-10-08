#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the generated read-only workflow variants (#1081)
#
# A facade reusable marks its mutation-only regions; the read-only variant is
# generated from it by scripts/ci/workflows/sync-readonly-variants.sh. These
# tests pin what makes the variant safe to offer: it cannot drift from the
# facade, its permission union holds no write scope, and dropping the marked
# regions leaves no dangling job, needs or input reference.

load "../../helpers/common"

WORKFLOWS_DIR="${PROJECT_ROOT}/.github/workflows"
SYNC="${PROJECT_ROOT}/scripts/ci/workflows/sync-readonly-variants.sh"
UNION="${PROJECT_ROOT}/scripts/ci/docs/validate-caller-permissions.py"
VARIANT_MARK="# lgtm-ci-readonly-variant:"

# Only the union and reference tests need Python; the generator tests run
# without it.
require_python_yaml() {
	# PyYAML: system python3 on GitHub-hosted runners, the dev venv locally.
	PY=""
	local candidate
	for candidate in python3 "${PROJECT_ROOT}/.venv/bin/python"; do
		if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import yaml' 2>/dev/null; then
			PY="${candidate}"
			break
		fi
	done
	if [[ -z "${PY}" ]]; then
		# Skipping in CI would hide the whole contract suite.
		if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
			fail "no python3 with PyYAML in CI"
		fi
		skip "no python3 with PyYAML (install the dev extra)"
	fi
}

# Print "<facade> <variant>" for every facade carrying the marker.
variant_pairs() {
	local facade variant
	for facade in "${WORKFLOWS_DIR}"/reusable-*.yml; do
		variant="$(sed -n "s/^${VARIANT_MARK} *//p" "$facade" | head -n 1)"
		[[ -n "$variant" ]] && printf '%s %s\n' "$(basename "$facade")" "$variant"
	done
	return 0
}

# A minimal facade with one read job and one marked write job.
_write_facade() {
	local dir="$1"
	cat >"${dir}/reusable-demo.yml" <<'YAML'
---
name: Demo
# lgtm-ci-readonly:omit:begin
# lgtm-ci-readonly-variant: reusable-demo-run.yml
# lgtm-ci-readonly:omit:end

on:
  workflow_call:
    inputs:
      # lgtm-ci-readonly:omit:begin
      marker:
        type: string
        default: "x"
      # lgtm-ci-readonly:omit:end
      job-name:
        type: string
        default: "Demo"

jobs:
  test:
    name: ${{ inputs.job-name }}
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - run: echo test
  # lgtm-ci-readonly:omit:begin
  publish:
    needs: test
    runs-on: ubuntu-24.04
    permissions:
      pull-requests: write
    steps:
      - run: echo "${{ inputs.marker }}"
  # lgtm-ci-readonly:omit:end
YAML
}

@test "sync-readonly-variants: every committed variant matches its facade" {
	run bash "$SYNC" --check
	assert_success
}

@test "sync-readonly-variants: at least one facade declares a variant" {
	run variant_pairs
	assert_success
	[[ -n "$output" ]]
}

@test "read-only variants: permission union holds no write scope" {
	require_python_yaml
	local facade variant
	while read -r facade variant; do
		run "$PY" "$UNION" --union "$variant"
		assert_success
		[[ -n "$output" ]] || fail "$variant: empty union"
		if grep -q ': write$' <<<"$output"; then
			fail "$variant grants write: $output"
		fi
	done < <(variant_pairs)
}

@test "read-only variants: no dangling job, needs, output or input reference" {
	require_python_yaml
	local facade variant
	while read -r facade variant; do
		run "$PY" -c '
import re, sys, yaml
facade, variant = (yaml.safe_load(open(p)) for p in sys.argv[1:3])
call = (variant.get("on") or variant[True])["workflow_call"]
inputs = set(call.get("inputs") or {})
jobs = variant["jobs"]
errors = []
for name, job in jobs.items():
    needs = job.get("needs") or []
    for need in [needs] if isinstance(needs, str) else needs:
        if need not in jobs:
            errors.append(f"{name}: needs dropped job {need}")
    if facade["jobs"][name].get("name") != job.get("name"):
        errors.append(f"{name}: job name differs from the facade")
text = open(sys.argv[2]).read()
for ref in sorted(set(re.findall(r"\binputs\.([A-Za-z0-9_-]+)", text)) - inputs):
    errors.append(f"undeclared input {ref}")
for ref in sorted(set(re.findall(r"\bjobs\.([A-Za-z0-9_-]+)\.outputs", text)) - set(jobs)):
    errors.append(f"output reads dropped job {ref}")
for ref in sorted(set(re.findall(r"\bneeds\.([A-Za-z0-9_-]+)\.", text)) - set(jobs)):
    errors.append(f"expression reads dropped job {ref}")
print("\n".join(errors))
sys.exit(1 if errors else 0)
' "${WORKFLOWS_DIR}/${facade}" "${WORKFLOWS_DIR}/${variant}"
		[[ "$status" -eq 0 ]] || fail "${variant}: ${output}"
	done < <(variant_pairs)
}

@test "sync-readonly-variants: drops marked regions and renames the workflow" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	assert_output "wrote reusable-demo-run.yml"
	run grep -Ec "publish:|marker:|lgtm-ci-readonly" "${dir}/reusable-demo-run.yml"
	assert_output "0"
	run grep -x "name: Demo (read-only)" "${dir}/reusable-demo-run.yml"
	assert_success
	run grep -c "^# GENERATED by scripts/ci/workflows/sync-readonly-variants.sh" "${dir}/reusable-demo-run.yml"
	assert_output "1"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_success
}

@test "sync-readonly-variants: --check fails when the facade changed" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	env WORKFLOWS_DIR="$dir" bash "$SYNC" >/dev/null
	sed -i.bak 's/echo test/echo changed/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_failure
	assert_output --partial "read-only variant out of date: reusable-demo-run.yml"
}

@test "sync-readonly-variants: --check fails when the variant is missing" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_failure
	assert_output --partial "reusable-demo-run.yml"
}

@test "sync-readonly-variants: unterminated omit region fails" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak '$d' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "unterminated # lgtm-ci-readonly:omit:begin"
	[[ ! -f "${dir}/reusable-demo-run.yml" ]]
}

@test "sync-readonly-variants: generated file without a facade marker is an orphan" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	env WORKFLOWS_DIR="$dir" bash "$SYNC" >/dev/null
	sed -i.bak '/lgtm-ci-readonly-variant:/d' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_failure
	assert_output --partial "generated variant without a facade marker: reusable-demo-run.yml"
}

@test "sync-readonly-variants: renames a double-quoted name inside the quotes" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^name: Demo$/name: "Demo"/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	run grep -x 'name: "Demo (read-only)"' "${dir}/reusable-demo-run.yml"
	assert_success
}

@test "sync-readonly-variants: a name it cannot rewrite safely fails" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^name: Demo$/name: Demo # facade/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "cannot rename this name: form"
	[[ ! -f "${dir}/reusable-demo-run.yml" ]]
}

@test "sync-readonly-variants: a variant that inherits the marker is rejected, not used as a facade" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	# Marker outside every omit region: the variant would carry it too.
	sed -i.bak '/^# lgtm-ci-readonly-variant:/d' "${dir}/reusable-demo.yml"
	printf '# lgtm-ci-readonly-variant: reusable-demo-run.yml\n' >>"${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_failure
	assert_output --partial "generated variant carries # lgtm-ci-readonly-variant:"
	run grep -c "(read-only) (read-only)" "${dir}/reusable-demo-run.yml"
	assert_output "0"
}

@test "sync-readonly-variants: never overwrites the facade or a hand-maintained workflow" {
	local dir="${BATS_TEST_TMPDIR}/wf" before
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^# lgtm-ci-readonly-variant: .*/# lgtm-ci-readonly-variant: reusable-demo.yml/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	before="$(cat "${dir}/reusable-demo.yml")"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "variant name is the facade itself"
	[[ "$(cat "${dir}/reusable-demo.yml")" == "$before" ]]

	sed -i.bak 's/^# lgtm-ci-readonly-variant: .*/# lgtm-ci-readonly-variant: reusable-other.yml/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	printf -- '---\nname: Other\n' >"${dir}/reusable-other.yml"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "reusable-other.yml exists and is not generated"
	run cat "${dir}/reusable-other.yml"
	assert_output "$(printf -- '---\nname: Other')"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC" --check
	assert_failure
}

@test "sync-readonly-variants: two facades cannot claim one variant" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed 's/^name: Demo$/name: Demo Two/' "${dir}/reusable-demo.yml" >"${dir}/reusable-demo-two.yml"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "reusable-demo-run.yml is already the variant of another facade"
}

@test "sync-readonly-variants: prose that mentions a marker is not a marker" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^    steps:$/    # wrap regions in # lgtm-ci-readonly:omit:end pairs\n    steps:/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	run grep -c "wrap regions in" "${dir}/reusable-demo-run.yml"
	assert_output "1"
}

@test "sync-readonly-variants: renames a one-character name" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^name: Demo$/name: D/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	run grep -x "name: D (read-only)" "${dir}/reusable-demo-run.yml"
	assert_success
}

@test "sync-readonly-variants: an indented variant marker fails instead of skipping" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	sed -i.bak 's/^# lgtm-ci-readonly-variant:/  # lgtm-ci-readonly-variant:/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "must start in column 0"
}

@test "sync-readonly-variants: a blank line left at the end of the variant fails" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	# A blank line before the final omit region, outside it.
	sed -i.bak 's/^  # lgtm-ci-readonly:omit:begin$/\n&/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_failure
	assert_output --partial "variant would end in a blank line"
	[[ ! -f "${dir}/reusable-demo-run.yml" ]]
}

@test "sync-readonly-variants: kept block scalars are copied verbatim, blank lines included" {
	require_python_yaml
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	_write_facade "$dir"
	# A keep-chomping scalar whose trailing blank line sits just before the
	# omitted publish job; the blank line belongs to the kept value.
	sed -i.bak 's/^      - run: echo test$/      - run: |+\n          echo test\n\n          echo after/' "${dir}/reusable-demo.yml"
	rm -f "${dir}/reusable-demo.yml.bak"
	run env WORKFLOWS_DIR="$dir" bash "$SYNC"
	assert_success
	run "$PY" -c '
import sys, yaml
a, b = (yaml.safe_load(open(p))["jobs"]["test"]["steps"][0]["run"] for p in sys.argv[1:3])
assert a == b, (a, b)
print(repr(b))
' "${dir}/reusable-demo.yml" "${dir}/reusable-demo-run.yml"
	assert_success
}

@test "sync-readonly-variants: rejects unknown arguments" {
	run bash "$SYNC" --write
	[[ "$status" -eq 2 ]]
}
