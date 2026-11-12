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
#   - a `docker://` image, or
#   - a `./.lgtm-ci-tooling/...` path, which is valid only after the composite
#     has itself put lgtm-ci there: either by staging the copy the runner
#     downloaded (`stage-action-tooling.sh`, the prepare-pypi-upload pattern,
#     #1451) or by a `path: .lgtm-ci-tooling` checkout. The guard requires one
#     of the two earlier in the file.
#
# The self-repository form `$/<path>` is rejected (#1469): GitHub Enterprise
# Server and self-hosted runners older than 2.336.0 cannot resolve it, and
# lgtm-ci must run on both.

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
		# ---- one-line flow mapping `- {k: v, with: {k: v}, ...}` ----
		# A small tokenizer with YAML quoting rules: a quote opens a scalar
		# only at the start of a key or value; a backslash escapes inside
		# double quotes and a doubled quote escapes inside single quotes; an
		# apostrophe inside a plain scalar is text; braces inside quotes are
		# text. Fills
		# FT[key] with the step'"'"'s own fields and FW[key] with the fields of
		# `with: {...}`. Deeper nesting is skipped. Keys are unquoted; values
		# are passed through clean().
		function flow_parse(line, v, n, i, c, depth, state, key, val, q, k) {
			delete FT
			delete FW
			v = line
			sub(/^[[:space:]]*-[[:space:]]*/, "", v)
			n = length(v)
			depth = 0
			state = "key"
			key = ""
			val = ""
			q = ""
			for (i = 1; i <= n; i++) {
				c = substr(v, i, 1)
				if (q != "") {
					# Inside a quoted scalar.
					if (q == "\"" && c == "\\" && i < n) {
						val = val substr(v, i + 1, 1)
						i++
						continue
					}
					if (c == q) {
						if (q == "'"'"'" && substr(v, i + 1, 1) == "'"'"'") {
							val = val c
							i++
							continue
						}
						q = ""
						continue
					}
					val = val c
					continue
				}
				if (state == "key" && c ~ /[[:space:],]/) {
					continue
				}
				if (state == "key" && c == "}") {
					depth--
					if (depth < 2) with_mode = 0
					continue
				}
				if (state == "key" && c == "{") {
					depth++
					continue
				}
				if (state == "key") {
					# Read a key up to ':'.
					key = ""
					if (c == "\"" || c == "'"'"'") {
						q = c
						state = "qkey"
						val = ""
						continue
					}
					while (i <= n && substr(v, i, 1) != ":") {
						key = key substr(v, i, 1)
						i++
					}
					gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
					state = "value"
					val = ""
					continue
				}
				if (state == "qkey") {
					# Closed quote reached: `val` holds the key; expect ':'.
					key = val
					val = ""
					while (i <= n && substr(v, i, 1) != ":") i++
					state = "value"
					continue
				}
				if (state == "value") {
					if (c == " " && val == "") continue
					if (val == "" && (c == "\"" || c == "'"'"'")) {
						q = c
						state = "qvalue"
						continue
					}
					if (val == "" && c == "{") {
						# Nested mapping: only `with` is read.
						depth++
						if (depth == 2 && key == "with") {
							with_mode = 1
						}
						state = "key"
						continue
					}
					if (c == "," || c == "}") {
						gsub(/[[:space:]]+$/, "", val)
						store(depth, key, clean(val))
						state = "key"
						if (c == "}") {
							depth--
							if (depth < 2) with_mode = 0
						}
						continue
					}
					val = val c
					continue
				}
				if (state == "qvalue") {
					# Quote closed; `val` is the full scalar.
					store(depth, key, val)
					state = "key"
					if (c == "}") {
						depth--
						if (depth < 2) with_mode = 0
					}
					continue
				}
			}
			if (state == "value" && key != "") {
				gsub(/[[:space:]]+$/, "", val)
				store(depth, key, clean(val))
			}
		}
		function store(depth, key, val) {
			if (depth == 1) {
				FT[key] = val
				FT_HAS[key] = 1
			} else if (depth == 2 && with_mode) {
				FW[key] = val
			}
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
			# The step'"'"'s key column is learned from its first key, which may
			# be on this line (`- key:`) or the next (bare `-`).
			key_level_set = 0
			if ($0 ~ /^[[:space:]]*-[[:space:]]*[{]/) {
				# Flow mapping on one line: the step'"'"'s own keys come from the
				# top level and `path` only from its `with: {...}` group.
				flow_parse($0)
				if ("uses" in FT_HAS) {
					uses_line = NR
					uses_val = FT["uses"]
				}
				if ("path" in FW) {
					path_val = FW["path"]
				}
				delete FT_HAS
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
			if (!key_level_set) {
				key_level = col
				key_level_set = 1
			}
			# Back at the step'"'"'s own key level ends any `with:` block.
			if (col <= key_level) { in_with = 0 }
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
						# Flow `with: {path: x}` under a block-style step.
						flow_parse("{with: " v "}")
						if ("path" in FW) path_val = FW["path"]
						delete FT_HAS
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

# Line number of the first step that stages the action's own repository into
# `.lgtm-ci-tooling`, or 0 when there is none. Only the exact step form counts:
# a `run:` key whose whole value invokes stage-action-tooling.sh through the
# action's own downloaded path. A mention inside another step's block scalar
# is indented text without that `run:` key and does not match.
_tooling_stage_line() {
	local file="$1"
	local line

	line="$(grep -nE \
		'^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bash "\$\{GITHUB_ACTION_PATH\}/\.\./\.\./\.\./scripts/ci/actions/stage-action-tooling\.sh"[[:space:]]*$' \
		"$file" | head -n 1 | cut -d: -f1)"
	echo "${line:-0}"
}

# Classify one ref; echo nothing when allowed, else a reason.
_composite_ref_violation() {
	local ref="$1"
	local file="$2"
	local line="$3"
	local checkout_line stage_line

	case "$ref" in
	'$/'*)
		echo "\$/ self-repository ref is unavailable on GHES and self-hosted runners older than 2.336.0 (#1469)"
		return 0
		;;
	docker://*) return 0 ;;
	./.lgtm-ci-tooling/*)
		# Only valid once this composite has itself staged or checked lgtm-ci
		# out there; otherwise it resolves against the caller just like `./`.
		stage_line="$(_tooling_stage_line "$file")"
		if [[ "$stage_line" -gt 0 && "$stage_line" -lt "$line" ]]; then
			return 0
		fi
		checkout_line="$(_tooling_checkout_line "$file")"
		if [[ "$checkout_line" -eq 0 || "$checkout_line" -gt "$line" ]]; then
			echo "no preceding checkout with path: .lgtm-ci-tooling or stage-action-tooling.sh step in this action"
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

	echo "not a SHA-pinned remote, docker://, or .lgtm-ci-tooling ref"
}

# Print every `$/` occurrence in .github/actions/**/action.yml as
# `<file>:<line>:<text>`; fail when there is none. Grep-style on purpose, so a
# folded, flow-mapping or otherwise unusual `uses:` cannot slip past (#1469).
_self_repository_refs() {
	local scan_path="$1"

	find "$scan_path" -path "*/action.yml" -type f -print0 | sort -z |
		xargs -0 grep -nF '$/' /dev/null
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

@test "composite actions: every nested uses: is SHA-pinned remote, docker://, or .lgtm-ci-tooling" {
	run _composite_reference_violations "${PROJECT_ROOT}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: no action uses a \$/ self-repository ref (#1469)" {
	run _self_repository_refs "${PROJECT_ROOT}/.github/actions"
	# grep exits 1 for "no match"; 2 (an error) must not pass as clean.
	assert_equal "$status" 1
	refute_output
}

@test "composite actions: \$/ scan and guard both flag a self-repository ref" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/self-ref"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Self-reference
runs:
  using: composite
  steps:
    - name: Setup Python
      uses: $/.github/actions/setup-python
YAML

	run _self_repository_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_output "${fixture_dir}/action.yml:7:      uses: \$/.github/actions/setup-python"

	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "self-ref/action.yml:7: uses: \$/.github/actions/setup-python"
	assert_output --partial "unavailable on GHES"
}

# Compare run-pytest's leading steps with setup-python's, step by step, with
# setup-python's input defaults substituted (#1469).
_inlined_setup_python_check() {
	"$PY" "${PROJECT_ROOT}/tests/helpers/inlined_setup_python_check.py" "$1" "$2"
}

# Copy both actions into the test tmpdir for a mutation; sets SETUP and PYTEST.
_copy_setup_actions() {
	SETUP="${BATS_TEST_TMPDIR}/setup-python.yml"
	PYTEST="${BATS_TEST_TMPDIR}/run-pytest.yml"
	cp "${PROJECT_ROOT}/.github/actions/setup-python/action.yml" "$SETUP"
	cp "${PROJECT_ROOT}/.github/actions/run-pytest/action.yml" "$PYTEST"
}

@test "composite actions: run-pytest inlines setup-python's steps exactly (#1469)" {
	require_python_yaml
	run _composite_uses_refs "${PROJECT_ROOT}/.github/actions/run-pytest"
	assert_success
	refute_output --partial "setup-python"
	run _inlined_setup_python_check \
		"${PROJECT_ROOT}/.github/actions/setup-python/action.yml" \
		"${PROJECT_ROOT}/.github/actions/run-pytest/action.yml"
	assert_success
	refute_output
}

@test "composite actions: inlined-setup check flags a step calling the wrong script" {
	require_python_yaml
	_copy_setup_actions
	"$PY" - "$PYTEST" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "STEP: deps\n        EXTRAS: \"\"\n      run: bash \"$GITHUB_ACTION_PATH/../../../scripts/ci/actions/setup-python.sh\""
assert old in s
p.write_text(s.replace(old, old.replace("setup-python.sh", "run-pytest.sh")))
PY
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Install dependencies): run:"
}

@test "composite actions: inlined-setup check flags a hard-coded PYTHON_VERSION" {
	require_python_yaml
	_copy_setup_actions
	sed -i.bak 's/PYTHON_VERSION: \${{ inputs.python-version }}/PYTHON_VERSION: "3.11"/' "$PYTEST"
	run grep -c 'PYTHON_VERSION: "3.11"' "$PYTEST"
	assert_output "1"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Setup Python): env:"
}

@test "composite actions: inlined-setup check flags a changed cache key" {
	require_python_yaml
	_copy_setup_actions
	sed -i.bak "s|'\*\*/uv.lock') }}|'**/uv.lock', '**/setup.py') }}|" "$PYTEST"
	run grep -c "setup.py') }}" "$PYTEST"
	assert_output "1"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Cache uv dependencies): with:"
}

@test "composite actions: inlined-setup check flags a step added to setup-python" {
	require_python_yaml
	_copy_setup_actions
	"$PY" - "$SETUP" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
anchor = "    - name: Install dependencies\n"
assert anchor in s
step = (
    "    - name: Prune cache\n"
    "      shell: bash\n"
    "      env:\n"
    "        STEP: prune\n"
    '      run: bash "$GITHUB_ACTION_PATH/../../../scripts/ci/actions/setup-python.sh"\n\n'
)
p.write_text(s.replace(anchor, step + anchor))
PY
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "STEP"
	assert_output --partial "prune"
}

@test "composite actions: inlined-setup check flags a changed setup-python default" {
	require_python_yaml
	_copy_setup_actions
	sed -i.bak '/^  install-extras:/,/^  [a-z]/ s/default: ""/default: "dev"/' "$SETUP"
	run grep -c 'default: "dev"' "$SETUP"
	assert_output "1"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "EXTRAS"
}

# Rewrite a copied action with a Python snippet: $1 file, $2 old, $3 new.
_rewrite_once() {
	"$PY" - "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
assert text.count(old) == 1, f"{old!r} occurs {text.count(old)} times"
path.write_text(text.replace(old, new))
PY
}

@test "composite actions: inlined-setup check flags a step removed from setup-python" {
	require_python_yaml
	_copy_setup_actions
	"$PY" - "$SETUP" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
start = s.index("    - name: Install dependencies\n")
end = s.index("\nbranding:")
p.write_text(s[:start].rstrip() + "\n" + s[end:])
PY
	run grep -c 'STEP: deps' "$SETUP"
	assert_output "0"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Install dependencies): setup-equivalent step after the 5-step block"
}

@test "composite actions: inlined-setup check flags a setup-python step disabled by its default" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$SETUP" "if: inputs.install-dependencies == 'true'" \
		"if: inputs.install-dependencies == 'false'"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Install dependencies): setup-equivalent step after the 5-step block"
}

