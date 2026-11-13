#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for egress allowlist presets

load "../../../../helpers/common"

PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"

# Domains under which anyone can register a subdomain (a storage account,
# bucket, app or site). A `*` entry under one of them admits hosts an attacker
# can create, so no preset may carry one (#1495). This is the only copy of
# the list; add a domain when a preset starts reaching a new shared-hosting
# domain.
PUBLIC_REGISTRATION_DOMAINS=(
	blob.core.windows.net
	azurewebsites.net
	azureedge.net
	cloudfront.net
	s3.amazonaws.com
	storage.googleapis.com
	herokuapp.com
	github.io
	pages.dev
	workers.dev
	vercel.app
	netlify.app
)

# GitHub's Actions results storage shards, as published in
# `GET https://api.github.com/meta` `.domains.actions` (checked 2026-11-12).
# Deliberately a second copy of the ranges in presets.sh: a change there must
# be made here too.
expected_results_storage_hosts() {
	local n
	for n in {0..19} {30..49} {100..199}; do
		printf 'productionresultssa%s.blob.core.windows.net:443\n' "$n"
	done
}

# Print every wildcard entry on stdin (one host:port per line) that falls
# under a PUBLIC_REGISTRATION_DOMAINS domain.
public_registration_wildcards() {
	local entry host domain
	while IFS= read -r entry; do
		[[ "$entry" == *'*'* ]] || continue
		host="${entry%:*}"
		for domain in "${PUBLIC_REGISTRATION_DOMAINS[@]}"; do
			if [[ "$host" == *".$domain" || "$host" == "$domain" ]]; then
				printf '%s\n' "$entry"
				break
			fi
		done
	done
}

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

@test "Docker Hub presets include the observed BuildKit blob redirect (#1269)" {
	local preset
	for preset in docker quality rust-release; do
		run bash -c 'source "$1"; egress_preset_endpoints "$2"' test "$PRESETS" "$preset"
		assert_success
		assert_line 'registry-1.docker.io:443'
		assert_line 'auth.docker.io:443'
		assert_line 'docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443'
	done
}

@test "Docker blob egress permits only the exact AWS host and HTTPS port" {
	local preset
	while IFS= read -r preset; do
		run bash -c 'source "$1"; egress_preset_endpoints "$2"' test "$PRESETS" "$preset"
		assert_success
		# Reject broader AWS/S3 wildcards, other buckets/regions and other ports.
		run awk '/amazonaws[.]com/ { print }' <<<"$output"
		assert_success
		case "$preset" in
		docker | quality | rust-release)
			assert_output 'docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443'
			;;
		*) assert_output "" ;;
		esac
	done < <(bash -c 'source "$1"; egress_preset_names' test "$PRESETS")
}

@test "egress preset docker includes the Trivy and attestation hosts (#1081)" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints docker"
	assert_success
	local host
	# Trivy uses verified GitHub release assets and mirror.gcr.io for its DB.
	# OIDC and sigstore.dev hosts serve attest-build-provenance in Merge
	# Manifests. The githubapp.com pair is the
	# private-repository Sigstore instance (actions/toolkit attest
	# endpoints.ts), which a public fixture cannot reach.
	for host in release-assets.githubusercontent.com mirror.gcr.io \
		token.actions.githubusercontent.com fulcio.sigstore.dev rekor.sigstore.dev \
		timestamp.sigstore.dev tuf-repo-cdn.sigstore.dev \
		fulcio.githubapp.com timestamp.githubapp.com; do
		assert_line "${host}:443"
	done
	refute_output --partial get.trivy.dev
	refute_output --partial check.trivy.dev
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
	# setup-bun's release download redirects here on a cold cache (#1467).
	assert_output --partial 'release-assets.githubusercontent.com:443'
	assert_output --partial 'registry.npmjs.org:443'
}

@test "egress preset playwright allows install-deps on GitHub-hosted runners (#1103)" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints playwright"
	assert_success
	# apt on GitHub-hosted ubuntu runners resolves to the Azure mirror.
	assert_line 'azure.archive.ubuntu.com:80'
	assert_line 'archive.ubuntu.com:80'
	assert_line 'security.ubuntu.com:80'
	# The runner's mirror list falls back to these over HTTPS (#1432).
	assert_line 'archive.ubuntu.com:443'
	assert_line 'security.ubuntu.com:443'
	# cdn.playwright.dev redirects Chrome-for-Testing builds here.
	assert_line 'storage.googleapis.com:443'
}

