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

@test "prepare-pypi-upload: sparse checkout includes actions and scripts" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/sparse-checkout: \|/ { in_sparse = 1; next }
		in_sparse && /^        [^ ]/ { in_sparse = 0 }
		in_sparse && /\.github\/actions\// { actions = 1 }
		in_sparse && /scripts\/ci\// { scripts = 1 }
		END { exit !(actions && scripts) }
	' "$action"
	assert_success
}
