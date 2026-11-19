#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for #1659 — the Playwright browser cache is restored on
#          every event and saved only by a push to the default branch, right
#          after a successful install, in every file that caches the browsers.

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
run = index(lambda s: s.get("id") == "run", "run")
if None in (restore, save, install, run):
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
expected_save_if = " && ".join([
    "github.event_name == 'push'",
    "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)",
    f"steps.{key_id}.outputs.cache-key != ''",
    f"steps.{restore_id}.outputs.cache-hit != 'true'",
    f"steps.{install_id}.outcome == 'success'",
])
if flat(s.get("if")) != expected_save_if:
    problems.append(f"save if is {flat(s.get('if'))!r}")
if s.get("continue-on-error") is not True:
    problems.append("save is not continue-on-error")

hit = f"${{{{ steps.{restore_id}.outputs.cache-hit }}}}"
if (steps[install].get("env") or {}).get("BROWSER_CACHE_HIT") != hit:
    problems.append("install does not read the restore's cache-hit")
if not restore < install < save < run:
    problems.append(f"order restore={restore} install={install} save={save} run={run}")
if save != install + 1:
    problems.append("save does not directly follow the install")

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

@test "playwright browser cache: no other workflow or action caches the browsers" {
	# The e2e and matrix reusables cache through the composite (#1433); any
	# other cache step over the browser directory would bypass this contract.
	run bash -c "grep -rlE 'playwright-browsers|ms-playwright|Playwright browsers' \
		'${PROJECT_ROOT}/.github/workflows' '${PROJECT_ROOT}/.github/actions' | sort"
	assert_success
	assert_output "$(printf '%s\n%s' "$COMPOSITE" "$REUSABLE")"
}

@test "playwright browser cache: the checker rejects a weakened composite" {
	require_python_yaml
	local copy
	copy="$(_mutate "$COMPOSITE" "github.event_name == 'push'" "github.event_name != ''")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "save if is"

	copy="$(_mutate "$COMPOSITE" "actions/cache/restore@" "actions/cache@")"
	run _check_browser_cache "$copy" composite
	assert_failure
	assert_output --partial "single actions/cache step"

	copy="$(_mutate "$COMPOSITE" "&& steps.setup.outcome == 'success'" "")"
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
}

@test "playwright browser cache: the checker rejects a weakened reusable" {
	require_python_yaml
	local copy
	copy="$(_mutate "$REUSABLE" \
		"github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" \
		"github.ref != ''")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save if is"

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
        continue-on-error: true" "        timeout-minutes: 30
        continue-on-error: true")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save timeout-minutes is 30"
}

@test "playwright browser cache: the checker rejects a save placed after the tests" {
	require_python_yaml
	local copy
	# A step between the install and the save: a save that waits for later
	# steps (the tests among them) could be skipped when they fail.
	copy="$(_mutate "$REUSABLE" "      - name: Save Playwright browsers" "      - name: Placeholder
        run: 'true'
      - name: Save Playwright browsers")"
	run _check_browser_cache "$copy" workflow
	assert_failure
	assert_output --partial "save does not directly follow the install"
}
