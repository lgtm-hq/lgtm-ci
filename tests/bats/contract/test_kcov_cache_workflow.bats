#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for the kcov build cache in reusable-test-shell (#886).
#
# Both coverage paths (the single `test` job and the `test-sharded` matrix),
# in the facade and its generated read-only variant, resolve the exact kcov
# key, restore it with a SHA-pinned actions/cache right before "Install kcov
# for coverage" with no restore-keys, hand the stage to install-kcov, and
# bound both install steps with timeout-minutes: 10.

load "../../helpers/common"

WORKFLOWS=(
	"${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"
	"${PROJECT_ROOT}/.github/workflows/reusable-test-shell-run.yml"
)
CACHE_PIN="actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"

# Evaluate a Python expression against the steps of <job> in <workflow> as
# `steps`, with `names` the step names in order and `step(name)` one step.
steps_eval() {
	python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"][sys.argv[2]]["steps"]
names = [s.get("name") for s in steps]
def step(name):
    return steps[names.index(name)]
print(eval(sys.argv[3]))
' "$1" "$2" "$3"
}

@test "kcov cache: the key step and the cache sit right before the kcov install in both paths" {
	local wf job
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			run steps_eval "$wf" "$job" \
				"names[names.index('Install kcov for coverage') - 2:names.index('Install kcov for coverage')]"
			assert_success
			assert_output "['Resolve kcov cache key', 'Cache kcov build']"
			run steps_eval "$wf" "$job" "names.index('Install BATS and helpers') < names.index('Resolve kcov cache key')"
			assert_output "True"
		done
	done
}

@test "kcov cache: SHA-pinned actions/cache keyed by the key step, with no restore-keys" {
	local wf job
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			run steps_eval "$wf" "$job" "step('Cache kcov build')['uses']"
			assert_output "$CACHE_PIN"
			run steps_eval "$wf" "$job" "sorted(step('Cache kcov build')['with'])"
			assert_output "['key', 'path']"
			run steps_eval "$wf" "$job" "step('Cache kcov build')['with']['key']"
			assert_output '${{ steps.kcov-cache-key.outputs.cache-key }}'
			run steps_eval "$wf" "$job" "step('Cache kcov build')['with']['path']"
			assert_output '${{ steps.kcov-cache-key.outputs.stage-dir }}'
			run steps_eval "$wf" "$job" "step('Cache kcov build')['if']"
			assert_output --partial "steps.kcov-cache-key.outputs.cache-key != ''"
			run steps_eval "$wf" "$job" "step('Resolve kcov cache key')['id'] + ' ' + step('Resolve kcov cache key')['env']['STEP']"
			assert_output "kcov-cache-key kcov-cache-key"
			run steps_eval "$wf" "$job" "step('Install kcov for coverage')['env']['KCOV_STAGE_DIR']"
			assert_output '${{ steps.kcov-cache-key.outputs.stage-dir }}'
			run steps_eval "$wf" "$job" "[s['name'] for s in steps if 'restore-keys' in (s.get('with') or {})]"
			assert_output "[]"
		done
	done
}

@test "kcov cache: the single-job path keys and caches only for coverage runs" {
	local wf
	for wf in "${WORKFLOWS[@]}"; do
		run steps_eval "$wf" test "step('Resolve kcov cache key')['if']"
		assert_output "inputs.coverage"
		run steps_eval "$wf" test "step('Cache kcov build')['if']"
		assert_output "inputs.coverage && steps.kcov-cache-key.outputs.cache-key != ''"
	done
}

@test "kcov cache: both install steps carry timeout-minutes 10 in both paths" {
	local wf job name
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			for name in 'Install BATS and helpers' 'Install kcov for coverage'; do
				run steps_eval "$wf" "$job" "step('${name}').get('timeout-minutes')"
				assert_output "10"
			done
		done
	done
}

@test "kcov cache: the key covers version, commit, patch digest, image, OS release and architecture" {
	local lib="${PROJECT_ROOT}/scripts/ci/lib/testing/kcov_cache.sh"
	local release="${BATS_TEST_TMPDIR}/os-release"
	printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$release"
	local commit="a39874f938ce13f7a65f253120d1ec946b349ffe"
	local patch="${PROJECT_ROOT}/scripts/ci/patches/kcov-v43-ansi-c-quotes.patch"
	run env OS_RELEASE_FILE="$release" ImageOS=ubuntu24 RUNNER_ARCH=X64 bash -c \
		'source "$1"; kcov_cache_key v43 "$2" "$3"' _ "$lib" "$commit" "$patch"
	assert_success
	local digest
	digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$patch")"
	assert_output "lgtm-kcov-v43-${commit}-${digest}-ubuntu24-ubuntu24.04-x64"
}