@test "egress preset pypi includes package index hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints pypi"
	assert_success
	assert_output --partial 'pypi.org:443'
	assert_output --partial 'files.pythonhosted.org:443'
}

@test "Python presets use the real PyPI and TestPyPI upload hosts" {
	local preset
	for preset in pypi python-dist; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset'"
		assert_success
		assert_line 'upload.pypi.org:443'
		assert_line 'test.pypi.org:443'
		refute_line 'upload.test.pypi.org:443'
	done
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

@test "egress preset npm-publish includes the GitHub release asset host for setup-node" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints npm-publish"
	assert_success
	# setup-node downloads Node from actions/node-versions releases (#1467).
	assert_line 'release-assets.githubusercontent.com:443'
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

@test "egress_ai_review_provider_endpoints: incomplete tuple never broadens hosts" {
	for provider in anthropic cursor openai; do
		run bash -c 'source "$1"; egress_ai_review_provider_endpoints "$2" ""' test "$PRESETS" "$provider"
		assert_success
		assert_output ""
	done
}

@test "egress_ai_review_provider_endpoints: openai rows are transport-scoped" {
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai api"
	assert_success
	assert_output --partial 'api.openai.com:443'
	refute_output --partial 'nodejs.org'
	refute_output --partial 'registry.npmjs.org'
	run bash -c "source '$PRESETS' && egress_ai_review_provider_endpoints openai cli"
	assert_success
	assert_output --partial 'chatgpt.com:443'
	assert_output --partial 'auth.openai.com:443'
	refute_output --partial 'api.openai.com:443'
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
	# The runner's mirror list falls back to these over HTTPS (#1432).
	assert_line 'archive.ubuntu.com:443'
	assert_line 'security.ubuntu.com:443'
}

@test "egress preset pypi includes artifact pipeline host" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints pypi"
	assert_success
	assert_output --partial 'pipelines.actions.githubusercontent.com:443'
}

@test "egress preset pypi includes the setup-uv download hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints pypi"
	assert_success
	assert_line 'releases.astral.sh:443'
	assert_line 'release-assets.githubusercontent.com:443'
}

@test "egress preset rejects unknown name" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints not-a-preset"
	assert_failure
}

@test "egress preset duplication-scan is exactly the GitHub API pair" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints duplication-scan"
	assert_success
	assert_output $'github.com:443\napi.github.com:443'
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
	assert_output "$(
		bash -c "source '$PRESETS' && egress_preset_endpoints github-minimal"
		expected_results_storage_hosts
	)"
	run bash -c "source '$PRESETS' && egress_preset_endpoints github-minimal | grep -c blob"
	assert_output "0"
}

@test "egress results storage: exactly GitHub's published productionresultssa shards" {
	# Exact hosts instead of a blob.core.windows.net wildcard (#1495); the
	# source and the shard-added failure mode are documented in presets.sh.
	run bash -c "source '$PRESETS' && egress_github_results_storage_endpoints"
	assert_success
	assert_output "$(expected_results_storage_hosts)"
	# The count follows the expected list (140 hosts as of 2026-11-12), so a
	# new shard is one edit to expected_results_storage_hosts, not two.
	local expected_count
	expected_count="$(expected_results_storage_hosts | wc -l | tr -d ' ')"
	[[ "${#lines[@]}" -eq "$expected_count" ]] ||
		fail "expected ${expected_count} hosts, got ${#lines[@]}"
}

@test "egress presets: every blob.core.windows.net entry is a results shard, identical across presets" {
	# github-results, npm-publish and release-recover all reach the results
	# storage; each must carry the full shard list and nothing else on the
	# Azure blob domain, so the three cannot drift apart.
	local preset with_blob=()
	while IFS= read -r preset; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset' | grep 'blob\.core\.windows\.net' | sort"
		[[ -n "$output" ]] || continue
		with_blob+=("$preset")
		[[ "$output" == "$(expected_results_storage_hosts | sort)" ]] ||
			fail "preset $preset: blob.core.windows.net entries differ from the results shards"
	done < <(bash -c "source '$PRESETS' && egress_preset_names")
	[[ "${with_blob[*]}" == "github-results npm-publish release-recover" ]] ||
		fail "presets with results storage: ${with_blob[*]}"
}

