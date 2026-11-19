#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for #1659 — the Playwright browser cache is restored on
#          every event (a failed restore is a cold install) and saved only by
#          a push to the default branch, decided case-sensitively by
#          default-branch-push.sh, right after an install whose completeness
#          check passed, in every file that caches the browsers.

load "../../helpers/common"

COMPOSITE="${PROJECT_ROOT}/.github/actions/run-playwright/action.yml"
REUSABLE="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-playwright.yml"

# Check one file's browser cache steps. Arguments: the file, then
# "composite" or "workflow". Prints one line per violation and fails on any.
_check_browser_cache() {
	"$PY" - "$1" "$2" <<'PY'
import re
import sys

import yaml

path, kind = sys.argv[1:3]
doc = yaml.safe_load(open(path, encoding="utf-8"))
pin = "55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
problems = []

if kind == "composite":
    steps = doc["runs"]["steps"]
    key_id, restore_id, install_id = "browser-cache-key", "browser-cache", "setup"
else:
    steps = next(
        job["steps"]
        for job in doc["jobs"].values()
        if any(s.get("name") == "Restore Playwright browsers" for s in job.get("steps", []))
    )
    key_id, restore_id = "playwright-cache", "playwright-browser-cache"
    install_id = "install-browsers"


def index(predicate, label):
    found = [i for i, step in enumerate(steps) if predicate(step)]
    if len(found) != 1:
        problems.append(f"expected one {label} step, found {len(found)}")
        return None
    return found[0]


def flat(value):
    return " ".join(str(value or "").split())


uses = [str(step.get("uses", "")) for step in steps]
if any(re.match(r"actions/cache@", u) for u in uses):
    problems.append("a single actions/cache step is still present")

restore = index(lambda s: s.get("name") == "Restore Playwright browsers", "restore")
save = index(lambda s: s.get("name") == "Save Playwright browsers", "save")
install = index(lambda s: s.get("id") == install_id, "install")
decide = index(lambda s: s.get("id") == "default-branch-push", "default-branch-push")
run = index(lambda s: s.get("id") == "run", "run")
if None in (restore, save, install, decide, run):
    print("\n".join(problems))
    sys.exit(1)

r, s = steps[restore], steps[save]
key = f"${{{{ steps.{key_id}.outputs.cache-key }}}}"
cache_path = f"${{{{ steps.{key_id}.outputs.cache-path }}}}"

if r.get("uses") != f"actions/cache/restore@{pin}":
    problems.append(f"restore uses {r.get('uses')!r}")
if s.get("uses") != f"actions/cache/save@{pin}":
    problems.append(f"save uses {s.get('uses')!r}")
if r.get("id") != restore_id:
    problems.append(f"restore id is {r.get('id')!r}")
for label, step in (("restore", r), ("save", s)):
    w = step.get("with") or {}
    if w.get("key") != key or w.get("path") != cache_path:
        problems.append(f"{label} key/path differ from the resolved exact key")
    if "restore-keys" in w:
        problems.append(f"{label} has restore-keys")
    if kind == "composite":
        # The runner's action schema has no timeout-minutes on a composite
        # step; one would stop the action from loading.
        if "timeout-minutes" in step:
            problems.append(f"composite {label} has timeout-minutes")
    elif step.get("timeout-minutes") != 5:
        problems.append(f"{label} timeout-minutes is {step.get('timeout-minutes')!r}")

if flat(r.get("if")) != f"steps.{key_id}.outputs.cache-key != ''":
    problems.append(f"restore if is {flat(r.get('if'))!r}")
# A failed or timed-out restore is a cold install, never a failed job.
if r.get("continue-on-error") is not True:
    problems.append("restore is not continue-on-error")
expected_save_if = " && ".join([
    "steps.default-branch-push.outputs.default-branch-push == 'true'",
    f"steps.{key_id}.outputs.cache-key != ''",
    f"steps.{restore_id}.outcome == 'success'",
    f"steps.{restore_id}.outputs.cache-hit != 'true'",
    f"steps.{install_id}.outputs.browsers-ready == 'true'",
])
if flat(s.get("if")) != expected_save_if:
    problems.append(f"save if is {flat(s.get('if'))!r}")
if s.get("continue-on-error") is not True:
    problems.append("save is not continue-on-error")

# The save condition must not compare the ref itself: expression == ignores
# case. The decision is the script's, fed the default branch through env.
if re.search(r"github\.(ref|event_name)\b", flat(s.get("if"))):
    problems.append("save compares the event or ref in an expression")
d = steps[decide]
if flat(d.get("if")) != f"steps.{key_id}.outputs.cache-key != ''":
    problems.append(f"default-branch-push if is {flat(d.get('if'))!r}")
if (d.get("env") or {}) != {"DEFAULT_BRANCH": "${{ github.event.repository.default_branch }}"}:
    problems.append(f"default-branch-push env is {d.get('env')!r}")
run_line = str(d.get("run", ""))
if not run_line.endswith("/ci/actions/default-branch-push.sh") or "${{" in run_line:
    problems.append(f"default-branch-push run is {run_line!r}")
if "continue-on-error" in d:
    problems.append("default-branch-push is continue-on-error")
if kind == "composite":
    if "timeout-minutes" in d:
        problems.append("composite default-branch-push has timeout-minutes")
elif d.get("timeout-minutes") != 1:
    problems.append(f"default-branch-push timeout-minutes is {d.get('timeout-minutes')!r}")

env = steps[install].get("env") or {}
for name, output in (
    ("BROWSER_CACHE_HIT", f"steps.{restore_id}.outputs.cache-hit"),
    ("BROWSER_CACHE_PATH", f"steps.{key_id}.outputs.cache-path"),
):
    if env.get(name) != f"${{{{ {output} }}}}":
        problems.append(f"install {name} is {env.get(name)!r}")
if not restore < install < decide < save < run:
    problems.append(
        f"order restore={restore} install={install} decide={decide} save={save} run={run}",
    )
if (decide, save) != (install + 1, install + 2):
    problems.append("save does not directly follow the install and the branch check")
# The clean-state check is taken in the install step itself (#1659): no
# freshness flag from an earlier step may authorise anything.
if any("cache-path-fresh" in str(step) for step in steps):
    problems.append("a cache-path-fresh output is still wired")

if any("restore-keys" in str(step.get("with") or {}) for step in steps):
    problems.append("restore-keys present")

print("\n".join(problems) if problems else "ok")
sys.exit(1 if problems else 0)
PY
}

