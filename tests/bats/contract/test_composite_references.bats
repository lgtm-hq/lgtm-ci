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

# Print every `uses:` value under .github/actions/**/action.yml as
# `<file>:<line>:<ref>`, with the trailing version comment and surrounding
# quotes stripped. Folded/multi-line values are joined onto one line so a
# `>-` ref cannot hide from the checks below.
_composite_uses_refs() {
	local scan_path="$1"

	while IFS= read -r -d '' action; do
		awk -v file="$action" '
			function indent_of(line, prefix) {
				prefix = line
				sub(/[^ \t].*$/, "", prefix)
				return length(prefix)
			}
			function flush() {
				if (!in_uses) {
					return
				}
				sub(/[[:space:]]+#.*$/, "", value)
				sub(/^[>|][+-]?[[:space:]]*/, "", value)
				gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", value)
				printf("%s:%d:%s\n", file, uses_line, value)
				in_uses = 0
			}
			/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/ {
				flush()
				in_uses = 1
				uses_line = NR
				# Column of the `uses` key itself, so a sibling key such as
				# `with:` under a `- uses:` item ends the value.
				prefix = $0
				sub(/uses:.*$/, "", prefix)
				uses_indent = length(prefix)
				value = $0
				sub(/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/, "", value)
				next
			}
			in_uses {
				if ($0 ~ /^[[:space:]]*$/) {
					next
				}
				if (indent_of($0) <= uses_indent) {
					flush()
					next
				}
				line = $0
				sub(/^[[:space:]]+/, "", line)
				value = value " " line
			}
			END { flush() }
		' "$action"
	done < <(find "$scan_path" -path "*/action.yml" -type f -print0 | sort -z)
}

# Line number of the first `path: .lgtm-ci-tooling` that belongs to an
# `actions/checkout@...` step's `with:` block, or 0 when there is none. A
# `path:` under any other step (cache, upload, ...) does not count.
_tooling_checkout_line() {
	local file="$1"
	awk '
		/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/ {
			in_checkout = ($0 ~ /uses:[[:space:]]*["'"'"']?actions\/checkout@/)
			next
		}
		in_checkout && /^[[:space:]]*path:[[:space:]]*["'"'"']?\.lgtm-ci-tooling["'"'"']?[[:space:]]*(#.*)?$/ {
			print NR
			found = 1
			exit
		}
		END { if (!found) print 0 }
	' "$file"
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
	run grep -rn --include=action.yml -E \
		'^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*["'"'"']?\./\.github/actions/' \
		"${PROJECT_ROOT}/.github/actions"
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
