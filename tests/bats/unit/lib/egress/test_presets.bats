#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for egress allowlist presets

load "../../../../helpers/common"

PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"

@test "egress preset github-minimal includes GitHub API and tooling checkout hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-minimal"
	assert_success
	assert_output --partial 'github.com:443'
	assert_output --partial 'api.github.com:443'
	assert_output --partial 'codeload.github.com:443'
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset github-tooling includes raw, codeload, and uploads" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-tooling"
	assert_success
	assert_output --partial 'codeload.github.com:443'
	assert_output --partial 'raw.githubusercontent.com:443'
	assert_output --partial 'uploads.github.com:443'
}

@test "egress preset github-pages includes OIDC and release asset hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-pages"
	assert_success
	assert_output --partial 'actions.githubusercontent.com:443'
	assert_output --partial 'release-assets.githubusercontent.com:443'
}

@test "egress preset quality includes Docker and GHCR for lintro chk" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints quality"
	assert_success
	assert_output --partial 'ghcr.io:443'
	assert_output --partial 'docker.io:443'
	assert_output --partial 'semgrep.dev:443'
	assert_output --partial 'api.deps.dev:443'
}

@test "egress preset sbom includes Anchore and Sigstore hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints sbom"
	assert_success
	assert_output --partial 'anchore.io:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
	assert_output --partial 'sigstore-tuf-root.storage.googleapis.com:443'
}

@test "egress preset docker includes registry and artifact pipeline hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints docker"
	assert_success
	assert_output --partial 'ghcr.io:443'
	assert_output --partial 'docker.io:443'
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset playwright includes browser CDN hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints playwright"
	assert_success
	assert_output --partial 'cdn.playwright.dev:443'
	assert_output --partial 'registry.npmjs.org:443'
}

@test "egress preset pypi includes package index hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints pypi"
	assert_success
	assert_output --partial 'pypi.org:443'
	assert_output --partial 'files.pythonhosted.org:443'
}

@test "egress preset rubygems includes RubyGems API hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints rubygems | grep -cE '^actions\\.githubusercontent\\.com:443$'"
	assert_success
	assert_equal 1 "$output"
	run bash -c "source '$PRESETS' && egress_preset_endpoints rubygems"
	assert_success
	assert_output --partial 'rubygems.org:443'
	assert_output --partial 'api.rubygems.org:443'
}

@test "egress preset npm-publish includes npm registry, OIDC, and Sigstore" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints npm-publish"
	assert_success
	assert_output --partial 'actions.githubusercontent.com:443'
	assert_output --partial 'raw.githubusercontent.com:443'
	assert_output --partial 'registry.npmjs.org:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
}

@test "egress preset scorecard includes Scorecard API hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints scorecard"
	assert_success
	assert_output --partial 'api.scorecard.dev:443'
	assert_output --partial 'api.securityscorecards.dev:443'
	assert_output --partial 'gcr.io:443'
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset quality includes artifact pipeline host" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints quality"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset pypi includes artifact pipeline host" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints pypi"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset rejects unknown name" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints not-a-preset"
	assert_failure
}

@test "egress preset: every canonical name returns endpoints" {
	local preset
	local presets=(
		github-minimal
		github-pages
		github-tooling
		docker
		playwright
		pypi
		rubygems
		npm-publish
		quality
		sbom
		scorecard
	)
	for preset in "${presets[@]}"; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset' | grep -c ."
		assert_success
		[[ "$output" -gt 0 ]]
	done
}