@test "egress presets: no wildcard under a public-registration domain" {
	# Anyone can create a storage account under blob.core.windows.net (or an
	# app, bucket or site under the other listed domains), so a wildcard there
	# lets a compromised step send a token to an attacker's account (#1495).
	local preset n=0
	while IFS= read -r preset; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset'"
		assert_success
		run public_registration_wildcards <<<"$output"
		[[ -z "$output" ]] || fail "preset $preset allows: $output"
		n=$((n + 1))
	done < <(bash -c "source '$PRESETS' && egress_preset_names")
	[[ "$n" -ge 20 ]] || fail "checked only $n presets"
}

@test "public_registration_wildcards: flags each listed domain and spares exact hosts" {
	# The guard above passes vacuously if this checker stops matching.
	local domain
	for domain in "${PUBLIC_REGISTRATION_DOMAINS[@]}"; do
		run public_registration_wildcards <<<"*.${domain}:443"
		assert_output "*.${domain}:443"
	done
	run public_registration_wildcards <<<'productionresultssa*.blob.core.windows.net:443'
	assert_output 'productionresultssa*.blob.core.windows.net:443'
	run public_registration_wildcards <<<"$(printf '%s\n' \
		productionresultssa13.blob.core.windows.net:443 \
		'*.actions.githubusercontent.com:443' \
		'*.blob.core.windows.net.example:443')"
	assert_output ""
}

@test "egress preset python-dist is pypi plus Sigstore attestation hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints python-dist"
	assert_success
	assert_output --partial 'files.pythonhosted.org:443'
	assert_output --partial 'upload.pypi.org:443'
	assert_output --partial 'fulcio.sigstore.dev:443'
	assert_output --partial 'oauth2.sigstore.dev:443'
	assert_output --partial 'sigstore-tuf-root.storage.googleapis.com:443'
	# Inherited from pypi: setup-uv download hosts.
	assert_line 'releases.astral.sh:443'
	assert_line 'release-assets.githubusercontent.com:443'
}

@test "egress preset npm-publish includes the artifact service for the built tarball" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints npm-publish"
	assert_success
	assert_line 'pipelines.actions.githubusercontent.com:443'
	local host
	while IFS= read -r host; do
		assert_line "$host"
	done < <(expected_results_storage_hosts)
	refute_output --partial '*'
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
	assert_line 'archive.ubuntu.com:443'
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
	assert_output --partial 'oauth2.sigstore.dev:443'
	local host
	while IFS= read -r host; do
		assert_line "$host"
	done < <(expected_results_storage_hosts)
	refute_output --partial '*'
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
	# a foreign repository; it must reach nothing but the GitHub API. In
	# particular no wildcard: anyone can create a storage account under
	# blob.core.windows.net, so the infrastructure retry reads check-run
	# annotations from api.github.com instead of job logs (#1475).
	run bash -c "source '$PRESETS' && egress_preset_endpoints external-canary"
	assert_success
	assert_output "$(printf 'github.com:443\napi.github.com:443')"
	refute_output --partial '*'
}

@test "egress presets never emit duplicate hosts" {
	local preset
	while IFS= read -r preset; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$preset' | sort | uniq -d"
		assert_output ""
	done < <(bash -c "source '$PRESETS' && egress_preset_names")
}

@test "egress_ai_review_provider_endpoints: explicit API-key CLI excludes OAuth hosts" {
	run bash -c 'source "$1"; egress_ai_review_provider_endpoints openai cli api_key' test "$PRESETS"
	assert_output --partial 'api.openai.com:443'
	refute_output --partial 'chatgpt.com'
	refute_output --partial 'auth.openai.com'
}

@test "runner governor preset extends GitHub minimal with pinned release and backend hosts" {
	run bash -c "source '$PRESETS' && egress_preset_endpoints runner-governor"
	assert_success
	assert_output --partial 'api.github.com:443'
	assert_output --partial 'clireleases.blacksmith.sh:443'
	assert_output --partial 'backend.blacksmith.sh:443'
	refute_output --partial 'get.blacksmith.sh'
}

@test "presets: the full results-host lists in the docs and examples match the preset" {
	local expected file
	expected="$(bash -c 'source "$1" && egress_github_results_storage_endpoints' _ \
		"${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh" | sort)"
	for file in docs/workflow-contract.md examples/publish-python-release.yml \
		examples/publish-npm-set.yml; do
		run bash -c "grep -oE 'productionresultssa[0-9]+\.blob\.core\.windows\.net:443' \"\$1\" | sort" _ \
			"${PROJECT_ROOT}/${file}"
		assert_success
		assert_output "$expected"
	done
}
