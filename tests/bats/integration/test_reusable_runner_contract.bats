#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for runner-image and runner-map reusable workflow policy

load "../../helpers/common"
load_runner_contract

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-runner-contract.sh"

_runner_default_fixture() {
	local path="$1"
	mkdir -p "$(dirname "${path}")"
	cat >"${path}" <<YAML
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
YAML
}

setup() {
	require_python_yaml
	export PYTHON="${PY}"
}

@test "validate-runner-contract: passes on repository reusables" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "validate-runner-contract: rejects Docker classify fallback drift from the standard" {
	local root="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${root}/scripts/ci/actions/docker" "${root}/scripts/ci/lib" "${root}/.github/workflows"
	cp "${PROJECT_ROOT}/scripts/ci/lib/"*.sh "${root}/scripts/ci/lib/"
	local mutation
	for mutation in fallback argument source override; do
		cp "${PROJECT_ROOT}/scripts/ci/actions/docker/classify.sh" "${root}/scripts/ci/actions/docker/"
		"${PY}" - "${root}/scripts/ci/actions/docker/classify.sh" "$mutation" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
content = path.read_text()
if sys.argv[2] == "fallback":
    content, count = re.subn(r'(\.\[\$p\] // )(?:"ubuntu-[^"]+"|\$standard_runner)', r'\1"ubuntu-24.04"', content)
    assert count == 1
elif sys.argv[2] == "argument":
    before = '--arg standard_runner "$STANDARD_RUNNER"'
    assert before in content
    content = content.replace(before, '--arg standard_runner "ubuntu-24.04"')
elif sys.argv[2] == "source":
    before = 'source "$SCRIPT_DIR/../../lib/standard-runner.sh"'
    assert before in content
    content = content.replace(before, '# removed shared standard')
else:
    content += '\nSTANDARD_RUNNER="ubuntu-24.04"\n'
path.write_text(content)
PY
		REPO_ROOT="${root}" run "${VALIDATOR}"
		assert_failure
		assert_output --partial "classify.sh: runner-map fallback must use STANDARD_RUNNER"
	done
}

@test "control-plane runners: preserve job identities, permissions and event guards" {
	run "${PY}" - "${PROJECT_ROOT}" "${RUNNER_IMAGE_RUNS_ON}" <<'PY'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
for workflow, job_id, check_name, pull_requests, guard in (
    ("semantic-pr-title", "semantic-title", "Semantic PR Title", "write", None),
    ("pr-labeler", "label", "PR Labeler", "write", None),
    ("dependency-review", "dependency-review", "Dependency Review", "read",
     "github.event_name == 'pull_request' || github.event_name == 'merge_group'"),
):
    doc = yaml.safe_load((root / f".github/workflows/reusable-{workflow}.yml").read_text())
    inputs = doc.get(True, doc.get("on"))["workflow_call"]["inputs"]
    runner = inputs["runner-image"]
    assert runner["type"] == "string" and runner["required"] is False, workflow
    assert runner["default"] == "", workflow
    assert list(doc["jobs"]) == [job_id], workflow
    job = doc["jobs"][job_id]
    assert job["runs-on"] == sys.argv[2], workflow
    assert job["name"] == "${{ inputs.job-name }}", workflow
    assert inputs["job-name"]["default"] == check_name, workflow
    assert job["permissions"] == {"contents": "read", "pull-requests": pull_requests}, workflow
    assert job.get("if") == guard, workflow
    assert job["steps"][0]["uses"].startswith("step-security/harden-runner@"), workflow
PY
	assert_success
}

@test "control-plane runners: validator rejects regression to a fixed runner" {
	local workflows_dir="${BATS_TEST_TMPDIR}/workflows" name
	mkdir -p "${workflows_dir}"
	for name in semantic-pr-title pr-labeler dependency-review; do
		local workflow="reusable-${name}.yml"
		sed 's/^    runs-on: .*/    runs-on: ubuntu-latest/' \
			"${PROJECT_ROOT}/.github/workflows/${workflow}" >"${workflows_dir}/${workflow}"
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_failure
		assert_output --partial "${workflow}: job"
		assert_output --partial "hardcodes runs-on 'ubuntu-latest' but runner-image input is defined"
		rm "${workflows_dir}/${workflow}"
	done
}

