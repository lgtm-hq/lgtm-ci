#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Docker workflow readiness contracts, negative mutations and isolated command replays
# Bats isolates each test's environment; negated assertions end their test body.
# shellcheck disable=SC2030,SC2031,SC2314

load "../../helpers/docker_readiness"

@test "hardener readiness: every reusable Docker setup job requires readiness exactly on hosted Linux before QEMU or Buildx" {
	require_python_yaml
	run "$PY" "$CONTRACT" check "$PROJECT_ROOT"
	assert_success
	assert_output '7 Docker setup jobs require hardener completion'
	run "$PY" -O "$CONTRACT" check "$PROJECT_ROOT"
	assert_success
	assert_output '7 Docker setup jobs require hardener completion'
}

@test "hardener readiness: optimized Python rejects weakened caller contracts" {
	require_python_yaml
	local fixture_root="${BATS_TEST_TMPDIR}/repo" mutation workflow job
	while read -r workflow job; do
		for mutation in \
			conditional nonfatal late hardener-order hardener-late \
			missing-hardener missing-tooling sparse-checkout caller-map missing-identity \
			missing-checkout identity-conditional identity-nonfatal identity-repository identity-sha \
			identity-body checkout-order checkout-late checkout-conditional checkout-nonfatal \
			checkout-pin checkout-ref checkout-repository checkout-path checkout-sparse \
			checkout-cone checkout-credentials tooling-override \
			identity-unconditional identity-linux-only identity-hosted-only identity-widened identity-env \
			checkout-unconditional checkout-linux-only checkout-hosted-only checkout-widened checkout-env \
			barrier-unconditional barrier-linux-only barrier-hosted-only barrier-widened barrier-env; do
			"$PY" - "$PROJECT_ROOT" "$fixture_root" "$mutation" "$workflow" "$job" <<'PY'
from pathlib import Path
import sys

import yaml

source, destination = map(Path, sys.argv[1:3])
mutation = sys.argv[3]
workflows = destination / ".github/workflows"
workflows.mkdir(parents=True, exist_ok=True)
for path in (source / ".github/workflows").glob("reusable-docker*.yml"):
    (workflows / path.name).write_text(path.read_text())
path = workflows / sys.argv[4]
# The 301-case matrix must not repeatedly pay for pure-Python YAML parsing
# and emission. Both compiled classes retain the safe-loader/dumper contract.
workflow = yaml.load(path.read_text(), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))
steps = workflow["jobs"][sys.argv[5]]["steps"]
barrier = next(i for i, step in enumerate(steps)
               if step.get("name") == "Wait for hardener Docker readiness")
tooling = next(i for i, step in enumerate(steps) if step.get("id") == "egress")
hardener = next(i for i, step in enumerate(steps)
                if step.get("uses", "").startswith("step-security/harden-runner@"))
identity = next(i for i, step in enumerate(steps)
                if step.get("name") == "Require workflow readiness identity")
checkout = next(i for i, step in enumerate(steps)
                if step.get("name") == "Checkout workflow readiness helper")
if mutation.rsplit("-", 1)[-1] in (
    "unconditional", "only", "widened", "env",
):
    stage, condition = mutation.split("-", 1)
    target = steps[{"identity": identity, "checkout": checkout, "barrier": barrier}[stage]]
    if condition == "unconditional":
        del target["if"]
    else:
        target["if"] = {
            "linux-only": "${{ runner.os == 'Linux' }}",
            "hosted-only": "${{ runner.environment == 'github-hosted' }}",
            "widened": "${{ runner.os == 'Linux' || runner.environment == 'github-hosted' }}",
            "env": "${{ env.RUNNER_OS == 'Linux' && env.RUNNER_ENVIRONMENT == 'github-hosted' }}",
        }[condition]
elif mutation == "conditional":
    steps[barrier]["if"] = "false"
elif mutation == "nonfatal":
    steps[barrier]["continue-on-error"] = True
elif mutation == "late":
    steps.append(steps.pop(barrier))
elif mutation == "hardener-order":
    steps.insert(tooling, steps.pop(barrier))
elif mutation == "hardener-late":
    steps.insert(tooling + 1, steps.pop(hardener))
elif mutation == "missing-hardener":
    steps.pop(hardener)
elif mutation == "missing-tooling":
    steps.pop(tooling)
elif mutation == "sparse-checkout":
    steps[tooling]["with"]["sparse-checkout-extra"] = "docs/"
