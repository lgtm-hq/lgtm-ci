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

# Print the `run:` value of every step of an action.yml, one per line, as
# `<line>:<value>`. A block scalar (`run: |`) prints its indicator.
_run_values() {
	awk '/^[[:space:]]*(-[[:space:]]+)?run:/ {
		v = $0
		sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", v)
		printf("%d:%s\n", NR, v)
	}' "$1"
}

# Reasons an action.yml reaches its tooling in a way that breaks forks,
# mirrors, GitHub Enterprise Server or older runners; empty when it is clean.
_tooling_source_violations() {
	local file="$1"

	# `$/` self-repository refs need a server feature and runner >= 2.336.0.
	grep -nF '$/' "$file" | sed 's/^/self-repository ref: /'
	# A literal upstream repository clones upstream from a fork or mirror.
	grep -nE 'lgtm-hq/lgtm-ci' "$file" | sed 's/^/literal upstream repository: /'
	# No checkout at all: the runner already downloaded the tooling.
	grep -nE 'uses:[[:space:]]*["'"'"']?actions/checkout(@|["'"'"']?[[:space:]]*$)' "$file" |
		sed 's/^/tooling checkout: /'
	grep -nE '^[[:space:]]*repository:' "$file" | sed 's/^/repository key: /'
	grep -nE 'git[[:space:]]+clone' "$file" | sed 's/^/git clone: /'
	return 0
}

@test "prepare-pypi-upload: no \$/ ref, no literal upstream repository, no tooling checkout (#1451)" {
	run _tooling_source_violations "${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	assert_success
	refute_output
}

@test "prepare-pypi-upload: the tooling-source guard flags each forbidden form" {
	local fixture="${BATS_TEST_TMPDIR}/action.yml"
	cat >"$fixture" <<'YAML'
runs:
  using: composite
  steps:
    - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      with:
        repository: lgtm-hq/lgtm-ci
        path: .lgtm-ci-tooling
    - uses: $/.github/actions/setup-python
    - shell: bash
      run: git clone https://example.invalid/ci.git .lgtm-ci-tooling
YAML

	run _tooling_source_violations "$fixture"
	assert_output --partial "tooling checkout: 4:"
	assert_output --partial "literal upstream repository: 6:"
	assert_output --partial "repository key: 6:"
	assert_output --partial "self-repository ref: 8:"
	assert_output --partial "git clone: 10:"
}

@test "prepare-pypi-upload: every script step runs from the staged SCRIPTS_DIR" {
	# Shape, not count: the first run: step stages the tooling through the
	# action's own path, and every later one runs a script of the staged tree.
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	local stage='bash "${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/stage-action-tooling.sh"'
	local entry value index=0 staged_scripts=0

	while IFS= read -r entry; do
		value="${entry#*:}"
		if [[ "$index" -eq 0 ]]; then
			[[ "$value" == "$stage" ]] || fail "first run: step is not the staging step: ${entry}"
		elif [[ "$value" =~ ^\"\$SCRIPTS_DIR/ci/actions/[a-z-]+\.sh\"$ ]]; then
			staged_scripts=$((staged_scripts + 1))
		else
			fail "run: step outside the staged SCRIPTS_DIR: ${entry}"
		fi
		index=$((index + 1))
	done < <(_run_values "$action")

	[[ "$staged_scripts" -ge 1 ]]
}

@test "prepare-pypi-upload: the staging step and the staged sibling work from a mirror's _actions layout" {
	# The runner unpacks an action's repository to _actions/<owner>/<repo>/<ref>.
	# Build that layout from this repository under another owner and name, then
	# run the action's own staging command against it.
	local root="${BATS_TEST_TMPDIR}/work/_actions/mirror-owner/ci-mirror/0123abc"
	local workspace="${BATS_TEST_TMPDIR}/work/consumer/consumer"
	local action_yml="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	mkdir -p "${root}/.github" "$workspace"
	cp -R "${PROJECT_ROOT}/.github/actions" "${root}/.github/actions"
	cp -R "${PROJECT_ROOT}/scripts" "${root}/scripts"

	local command
	command="$(_run_values "$action_yml" | head -n 1)"
	command="${command#*:}"
	[[ "$command" == *stage-action-tooling.sh* ]]

	run env GITHUB_ACTION_PATH="${root}/.github/actions/prepare-pypi-upload" \
		GITHUB_WORKSPACE="$workspace" GITHUB_ENV="${BATS_TEST_TMPDIR}/env" \
		TOOLING_REF="" bash -c "$command"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/env"
	assert_output "SCRIPTS_DIR=${workspace}/.lgtm-ci-tooling/scripts"

	# The sibling the action calls exists in the staged tree, and every script
	# it reaches through its own GITHUB_ACTION_PATH resolves inside that tree.
	local sibling
	sibling="$(sed -n 's|^[[:space:]]*uses: \./\(\.lgtm-ci-tooling/\.github/actions/[a-z-]*\)$|\1|p' "$action_yml")"
	[[ -n "$sibling" ]]
	local sibling_dir="${workspace}/${sibling}"
	[[ -f "${sibling_dir}/action.yml" ]]
	local rel found=0
	while IFS= read -r rel; do
		[[ -f "${sibling_dir}/${rel}" ]] || fail "staged sibling cannot reach ${rel}"
		found=$((found + 1))
	done < <(grep -oE '\$GITHUB_ACTION_PATH/[^"]+' "${sibling_dir}/action.yml" |
		sed 's|^\$GITHUB_ACTION_PATH/||' | sort -u)
	[[ "$found" -ge 1 ]]

	# Every script the action runs is present and executable in the staged tree.
	local entry script
	while IFS= read -r entry; do
		script="${entry#*\$SCRIPTS_DIR/}"
		script="${script%\"}"
		[[ -x "${workspace}/.lgtm-ci-tooling/scripts/${script}" ]] ||
			fail "staged script missing or not executable: ${script}"
	done < <(_run_values "$action_yml" | grep -F '$SCRIPTS_DIR/')
}

@test "prepare-pypi-upload: tooling-ref is deprecated and only feeds the mismatch warning" {
	local action="${PROJECT_ROOT}/.github/actions/prepare-pypi-upload/action.yml"
	run awk '
		/^  tooling-ref:/ { in_input = 1; next }
		in_input && /^  [a-z]/ { in_input = 0 }
		in_input && /deprecationMessage:/ { deprecated = 1 }
		END { exit !deprecated }
	' "$action"
	assert_success
	# The only reader is the staging step's TOOLING_REF; it selects nothing.
	run grep -F 'inputs.tooling-ref' "$action"
	assert_success
	assert_output "        TOOLING_REF: \${{ inputs.tooling-ref }}"
}