@test "validate-runner-contract: honors the selected Python interpreter" {
	local interpreter="${BATS_TEST_TMPDIR}/selected-python"
	cat >"${interpreter}" <<'SH'
#!/usr/bin/env bash
touch "${RUNNER_TEST_MARKER}"
exec "${RUNNER_TEST_PYTHON}" "$@"
SH
	chmod +x "${interpreter}"
	PYTHON="${interpreter}" RUNNER_TEST_PYTHON="${PY}" \
		RUNNER_TEST_MARKER="${BATS_TEST_TMPDIR}/python-used" run "${VALIDATOR}"
	assert_success
	[[ -f "${BATS_TEST_TMPDIR}/python-used" ]]
}

@test "validate-runner-contract: short event syntax reports missing inputs" {
	local workflows_dir="${BATS_TEST_TMPDIR}/workflows" events
	mkdir -p "${workflows_dir}"
	for events in '[workflow_call]' 'workflow_call'; do
		cat >"${workflows_dir}/reusable-short-events.yml" <<YAML
on: ${events}
jobs:
  work:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: bash scripts/ci/example.sh
YAML
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_failure
		assert_output --partial 'missing timeout-minutes input'
		assert_output --partial 'without runner-image input'
		[[ "${output}" != *Traceback* ]]
	done
}

@test "validate-runner-contract: rejects stale defaults and reports file and label" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local workflow="${workflows_dir}/reusable-stale-default.yml"
	_runner_default_fixture "${workflow}"
	local default
	for default in '"ubuntu-24.04"' "'ubuntu-24.04'" 'ubuntu-24.04'; do
		"${PY}" - "${workflow}" "${default}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
path.write_text(re.sub(r'^        default: .*$', f'        default: {sys.argv[2]}', path.read_text(), count=1, flags=re.M))
PY
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_failure
		assert_output --partial "reusable-stale-default.yml: runner-image default must be \"\" (found 'ubuntu-24.04')"
		assert_output --partial "ERROR: 1 reusable workflow runner contract violation(s)"
	done
}

@test "validate-runner-contract: accepts an empty default in either quote style" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local workflow="${workflows_dir}/reusable-standard-default.yml"
	_runner_default_fixture "${workflow}"
	local default
	for default in '""' "''"; do
		"${PY}" - "${workflow}" "${default}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
path.write_text(re.sub(r'^        default: .*$', f'        default: {sys.argv[2]}', path.read_text(), count=1, flags=re.M))
PY
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_success
	done
}

@test "validate-runner-contract: accepts commented declarations and indented multiline descriptions with either on key" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local workflow="${workflows_dir}/reusable-commented-input.yml"
	local on_key
	for on_key in on '"on"'; do
		_runner_default_fixture "${workflow}"
		"${PY}" - "${workflow}" "${on_key}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text().replace('on:', f'{sys.argv[2]}:', 1)
content = content.replace('      runner-image:\n', '''      runner-image: # note
        description: |-
          Runner label for every job.
            Indented details stay in the description.
          default: ubuntu-24.04 is just description text.
''', 1)
path.write_text(content)
PY
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_success
	done
}

@test "validate-runner-contract: does not borrow a missing default from another input" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local workflow="${workflows_dir}/reusable-missing-default.yml"
	_runner_default_fixture "${workflow}"
	"${PY}" - "${workflow}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    '        default: ""',
    '      other-image:\n        type: string\n        default: ""',
    1,
))
PY
	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "reusable-missing-default.yml: runner-image default must be \"\" (found missing)"
}

@test "validate-runner-contract: checks defaults even in Docker and action-only exceptions" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local name
	for name in reusable-codeql.yml reusable-docker-build.yml; do
		_runner_default_fixture "${workflows_dir}/${name}"
		sed -i 's/default: ""/default: "ubuntu-24.04"/' "${workflows_dir}/${name}"
		WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
		assert_failure
		assert_output --partial "${name}: runner-image default must be \"\" (found 'ubuntu-24.04')"
		rm "${workflows_dir}/${name}"
	done
}

@test "validate-runner-contract: rejects a Docker coordinator on a different runner" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	sed "s/runs-on: ${STANDARD_RUNNER}/runs-on: ubuntu-24.04/" \
		"${PROJECT_ROOT}/.github/workflows/reusable-docker.yml" >"${workflows_dir}/reusable-docker.yml"
	run cmp -s "${PROJECT_ROOT}/.github/workflows/reusable-docker.yml" "${workflows_dir}/reusable-docker.yml"
	assert_failure 1
	run grep -F 'runs-on: ubuntu-24.04' "${workflows_dir}/reusable-docker.yml"
	assert_success
	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "reusable-docker.yml: job classify must use ${STANDARD_RUNNER} coordinator runner (found 'ubuntu-24.04')"
	assert_output --partial "ERROR: 1 reusable workflow runner contract violation(s)"
}

