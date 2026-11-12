#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: A workflow whose reusable calls skip drafts re-runs on ready_for_review (#1471)

load "../../helpers/common"

# Print "<file>: <job>" for every caller workflow that runs on pull_request
# while one of its jobs calls a local reusable that skips drafts by default
# and does not set draft-pr-skip: false. With mode "missing" (default), only
# those whose pull_request types leave out ready_for_review.
_draft_skipping_callers() {
	"$PY" - "$1" "${2:-missing}" <<'PY'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
mode = sys.argv[2]


def skips_drafts(target: Path) -> bool:
    doc = yaml.safe_load(target.read_text()) or {}
    on = doc.get("on", doc.get(True)) or {}
    call = on.get("workflow_call") or {} if isinstance(on, dict) else {}
    spec = (call.get("inputs") or {}).get("draft-pr-skip")
    return isinstance(spec, dict) and spec.get("default") is True


for path in sorted(root.glob("*.y*ml")):
    if path.name.startswith("reusable-"):
        continue
    doc = yaml.safe_load(path.read_text()) or {}
    on = doc.get("on", doc.get(True))
    # `on: pull_request` and `on: [pull_request, ...]` mean the default types.
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = dict.fromkeys(on)
    if not isinstance(on, dict) or "pull_request" not in on:
        continue
    pull_request = on.get("pull_request") or {}
    types = pull_request.get("types") if isinstance(pull_request, dict) else None
    if mode == "missing" and types is not None and "ready_for_review" in types:
        continue
    for job_id, job in (doc.get("jobs") or {}).items():
        uses = str(job.get("uses", ""))
        if not uses.startswith("./.github/workflows/"):
            continue
        target = root / uses.rsplit("/", 1)[-1]
        if not target.is_file() or not skips_drafts(target):
            continue
        if (job.get("with") or {}).get("draft-pr-skip") is False:
            continue
        print(f"{path.name}: {job_id}")
PY
}

@test "draft-ready triggers: every caller of a draft-skipping reusable re-runs on ready_for_review" {
	require_python_yaml
	run _draft_skipping_callers "${PROJECT_ROOT}/.github/workflows"
	assert_success
	assert_output ""
}

@test "draft-ready triggers: ci.yml is in scope, so the first test is not vacuous" {
	require_python_yaml
	run _draft_skipping_callers "${PROJECT_ROOT}/.github/workflows" all
	assert_success
	assert_line --regexp '^ci\.yml: '
}

@test "draft-ready triggers: the check flags a caller without ready_for_review" {
	require_python_yaml
	local dir="${BATS_TEST_TMPDIR}/workflows"
	mkdir -p "$dir"
	cat >"${dir}/reusable-test-x.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      draft-pr-skip:
        type: boolean
        default: true
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
	cat >"${dir}/caller.yml" <<'YAML'
on:
  pull_request:
    branches: [main]
jobs:
  tests:
    uses: ./.github/workflows/reusable-test-x.yml
  opted-out:
    uses: ./.github/workflows/reusable-test-x.yml
    with:
      draft-pr-skip: false
YAML
	cat >"${dir}/list-form.yml" <<'YAML'
on: [pull_request, push]
jobs:
  tests:
    uses: ./.github/workflows/reusable-test-x.yml
YAML
	run _draft_skipping_callers "$dir"
	assert_success
	assert_output "caller.yml: tests
list-form.yml: tests"
}
