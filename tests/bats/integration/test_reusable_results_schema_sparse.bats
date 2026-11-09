#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract test - jobs that reach lib/testing/results.sh must check out schemas/ (#1370)

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-results-schema-sparse-checkout.sh"

# Build a fixture repo whose job runs a composite -> script -> parse.sh -> results.sh.
# $1: extra sparse-checkout-extra line(s), already indented and newline-terminated.
_write_fixture() {
	local extra="$1"
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/scripts/ci/lib/testing" "${root}/scripts/ci/actions" \
		"${root}/.github/actions/run-thing" "${root}/.github/workflows"
	printf '#!/usr/bin/env bash\n' >"${root}/scripts/ci/lib/testing/results.sh"
	printf '#!/usr/bin/env bash\nsource "$LIB/testing/results.sh"\n' \
		>"${root}/scripts/ci/lib/testing/parse.sh"
	printf '#!/usr/bin/env bash\nsource "$LIB/../lib/testing/parse.sh"\n' \
		>"${root}/scripts/ci/actions/run-thing.sh"
	cat >"${root}/.github/actions/run-thing/action.yml" <<'YAML'
---
name: Run thing
runs:
  using: composite
  steps:
    - shell: bash
      run: $SCRIPTS_DIR/ci/actions/run-thing.sh
YAML
	cat >"${root}/.github/workflows/reusable-thing.yml" <<YAML
---
name: Thing
on:
  workflow_call:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          sparse-checkout-extra: |
            .github/actions/
${extra}            scripts/ci/
      - name: Run thing
        uses: ./.lgtm-ci-tooling/.github/actions/run-thing
YAML
	echo "${root}"
}

@test "results-schema sparse: every repository reusable job reaching results.sh lists schemas/" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "results-schema sparse: e2e facades list schemas/ for run-playwright" {
	for wf in reusable-test-e2e reusable-test-e2e-matrix; do
		run grep -c "^            schemas/$" "${PROJECT_ROOT}/.github/workflows/${wf}.yml"
		assert_success
	done
}

@test "results-schema sparse: flags a transitive results.sh consumer without schemas/" {
	local root
	root="$(_write_fixture "")"
	REPO_ROOT="${root}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "reusable-thing.yml"
	assert_output --partial "run-thing"
	assert_output --partial "schemas/"
}

@test "results-schema sparse: accepts the same job once schemas/ is listed" {
	local root
	root="$(_write_fixture $'            schemas/\n')"
	REPO_ROOT="${root}" run "${VALIDATOR}"
	assert_success
}