@test "validate-runner-contract: flags script-backed reusable without runner-image" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-script-backed-bad.yml" <<YAML
---
name: Script backed bad example
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
        default: ""
jobs:
  check:
    name: Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          repository: lgtm-hq/lgtm-ci
          path: .lgtm-ci-tooling
          sparse-checkout: |
            scripts/ci/
      - run: .lgtm-ci-tooling/scripts/ci/example.sh
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "without runner-image input"
}

@test "validate-runner-contract: flags incomplete runner-image wiring" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-partial-wiring-bad.yml" <<YAML
---
name: Partial wiring bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo ok
  aggregate:
    runs-on: ubuntu-latest
    steps:
      - run: echo aggregate
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "hardcodes runs-on"
}

@test "validate-runner-contract: flags reusable without timeout-minutes input" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-no-timeout-bad.yml" <<YAML
---
name: No timeout bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "missing timeout-minutes input"
}

@test "validate-runner-contract: accepts reusable with timeout-minutes input" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-with-timeout-good.yml" <<YAML
---
name: With timeout good example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: flags timeout-minutes input that is not type number" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-with-timeout-string.yml" <<YAML
---
name: With timeout string example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: string
        default: "10"
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "timeout-minutes input is not type: number"
}

@test "validate-runner-contract: flags timeout-minutes input never applied to a job" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-with-timeout-unused.yml" <<YAML
---
name: With timeout unused example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: 30
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "timeout-minutes input is never applied to a job"
}

@test "validate-runner-contract: flags runs-on job without job-level timeout-minutes" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-uncapped-job-bad.yml" <<YAML
---
name: Uncapped job bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  test:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
  aggregate:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo aggregate
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "job aggregate runs-on without timeout-minutes"
}

@test "validate-runner-contract: honors TIMEOUT_PER_JOB_EXCEPTIONS bypass" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local validator_copy="${BATS_TEST_TMPDIR}/validate-runner-contract.sh"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-uncapped-job-bad.yml" <<YAML
---
name: Uncapped job bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  test:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
  aggregate:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo aggregate
YAML

	# Patch a throwaway copy of the validator so the exception key format is
	# exercised without mutating the repo-owned empty set.
	cp "${VALIDATOR}" "${validator_copy}"
	"${PY}" - "${validator_copy}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "TIMEOUT_PER_JOB_EXCEPTIONS: set[str] = set()"
new = (
    "TIMEOUT_PER_JOB_EXCEPTIONS: set[str] = {\n"
    '    "reusable-uncapped-job-bad.yml:aggregate",\n'
    "}"
)
if old not in text:
    raise SystemExit("TIMEOUT_PER_JOB_EXCEPTIONS declaration not found")
path.write_text(text.replace(old, new, 1))
PY

	REPO_ROOT="${PROJECT_ROOT}" WORKFLOWS_DIR="${workflows_dir}" run "${validator_copy}"
	assert_success
}

@test "validate-runner-contract: accepts job with independent literal timeout cap" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-literal-cap-good.yml" <<YAML
---
name: Literal cap good example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ""
      timeout-minutes:
        type: number
        default: 10
jobs:
  test:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: \${{ inputs.timeout-minutes }}
    steps:
      - run: echo ok
  report-failure:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    timeout-minutes: 10
    steps:
      - run: echo report
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: allows documented action-only exception" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-codeql.yml" "${workflows_dir}/"

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: allows docker coordinator and matrix runners" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker.yml" "${workflows_dir}/"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker-build.yml" "${workflows_dir}/"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform.yml" "${workflows_dir}/"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform-validate.yml" "${workflows_dir}/"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform-publish.yml" "${workflows_dir}/"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker-smoke-test.yml" "${workflows_dir}/"

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (double quotes)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-bad.yml" <<YAML
---
name: Latest default bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: "ubuntu-latest"
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be \"\""
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (single quotes)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-single-quote-bad.yml" <<YAML
---
name: Latest default single quote bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: 'ubuntu-latest'
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be \"\""
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (unquoted)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-unquoted-bad.yml" <<YAML
---
name: Latest default unquoted bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ubuntu-latest
jobs:
  work:
    runs-on: ${RUNNER_IMAGE_RUNS_ON}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be \"\""
}

