#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the documented caller permissions validator
#          (scripts/ci/docs/validate-caller-permissions.py, #735/#736/#669).
#
# GitHub validates a reusable workflow's `permissions:` request statically,
# so every documented caller snippet must grant at least the union of the
# scopes the called workflow's jobs declare. The validator runs against the
# live repository (first test) and against throwaway fixtures that pin each
# classification rule.

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/docs/validate-caller-permissions.py"

# Build a fixture repo root with one reusable workflow whose jobs declare
# `contents: read` (workflow level), `pull-requests: write` and
# `actions: read` (job level), plus a nested call that adds `issues: write`.
_fixture_root() {
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/.github/workflows" "${root}/docs" "${root}/examples"
	cat >"${root}/.github/workflows/reusable-demo.yml" <<'YAML'
---
name: Demo
on:
  workflow_call:
permissions:
  contents: read
jobs:
  work:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      pull-requests: read
    steps:
      - run: echo work
  publish:
    runs-on: ubuntu-24.04
    permissions:
      # comment lines inside the block are ignored
      pull-requests: write
      actions: read
    steps:
      - run: echo publish
  notify:
    uses: ./.github/workflows/reusable-demo-nested.yml
YAML
	cat >"${root}/.github/workflows/reusable-demo-nested.yml" <<'YAML'
---
name: Demo nested
on:
  workflow_call:
jobs:
  issue:
    runs-on: ubuntu-24.04
    permissions:
      issues: write
    steps:
      - run: echo issue
YAML
	echo "${root}"
}

@test "validate-caller-permissions: passes on repository docs and examples" {
	run python3 "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "validate-caller-permissions: union takes workflow, job, nested and stronger levels" {
	local root
	root="$(_fixture_root)"
	run python3 "${VALIDATOR}" --repo-root "${root}" --union reusable-demo.yml
	assert_success
	assert_output "actions: read
contents: read
issues: write
pull-requests: write"
}

@test "validate-caller-permissions: exact block on a complete snippet passes" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@0000000000000000000000000000000000000000 # v1.0.0
    permissions:
      actions: read
      contents: read
      issues: write
      pull-requests: write
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_success
	assert_output --partial "OK: 1 documented caller call site(s)"
}

@test "validate-caller-permissions: understated block fails naming the missing scopes" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main
    permissions:
      contents: read
      pull-requests: read
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_failure
	assert_output --partial "examples/ci.yml:3: reusable-demo.yml needs actions: read, issues: write, pull-requests: write"
	assert_output --partial "ERROR: 1 caller permission violation(s)"
}

@test "validate-caller-permissions: workflow-level block governs a job without its own" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
name: CI
permissions:
  actions: read
  contents: read
  issues: write
  pull-requests: write
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main
    with:
      flag: true
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_success
}

@test "validate-caller-permissions: read-all shorthand does not satisfy a write scope" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
permissions: read-all
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_failure
	assert_output --partial "needs issues: write, pull-requests: write"
}

@test "validate-caller-permissions: complete snippet with no block fails even when marked" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/docs/guide.md" <<'MD'
# Guide

_Fragment: permissions omitted for brevity._

```yaml
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>
    with:
      flag: true
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_failure
	assert_output --partial "docs/guide.md:8: complete snippet calls reusable-demo.yml with no permissions block"
}

@test "validate-caller-permissions: unmarked blockless fragment fails, marked one passes" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/docs/guide.md" <<'MD'
# Guide

```yaml
demo:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>
  with:
    flag: true
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_failure
	assert_output --partial "docs/guide.md:5: unmarked fragment calls reusable-demo.yml with no permissions block"

	cat >"${root}/docs/guide.md" <<'MD'
# Guide

_Fragment: permissions omitted for brevity, not copyable as-is._

<!-- markdownlint-disable MD013 -->

```yaml
demo:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>
  with:
    flag: true
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_success
}

@test "validate-caller-permissions: marker inside the fence also classifies a fragment" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/docs/guide.md" <<'MD'
```yaml
# permissions omitted for brevity
demo:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_success
}

@test "validate-caller-permissions: fragment block is still checked when present" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/docs/guide.md" <<'MD'
_Fragment: permissions omitted for brevity._

```yaml
demo:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@<sha>
  permissions:
    contents: read
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_failure
	assert_output --partial "needs actions: read, issues: write, pull-requests: write"
}

@test "validate-caller-permissions: call to a missing workflow fails" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
jobs:
  gone:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-renamed.yml@main
    permissions:
      contents: read
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_failure
	assert_output --partial "calls reusable-renamed.yml, which does not exist"
}

@test "validate-caller-permissions: detect-changes job must grant pull-requests read (#669)" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/docs/guide.md" <<'MD'
```yaml
jobs:
  changes:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
      - uses: lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha> # vX.Y.Z
        id: detect
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_failure
	assert_output --partial "docs/guide.md:9: actions/detect-changes needs pull-requests: read"

	cat >"${root}/docs/guide.md" <<'MD'
```yaml
jobs:
  changes:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha> # vX.Y.Z
```
MD
	run python3 "${VALIDATOR}" --repo-root "${root}" docs
	assert_success
}

@test "validate-caller-permissions: surplus grants are reported as notices, not failures" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main
    permissions:
      actions: write
      contents: write
      issues: write
      pull-requests: write
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_success
	assert_output --partial "NOTICE: examples/ci.yml:3: reusable-demo.yml grants more than it declares: actions: write, contents: write"
}

@test "validate-caller-permissions: unparseable block is reported, not skipped" {
	local root
	root="$(_fixture_root)"
	cat >"${root}/examples/ci.yml" <<'YAML'
jobs:
  demo:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-demo.yml@main
    permissions:
      contents: ${{ inputs.level }}
YAML
	run python3 "${VALIDATOR}" --repo-root "${root}" examples
	assert_failure
	assert_output --partial "unparseable permissions block"
}
