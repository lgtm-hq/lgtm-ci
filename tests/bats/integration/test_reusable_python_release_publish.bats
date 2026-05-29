#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for Python release publish reusables (#232)

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

@test "reusable-publish-pypi-release: build job checkout order" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run _checkout_order_ok "$workflow" "build-artifacts"
	assert_success
}

@test "reusable-publish-pypi-release: build uses publish-pypi dry-run and uploads artifact" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  build-artifacts:/ { in_build = 1 }
		/^  publish:/ { in_build = 0 }
		in_build && /dry-run: true/ { dry_run = 1 }
		in_build && /actions\/upload-artifact@/ { upload = 1 }
		in_build && /publish-pypi/ { action = 1 }
		END { exit !(dry_run && upload && action) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: publish job uses github-environment input" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/github-environment:/ { input = 1 }
		/^  publish:/ { in_publish = 1 }
		in_publish && /^  [a-zA-Z0-9_-]+:/ && $0 !~ /^  publish:/ { in_publish = 0 }
		in_publish && /environment: \$\{\{ inputs\.github-environment \}\}/ { env = 1 }
		END { exit !(input && env) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: publish job validates dist and attests" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  [a-zA-Z0-9_-]+:/ { in_publish = 0 }
		/^  publish:/ { in_publish = 1 }
		in_publish && /STEP: validate-dist/ { validate = 1 }
		in_publish && /scripts\/ci\/actions\/publish-pypi\.sh/ { validate_script = 1 }
		in_publish && /run: \|/ { inline_shell = 1 }
		in_publish && /gh-action-pypi-publish@/ { pypi = 1 }
		in_publish && /attest-build-provenance@/ { attest = 1 }
		END { exit !(validate && validate_script && pypi && attest && !inline_shell) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: publish job downloads artifact before setup python" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  [a-zA-Z0-9_-]+:/ { in_publish = 0 }
		/^  publish:/ { in_publish = 1 }
		in_publish && /name: Download Python distribution/ { download = NR }
		in_publish && /name: Setup Python/ { setup = NR }
		in_publish && /STEP: validate-dist/ { validate = NR }
		END { exit !(download > 0 && setup > 0 && validate > 0 && download < setup && setup < validate) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: publish job installs Python before validate" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  [a-zA-Z0-9_-]+:/ { in_publish = 0 }
		/^  publish:/ { in_publish = 1 }
		in_publish && /setup-python/ { setup = NR }
		in_publish && /STEP: validate-dist/ { validate = NR }
		END { exit !(setup > 0 && validate > 0 && setup < validate) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: sets published output after attestation" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  [a-zA-Z0-9_-]+:/ { in_publish = 0 }
		/^  publish:/ { in_publish = 1 }
		in_publish && /attest-build-provenance@/ { attest = NR }
		in_publish && /id: set-published/ { published = NR }
		END { exit !(attest > 0 && published > 0 && attest < published) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: publish job permissions" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run awk '
		/^  publish:/ { in_publish = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish:/ { in_publish = 0 }
		in_publish && /contents: read/ { contents = 1 }
		in_publish && /id-token: write/ { id_token = 1 }
		in_publish && /attestations: write/ { attestations = 1 }
		in_publish && /contents: write/ { bad = 1 }
		END { exit !(contents && id_token && attestations && !bad) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi-release: exposes publish outputs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi-release.yml"
	run grep -q 'jobs.publish.outputs.published' "$workflow"
	assert_success
	run grep -q 'jobs.publish.outputs.version' "$workflow"
	assert_success
	run grep -q 'jobs.publish.outputs.package-name' "$workflow"
	assert_success
}

@test "reusable-publish-pypi: wires python-version via setup-python" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi.yml"
	run awk '
		/setup-python/ { setup = 1 }
		/python-version: \$\{\{ inputs.python-version \}\}/ { version = 1 }
		/install-dependencies: "false"/ { no_deps = 1 }
		END { exit !(setup && version && no_deps) }
	' "$workflow"
	assert_success
}

@test "reusable-publish-pypi: tooling sparse checkout uses cone mode" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-pypi.yml"
	run _tooling_sparse_cone_ok "$workflow"
	assert_success
}

@test "reusable-github-release: downloads artifact and creates release via gh script" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-github-release.yml"
	run awk '
		/actions\/download-artifact@/ { download = 1 }
		/Verify release assets exist/ { verify = 1 }
		/verify-release-assets\.sh/ { verify_script = 1 }
		/run: \|/ { inline_shell = 1 }
		/create-github-release\.sh/ { release = 1 }
		END { exit !(download && verify && verify_script && release && !inline_shell) }
	' "$workflow"
	assert_success
	run grep -Eq "format\\(['\"]\\{0\\}/\\*['\"],\\s*inputs\\.artifact-path\\)" "$workflow"
	assert_success
}

@test "reusable-github-release: requires contents write only" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-github-release.yml"
	run awk '
		/^  release:/ { in_release = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  release:/ { in_release = 0 }
		in_release && /^    permissions:/ { in_permissions = 1 }
		in_permissions && /^    [a-zA-Z0-9_-]+:/ && !/^    permissions:/ { in_permissions = 0 }
		in_permissions && /^      [a-zA-Z0-9_-]+: / {
			total_permissions++
			if ($1 == "contents:" && $2 == "write") {
				contents_count++
			}
		}
		END { exit !(contents_count == 1 && total_permissions == 1) }
	' "$workflow"
	assert_success
}

@test "reusable-github-release: exposes release outputs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-github-release.yml"
	run grep -q 'jobs.release.outputs.release-url' "$workflow"
	assert_success
	run grep -q 'steps.gh-release.outputs.release-url' "$workflow"
	assert_success
}