@test "reusable-release-version-pr: exposes runner-image on all jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	run grep -F 'runner-image:' "$workflow"
	assert_success
	run awk '
		/^  version-pr:/ { in_job = 1 }
		/^  report-release-failure:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  version-pr:/ && !/^  report-release-failure:/ { in_job = 0 }
		in_job && /^    runs-on: \$\{\{ inputs\.runner-image \|\| vars\.LGTM_CI_RUNNER \|\| / { found++ }
		END { exit found != 2 }
	' "$workflow"
	assert_success
}

@test "reusable-quality-lint: wires runner-image input" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml"
	run grep -F 'default: ""' "$workflow"
	assert_success
	run awk '
		/^  quality:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality:/ { in_job = 0 }
		in_job && /^    runs-on: \$\{\{ inputs\.runner-image \|\| vars\.LGTM_CI_RUNNER \|\| / { found = 1 }
		END { exit !found }
	' "$workflow"
	assert_success
}

# A minimal fixture isolates runner validation from the timeout contract.
_runner_fixture() {
	local default_line="$1" runs_on="$2"
	WORKFLOWS_DIR="${BATS_TEST_TMPDIR}/workflows"
	export WORKFLOWS_DIR
	mkdir -p "${WORKFLOWS_DIR}"
	cat >"${WORKFLOWS_DIR}/reusable-runner.yml" <<YAML
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        ${default_line}
      timeout-minutes:
        type: number
        default: 10
jobs:
  work:
    runs-on: ${runs_on}
    timeout-minutes: \${{ inputs.timeout-minutes }}
YAML
}

@test "validate-runner-contract: accepts the exact runner expression with an empty default" {
	_runner_fixture 'default: ""' "${RUNNER_IMAGE_RUNS_ON}"
	run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: rejects every non-empty runner-image default" {
	local default
	for default in '"ubuntu-26.04"' "'ubuntu-26.04'" ubuntu-26.04 '"blacksmith-2vcpu-ubuntu-2604"' '" "'; do
		_runner_fixture "default: ${default}" "${RUNNER_IMAGE_RUNS_ON}"
		run "${VALIDATOR}"
		assert_failure
		assert_output --partial 'runner-image default must be ""'
	done
}

@test "validate-runner-contract: missing or null default cannot inherit the next input default" {
	local declaration
	for declaration in '# omitted' 'default:' 'default: null'; do
		_runner_fixture "${declaration}" "${RUNNER_IMAGE_RUNS_ON}"
		run "${VALIDATOR}"
		assert_failure
		assert_output --partial 'runner-image default must be ""'
	done
}

@test "validate-runner-contract: accepts a single-quoted empty default with an inline comment" {
	_runner_fixture "default: '' # follow the org switch" "${RUNNER_IMAGE_RUNS_ON}"
	run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: rejects a fallback different from STANDARD_RUNNER" {
	_runner_fixture 'default: ""' "\${{ inputs.runner-image || vars.LGTM_CI_RUNNER || 'ubuntu-24.04' }}"
	run "${VALIDATOR}"
	assert_failure
	assert_output --partial "must use"
	assert_output --partial "${STANDARD_RUNNER}"
}

@test "validate-runner-contract: rejects a plain runner-image expression" {
	_runner_fixture 'default: ""' '${{ inputs.runner-image }}'
	run "${VALIDATOR}"
	assert_failure
	assert_output --partial "must use"
}

@test "validate-runner-contract: rejects missing org fallback or reversed runner precedence" {
	local runs_on
	for runs_on in \
		"\${{ vars.LGTM_CI_RUNNER || inputs.runner-image || '${STANDARD_RUNNER}' }}" \
		"\${{ inputs.runner-image || '${STANDARD_RUNNER}' || vars.LGTM_CI_RUNNER }}" \
		"\${{ inputs.runner-image || '${STANDARD_RUNNER}' }}"; do
		_runner_fixture 'default: ""' "${runs_on}"
		run "${VALIDATOR}"
		assert_failure
		assert_output --partial "job work runs-on"
		assert_output --partial "must use ${RUNNER_IMAGE_RUNS_ON}"
	done
}
