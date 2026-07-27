#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-sbom workflow inputs and scan wiring (#480)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"
UPLOAD_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml"

@test "reusable-sbom: fail-on-severity defaults to critical" {
	run awk '/^      fail-on-severity:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "critical"'
}

@test "reusable-sbom: scan-vulnerabilities defaults to true" {
	run awk '/^      scan-vulnerabilities:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: true'
}

@test "reusable-sbom: egress-preset defaults to sbom" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "sbom"'
}

@test "reusable-sbom: scan step passes fail-on from fail-on-severity input" {
	run awk '
		/^  sbom:/ { in_job = 1; scan = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0; scan = 0 }
		in_job && scan && /^[[:space:]]+- name:/ { scan = 0 }
		in_job && /- name: Scan vulnerabilities/ { scan = 1 }
		in_job && scan && /fail-on: \$\{\{ inputs\.fail-on-severity \}\}/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: scan step is gated on scan-vulnerabilities" {
	run awk '
		/^  sbom:/ { in_job = 1; scan = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0; scan = 0 }
		in_job && scan && /^[[:space:]]+- name:/ { scan = 0 }
		in_job && /- name: Scan vulnerabilities/ { scan = 1 }
		in_job && scan && /if: inputs\.scan-vulnerabilities/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: generation job uses contents: read" {
	run awk '
		/^  sbom:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0 }
		in_job && /^    permissions:/ { perms = 1 }
		in_job && perms && /^      contents: read$/ { found = 1; exit }
		in_job && perms && /^    [a-z]/ && !/^    permissions:/ { perms = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

# The release-asset upload moved into its own workflow (#770) so that scan-mode
# callers stop granting contents:write. The scope it needs did not change — only
# which file declares it, and therefore who has to grant it.
@test "reusable-sbom-release-upload: upload job uses contents: write" {
	run awk '
		/^  upload-release-assets:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  upload-release-assets:/ { in_job = 0 }
		in_job && /^    permissions:/ { perms = 1 }
		in_job && perms && /^      contents: write$/ { found = 1; exit }
		in_job && perms && /^    [a-z]/ && !/^    permissions:/ { perms = 0 }
		END { exit !found }
	' "$UPLOAD_WORKFLOW"
	assert_success
}

@test "reusable-sbom-release-upload: uploads the downloaded artifact to the release" {
	run grep -F 'scripts/ci/actions/upload-sbom-release-assets.sh' "$UPLOAD_WORKFLOW"
	assert_success
	run grep -F 'SBOM_ARTIFACT_DIR: sbom-artifact' "$UPLOAD_WORKFLOW"
	assert_success
	# The download path and the script's input directory must be the same
	# string, or the upload finds an empty directory and fails at release time.
	run grep -F 'path: sbom-artifact' "$UPLOAD_WORKFLOW"
	assert_success
}

# The upload job is gone from reusable-sbom.yml, not merely disabled: a job left
# behind would keep contents:write in the caller union no matter what its `if:`
# says, which is the whole failure mode #737 documented.
@test "reusable-sbom: no upload-release-assets job survives" {
	run grep -q '^  upload-release-assets:' "$WORKFLOW"
	assert_failure
}

@test "reusable-sbom: upload-release-assets input is accepted but inert" {
	# Still accepted: an unknown input to a reusable workflow is a hard
	# startup_failure, so removing it outright would break pinned callers at
	# parse time instead of letting them migrate.
	run awk '/^      upload-release-assets:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial "DEPRECATED"
	# Inert: nothing but the deprecation warning may read it.
	run grep -c 'inputs\.upload-release-assets' "$WORKFLOW"
	assert_success
	[ "$output" -eq 1 ]
	run grep -q 'INPUT_VALUE: ${{ inputs.upload-release-assets }}' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: generate step disables anchore release asset upload" {
	run awk '
		/^  sbom:/ { in_job = 1; gen = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0; gen = 0 }
		in_job && /- name: Generate SBOM/ { gen = 1 }
		in_job && gen && /^[[:space:]]+- name:/ && $0 !~ /Generate SBOM/ { gen = 0 }
		in_job && gen && /upload-release-assets: "false"/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: mode defaults to report" {
	run awk '/^      mode:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "report"'
}

@test "reusable-sbom: formats default to spdx and cyclonedx json" {
	run awk '/^      formats:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "spdx-json,cyclonedx-json"'
}

@test "reusable-sbom: sign defaults to true" {
	run awk '/^      sign:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: true'
}

@test "reusable-sbom: report job skipped in release-assets mode" {
	run awk '
		/^  sbom:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  sbom:/ { in_job = 0 }
		in_job && /if: inputs\.mode != '\''release-assets'\''/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

# release-assets mode was split too, not left alone (#770). Leaving it would
# have kept contents:write in this workflow's union, so the report-mode caller
# would have gained nothing from splitting the report-mode upload job — the
# union is over ALL jobs in the file, disabled ones included.
@test "reusable-sbom: release-assets job uses contents read and id-token write" {
	run awk '
		/^  release-assets:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  release-assets:/ { in_job = 0 }
		in_job && /^    permissions:/ { perms = 1 }
		in_job && perms && /^      contents: read$/ { contents = 1 }
		in_job && perms && /^      id-token: write$/ { idtoken = 1 }
		in_job && perms && /^      contents: write$/ { bad = 1 }
		in_job && perms && /^    [a-z]/ && !/^    permissions:/ { perms = 0 }
		END { exit !(contents && idtoken && !bad) }
	' "$WORKFLOW"
	assert_success
}

# The handoff that replaces the in-job `gh release upload`: signing still
# happens here (it needs only id-token), and the signed files leave as an
# artifact under the same name the upload workflow downloads by default.
@test "reusable-sbom: release-assets hands the signed files over as an artifact" {
	run awk '
		/^  release-assets:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  release-assets:/ { in_job = 0 }
		in_job && /- name: Upload SBOM assets as artifact/ { step = 1; next }
		in_job && step && /^      - name: / { step = 0 }
		in_job && step && /name: \$\{\{ inputs\.artifact-name \}\}/ { named = 1 }
		in_job && step && /path: sbom$/ { path = 1 }
		in_job && step && /if-no-files-found: error/ { fatal = 1 }
		END { exit !(named && path && fatal) }
	' "$WORKFLOW"
	assert_success
	run grep -q 'sign-sbom-release-assets.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom-release-upload: artifact-name default matches the producer" {
	run awk '/^      artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$UPLOAD_WORKFLOW"
	assert_success
	assert_output --partial 'default: "sbom"'
	run awk '/^      artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "sbom"'
}

@test "reusable-sbom: release-assets job gated on mode" {
	run awk '
		/^  release-assets:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  release-assets:/ { in_job = 0 }
		in_job && /if: inputs\.mode == '\''release-assets'\''/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-sbom: validate job invokes validate-sbom-mode.sh" {
	run grep -F 'scripts/ci/actions/validate-sbom-mode.sh' "$WORKFLOW"
	assert_success
}

# The release-asset write is the one thing this workflow must no longer do: a
# surviving invocation would mean a job in it still needs contents:write.
@test "reusable-sbom: no job invokes upload-sbom-release-assets.sh" {
	run grep -q 'scripts/ci/actions/upload-sbom-release-assets.sh' "$WORKFLOW"
	assert_failure
}
