#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for the kcov build cache in reusable-test-shell (#886).
#
# Both coverage paths (the single `test` job and the `test-sharded` matrix),
# in the facade and its generated read-only variant, resolve the exact kcov
# key, restore it with a SHA-pinned actions/cache/restore right before
# "Install kcov for coverage" with no restore-keys, hand the stage to
# install-kcov, and save it with actions/cache/save right after, only on a
# push to the default branch, after a restore miss and a staged build. The
# push is decided case-sensitively by "Check for a default-branch push"
# (default-branch-push.sh, #1659) between the install and the save. The
# install steps are bounded with timeout-minutes: 10, the cache steps with 5.

load "../../helpers/common"

WORKFLOWS=(
	"${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"
	"${PROJECT_ROOT}/.github/workflows/reusable-test-shell-run.yml"
)
CACHE_SHA="55cc8345863c7cc4c66a329aec7e433d2d1c52a9"

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

@test "kcov cache: key, restore, install, branch check and save sit together after the BATS install in both paths" {
	local wf job
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			run steps_eval "$wf" "$job" \
				"names[names.index('Resolve kcov cache key'):names.index('Resolve kcov cache key') + 5]"
			assert_success
			assert_output "['Resolve kcov cache key', 'Restore kcov build cache', 'Install kcov for coverage', 'Check for a default-branch push', 'Save kcov build cache']"
			run steps_eval "$wf" "$job" "names.index('Install BATS and helpers') < names.index('Resolve kcov cache key')"
			assert_output "True"
		done
	done
}

@test "kcov cache: restore and save are SHA-pinned, keyed by the key step, with no restore-keys anywhere" {
	local wf job name action
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			for name in 'Restore kcov build cache' 'Save kcov build cache'; do
				action=restore
				[[ "$name" == Save* ]] && action=save
				run steps_eval "$wf" "$job" "step('${name}')['uses']"
				assert_output "actions/cache/${action}@${CACHE_SHA}"
				run steps_eval "$wf" "$job" "sorted(step('${name}')['with'])"
				assert_output "['key', 'path']"
				run steps_eval "$wf" "$job" "step('${name}')['with']['key']"
				assert_output '${{ steps.kcov-cache-key.outputs.cache-key }}'
				run steps_eval "$wf" "$job" "step('${name}')['with']['path']"
				assert_output '${{ steps.kcov-cache-key.outputs.stage-dir }}'
				run steps_eval "$wf" "$job" "step('${name}')['continue-on-error']"
				assert_output "True"
			done
			run steps_eval "$wf" "$job" "[s['name'] for s in steps if 'restore-keys' in (s.get('with') or {})]"
			assert_output "[]"
			run steps_eval "$wf" "$job" "[s['uses'] for s in steps if s.get('uses', '').startswith('actions/cache@')]"
			assert_output "[]"
			run steps_eval "$wf" "$job" "step('Restore kcov build cache')['id'] + ' ' + step('Install kcov for coverage')['id']"
			assert_output "kcov-cache-restore install-kcov"
			run steps_eval "$wf" "$job" "step('Restore kcov build cache')['if']"
			assert_output --partial "steps.kcov-cache-key.outputs.cache-key != ''"
			run steps_eval "$wf" "$job" "step('Resolve kcov cache key')['id'] + ' ' + step('Resolve kcov cache key')['env']['STEP']"
			assert_output "kcov-cache-key kcov-cache-key"
			run steps_eval "$wf" "$job" "step('Install kcov for coverage')['env']['KCOV_STAGE_DIR']"
			assert_output '${{ steps.kcov-cache-key.outputs.stage-dir }}'
		done
	done
}

