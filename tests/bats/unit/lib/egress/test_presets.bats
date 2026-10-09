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

@test "egress preset github-tooling includes release-assets CDN for release-binary downloads" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-tooling"
	assert_success
	assert_output --partial 'release-assets.githubusercontent.com:443'
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
	assert_output --partial 'rekor.sigstore.dev:443'
	assert_output --partial 'oauth2.sigstore.dev:443'
	assert_output --partial 'uploads.github.com:443'
	assert_output --partial 'sigstore-tuf-root.storage.googleapis.com:443'
}

@test "egress preset docker includes registry and artifact pipeline hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints docker"
	assert_success
	assert_output --partial 'ghcr.io:443'
	assert_output --partial 'docker.io:443'
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset docker includes the Trivy and attestation hosts (#1081)" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints docker"
	assert_success
	local host
	# Each one was a block-mode failure in the external fixture (Trivy setup
	# exit 7; attest-build-provenance in Merge Manifests) or, for the
	# githubapp.com pair, the private-repository Sigstore instance.
	for host in get.trivy.dev mirror.gcr.io check.trivy.dev \
		token.actions.githubusercontent.com fulcio.sigstore.dev rekor.sigstore.dev \
		timestamp.sigstore.dev tuf-repo-cdn.sigstore.dev \
		fulcio.githubapp.com timestamp.githubapp.com; do
		assert_line "${host}:443"
	done
	# Interactive OIDC and the GCS-hosted TUF root stay out on purpose.
	refute_output --partial 'oauth2.sigstore.dev'
	refute_output --partial 'storage.googleapis.com'
}

@test "egress preset playwright includes browser CDN hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints playwright"
	assert_success
	assert_output --partial 'cdn.playwright.dev:443'
	assert_output --partial 'playwright.azureedge.net:443'
	assert_output --partial 'playwright-akamai.azureedge.net:443'
	assert_output --partial 'registry.npmjs.org:443'
}

@test "egress preset playwright allows install --with-deps on GitHub-hosted runners (#1103)" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints playwright"
	assert_success
	# apt on GitHub-hosted ubuntu runners resolves to the Azure mirror.
	assert_line 'azure.archive.ubuntu.com:80'
	assert_line 'archive.ubuntu.com:80'
	assert_line 'security.ubuntu.com:80'
	# cdn.playwright.dev redirects Chrome-for-Testing builds here.
	assert_line 'storage.googleapis.com:443'
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
	assert_output --partial 'token.actions.githubusercontent.com:443'
	assert_output --partial 'raw.githubusercontent.com:443'
	assert_output --partial 'registry.npmjs.org:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
	assert_output --partial 'oauth2.sigstore.dev:443'
}

@test "egress preset scorecard includes Scorecard API hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints scorecard"
	assert_success
	assert_output --partial 'api.scorecard.dev:443'
	assert_output --partial 'api.securityscorecards.dev:443'
	assert_output --partial 'gcr.io:443'
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset ai-review includes PyPI and uv hosts without provider inference" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints ai-review"
	assert_success
	assert_output --partial 'pypi.org:443'
	assert_output --partial 'files.pythonhosted.org:443'
	assert_output --partial 'astral.sh:443'
	assert_output --partial 'releases.astral.sh:443'
	assert_output --partial 'raw.githubusercontent.com:443'
	assert_output --partial 'api.github.com:443'
	refute_output --partial 'api.anthropic.com:443'
	refute_output --partial 'api.openai.com:443'
	refute_output --partial 'cursor.sh'
}

@test "egress_ai_review_provider_endpoints: empty provider prints nothing" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints '' ''"
	assert_success
	assert_output ""
}

@test "egress_ai_review_provider_endpoints: anthropic api is provider-scoped" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints anthropic api"
	assert_success
	assert_output --partial 'api.anthropic.com:443'
	refute_output --partial 'api.openai.com'
	refute_output --partial 'cursor.sh'
	refute_output --partial 'registry.npmjs.org'
}

@test "egress_ai_review_provider_endpoints: cursor hosts exclude other providers" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints cursor cli"
	assert_success
	assert_output --partial 'downloads.cursor.com:443'
	assert_output --partial 'api2.cursor.sh:443'
	refute_output --partial 'api.anthropic.com'
	refute_output --partial 'api.openai.com'
}

@test "egress_ai_review_provider_endpoints: unsupported populated transport prints nothing" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints cursor api"
	assert_success
	assert_output ""
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints anthropic grpc"
	assert_success
	assert_output ""
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai grpc"
	assert_success
	assert_output ""
}

