#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Behavioural and wiring tests for the "Select GitHub App credential"
#          step in the release reusables (#1367).
#
# The step runs BEFORE the tooling checkout (the minted token is what checks
# the tooling out), so its shell cannot live in scripts/ci/release/ and stays
# inline. These tests extract the `run:` block from each workflow and execute
# it, so the shipped text is what is verified.

load "../../helpers/common"

WORKFLOWS=(
	reusable-release-version-pr.yml
	reusable-release-auto-tag.yml
	reusable-release-multi-ecosystem.yml
)

# Write each credential step's run block to DIR/<workflow>-<n>.sh and print
# the paths.
_extract_steps() {
	python3 - "$1" "${PROJECT_ROOT}/.github/workflows" "${WORKFLOWS[@]}" <<'PY'
import sys

out, base, *names = sys.argv[1:]
for name in names:
    lines = open(f"{base}/{name}").read().splitlines()
    n = 0
    for i, line in enumerate(lines):
        if line.strip() != "- name: Select GitHub App credential":
            continue
        j = i
        while lines[j].strip() != "run: |":
            j += 1
        indent = len(lines[j]) - len(lines[j].lstrip()) + 2
        body = []
        for k in range(j + 1, len(lines)):
            if lines[k].strip() and len(lines[k]) - len(lines[k].lstrip()) < indent:
                break
            body.append(lines[k][indent:])
        n += 1
        path = f"{out}/{name}-{n}.sh"
        open(path, "w").write("\n".join(body) + "\n")
        print(path)
PY
}

setup() {
	STEPS_DIR="${BATS_TEST_TMPDIR}/steps"
	mkdir -p "$STEPS_DIR"
	mapfile -t STEP_FILES < <(_extract_steps "$STEPS_DIR")
}

# Run one extracted step with the given APP_ID / APP_CLIENT_ID values.
_run_step() {
	local script="$1" app_id="$2" client_id="$3"
	OUT_FILE="${BATS_TEST_TMPDIR}/out-$(basename "$script")"
	: >"$OUT_FILE"
	run env APP_ID="$app_id" APP_CLIENT_ID="$client_id" GITHUB_OUTPUT="$OUT_FILE" \
		bash "$script"
}

@test "credential step exists once per mint site (5 total)" {
	[ "${#STEP_FILES[@]}" -eq 5 ]
}

@test "credential step: app-id only selects app-id" {
	local f
	for f in "${STEP_FILES[@]}"; do
		_run_step "$f" "12345" ""
		assert_success
		run cat "$OUT_FILE"
		assert_line "app-id=12345"
		assert_line "client-id="
	done
}

@test "credential step: client-id only selects client-id" {
	local f
	for f in "${STEP_FILES[@]}"; do
		_run_step "$f" "" "Iv23liABC"
		assert_success
		run cat "$OUT_FILE"
		assert_line "app-id="
		assert_line "client-id=Iv23liABC"
	done
}

@test "credential step: both set prefers client-id and emits a notice" {
	local f
	for f in "${STEP_FILES[@]}"; do
		_run_step "$f" "12345" "Iv23liABC"
		assert_success
		assert_output --partial "::notice"
		assert_output --partial "RELEASE_APP_ID ignored"
		run cat "$OUT_FILE"
		assert_line "app-id="
		assert_line "client-id=Iv23liABC"
	done
}

@test "credential step: neither set fails closed with an error annotation" {
	local f
	for f in "${STEP_FILES[@]}"; do
		_run_step "$f" "" ""
		assert_failure
		assert_output --partial "::error"
		[ ! -s "$OUT_FILE" ]
	done
}

@test "every mint step takes app-id and client-id from the credential step outputs" {
	local wf total_mints=0 total_sel=0
	for wf in "${WORKFLOWS[@]}"; do
		local file="${PROJECT_ROOT}/.github/workflows/${wf}"
		local mints sel
		mints="$(grep -c 'uses: actions/create-github-app-token@' "$file")"
		sel="$(grep -c 'app-id: \${{ steps.app-cred.outputs.app-id }}' "$file")"
		[ "$mints" -eq "$sel" ]
		run grep -c 'client-id: \${{ steps.app-cred.outputs.client-id }}' "$file"
		[ "$output" -eq "$mints" ]
		total_mints=$((total_mints + mints))
		total_sel=$((total_sel + sel))
		run grep -F 'app-id: ${{ secrets.' "$file"
		assert_failure
	done
	[ "$total_mints" -eq 5 ]
}

@test "release reusables declare both App secrets optional" {
	local wf
	for wf in "${WORKFLOWS[@]}"; do
		local file="${PROJECT_ROOT}/.github/workflows/${wf}"
		local name
		for name in RELEASE_APP_ID RELEASE_APP_CLIENT_ID; do
			run awk -v key="      ${name}:" '
				$0 == key { found = 1; next }
				found && /^      [A-Za-z_][A-Za-z0-9_-]+:/ { exit }
				found && /^        required: false$/ { ok = 1 }
				END { exit !ok }
			' "$file"
			assert_success
		done
	done
}

@test "each mint step follows a step with id app-cred in the same job" {
	local wf
	for wf in "${WORKFLOWS[@]}"; do
		run python3 - "${PROJECT_ROOT}/.github/workflows/${wf}" <<'PY'
import re
import sys

job = None
seen_cred = False
uses_cred = False
bad = []
for n, line in enumerate(open(sys.argv[1]), 1):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
        job, seen_cred = line.strip(), False
    if re.match(r"^\s+id: app-cred\s*$", line):
        seen_cred = True
    if "steps.app-cred.outputs" in line:
        uses_cred = True
        if not seen_cred:
            bad.append(f"{job} line {n}")
if bad or not uses_cred:
    print("app-cred referenced before it is defined:", bad)
    sys.exit(1)
PY
		assert_success
	done
}