elif mutation == "caller-map":
    del workflow["jobs"][sys.argv[5]]
elif mutation == "missing-identity":
    steps.pop(identity)
elif mutation == "missing-checkout":
    steps.pop(checkout)
elif mutation == "identity-conditional":
    steps[identity]["if"] = "false"
elif mutation == "identity-nonfatal":
    steps[identity]["continue-on-error"] = True
elif mutation == "identity-repository":
    steps[identity]["env"]["WORKFLOW_REPOSITORY"] = "lgtm-hq/lgtm-ci"
elif mutation == "identity-sha":
    steps[identity]["env"]["WORKFLOW_SHA"] = "${{ inputs.tooling-ref }}"
elif mutation == "identity-body":
    steps[identity]["run"] = "true"
elif mutation == "checkout-order":
    steps.insert(identity, steps.pop(checkout))
elif mutation == "checkout-late":
    steps.append(steps.pop(checkout))
elif mutation == "checkout-conditional":
    steps[checkout]["if"] = "false"
elif mutation == "checkout-nonfatal":
    steps[checkout]["continue-on-error"] = True
elif mutation == "checkout-pin":
    steps[checkout]["uses"] = "actions/checkout@main"
elif mutation == "checkout-ref":
    steps[checkout]["with"]["ref"] = "${{ inputs.tooling-ref || github.sha || 'main' }}"
elif mutation == "checkout-repository":
    steps[checkout]["with"]["repository"] = "${{ github.repository }}"
elif mutation == "checkout-path":
    steps[checkout]["with"]["path"] = ".lgtm-ci-tooling"
elif mutation == "checkout-sparse":
    steps[checkout]["with"]["sparse-checkout"] = "scripts/ci/"
elif mutation == "checkout-cone":
    steps[checkout]["with"]["sparse-checkout-cone-mode"] = True
elif mutation == "checkout-credentials":
    steps[checkout]["with"]["persist-credentials"] = True
elif mutation == "tooling-override":
    steps[tooling]["with"]["tooling-ref"] = "${{ job.workflow_sha }}"
path.write_text(yaml.dump(workflow, Dumper=getattr(yaml, "CSafeDumper", yaml.SafeDumper)))
PY
			run "$PY" -O "$CONTRACT" check "$fixture_root"
			assert_failure
			assert_output --partial 'AssertionError'
			case "$mutation" in
			missing-hardener) assert_output --partial 'missing harden-runner step' ;;
			missing-tooling) assert_output --partial 'missing tooling checkout' ;;
			esac
		done
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: validate setup commands cannot cross the pending restart boundary" {
	require_python_yaml
	cd "$BATS_TEST_TMPDIR"
	# Replay actual conditions and shell steps; Docker actions use the local stub.
	# Without a barrier this deterministically fails with the original lease error.
	run "$PY" "$CONTRACT" replay "$PROJECT_ROOT"
	assert_success
	refute_output --partial 'invalid value for trace file descriptor'
	refute_output --partial 'kcov@'
	grep -q '^docker buildx inspect --bootstrap ready$' "$READINESS_EVENTS"
	! grep -q '^docker buildx inspect --bootstrap pending$' "$READINESS_EVENTS"
}