@test "egress_ai_review_provider_endpoints: empty transport includes api and cli hosts" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints anthropic ''"
	assert_success
	assert_output --partial 'api.anthropic.com:443'
	assert_output --partial 'nodejs.org:443'
	assert_output --partial 'registry.npmjs.org:443'
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai ''"
	assert_success
	assert_output --partial 'api.openai.com:443'
	assert_output --partial 'registry.npmjs.org:443'
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints cursor ''"
	assert_success
	assert_output --partial 'downloads.cursor.com:443'
	assert_output --partial 'repo42.cursor.sh:443'
}

@test "egress_ai_review_provider_endpoints: openai rows are transport-scoped" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai api"
	assert_success
	assert_output --partial 'api.openai.com:443'
	refute_output --partial 'nodejs.org'
	refute_output --partial 'registry.npmjs.org'
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai cli"
	assert_success
	assert_output --partial 'api.openai.com:443'
	assert_output --partial 'nodejs.org:443'
	assert_output --partial 'registry.npmjs.org:443'
}

@test "egress_ai_review_provider_endpoints: cursor cli lists the full shard set" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints cursor cli"
	assert_success
	assert_output --partial 'downloads.cursor.com:443'
	assert_output --partial 'api2.cursor.sh:443'
	assert_output --partial 'api3.cursor.sh:443'
	assert_output --partial 'agentn.global.api5.cursor.sh:443'
	assert_output --partial 'repo42.cursor.sh:443'
}

@test "egress preset osv-scanner includes release assets and OSV API hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints osv-scanner"
	assert_success
	assert_output --partial 'release-assets.githubusercontent.com:443'
	assert_output --partial 'api.osv.dev:443'
	assert_output --partial 'api.deps.dev:443'
	assert_output --partial 'codeload.github.com:443'
}

@test "egress preset quality includes artifact pipeline host" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints quality"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset rust-release includes Rust Docker and Sigstore hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints rust-release"
	assert_success
	assert_output --partial 'crates.io:443'
	# Digest-verified release archives (cross, cargo-binstall) redirect here (#1096).
	assert_output --partial 'release-assets.githubusercontent.com:443'
	assert_output --partial 'docker.io:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
	assert_output --partial 'rekor.sigstore.dev:443'
	assert_output --partial 'tuf-repo-cdn.sigstore.dev:443'
}

@test "egress preset rust-release includes the xwin Windows SDK hosts" {
	# cargo-xwin fetches the MSVC CRT and Windows SDK through aka.ms and the
	# Visual Studio download CDN (#1076).
	run bash -c "source '$PRESETS' && egress_preset_endpoints rust-release"
	assert_success
	assert_output --partial 'aka.ms:443'
	assert_output --partial 'download.visualstudio.microsoft.com:443'
}

@test "egress preset rust-release excludes unrelated quality-only hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints rust-release"
	assert_success
	refute_output --partial 'pypi.org:443'
	refute_output --partial 'semgrep.dev:443'
}

@test "egress preset rust-release includes Ubuntu apt mirrors for musl-tools" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints rust-release"
	assert_success
	assert_output --partial 'archive.ubuntu.com:80'
	assert_output --partial 'azure.archive.ubuntu.com:80'
	assert_output --partial 'security.ubuntu.com:80'
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

@test "egress preset: every name from egress_preset_names returns endpoints" {
	local preset
	while IFS= read -r preset; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset' | grep -c ."
		assert_success
		[[ "$output" -gt 0 ]]
	done < <(bash -c "source '$PRESETS' && egress_preset_names")
}

@test "egress_preset_names: lists every case arm exactly once" {
	# Every `name)` arm in egress_preset_endpoints must be enumerated (the
	# renderer only emits listed names) and no name may repeat.
	local arms names
	arms="$(awk '
		/^egress_preset_endpoints\(\)/ { on = 1; next }
		on && /^}/ { exit }
		on && /^\t[a-z][a-z-]*\)$/ { sub(/^\t/, ""); sub(/\)$/, ""); print }
	' "$PRESETS" | sort)"
	names="$(bash -c "source '$PRESETS' && egress_preset_names" | sort)"
	[[ -n "$arms" ]]
	[[ "$arms" == "$names" ]] || {
		echo "case arms:"
		echo "$arms"
		echo "egress_preset_names:"
		echo "$names"
		return 1
	}
	run bash -c "source '$PRESETS' && egress_preset_names | sort | uniq -d"
	assert_output ""
}

