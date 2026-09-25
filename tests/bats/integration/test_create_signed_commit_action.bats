#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Wiring contract tests for the create-signed-commit composite action (#1042)

load "../../helpers/common"

ACTION="${PROJECT_ROOT}/.github/actions/create-signed-commit/action.yml"
SCRIPT_REL="scripts/ci/git/create-signed-commit.sh"

# Print "ENV_NAME=expression" for every env entry of the step with the given id.
_step_env() {
	local step_id="$1"
	awk -v id="$step_id" '
		/^    - name:/ { in_step = 0; in_env = 0 }
		$0 ~ "^      id: " id "$" { in_step = 1; next }
		in_step && /^      env:/ { in_env = 1; next }
		in_step && in_env && /^      [a-z]/ { in_env = 0 }
		in_step && in_env && /^        [A-Z_]+:/ {
			line = $0
			sub(/^ +/, "", line)
			key = line
			sub(/:.*/, "", key)
			val = line
			sub(/^[A-Z_]+: */, "", val)
			print key "=" val
		}
	' "$ACTION"
}

@test "create-signed-commit action: runs the committed, executable script" {
	[ -x "${PROJECT_ROOT}/${SCRIPT_REL}" ]
	run grep -F 'run: "$SCRIPTS_DIR/ci/git/create-signed-commit.sh"' "$ACTION"
	assert_success
	run grep -F 'GITHUB_ACTION_PATH}/../../../scripts' "$ACTION"
	assert_success
}

@test "create-signed-commit action: maps every input to the script env" {
	run _step_env commit
	assert_success
	assert_output --partial 'GH_TOKEN=${{ inputs.token }}'
	assert_output --partial 'COMMIT_REPOSITORY=${{ inputs.repository }}'
	assert_output --partial 'COMMIT_BRANCH=${{ inputs.branch }}'
	assert_output --partial 'COMMIT_MODE=${{ inputs.mode }}'
	assert_output --partial 'COMMIT_EXPECTED_HEAD=${{ inputs.expected-head }}'
	assert_output --partial 'COMMIT_BASE=${{ inputs.base }}'
	assert_output --partial 'COMMIT_MESSAGE=${{ inputs.message }}'
	assert_output --partial 'COMMIT_BODY=${{ inputs.body }}'
	assert_output --partial 'COMMIT_FILES=${{ inputs.files }}'
	assert_output --partial 'COMMIT_DELETE=${{ inputs.delete }}'
}

@test "create-signed-commit action: script reads every env var the action sets" {
	local script="${PROJECT_ROOT}/${SCRIPT_REL}"
	local name
	while IFS='=' read -r name _; do
		grep -qF "$name" "$script" || {
			echo "script does not read ${name}"
			return 1
		}
	done < <(_step_env commit)
}

@test "create-signed-commit action: no expression interpolation inside run blocks" {
	run awk '
		/^      run:/ { in_run = 1; if ($0 ~ /\$\{\{/) bad = 1; next }
		/^      [a-z-]+:/ || /^    - / { in_run = 0 }
		in_run && /\$\{\{/ { bad = 1 }
		END { exit bad }
	' "$ACTION"
	assert_success
}

@test "create-signed-commit action: exposes commit-sha and commit-url outputs" {
	run grep -F 'value: ${{ steps.commit.outputs.commit-sha }}' "$ACTION"
	assert_success
	run grep -F 'value: ${{ steps.commit.outputs.commit-url }}' "$ACTION"
	assert_success
}

@test "create-signed-commit action: defaults to append mode and the current repository" {
	run awk '
		/^  mode:/ { in_mode = 1; next }
		/^  repository:/ { in_repo = 1; next }
		/^  [a-z-]+:/ { in_mode = 0; in_repo = 0 }
		in_mode && /default: "append"/ { mode_ok = 1 }
		in_repo && /default: \$\{\{ github.repository \}\}/ { repo_ok = 1 }
		END { exit !(mode_ok && repo_ok) }
	' "$ACTION"
	assert_success
}

@test "create-signed-commit action: listed in the actions index and README" {
	run grep -F '`create-signed-commit`' "${PROJECT_ROOT}/docs/actions/README.md"
	assert_success
	run grep -F 'create-signed-commit' "${PROJECT_ROOT}/.github/actions/README.md"
	assert_success
	[ -f "${PROJECT_ROOT}/.github/actions/create-signed-commit/README.md" ]
}