@test "hardener readiness: all seven workflow commands work with released tooling that predates the helper" {
	require_python_yaml
	local old_ref=f63b85534ce3a561f177c4ee3417b17c04f14a8b
	local tooling="${BATS_TEST_TMPDIR}/.lgtm-ci-tooling" workflow job
	# Minimal old-ref sparse layout: scripts/ci exists, this newer helper does not.
	# The exact released tree reproduction is retained in operator evidence.
	mkdir -p "$tooling/scripts/ci"
	printf '%s\n' "$old_ref" >"$tooling/released-ref"
	[[ -d "$tooling/scripts/ci" ]]
	[[ ! -e "$tooling/scripts/ci/docker/wait-for-harden-runner.sh" ]]
	cd "$BATS_TEST_TMPDIR"
	while read -r workflow job; do
		: >"$READINESS_EVENTS"
		rm -f "$HARDEN_RUNNER_STATUS_FILE"
		echo pending >"$READINESS_PHASE"
		run "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
		assert_success
		assert_output --partial 'harden-runner initialized; Docker setup may proceed'
		grep -q '^docker buildx inspect --bootstrap ready$' "$READINESS_EVENTS"
		[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
		# A poison helper in caller tooling must never supply this workflow barrier.
		mkdir -p "$tooling/scripts/ci/docker"
		printf 'exit 99\n' >"$tooling/scripts/ci/docker/wait-for-harden-runner.sh"
		run "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
		assert_success
		rm "$tooling/scripts/ci/docker/wait-for-harden-runner.sh"
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: all seven identity guards reject missing or mutable identity before running the helper" {
	require_python_yaml
	local workflow job identity repository sha
	cd "$BATS_TEST_TMPDIR"
	# No helper is present: the actual guard must fail before checkout or Docker.
	while read -r workflow job; do
		for identity in missing-repository missing-sha mutable-sha short-sha; do
			repository="$WORKFLOW_REPOSITORY"
			sha="$WORKFLOW_SHA"
			case "$identity" in
			missing-repository) repository="" ;;
			missing-sha) sha="" ;;
			mutable-sha) sha=main ;;
			short-sha) sha=86958e1 ;;
			esac
			run env WORKFLOW_REPOSITORY="$repository" WORKFLOW_SHA="$sha" "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
			assert_failure 1
			assert_output --partial 'Immutable workflow identity is required for Docker readiness'
			refute_output --partial 'No such file'
			refute_output --partial 'replay: Checkout workflow readiness helper'
			[[ ! -e .lgtm-ci-readiness ]]
			[[ ! -s "$READINESS_EVENTS" ]]
		done
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: all seven jobs skip only readiness on other runners without identity or helper" {
	require_python_yaml
	local workflow job runner_pair helper
	cd "$BATS_TEST_TMPDIR"
	# The helper source is absent too, so even an attempted checkout must fail.
	mkdir -p repo/.github
	cp -R "$PROJECT_ROOT/.github/workflows" repo/.github/
	export WORKFLOW_REPOSITORY="" WORKFLOW_SHA=""
	configure_timeout_layout missing
	for runner_pair in 'Linux self-hosted' 'Windows self-hosted' 'macOS self-hosted' \
		'Windows github-hosted' 'macOS github-hosted'; do
		read -r RUNNER_OS RUNNER_ENVIRONMENT <<<"$runner_pair"
		export RUNNER_OS RUNNER_ENVIRONMENT
		while read -r workflow job; do
			for helper in missing poison; do
				rm -rf .lgtm-ci-readiness
				if [[ "$helper" == poison ]]; then
					mkdir -p .lgtm-ci-readiness/scripts/ci/docker
					printf 'echo poison-readiness; exit 99\n' >.lgtm-ci-readiness/scripts/ci/docker/wait-for-harden-runner.sh
				fi
				: >"$READINESS_EVENTS"
				# Normal Docker setup is allowed immediately on these runners.
				echo ready >"$READINESS_PHASE"
				run "$PY" "$CONTRACT" replay "$BATS_TEST_TMPDIR/repo" "$workflow" "$job"
				assert_success
				refute_output --partial 'replay: Require workflow readiness identity'
				refute_output --partial 'replay: Checkout workflow readiness helper'
				refute_output --partial 'replay: Wait for hardener Docker readiness'
				refute_output --partial 'poison-readiness'
				[[ "$(cat "$READINESS_EVENTS")" == 'docker buildx inspect --bootstrap ready' ]]
				if [[ "$helper" == missing ]]; then [[ ! -e .lgtm-ci-readiness ]]; fi
			done
		done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
	done
}

@test "hardener readiness: all seven hosted Linux jobs fail closed when their own helper is missing" {
	require_python_yaml
	local workflow job
	cd "$BATS_TEST_TMPDIR"
	mkdir -p repo/.github .lgtm-ci-tooling/scripts/ci/docker
	cp -R "$PROJECT_ROOT/.github/workflows" repo/.github/
	# Caller tooling cannot rescue a missing workflow helper or bypass readiness.
	printf 'echo poison-tooling; exit 0\n' >.lgtm-ci-tooling/scripts/ci/docker/wait-for-harden-runner.sh
	while read -r workflow job; do
		: >"$READINESS_EVENTS"
		run "$PY" "$CONTRACT" replay "$BATS_TEST_TMPDIR/repo" "$workflow" "$job"
		assert_failure
		assert_output --partial 'replay: Checkout workflow readiness helper'
		refute_output --partial 'poison-tooling'
		[[ ! -s "$READINESS_EVENTS" ]]
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}
