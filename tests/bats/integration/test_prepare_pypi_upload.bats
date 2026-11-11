#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for prepare-pypi-upload and PyPI publish split (#269)

load "../../helpers/common"

_no_nested_pypa_publish_in_composites() {
	local scan_path="$1"
	local rc=0

	while IFS= read -r -d '' action; do
		if grep -q 'gh-action-pypi-publish@' "$action"; then
			echo "$action"
			rc=1
		fi
	done < <(find "$scan_path" -path "*/action.yml" -type f -print0)

	return "$rc"
}

@test "composite actions: forbid nested pypa/gh-action-pypi-publish" {
	run _no_nested_pypa_publish_in_composites "${PROJECT_ROOT}/.github/actions"
	assert_success
	refute_output --partial ".github/actions/"
}

@test "prepare-pypi-upload: downloads artifact before validate and metadata" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/actions\/download-artifact@/ { download = NR }
		/STEP: validate-dist/ { validate = NR }
		/id: extract-metadata/ { extract = NR }
		/gh-action-pypi-publish@/ { bad = 1 }
		/attest-build-provenance@/ { bad = 1 }
		END {
			exit !(download > 0 && validate > 0 && extract > 0 &&
				download < validate && validate < extract && !bad)
		}
	' "$action"
	assert_success
}

@test "prepare-pypi-upload: exposes dist-path, validated, and package outputs" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run grep -q 'dist-path:' "$action"
	assert_success
	run grep -q 'validated:' "$action"
	assert_success
	run grep -q 'package-name:' "$action"
	assert_success
	run grep -q 'package-version:' "$action"
	assert_success
	run grep -q 'steps.set-validated.outputs.validated' "$action"
	assert_success
	run grep -q 'steps.extract-metadata.outputs.name' "$action"
	assert_success
	run grep -q 'steps.extract-metadata.outputs.version' "$action"
	assert_success
}

@test "prepare-pypi-upload: validate step uses strict distribution validation" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/Validate distribution/ { in_step = 1; next }
		in_step && /^    - name:/ { in_step = 0 }
		in_step && /STEP: validate-dist/ { step = 1 }
		in_step && /VALIDATE_STRICT: "true"/ { strict = 1 }
		END { exit !(step && strict) }
	' "$action"
	assert_success
}

@test "prepare-pypi-upload: VALIDATE_STRICT is scoped to validate step only" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/Validate distribution/ { in_validate = 1; next }
		in_validate && /^    - name:/ { in_validate = 0 }
		in_validate && /VALIDATE_STRICT: "true"/ { in_validate_strict = 1 }
		!in_validate && /VALIDATE_STRICT: "true"/ { outside_strict = 1 }
		END { exit !(in_validate_strict && !outside_strict) }
	' "$action"
	assert_success
}

@test "prepare-pypi-upload: clones no tooling repository (#1451)" {
	# A literal owner/repo broke forks and mirrors: the step cloned upstream,
	# or failed where upstream is unreachable.
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run grep -nE '^[[:space:]]*repository:|uses: actions/checkout@' "$action"
	assert_failure
	run grep -n 'lgtm-hq/lgtm-ci' "$action"
	assert_failure
}

@test "prepare-pypi-upload: every script step runs from the resolved SCRIPTS_DIR" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run grep -cE '^      run: "\$SCRIPTS_DIR/ci/actions/[a-z-]+\.sh"$' "$action"
	assert_success
	assert_output "5"
	run grep -c '^      run: ' "$action"
	assert_output "6"
}

@test "prepare-pypi-upload: SCRIPTS_DIR resolves inside the repository the action was loaded from" {
	# The runner unpacks an action's repository to _actions/<owner>/<repo>/<ref>.
	local root="${BATS_TEST_TMPDIR}/_actions/mirror-owner/ci-mirror/0123abc"
	local action_dir="${root}/.github/actions/prepare-pypi-upload"
	mkdir -p "$action_dir" "${root}/scripts"
	local step
	step="$(sed -n 's/^      run: bash "\(.*resolve-scripts-dir\.sh\)"$/\1/p' \
		"${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml")"
	[ -n "$step" ]
	# Run this repository's resolver the way the step does, from the mirror path.
	GITHUB_ACTION_PATH="$action_dir" GITHUB_ENV="${BATS_TEST_TMPDIR}/env" \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/resolve-scripts-dir.sh"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/env"
	assert_output "SCRIPTS_DIR=${root}/scripts"
	[ "${step}" = '${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/resolve-scripts-dir.sh' ]
}

@test "prepare-pypi-upload: tooling-ref is kept but deprecated" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/^  tooling-ref:/ { in_input = 1; next }
		in_input && /^  [a-z]/ { in_input = 0 }
		in_input && /deprecationMessage:/ { deprecated = 1 }
		END { exit !deprecated }
	' "$action"
	assert_success
	run grep -F 'inputs.tooling-ref' "$action"
	assert_failure
}
