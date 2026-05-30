#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for composite action references (#253)

load "../../helpers/common"

_forbidden_dynamic_lgtm_ci_uses() {
	local scan_path="$1"

	while IFS= read -r -d '' action; do
		awk -v file="$action" '
			function indent_of(line, prefix) {
				prefix = line
				sub(/[^ \t].*$/, "", prefix)
				return length(prefix)
			}
			function check(line, clean) {
				clean = line
				sub(/[[:space:]]+#.*/, "", clean)
				if (clean ~ /lgtm-hq\/lgtm-ci\/.*@\$\{\{/) {
					printf("%s:%d:%s\n", file, NR, line)
					found = 1
				}
			}
			/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/ {
				in_uses = 1
				uses_indent = indent_of($0)
				check($0)
				next
			}
			in_uses {
				if ($0 ~ /^[[:space:]]*$/) {
					next
				}
				current_indent = indent_of($0)
				if (current_indent <= uses_indent && $0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:/) {
					in_uses = 0
				} else {
					check($0)
				}
			}
			END {
				exit found
			}
		' "$action"
	done < <(find "$scan_path" -path "*/action.yml" -type f -print0)
}

@test "composite actions: forbid dynamic lgtm-ci remote uses refs" {
	run _forbidden_dynamic_lgtm_ci_uses "${PROJECT_ROOT}/.github/actions"
	assert_success
	refute_output --partial "lgtm-hq/lgtm-ci/"
}

@test "composite actions: guard catches folded dynamic lgtm-ci uses refs" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/broken"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Broken composite
runs:
  using: composite
  steps:
    - name: Setup Python
      uses: >-
        lgtm-hq/lgtm-ci/.github/actions/setup-python@${{
        inputs.tooling-ref != '' && inputs.tooling-ref || github.action_ref }}
YAML

	run _forbidden_dynamic_lgtm_ci_uses "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "lgtm-hq/lgtm-ci/.github/actions/setup-python@\${{"
}

@test "upload-pypi-oidc: checks out lgtm-ci tooling before local setup-python" {
	local action="${PROJECT_ROOT}/.github/actions/upload-pypi-oidc/action.yml"
	run awk '
		/Checkout lgtm-ci tooling/ { checkout = NR }
		/path: .lgtm-ci-tooling/ { path = NR }
		/sparse-checkout-cone-mode: true/ { cone = NR }
		/SCRIPTS_DIR=\$\{GITHUB_WORKSPACE\}\/.lgtm-ci-tooling\/scripts/ { scripts = NR }
		/uses: \.\/.lgtm-ci-tooling\/.github\/actions\/setup-python/ { setup = NR }
		END {
			exit !(checkout > 0 && path > checkout && cone > path &&
				scripts > cone && setup > scripts)
		}
	' "$action"
	assert_success
}