# Copy FILE into the test dir, apply a Python str.replace(OLD, NEW) once and
# print the copy's path. Fails when OLD is not in the file.
_mutate() {
	local src="$1" old="$2" new="$3" dest
	dest="${BATS_TEST_TMPDIR}/$(basename "$src")"
	"$PY" - "$src" "$dest" "$old" "$new" <<'PY'
import sys

src, dest, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(old) < 1:
    sys.exit(f"mutation anchor not found: {old!r}")
open(dest, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
	printf '%s\n' "$dest"
}

@test "playwright browser cache: the run-playwright composite restores always and saves only on a default-branch push" {
	require_python_yaml
	run _check_browser_cache "$COMPOSITE" composite
	assert_success
	assert_output "ok"
}

@test "playwright browser cache: reusable-test-e2e-playwright restores always and saves only on a default-branch push" {
	require_python_yaml
	run _check_browser_cache "$REUSABLE" workflow
	assert_success
	assert_output "ok"
}

# Print, one per line and sorted, the files under .github/workflows and
# .github/actions (or the directory given) with an actions/cache* step whose
# key or path involves the Playwright browsers. Comments and step names do
# not count: the YAML is parsed.
_browser_cache_files() {
	"$PY" - "${1:-${PROJECT_ROOT}/.github}" <<'PY'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
hits = set()
files = sorted(root.glob("workflows/*.yml")) + sorted(root.glob("workflows/*.yaml"))
files += sorted(root.glob("actions/*/action.yml")) + sorted(root.glob("actions/*/action.yaml"))
for path in files:
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    steps = list((doc.get("runs") or {}).get("steps") or [])
    for job in (doc.get("jobs") or {}).values():
        steps += (job or {}).get("steps") or []
    for step in steps:
        uses = str((step or {}).get("uses", ""))
        if not uses.startswith("actions/cache@") and not uses.startswith("actions/cache/"):
            continue
        w = step.get("with") or {}
        text = f"{w.get('key', '')} {w.get('path', '')}".lower()
        if "playwright" in text or "browser-cache" in text:
            hits.add(str(path))
print("\n".join(sorted(hits)))
PY
}

@test "playwright browser cache: no other workflow or action caches the browsers" {
	require_python_yaml
	# The e2e and matrix reusables cache through the composite (#1433); any
	# other cache step over the browser directory would bypass this contract.
	run _browser_cache_files
	assert_success
	assert_output "$(printf '%s\n%s' "$COMPOSITE" "$REUSABLE" | sort)"
}

@test "playwright browser cache: the exclusivity check parses steps, not text" {
	require_python_yaml
	local root="${BATS_TEST_TMPDIR}/gh"
	mkdir -p "${root}/workflows" "${root}/actions/x"
	# Mentions in comments and names only: not a cache step.
	cat >"${root}/workflows/comment.yml" <<'YAML'
# Playwright browsers live in ms-playwright (playwright-browsers-...).
jobs:
  a:
    steps:
      - name: Cache Playwright browsers (not really)
        run: echo hi
YAML
	# A cache step over the browser path in another workflow: caught.
	cat >"${root}/workflows/rogue.yml" <<'YAML'
jobs:
  a:
    steps:
      - uses: actions/cache/save@0000000000000000000000000000000000000000
        with:
          path: ~/.cache/ms-playwright
          key: anything
YAML
	cat >"${root}/actions/x/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: actions/cache@0000000000000000000000000000000000000000
      with:
        path: node_modules
        key: deps-${{ hashFiles('bun.lock') }}
YAML
	run _browser_cache_files "$root"
	assert_success
	assert_output "${root}/workflows/rogue.yml"
}

@test "playwright browser cache: the checker rejects a weakened composite" {
	require_python_yaml
	local copy
	copy="$(_mutate "$COMPOSITE" \
		"steps.default-branch-push.outputs.default-branch-push == 'true'" \
		"github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "save compares the event or ref in an expression"

	copy="$(_mutate "$COMPOSITE" "actions/cache/restore@" "actions/cache@")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "single actions/cache step"

	copy="$(_mutate "$COMPOSITE" "&& steps.setup.outputs.browsers-ready == 'true'" \
		"&& steps.setup.outcome == 'success'")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "save if is"

	copy="$(_mutate "$COMPOSITE" "&& steps.browser-cache.outcome == 'success'" "")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "save if is"

	copy="$(_mutate "$COMPOSITE" "      continue-on-error: true
      # Pinned to SHA for supply chain security
      uses: actions/cache/save@" "      timeout-minutes: 5
      continue-on-error: true
      uses: actions/cache/save@")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "composite save has timeout-minutes"

	copy="$(_mutate "$COMPOSITE" "      continue-on-error: true
      # Pinned to SHA for supply chain security. Exact key only" "      # Pinned to SHA for supply chain security. Exact key only")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "restore is not continue-on-error"
}

@test "playwright browser cache: the checker rejects a weakened reusable" {
	require_python_yaml
	local copy
	copy="$(_mutate "$REUSABLE" \
		"DEFAULT_BRANCH: \${{ github.event.repository.default_branch }}" \
		"DEFAULT_BRANCH: \${{ github.ref_name }}")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "default-branch-push env is"

	copy="$(_mutate "$REUSABLE" "run: bash .lgtm-ci-tooling/scripts/ci/actions/default-branch-push.sh" \
		"run: echo default-branch-push=\${{ github.ref == 'refs/heads/main' }} >> \"\$GITHUB_OUTPUT\"")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "default-branch-push run is"

	copy="$(_mutate "$REUSABLE" "uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9" \
		"uses: actions/cache/save@v6")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save uses"

	copy="$(_mutate "$REUSABLE" "          key: \${{ steps.playwright-cache.outputs.cache-key }}
      # Worst case" "          key: \${{ steps.playwright-cache.outputs.cache-key }}
          restore-keys: playwright-browsers-
      # Worst case")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "restore has restore-keys"

	copy="$(_mutate "$REUSABLE" "        timeout-minutes: 5
        continue-on-error: true
        # Pinned to SHA for supply chain security
        uses: actions/cache/save@" "        timeout-minutes: 30
        continue-on-error: true
        uses: actions/cache/save@")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save timeout-minutes is 30"

	copy="$(_mutate "$REUSABLE" \
		"          BROWSER_CACHE_PATH: \${{ steps.playwright-cache.outputs.cache-path }}
" "          BROWSER_CACHE_PATH: \${{ steps.playwright-cache.outputs.cache-path }}
          BROWSER_CACHE_PATH_FRESH: \${{ steps.playwright-cache.outputs.cache-path-fresh }}
")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "a cache-path-fresh output is still wired"
}

@test "playwright browser cache: the checker rejects a save placed after the tests" {
	require_python_yaml
	local copy
	# A step between the branch check and the save: a save that waits for
	# later steps (the tests among them) could be skipped when they fail.
	copy="$(_mutate "$REUSABLE" "      - name: Save Playwright browsers" "      - name: Placeholder
        run: 'true'
      - name: Save Playwright browsers")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save does not directly follow the install and the branch check"
}
