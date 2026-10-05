#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for nested `uses:` references inside composite
# actions (#1075).
#
# A composite under .github/actions/ is fetched by consumers with
# `uses: lgtm-hq/lgtm-ci/.github/actions/<name>@<sha>`. GitHub resolves a
# nested `uses: ./...` against the *caller's* workspace, not the action's own
# source, so `./.github/actions/<sibling>` only works when the caller happens
# to have lgtm-ci checked out at the workspace root. Every nested `uses:` in a
# composite must therefore be one of:
#
#   - a SHA-pinned remote action (`owner/repo[/path]@<40-hex>`),
#   - a `docker://` image,
#   - the self-repository form `$/<path>` (resolves to lgtm-ci at the SHA the
#     composite was fetched from), or
#   - a `./.lgtm-ci-tooling/...` path, which is valid only after the composite
#     has itself checked lgtm-ci out there (prepare-pypi-upload pattern); the
#     guard requires a `path: .lgtm-ci-tooling` checkout earlier in the file.

load "../../helpers/common"

# Walk the `runs.steps` list of one action.yml and print one record per step
# that has a `uses:` key, as `<line>:<ref>:<tooling>`:
#
#   line     line of the `uses` key
#   ref      its value, trailing version comment and quotes stripped, folded
#            (`>-` / `|`) values joined onto one line
#   tooling  1 when the step is `actions/checkout@...` AND its `with:` block
#            sets `path: .lgtm-ci-tooling`, else 0
#
# This is a step-structured scan, not a textual grep: keys are only read at the
# step level or inside that step's `with:` mapping, so a `uses` input under
# `with:` is not a step, `path:` only counts under a checkout's `with:`, key
# order inside the step does not matter, the key may be quoted (`"uses":`),
# flow-mapping steps (`- {uses: ..., with: {...}}`) are read, and lines inside
# any other key's block scalar (`run: |`, `description: >`) are skipped.
_composite_steps() {
	local file="$1"

	awk '
		function indent_of(line, prefix) {
			prefix = line
			sub(/[^ \t].*$/, "", prefix)
			return length(prefix)
		}
		function clean(v) {
			sub(/[[:space:]]+#.*$/, "", v)
			sub(/^[>|][+-]?[[:space:]]*/, "", v)
			gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", v)
			return v
		}
		function end_scalar() {
			if (scalar_key == "uses") {
				uses_val = clean(scalar_val)
			} else if (scalar_key == "path" && in_with) {
				path_val = clean(scalar_val)
			}
			scalar_key = ""
		}
		function end_step() {
			end_scalar()
			if (in_step && uses_line) {
				tooling = (uses_val ~ /^actions\/checkout@/ && path_val == ".lgtm-ci-tooling") ? 1 : 0
				printf("%d:%s:%d\n", uses_line, uses_val, tooling)
			}
			in_step = 0
			in_with = 0
			uses_line = 0
			uses_val = ""
			path_val = ""
		}
		# Key name of a mapping entry (`- key:`, `key:`, `"key":`), or "".
		function key_of(line, k) {
			k = line
			if (k !~ /^[[:space:]]*-?[[:space:]]*["'"'"']?[A-Za-z0-9_-]+["'"'"']?:([[:space:]]|$)/) {
				return ""
			}
			sub(/^[[:space:]]*-?[[:space:]]*["'"'"']?/, "", k)
			sub(/["'"'"']?:.*$/, "", k)
			return k
		}
		# Column of the key name itself (after any `- `).
		function key_col(line, k) {
			k = line
			sub(/["'"'"']?[A-Za-z0-9_-]+["'"'"']?:.*$/, "", k)
			return length(k)
		}
		# Value after `key:` on the same line.
		function value_of(line, v) {
			v = line
			sub(/^[[:space:]]*-?[[:space:]]*["'"'"']?[A-Za-z0-9_-]+["'"'"']?:[[:space:]]*/, "", v)
			return v
		}
		function flow_field(line, key, v) {
			v = line
			if (!match(v, "(^|[{,][[:space:]]*)[\"'"'"']?" key "[\"'"'"']?:[[:space:]]*")) {
				return ""
			}
			v = substr(v, RSTART + RLENGTH)
			sub(/[,}].*$/, "", v)
			return clean(v)
		}

		# ---- block scalar of some other key: data, not structure ----
		in_block {
			if ($0 ~ /^[[:space:]]*$/ || indent_of($0) > block_indent) {
				next
			}
			in_block = 0
		}
		# ---- folded/literal value of uses: or with.path: ----
		scalar_key != "" {
			if ($0 ~ /^[[:space:]]*$/) {
				next
			}
			if (indent_of($0) > scalar_col) {
				line = $0
				sub(/^[[:space:]]+/, "", line)
				scalar_val = scalar_val " " line
				next
			}
			end_scalar()
		}

		/^[[:space:]]*steps:[[:space:]]*$/ {
			in_steps = 1
			steps_col = indent_of($0)
			next
		}
		!in_steps { next }
		/^[[:space:]]*$/ { next }
		/^[[:space:]]*#/ { next }
		# Leaving the steps list.
		indent_of($0) <= steps_col {
			end_step()
			in_steps = 0
			next
		}
		# ---- new step ----
		/^[[:space:]]*-([[:space:]]|$)/ {
			end_step()
			in_step = 1
			step_col = indent_of($0)
			if ($0 ~ /^[[:space:]]*-[[:space:]]*[{]/) {
				# Flow mapping on one line.
				v = flow_field($0, "uses")
				if (v != "" || $0 ~ /[{,][[:space:]]*["'"'"']?uses["'"'"']?:/) {
					uses_line = NR
					uses_val = v
				}
				if ($0 ~ /checkout@/) {
					path_val = flow_field($0, "path")
				}
				end_step()
				next
			}
			# `- key: value` — fall through to key handling with the
			# `- ` stripped from the indent computation.
		}
		in_step {
			col = key_col($0)
			k = key_of($0)
			if (k == "") { next }
			# Back at the step'"'"'s own key level ends any `with:` block.
			if (col <= key_level) { in_with = 0 }
			if (!key_level_set || col < key_level) {
				key_level = col
				key_level_set = 1
			}
			v = value_of($0)
			if (col == key_level) {
				if (k == "uses") {
					uses_line = NR
					if (v ~ /^[>|][+-]?[0-9]?[[:space:]]*(#.*)?$/) {
						scalar_key = "uses"; scalar_col = col; scalar_val = ""
					} else {
						uses_val = clean(v)
					}
					next
				}
				if (k == "with") {
					if (v ~ /^[{]/) {
						# Flow `with: {path: x}`.
						path_val = flow_field(v, "path")
					} else {
						in_with = 1
					}
					next
				}
				if (v ~ /^[>|][+-]?[0-9]?[[:space:]]*(#.*)?$/) {
					in_block = 1
					block_indent = col
				}
				next
			}
			if (in_with && k == "path") {
				if (v ~ /^[>|][+-]?[0-9]?[[:space:]]*(#.*)?$/) {
					scalar_key = "path"; scalar_col = col; scalar_val = ""
				} else {
					path_val = clean(v)
				}
				next
			}
			if (v ~ /^[>|][+-]?[0-9]?[[:space:]]*(#.*)?$/) {
				in_block = 1
				block_indent = col
			}
		}
		END { end_step() }
	' "$file"
}

# Print every step `uses:` under .github/actions/**/action.yml as
# `<file>:<line>:<ref>`.
_composite_uses_refs() {
	local scan_path="$1"
	local action rec

	while IFS= read -r -d '' action; do
		while IFS= read -r rec; do
			printf '%s:%s\n' "$action" "${rec%:*}"
		done < <(_composite_steps "$action")
	done < <(find "$scan_path" -path "*/action.yml" -type f -print0 | sort -z)
}

# Line number of the first `actions/checkout@...` step whose `with:` block sets
# `path: .lgtm-ci-tooling`, or 0 when there is none. A `path:` under any other
# step (cache, upload, ...) or outside `with:` does not count.
_tooling_checkout_line() {
	local file="$1"
	local rec line

	while IFS= read -r rec; do
		if [[ "${rec##*:}" == "1" ]]; then
			line="${rec%%:*}"
			echo "$line"
			return 0
		fi
	done < <(_composite_steps "$file")
	echo 0
}

# Classify one ref; echo nothing when allowed, else a reason.
_composite_ref_violation() {
	local ref="$1"
	local file="$2"
	local line="$3"
	local checkout_line

	case "$ref" in
	'$/'*) return 0 ;;
	docker://*) return 0 ;;
	./.lgtm-ci-tooling/*)
		# Only valid once this composite has itself checked lgtm-ci out
		# there; otherwise it resolves against the caller just like `./`.
		checkout_line="$(_tooling_checkout_line "$file")"
		if [[ "$checkout_line" -eq 0 || "$checkout_line" -gt "$line" ]]; then
			echo "no preceding checkout with path: .lgtm-ci-tooling in this action"
		fi
		return 0
		;;
	./*)
		echo "workspace-relative ref resolves against the caller, not lgtm-ci"
		return 0
		;;
	esac

	if [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@[:space:]]+)?@[0-9a-f]{40}$ ]]; then
		return 0
	fi

	echo "not a SHA-pinned remote, docker://, \$/ self-repository, or .lgtm-ci-tooling ref"
}

_composite_reference_violations() {
	local scan_path="$1"
	local entry file line ref reason rc=0

	while IFS= read -r entry; do
		file="${entry%%:*}"
		entry="${entry#*:}"
		line="${entry%%:*}"
		ref="${entry#*:}"
		reason="$(_composite_ref_violation "$ref" "$file" "$line")"
		if [[ -n "$reason" ]]; then
			echo "${file}:${line}: uses: ${ref} (${reason})"
			rc=1
		fi
	done < <(_composite_uses_refs "$scan_path")

	return "$rc"
}

@test "composite actions: no nested uses: ./.github/actions/ references" {
	_workspace_relative_refs() {
		_composite_uses_refs "$1" | grep -E ':\./\.github/actions/'
	}
	run _workspace_relative_refs "${PROJECT_ROOT}/.github/actions"
	assert_failure
	refute_output
}

@test "composite actions: every nested uses: is SHA-pinned remote, docker://, \$/, or .lgtm-ci-tooling" {
	run _composite_reference_violations "${PROJECT_ROOT}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: runner actions reach their setup siblings via \$/ self-repository refs" {
	local -A expected=(
		[run-pytest]='$/.github/actions/setup-python'
		[run-vitest]='$/.github/actions/setup-node'
		[run-playwright]='$/.github/actions/setup-node'
		[run-lighthouse]='$/.github/actions/setup-node'
	)
	local name
	for name in "${!expected[@]}"; do
		run _composite_uses_refs "${PROJECT_ROOT}/.github/actions/${name}"
		assert_success
		assert_output --partial ":${expected[$name]}"
	done
}

@test "composite actions: guard flags a workspace-relative sibling ref" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/broken"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Broken composite
runs:
  using: composite
  steps:
    - name: Setup Python
      uses: ./.github/actions/setup-python
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "broken/action.yml:7: uses: ./.github/actions/setup-python"
	assert_output --partial "resolves against the caller"
}

@test "composite actions: guard flags an unpinned or tag-pinned remote ref" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/tagged"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Tagged composite
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "tagged/action.yml:6: uses: actions/checkout@v4"
	assert_output --partial "tagged/action.yml:7: uses: actions/setup-node"
}

@test "composite actions: guard accepts \$/, docker://, .lgtm-ci-tooling, and folded SHA refs" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/ok"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Clean composite
runs:
  using: composite
  steps:
    - uses: $/.github/actions/setup-node
    - uses: docker://alpine:3.20
    - uses: "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd" # v6.0.2
      with:
        repository: lgtm-hq/lgtm-ci
        path: .lgtm-ci-tooling
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
    - uses: >-
        actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
      with:
        name: report
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: extractor ignores uses: inside run: and description: block scalars" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/prose"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Prose mentions
description: >
  Example: uses: ./.github/actions/in-description
runs:
  using: composite
  steps:
    - run: |
        echo "uses: ./.github/actions/in-run"
      shell: bash
    - uses: $/.github/actions/setup-node
YAML

	run _composite_uses_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_output "${fixture_dir}/action.yml:11:\$/.github/actions/setup-node"
}

@test "composite actions: extractor reads flow-mapping steps and commented fold indicators" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/flow"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Flow and folded
runs:
  using: composite
  steps:
    - {name: Setup, uses: ./.github/actions/setup-python, with: {python-version: "3.12"}}
    - uses: >- # pinned
        actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
YAML

	run _composite_uses_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_line --index 0 "${fixture_dir}/action.yml:6:./.github/actions/setup-python"
	assert_line --index 1 "${fixture_dir}/action.yml:7:actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "flow/action.yml:6: uses: ./.github/actions/setup-python"
	refute_output --partial "actions/checkout@"
}

@test "composite actions: extractor reads a quoted uses key and ignores a uses input under with:" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/quoted"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Quoted key and uses input
runs:
  using: composite
  steps:
    - "uses": ./.github/actions/setup-python
    - uses: $/.github/actions/setup-node
      with:
        uses: ./.github/actions/not-a-step
        node-version: "22"
YAML

	run _composite_uses_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_line --index 0 "${fixture_dir}/action.yml:6:./.github/actions/setup-python"
	assert_line --index 1 "${fixture_dir}/action.yml:7:\$/.github/actions/setup-node"
	refute_output --partial "not-a-step"
}

@test "composite actions: tooling checkout is recognised with with: before uses:" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/with-first"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: with before uses
runs:
  using: composite
  steps:
    - name: Checkout lgtm-ci tooling
      with:
        repository: lgtm-hq/lgtm-ci
        path: .lgtm-ci-tooling
      uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: a path: .lgtm-ci-tooling outside a checkout's with: block does not count" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/leaked-path"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Checkout without tooling path, then a run step mentioning the path
runs:
  using: composite
  steps:
    - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      with:
        persist-credentials: false
    - name: Something else
      shell: bash
      env:
        path: .lgtm-ci-tooling
      run: |
        path: .lgtm-ci-tooling
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "leaked-path/action.yml:15: uses: ./.lgtm-ci-tooling/.github/actions/setup-python"
	assert_output --partial "no preceding checkout with path: .lgtm-ci-tooling"
}

@test "composite actions: extractor covers every uses: step in the real tree" {
	local extracted grepped
	extracted="$(_composite_uses_refs "${PROJECT_ROOT}/.github/actions" | wc -l | tr -d ' ')"
	grepped="$(grep -rhE '^[[:space:]]*-?[[:space:]]*"?uses"?:' --include=action.yml "${PROJECT_ROOT}/.github/actions" | wc -l | tr -d ' ')"
	[[ "$extracted" -ge 1 ]]
	[[ "$extracted" -eq "$grepped" ]]
}

@test "composite actions: guard flags a .lgtm-ci-tooling ref without a preceding tooling checkout" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/no-checkout"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Tooling ref without checkout
runs:
  using: composite
  steps:
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
    - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      with:
        repository: lgtm-hq/lgtm-ci
        path: .lgtm-ci-tooling
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "no-checkout/action.yml:6: uses: ./.lgtm-ci-tooling/.github/actions/setup-python"
	assert_output --partial "no preceding checkout with path: .lgtm-ci-tooling"
}

@test "composite actions: guard recognises a folded actions/checkout as the tooling checkout" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/folded-checkout"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Folded checkout
runs:
  using: composite
  steps:
    - name: Checkout lgtm-ci tooling
      uses: >-
        actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
      with:
        repository: lgtm-hq/lgtm-ci
        path: .lgtm-ci-tooling
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: guard ignores a path: .lgtm-ci-tooling that is not under actions/checkout" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/cache-path"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Tooling path on a non-checkout step
runs:
  using: composite
  steps:
    - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
      with:
        path: .lgtm-ci-tooling
        key: tooling
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "cache-path/action.yml:10: uses: ./.lgtm-ci-tooling/.github/actions/setup-python"
	assert_output --partial "no preceding checkout with path: .lgtm-ci-tooling"
}