@test "egress preset github-results is github-minimal plus results blob storage" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-results"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
	assert_output --partial '*.blob.core.windows.net:443'
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-minimal | grep -c blob"
	assert_output "0"
}

@test "egress preset python-dist is pypi plus Sigstore attestation hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints python-dist"
	assert_success
	assert_output --partial 'files.pythonhosted.org:443'
	assert_output --partial 'upload.pypi.org:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
	assert_output --partial 'oauth2.sigstore.dev:443'
	assert_output --partial 'sigstore-tuf-root.storage.googleapis.com:443'
}

@test "egress preset npm-publish includes the artifact service for the built tarball" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints npm-publish"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
	assert_output --partial '*.blob.core.windows.net:443'
}

@test "egress preset build-artifact covers every vetted toolchain registry" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints build-artifact"
	assert_success
	assert_output --partial 'bun.sh:443'
	assert_output --partial 'nodejs.org:443'
	assert_output --partial 'registry.npmjs.org:443'
	assert_output --partial 'files.pythonhosted.org:443'
	assert_output --partial 'releases.astral.sh:443'
	assert_output --partial 'sh.rustup.rs:443'
	assert_output --partial 'index.crates.io:443'
}

@test "egress preset shell-test is github-tooling plus Ubuntu apt mirrors" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints shell-test"
	assert_success
	assert_output --partial 'uploads.github.com:443'
	assert_output --partial 'archive.ubuntu.com:80'
	assert_output --partial 'azure.archive.ubuntu.com:80'
	assert_output --partial 'security.ubuntu.com:80'
	assert_output --partial 'security.ubuntu.com:443'
}

@test "egress preset release-recover covers registry probes and the npm resume" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints release-recover"
	assert_success
	assert_output --partial 'pypi.org:443'
	assert_output --partial 'registry.npmjs.org:443'
	assert_output --partial 'ghcr.io:443'
	assert_output --partial 'pkg-containers.githubusercontent.com:443'
	assert_output --partial 'uploads.github.com:443'
	assert_output --partial '*.blob.core.windows.net:443'
	assert_output --partial 'oauth2.sigstore.dev:443'
}

@test "egress preset release-version-pr is github-tooling plus the ecosystem bump registries" {
	# Default of both version-PR reusables (#1093): python/pep621 install
	# tomlkit from PyPI, rust regenerates Cargo.lock via rustup + crates.io.
	run bash -c "source '$PRESETS' && egress_preset_endpoints release-version-pr"
	assert_success
	# Whole-line matches: a --partial on crates.io:443 would be satisfied by
	# static.crates.io:443 alone.
	local host n=0
	while IFS= read -r host; do
		assert_line "$host"
		n=$((n + 1))
	done < <(bash -c "source '$PRESETS' && egress_preset_endpoints github-tooling")
	# The loop must have compared something: an empty substitution would pass vacuously.
	[[ "$n" -ge 8 ]] || fail "github-tooling resolved to only $n hosts"
	assert_line 'uploads.github.com:443'
	assert_line 'pypi.org:443'
	assert_line 'files.pythonhosted.org:443'
	assert_line 'static.rust-lang.org:443'
	assert_line 'crates.io:443'
	assert_line 'static.crates.io:443'
	assert_line 'index.crates.io:443'
	# No publish-side hosts: the bump never uploads anywhere.
	refute_line 'upload.pypi.org:443'
	refute_line 'test.pypi.org:443'
	refute_output --partial 'sigstore'
}

@test "version-PR reusables default egress-preset to release-version-pr" {
	local workflow
	for workflow in reusable-release-version-pr reusable-release-multi-ecosystem; do
		run awk '
			/^      egress-preset:$/ { on = 1; next }
			on && /^        default:/ { gsub(/"/, "", $2); print $2; exit }
			on && /^      [a-z-]+:$/ { on = 0 }
		' "${PROJECT_ROOT}/.github/workflows/${workflow}.yml"
		assert_output "release-version-pr"
	done
}

@test "egress preset external-canary is exactly the GitHub API pair" {
	# .github/workflows/external-consumer-canary.yml (#1074) holds a token for
	# a foreign repository; it must reach nothing but the GitHub API.
	run bash -c "source '$PRESETS' && egress_preset_endpoints external-canary"
	assert_success
	assert_output "$(printf 'github.com:443\napi.github.com:443')"
}

@test "egress presets never emit duplicate hosts" {
	local preset
	while IFS= read -r preset; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset' | sort | uniq -d"
		assert_output ""
	done < <(bash -c "source '$PRESETS' && egress_preset_names")
}