@test "kcov cache: only a default-branch push that missed and staged a build saves" {
	local wf job cond
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			run steps_eval "$wf" "$job" "' '.join(step('Save kcov build cache')['if'].split())"
			assert_success
			cond="$output"
			[[ "$cond" == *"steps.default-branch-push.outputs.default-branch-push == 'true'"* ]]
			[[ "$cond" == *"&& steps.kcov-cache-key.outputs.cache-key != ''"* ]]
			# Expression == ignores case (#1659): the event and ref are compared
			# by the script, never in the save condition.
			[[ "$cond" != *"github.event_name"* && "$cond" != *"github.ref"* ]]
			[[ "$cond" == *"&& steps.kcov-cache-restore.outputs.cache-hit != 'true'"* ]]
			[[ "$cond" == *"&& steps.install-kcov.outputs.stage-ready == 'true'"* ]]
			# No status function: the implicit success() keeps a failed install from saving.
			[[ "$cond" != *"always()"* && "$cond" != *"failure()"* && "$cond" != *"||"* ]]
		done
	done
}

@test "kcov cache: the branch check runs default-branch-push.sh with the default branch through env only" {
	local wf job
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			run steps_eval "$wf" "$job" "step('Check for a default-branch push')['id']"
			assert_output "default-branch-push"
			run steps_eval "$wf" "$job" "step('Check for a default-branch push')['env']"
			assert_output "{'DEFAULT_BRANCH': '\${{ github.event.repository.default_branch }}'}"
			run steps_eval "$wf" "$job" "step('Check for a default-branch push')['run']"
			assert_output "bash .lgtm-ci-tooling/scripts/ci/actions/default-branch-push.sh"
			run steps_eval "$wf" "$job" "step('Check for a default-branch push').get('timeout-minutes')"
			assert_output "1"
			run steps_eval "$wf" "$job" "'continue-on-error' in step('Check for a default-branch push')"
			assert_output "False"
		done
		run steps_eval "$wf" test "step('Check for a default-branch push')['if']"
		assert_output "inputs.coverage && steps.kcov-cache-key.outputs.cache-key != ''"
		run steps_eval "$wf" test-sharded "step('Check for a default-branch push')['if']"
		assert_output "steps.kcov-cache-key.outputs.cache-key != ''"
	done
}

@test "kcov cache: the single-job path keys, restores and saves only for coverage runs" {
	local wf
	for wf in "${WORKFLOWS[@]}"; do
		run steps_eval "$wf" test "step('Resolve kcov cache key')['if']"
		assert_output "inputs.coverage"
		run steps_eval "$wf" test "step('Restore kcov build cache')['if']"
		assert_output "inputs.coverage && steps.kcov-cache-key.outputs.cache-key != ''"
		run steps_eval "$wf" test "step('Save kcov build cache')['if'].startswith('inputs.coverage')"
		assert_output "True"
	done
}

@test "kcov cache: install steps carry timeout-minutes 10 and cache steps 5 in both paths" {
	local wf job name
	for wf in "${WORKFLOWS[@]}"; do
		for job in test test-sharded; do
			for name in 'Install BATS and helpers' 'Install kcov for coverage'; do
				run steps_eval "$wf" "$job" "step('${name}').get('timeout-minutes')"
				assert_output "10"
			done
			for name in 'Restore kcov build cache' 'Save kcov build cache'; do
				run steps_eval "$wf" "$job" "step('${name}').get('timeout-minutes')"
				assert_output "5"
			done
		done
	done
}

@test "kcov cache: the key covers version, commit, patch, recipe, image, OS release and architecture" {
	local lib="${PROJECT_ROOT}/scripts/ci/lib/testing/kcov_cache.sh"
	local release="${BATS_TEST_TMPDIR}/os-release"
	printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$release"
	local commit="a39874f938ce13f7a65f253120d1ec946b349ffe"
	local patch="${PROJECT_ROOT}/scripts/ci/patches/kcov-v43-ansi-c-quotes.patch"
	local recipe
	recipe="$(printf 'recipe' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
	run env OS_RELEASE_FILE="$release" ImageOS=ubuntu24 RUNNER_ARCH=X64 bash -c \
		'source "$1"; kcov_cache_key v43 "$2" "$3" "$4"' _ "$lib" "$commit" "$patch" "$recipe"
	assert_success
	local digest
	digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$patch")"
	assert_output "lgtm-kcov-v43-${commit}-${digest}-r${recipe}-ubuntu24-ubuntu24.04-x64"
}
