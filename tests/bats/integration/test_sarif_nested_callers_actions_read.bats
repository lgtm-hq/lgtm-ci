#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract test (#1310). GitHub validates a reusable-workflow call
#          tree at startup: a job that calls a nested reusable with an explicit
#          `permissions:` block must grant every permission the nested
#          workflow's jobs request, or the whole run is a startup_failure.
#          After the SARIF-uploading jobs gained `actions: read`, every
#          intermediate job that calls them with an explicit block must grant
#          it too (seen on the external fixture's Docker callers).

load "../../helpers/common"

# Print "<workflow>:<job> -> <nested>" for every job that calls a nested
# reusable workflow with an explicit permissions block lacking `actions: read`
# while the nested workflow has a job declaring `actions: read`.
_nested_callers_missing_actions_read() {
	local workflow="$1" dir
	dir="$(dirname "$workflow")"
	awk -v wf="$(basename "$workflow")" -v dir="$dir" '
		function flush(   cmd, line) {
			if (job == "" || uses == "" || !has_perms || has_actions) return
			line = 0
			cmd = "grep -cE \"^      actions:[[:space:]]+(read|write)\" " dir "/" uses
			cmd | getline line
			close(cmd)
			if (line + 0 > 0) print wf ":" job " -> " uses
		}
		/^[a-z_-]+:/ { flush(); job = ""; in_jobs = ($0 ~ /^jobs:/); uses = ""; has_perms = 0; has_actions = 0; in_perms = 0; next }
		in_jobs && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
			flush()
			job = $1; sub(/:$/, "", job)
			uses = ""; has_perms = 0; has_actions = 0; in_perms = 0
			next
		}
		/^    uses: \.\/\.github\/workflows\// { uses = $2; sub(/^\.\/\.github\/workflows\//, "", uses); next }
		/^    permissions:[[:space:]]*$/ { in_perms = 1; has_perms = 1; next }
		in_perms && /^      actions:[[:space:]]+(read|write)/ { has_actions = 1; next }
		in_perms && /^      (#|[a-z-]+:)/ { next }
		in_perms { in_perms = 0 }
		END { flush() }
	' "$workflow"
}

@test "nested callers: the detector flags a job calling an actions: read workflow without granting it" {
	local dir="${BATS_TEST_TMPDIR}/wf"
	mkdir -p "$dir"
	cat >"${dir}/inner.yml" <<'YAML'
---
on:
  workflow_call:
jobs:
  scan:
    permissions:
      contents: read
      actions: read
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
	cat >"${dir}/outer.yml" <<'YAML'
---
on:
  workflow_call:
jobs:
  publish:
    uses: ./.github/workflows/inner.yml
    permissions:
      contents: read
      packages: write
  fine:
    uses: ./.github/workflows/inner.yml
    permissions:
      contents: read
      actions: read
  inherit:
    uses: ./.github/workflows/inner.yml
YAML
	run _nested_callers_missing_actions_read "${dir}/outer.yml"
	assert_success
	assert_output "outer.yml:publish -> inner.yml"
}

@test "nested callers: every reusable job calling an actions: read workflow with an explicit block grants it" {
	local offenders=""
	for wf in "${PROJECT_ROOT}"/.github/workflows/reusable-*.yml; do
		offenders+="$(_nested_callers_missing_actions_read "$wf")"
	done
	if [[ -n "$offenders" ]]; then
		echo "nested callers lacking actions: read:"
		echo "$offenders"
		return 1
	fi
}
