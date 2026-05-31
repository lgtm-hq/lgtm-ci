#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-build-python-dist workflow (#248)

load "../../helpers/common"

_checkout_order_ok() {
	local workflow="$1"
	local job_pattern="$2"
	awk -v job="$job_pattern" '
		$0 ~ "^  " job ":" { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:/ && $0 !~ "^  " job ":" { in_job = 0 }
		in_job && /^    steps:/ { in_steps = 1 }
		in_job && in_steps && /^      - name: Harden runner/ { harden = NR }
		in_job && in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_job && in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (harden > 0 && repo > 0 && tooling > 0 && harden < repo && repo < tooling)
			exit !ok
		}
	' "$workflow"
}

_tooling_sparse_cone_ok() {
	local workflow="$1"
	awk '
		/sparse-checkout-cone-mode: true/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
}

@test "reusable-build-python-dist: build job checkout order" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-build-python-dist.yml"
	run _checkout_order_ok "$workflow" "build"
	assert_success
}

@test "reusable-build-python-dist: uses build-python-package and uploads artifact" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-build-python-dist.yml"
	run awk '
		/^  build:/ { in_build = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  build:/ { in_build = 0 }
		in_build && /build-python-package/ { action = 1 }
		in_build && /actions\/upload-artifact@/ { upload = 1 }
		in_build && /publish-pypi/ { bad = 1 }
		in_build && /gh-action-pypi-publish@/ { bad = 1 }
		END { exit !(action && upload && !bad) }
	' "$workflow"
	assert_success
}

@test "reusable-build-python-dist: tooling sparse checkout uses cone mode" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-build-python-dist.yml"
	run _tooling_sparse_cone_ok "$workflow"
	assert_success
}

@test "reusable-build-python-dist: exposes version and package-name outputs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-build-python-dist.yml"
	run grep -q 'jobs.build.outputs.version' "$workflow"
	assert_success
	run grep -q 'jobs.build.outputs.package-name' "$workflow"
	assert_success
	run grep -q 'github-environment' "$workflow"
	assert_failure
}

@test "examples/publish-python-release: references split PyPI publish contract" {
	local example="${PROJECT_ROOT}/examples/publish-python-release.yml"
	run grep -q 'reusable-build-python-dist.yml' "$example"
	assert_success
	run grep -q 'prepare-pypi-upload' "$example"
	assert_success
	run grep -q 'gh-action-pypi-publish@' "$example"
	assert_success
	run grep -q 'attest-build-provenance@' "$example"
	assert_success
	run grep -q 'reusable-github-release.yml' "$example"
	assert_success
	run grep -q 'step-security/harden-runner@' "$example"
	assert_success
	run grep -q 'upload-pypi-oidc' "$example"
	assert_failure
	run grep -q 'reusable-publish-pypi' "$example"
	assert_failure
}

@test "reusable-github-release: downloads artifact and creates release via gh script" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-github-release.yml"
	run awk '
		/actions\/download-artifact@/ { download = 1 }
		/Verify release assets exist/ { verify = 1 }
		/verify-release-assets\.sh/ { verify_script = 1 }
		/Create GitHub Release/ { in_release_step = 1; release = 1; next }
		in_release_step && /create-github-release\.sh/ { release_script = 1 }
		in_release_step && /^      - name:/ { in_release_step = 0 }
		in_release_step && /run: \|/ { inline_shell = 1 }
		END { exit !(download && verify && verify_script && release && release_script && !inline_shell) }
	' "$workflow"
	assert_success
	run grep -Eq 'format\(\s*['\''"]\{0\}/\*\s*['\''"],\s*inputs\.artifact-path\s*\)' "$workflow"
	assert_success
}