@test "composite actions: inlined-setup check fails closed on a dynamic hashFiles argument" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$PYTEST" "'**/uv.lock') }}" "'**/uv.lock', inputs.test-path) }}"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output "unsupported: non-literal hashFiles argument 'inputs.test-path'"
}

@test "composite actions: inlined-setup check flags a changed step id" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$PYTEST" "      id: cache" "      id: uv-cache"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "(Cache uv dependencies): id: expected 'cache', got 'uv-cache'"
}

@test "composite actions: inlined-setup check evaluates equivalent if: rewrites" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$SETUP" "if: inputs.cache == 'true'" "if: \${{ inputs.cache == 'true' }}"
	_rewrite_once "$SETUP" "if: inputs.install-dependencies == 'true'" \
		"if: inputs.install-dependencies != 'false'"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_success
	refute_output
}

@test "composite actions: inlined-setup check fails closed on an if: beyond inputs" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$SETUP" "if: inputs.cache == 'true'" \
		"if: inputs.cache == 'true' && steps.uv-version.outputs.version != ''"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "unsupported: if:"
	assert_output --partial "reads more than inputs"
}

@test "composite actions: Node runners pin their toolchain actions directly and gate Bun/pnpm on package-manager" {
	# The Bun-only setup-node sibling is gone from the Node runners (#1077):
	# each pins actions/setup-node, oven-sh/setup-bun and pnpm/action-setup
	# itself, so npm consumers never get Bun on the runner.
	local name
	for name in run-vitest run-playwright run-lighthouse; do
		run _composite_uses_refs "${PROJECT_ROOT}/.github/actions/${name}"
		assert_success
		refute_output --partial "setup-node'"
		refute_output --partial ':$/.github/actions/setup-node'
		assert_output --regexp ':actions/setup-node@[0-9a-f]{40}'
		assert_output --regexp ':oven-sh/setup-bun@[0-9a-f]{40}'
		assert_output --regexp ':pnpm/action-setup@[0-9a-f]{40}'
		run grep -c "if: inputs.package-manager == 'bun'" "${PROJECT_ROOT}/.github/actions/${name}/action.yml"
		assert_output "1"
		run grep -c "if: inputs.package-manager == 'pnpm'" "${PROJECT_ROOT}/.github/actions/${name}/action.yml"
		assert_output "1"
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

@test "composite actions: guard accepts docker://, .lgtm-ci-tooling, and folded SHA refs" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/ok"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Clean composite
runs:
  using: composite
  steps:
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
    - {with: {uses: "value", path: .lgtm-ci-tooling}, uses: ./.github/actions/with-first}
    - {uses: ./.github/actions/nested-uses, with: {uses: "value"}}
    - {name: "Setup {node", uses: ./.github/actions/quoted-brace, with: {x: "y}"}}
    - {name: "Setup \"{node", uses: ./.github/actions/escaped-quote}
    - {name: It's setup, uses: ./.github/actions/apostrophe, with: {k: 'it''s'}}
YAML

	run _composite_uses_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_line --index 0 "${fixture_dir}/action.yml:6:./.github/actions/setup-python"
	assert_line --index 1 "${fixture_dir}/action.yml:7:actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
	assert_line --index 2 "${fixture_dir}/action.yml:9:./.github/actions/with-first"
	assert_line --index 3 "${fixture_dir}/action.yml:10:./.github/actions/nested-uses"
	assert_line --index 4 "${fixture_dir}/action.yml:11:./.github/actions/quoted-brace"
	assert_line --index 5 "${fixture_dir}/action.yml:12:./.github/actions/escaped-quote"
	assert_line --index 6 "${fixture_dir}/action.yml:13:./.github/actions/apostrophe"
	refute_output --partial ":value"
	# A tooling path inside a non-checkout flow step's with: does not count.
	run _tooling_checkout_line "${fixture_dir}/action.yml"
	assert_output "0"

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

# Reference count built independently of the step walker: block-style steps
# whose own key level has a `uses` key (indentation only, no flow parsing).
# Fails if a flow-style step item is present; the real tree has none today and
# the walker self-tests cover that form.
_reference_uses_count() {
	local file total=0 n
	while IFS= read -r -d '' file; do
		n="$(awk '
			function ind(l, p) { p = l; sub(/[^ \t].*$/, "", p); return length(p) }
			/^[[:space:]]*steps:[[:space:]]*$/ { in_steps = 1; sc = ind($0); next }
			!in_steps { next }
			/^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
			ind($0) <= sc { in_steps = 0; next }
			/^[[:space:]]*-([[:space:]]|$)/ {
				if ($0 ~ /^[[:space:]]*-[[:space:]]*[{]/) { flow++; next }
				# Key column is wherever the first key starts after `-`; for a
				# bare `-` it is the column of the next key line.
				pre = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", pre)
				if (pre == "") { kl = -1; next }
				kl = length($0) - length(pre)
				if (pre ~ /^["'"'"']?uses["'"'"']?:/) count++
				next
			}
			kl == -1 { kl = ind($0) }
			ind($0) == kl && /^[[:space:]]*["'"'"']?uses["'"'"']?:/ { count++ }
			END { printf("%d %d", count, flow) }
		' "$file")"
		total=$((total + ${n% *}))
		if [[ "${n#* }" != "0" ]]; then
			echo "flow-style step in $file; extend the reference count" >&2
			return 1
		fi
	done < <(find "$1" -path "*/action.yml" -type f -print0)
	echo "$total"
}

@test "composite actions: extractor covers every uses: step in the real tree" {
	local extracted reference
	extracted="$(_composite_uses_refs "${PROJECT_ROOT}/.github/actions" | wc -l | tr -d ' ')"
	reference="$(_reference_uses_count "${PROJECT_ROOT}/.github/actions")"
	[[ "$extracted" -ge 1 ]]
	[[ "$extracted" -eq "$reference" ]]
}

@test "composite actions: flow-mapping checkout with quoted keys and apostrophes still counts as the tooling checkout" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/flow-checkout"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Flow checkout
runs:
  using: composite
  steps:
    - {name: It's the tooling, "uses": "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd", "with": {repository: lgtm-hq/lgtm-ci, 'path': ".lgtm-ci-tooling"}}
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _tooling_checkout_line "${fixture_dir}/action.yml"
	assert_output "6"
	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: an empty with: {} on a flow checkout does not let env.path qualify" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/empty-with"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Empty with then env path
runs:
  using: composite
  steps:
    - {uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd, with: {}, env: {path: .lgtm-ci-tooling}}
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _tooling_checkout_line "${fixture_dir}/action.yml"
	assert_output "0"
	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "no preceding checkout with path: .lgtm-ci-tooling"
}

@test "composite actions: extractor and reference count handle wide and bare dash indentation" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/wide"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Wide dash indentation
runs:
  using: composite
  steps:
    -   name: Setup
        uses: ./.github/actions/setup-python
        with:
            uses: not-a-step
    -   uses: $/.github/actions/setup-node
    -
      name: Bare dash
      uses: ./.github/actions/bare-dash
      with:
        uses: not-a-step
    -
          uses: ./.github/actions/bare-dash-wide
YAML

	run _composite_uses_refs "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	assert_line --index 0 "${fixture_dir}/action.yml:7:./.github/actions/setup-python"
	assert_line --index 1 "${fixture_dir}/action.yml:10:\$/.github/actions/setup-node"
	assert_line --index 2 "${fixture_dir}/action.yml:13:./.github/actions/bare-dash"
	assert_line --index 3 "${fixture_dir}/action.yml:17:./.github/actions/bare-dash-wide"
	refute_output --partial "not-a-step"
	run _reference_uses_count "${BATS_TEST_TMPDIR}/.github/actions"
	assert_output "4"
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

@test "composite actions: guard accepts a .lgtm-ci-tooling ref after a stage-action-tooling.sh step" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/staged"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Staged tooling
runs:
  using: composite
  steps:
    - name: Stage tooling
      shell: bash
      run: bash "${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/stage-action-tooling.sh"
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _tooling_stage_line "${fixture_dir}/action.yml"
	assert_output "8"
	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_success
	refute_output
}

@test "composite actions: guard flags a .lgtm-ci-tooling ref before the staging step, or with staging only mentioned" {
	local fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/stage-late"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Sibling before staging
runs:
  using: composite
  steps:
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
    - name: Stage tooling
      shell: bash
      run: bash "${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/stage-action-tooling.sh"
YAML
	fixture_dir="${BATS_TEST_TMPDIR}/.github/actions/stage-mentioned"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/action.yml" <<'YAML'
---
name: Staging script only mentioned
runs:
  using: composite
  steps:
    - name: Not a staging step
      shell: bash
      run: |
        echo 'bash "${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/stage-action-tooling.sh"'
    - uses: ./.lgtm-ci-tooling/.github/actions/setup-python
YAML

	run _tooling_stage_line "${fixture_dir}/action.yml"
	assert_output "0"
	run _composite_reference_violations "${BATS_TEST_TMPDIR}/.github/actions"
	assert_failure
	assert_output --partial "stage-late/action.yml:6: uses: ./.lgtm-ci-tooling/.github/actions/setup-python"
	assert_output --partial "stage-mentioned/action.yml:10: uses: ./.lgtm-ci-tooling/.github/actions/setup-python"
	assert_output --partial "or stage-action-tooling.sh step"
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

@test "composite actions: inlined-setup check flags setup-python.sh run again under another path" {
	require_python_yaml
	_copy_setup_actions
	"$PY" - "$PYTEST" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
step = (
    "    - name: Reinstall\n"
    "      shell: bash\n"
    '      run: bash "$GITHUB_ACTION_PATH/../../../scripts/ci/actions/./setup-python.sh"\n'
)
i = s.index("\nbranding:")
p.write_text(s[:i].rstrip() + "\n" + step + s[i:])
PY
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "setup-equivalent step after the"
}

@test "composite actions: inlined-setup check fails closed on a relational if:" {
	require_python_yaml
	_copy_setup_actions
	_rewrite_once "$SETUP" "if: inputs.cache == 'true'" "if: inputs.cache > 'false'"
	run _inlined_setup_python_check "$SETUP" "$PYTEST"
	assert_equal "$status" 1
	assert_output --partial "only == and != are supported"
}

@test "composite actions: inlined-setup check flags setup-python.sh run through an env variable" {
	require_python_yaml
	local form
	for form in 'bash "$SETUP_SCRIPT"' 'source "$SETUP_SCRIPT"'; do
		_copy_setup_actions
		"$PY" - "$PYTEST" "$form" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
step = (
    "    - name: Reinstall\n"
    "      shell: bash\n"
    "      env:\n"
    "        STEP: deps\n"
    "        SETUP_SCRIPT: ${{ github.action_path }}/../../../scripts/ci/actions/setup-python.sh\n"
    f"      run: {sys.argv[2]}\n"
)
i = s.index("\nbranding:")
p.write_text(s[:i].rstrip() + "\n" + step + s[i:])
PY
		run _inlined_setup_python_check "$SETUP" "$PYTEST"
		assert_equal "$status" 1
		assert_output --partial "setup-equivalent step after the"
	done
}
