#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Canonical egress allowlist presets for reusable workflows
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/presets.sh"
#   egress_preset_endpoints quality
#   egress_preset_names
#
# This file is the single source of truth. Reusable workflows do NOT read it
# at run time: step-security/harden-runner installs its agent in the action
# pre hook, before any step (and therefore before any checkout) runs, so the
# allowlist must be a literal at job start. scripts/ci/egress/render-presets.sh
# renders every preset below into a JSON map, and
# scripts/ci/egress/sync-workflow-presets.sh writes that map into each
# reusable workflow's `env.LGTM_CI_EGRESS_PRESETS`; the workflow selects a
# preset by expression (`fromJSON(env.LGTM_CI_EGRESS_PRESETS)[...]`). A BATS
# test re-renders and diffs every workflow, so edit presets here, run the
# sync script, and commit both (#913).
#
# Host lists use printf continuations (not readonly arrays) so kcov attributes
# coverage when a preset is resolved during BATS runs.

[[ -n "${_LGTM_CI_EGRESS_PRESETS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_EGRESS_PRESETS_LOADED=1

# Every preset name egress_preset_endpoints accepts, one per line, in render
# order. Keep this list and the case arms below in sync; test_presets.bats
# asserts that each listed name resolves and that no arm is unlisted.
egress_preset_names() {
	printf '%s\n' \
		github-minimal \
		github-results \
		github-tooling \
		github-pages \
		docker \
		playwright \
		pypi \
		python-dist \
		rubygems \
		npm-publish \
		quality \
		build-artifact \
		shell-test \
		sbom \
		scorecard \
		osv-scanner \
		ai-review \
		rust-release \
		release-recover \
		release-version-pr \
		external-canary \
		duplication-scan \
		results-hosts-drift \
		runner-governor
}

# GitHub's own Actions results storage accounts: the hosts behind job logs,
# job summaries, workflow artifacts (actions/upload-artifact and
# download-artifact v4+) and the Actions cache. Exact hosts, never a
# wildcard over blob.core.windows.net: anyone can create an Azure storage
# account under that domain, so a wildcard would let a compromised step upload
# a token to an account an attacker controls (#1495). test_presets.bats
# rejects a `*.` entry on that domain (and on the other public-registration
# domains it lists) in any preset.
#
# Source, checked 2026-11-12: `GET https://api.github.com/meta`,
# `.domains.actions`, lists exactly productionresultssa0-19, 30-49 and
# 100-199 (140 hosts; every one resolved). The 30-49 and 100-199 ranges were
# added on 2026-10-22, https://github.blog/changelog/2026-10-22-meta-api-endpoints-updated-for-actions-blob-storage/
# ("If you allow individual hosts, add the new hosts to avoid interruptions to
# job summaries and logs"). Observed redirect targets in this repository:
# productionresultssa4, 11 and 13. The docs page "About self-hosted runners"
# (docs.github.com/en/actions/reference/runners/self-hosted-runners) still
# lists only the wildcard, so the meta API is the authority for the range.
#
# When GitHub adds a shard, a job routed to it is blocked by harden-runner and
# fails visibly (an "unavailable" log probe or a failed artifact download),
# never silently. .github/workflows/results-hosts-drift.yml compares this
# list with /meta daily and opens a tracking issue on a difference (#1498).
# The fix is to add the new range here and to the expected
# ranges in test_presets.bats, then re-run
# scripts/ci/egress/sync-workflow-presets.sh. Sorted in numeric order, as the
# meta API lists them; printf (not an array) keeps kcov coverage attribution.
egress_github_results_storage_endpoints() {
	printf 'productionresultssa%s.blob.core.windows.net:443\n' \
		{0..19} {30..49} {100..199}
}

egress_preset_endpoints() {
	local preset="${1:?preset name required}"

	case "$preset" in
	github-minimal)
		# summary/report publish jobs: GitHub API, tooling checkout, and workflow artifacts.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443
		;;
	github-results)
		# github-minimal plus GitHub's results blob storage
		# (reusable-auto-rerun-on-infra-failure, reusable-all-checks-gate).
		# `GET /actions/jobs/{id}/logs` answers 302 straight to a sharded
		# productionresultssa<N>.blob.core.windows.net host, so
		# without it every #794 ingestion probe dies at the network layer and
		# the evidence table reads "unavailable" for every job — a uniform
		# failure indistinguishable from "the raw endpoint has nothing". Kept
		# out of github-minimal: no other publish job needs blob egress (#911).
		# The exact hosts, their source and what happens when GitHub adds a
		# shard: egress_github_results_storage_endpoints above (#1495).
		egress_preset_endpoints github-minimal
		egress_github_results_storage_endpoints
		;;
	github-tooling)
		# release-assets.githubusercontent.com: GitHub release-asset CDN — actions
		# that download release binaries (e.g. codeql-action CLI bundle) redirect
		# here; absent it, toolcache misses fail under block policy (#517).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			uploads.github.com:443 \
			pipelines.actions.githubusercontent.com:443
		;;
	github-pages)
		# GitHub Pages deploy/publish (OIDC + artifact upload).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443
		;;
	docker)
		# Docker image pull/push (reusable-docker.yml), plus what the family's
		# optional steps reach under block mode (#1081):
		# - `scan`: GitHub Releases (verified pinned Trivy binary) and
		#   mirror.gcr.io (Trivy DB). Scanner steps disable update notices and
		#   telemetry, so neither obsolete get.trivy.dev nor check.trivy.dev
		#   is needed; unresolvable allowlist hosts break hardener startup.
		# - provenance/SBOM attestation on push, when enabled:
		#   token.actions.githubusercontent.com (OIDC) and the Sigstore
		#   public-good hosts for public repositories (proven by the external
		#   fixture), fulcio/timestamp.githubapp.com for private ones (GitHub's
		#   Sigstore instance, chosen by actions/attest; not fixture-proven).
		# Keyless `cosign-sign` uses the same OIDC/Fulcio/Rekor/TUF hosts; it
		# is expected to work but the fixture does not sign yet.
		# Docker Hub's S3 blob redirect below was explicitly denied by the fixture
		# hardener during the BuildKit pull (#1269).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			github-releases.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			token.actions.githubusercontent.com:443 \
			ghcr.io:443 \
			pkg-containers.githubusercontent.com:443 \
			docker.io:443 \
			registry-1.docker.io:443 \
			auth.docker.io:443 \
			production.cloudflare.docker.com:443 \
			production.cloudfront.docker.com:443 \
			docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443 \
			mirror.gcr.io:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			timestamp.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			fulcio.githubapp.com:443 \
			timestamp.githubapp.com:443
		;;
	playwright)
		# Playwright browser downloads + package managers (reusable-test-e2e*.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			registry.npmjs.org:443 \
			bun.sh:443 \
			cdn.playwright.dev:443 \
			playwright.azureedge.net:443 \
			playwright-akamai.azureedge.net:443 \
			storage.googleapis.com:443 \
			archive.ubuntu.com:80 \
			azure.archive.ubuntu.com:80 \
			security.ubuntu.com:80
		# archive.ubuntu.com/security.ubuntu.com use :80 for apt HTTP mirrors in CI images;
		# GitHub-hosted runners resolve apt to azure.archive.ubuntu.com, which
		# `playwright install --with-deps` needs for browser system packages (#1103).
		# cdn.playwright.dev redirects Chrome-for-Testing builds to
		# storage.googleapis.com/chrome-for-testing-public/... (path-style), so the
		# bucket-scoped host form used for sigstore-tuf-root cannot match; the whole
		# GCS host is the narrowest entry a host-level allowlist can express.
		# Accepted risk: it reaches any GCS bucket, so job code (e.g. a package
		# postinstall) could write to one it controls. Callers without Chromium
		# can drop it with allowed-endpoints in replace mode.
		;;
	pypi)
		# PyPI / TestPyPI (python dist, wait-for-package).
		# TestPyPI uploads use test.pypi.org/legacy/; upload.test.pypi.org
		# does not resolve and breaks harden-runner DNS initialization (#1206).
		# releases.astral.sh + release-assets.githubusercontent.com: setup-uv
		# (via the setup-python composite) downloads the uv binary from the
		# Astral mirror, falling back to GitHub Releases, whenever the pinned
		# uv version is not already in the runner tool cache.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			release-assets.githubusercontent.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			releases.astral.sh:443 \
			test.pypi.org:443 \
			upload.pypi.org:443
		;;
	python-dist)
		# Python dist build + Sigstore attestation (reusable-build-python-dist.yml).
		# pypi plus the keyless-signing hosts; #992 tracks folding the
		# Sigstore/OIDC hosts into the pypi preset itself.
		egress_preset_endpoints pypi
		printf '%s\n' \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			timestamp.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			sigstore-tuf-root.storage.googleapis.com:443 \
			oauth2.sigstore.dev:443
		;;
	rubygems)
		# RubyGems publish (reusable-publish-gem.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			rubygems.org:443 \
			api.rubygems.org:443 \
			index.rubygems.org:443
		;;
	npm-publish)
		# npm publish + Sigstore attestation (reusable-publish-npm-set.yml).
		# oauth2.sigstore.dev + token.actions.githubusercontent.com are required
		# for OIDC trusted publishing / provenance token exchange.
		# pipelines.actions.githubusercontent.com + GitHub's results storage
		# (productionresultssa<N>.blob.core.windows.net) are the artifact
		# service: the publish job downloads the built tarball from the
		# preceding build job. The exact hosts, their source and what happens
		# when GitHub adds a shard: egress_github_results_storage_endpoints
		# above (#1495).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			actions.githubusercontent.com:443 \
			token.actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443
		egress_github_results_storage_endpoints
		printf '%s\n' \
			registry.npmjs.org:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			oauth2.sigstore.dev:443
		;;
	quality)
		# Docker-based lintro chk (py-lintro docker-ci dogfooding lint; py-lintro#939).
		# Docker Hub image pulls use the same exact blob redirect as docker (#1269).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			release-assets.githubusercontent.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			github-releases.githubusercontent.com:443 \
			ghcr.io:443 \
			pkg-containers.githubusercontent.com:443 \
			docker.io:443 \
			registry-1.docker.io:443 \
			auth.docker.io:443 \
			production.cloudflare.docker.com:443 \
			production.cloudfront.docker.com:443 \
			docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443 \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			static.rust-lang.org:443 \
			bun.sh:443 \
			astral.sh:443 \
			releases.astral.sh:443 \
			sh.rustup.rs:443 \
			deb.debian.org:80 \
			registry.npmjs.org:443 \
			crates.io:443 \
			static.crates.io:443 \
			index.crates.io:443 \
			semgrep.dev:443 \
			metrics.semgrep.dev:443 \
			api.osv.dev:443 \
			api.deps.dev:443
		;;
	build-artifact)
		# reusable-build-artifact.yml: the setup host and ecosystem registry
		# of every vetted toolchain (bun/node, uv/PyPI, rustup/crates), so any
		# `toolchain` value builds with no egress configuration.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			release-assets.githubusercontent.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			github-releases.githubusercontent.com:443 \
			bun.sh:443 \
			nodejs.org:443 \
			registry.npmjs.org:443 \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			astral.sh:443 \
			releases.astral.sh:443 \
			static.rust-lang.org:443 \
			sh.rustup.rs:443 \
			crates.io:443 \
			static.crates.io:443 \
			index.crates.io:443
		;;
	shell-test)
		# reusable-test-shell.yml: github-tooling plus the Ubuntu apt mirrors
		# (bats/kcov install). archive/security use :80 for apt HTTP mirrors in
		# CI images, with HTTPS fallbacks for archive/security.
		egress_preset_endpoints github-tooling
		printf '%s\n' \
			archive.ubuntu.com:80 \
			archive.ubuntu.com:443 \
			azure.archive.ubuntu.com:80 \
			security.ubuntu.com:80 \
			security.ubuntu.com:443
		;;
	sbom)
		# SBOM + Grype scan + Sigstore attestation/cosign + release asset upload.
		# oauth2.sigstore.dev is required for keyless cosign OIDC in release-assets
		# mode (#524); uploads.github.com for gh release upload.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			release-assets.githubusercontent.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			uploads.github.com:443 \
			anchore.io:443 \
			get.anchore.io:443 \
			toolbox-data.anchore.io:443 \
			grype.anchore.io:443 \
			pipelines.actions.githubusercontent.com:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			timestamp.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			sigstore-tuf-root.storage.googleapis.com:443 \
			oauth2.sigstore.dev:443
		;;
	scorecard)
		# OpenSSF Scorecard (reusable-scorecards.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			gcr.io:443 \
			api.osv.dev:443 \
			api.scorecard.dev:443 \
			api.securityscorecards.dev:443
		;;
	osv-scanner)
		# Direct osv-scanner binary install + scan (reusable-vuln-suppression-check).
		egress_preset_endpoints github-tooling
		printf '%s\n' \
			api.osv.dev:443 \
			api.deps.dev:443
		;;
	ai-review)
		# AI code review (reusable-ai-review.yml): GitHub checkout/tooling + gh PR
		# diff API and uv/PyPI install of pinned lintro[ai]. Provider inference
		# hosts are NOT in this baseline — reusable-ai-review.yml appends them
		# inline at harden time from the visible (input → Actions variable)
		# pair; egress_ai_review_provider_endpoints below is the canonical
		# matrix those inline lists are cross-checked against.
		# raw.githubusercontent.com is required (astral setup-uv/self-checks fetch
		# from it — its omission previously broke py-lintro's dogfood workflow).
		egress_preset_endpoints github-tooling
		printf '%s\n' \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			astral.sh:443 \
			releases.astral.sh:443
		;;
	rust-release)
		# Rust cross-compile release builds (reusable-build-rust-binaries.yml).
		# Minimal base: GitHub checkout/tooling, Rust/crates, cross Docker, apt, Sigstore.
		# release-assets.githubusercontent.com is where github.com/<repo>/releases/
		# download/ redirects; install-cross.sh, install-cargo-xwin.sh and the
		# setup-rust binstall step fetch their digest-verified release archives
		# from it (#1096). aka.ms and download.visualstudio.microsoft.com are
		# where xwin fetches the Windows SDK and CRT manifest and payloads for
		# the MSVC leg (#1076).
		# Cross Docker pulls need the same exact Docker Hub blob redirect (#1269).
		egress_preset_endpoints github-minimal
		printf '%s\n' \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			aka.ms:443 \
			download.visualstudio.microsoft.com:443 \
			static.rust-lang.org:443 \
			sh.rustup.rs:443 \
			crates.io:443 \
			static.crates.io:443 \
			index.crates.io:443 \
			ghcr.io:443 \
			pkg-containers.githubusercontent.com:443 \
			docker.io:443 \
			registry-1.docker.io:443 \
			auth.docker.io:443 \
			production.cloudflare.docker.com:443 \
			production.cloudfront.docker.com:443 \
			docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443 \
			archive.ubuntu.com:80 \
			azure.archive.ubuntu.com:80 \
			security.ubuntu.com:80 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			timestamp.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			sigstore-tuf-root.storage.googleapis.com:443
		;;
	release-recover)
		# reusable-release-recover.yml: the registry probes (PyPI, npm, GHCR),
		# the GitHub API + artifact service, release-asset upload, and the npm
		# resume (registry + Sigstore). Artifact and log downloads land on
		# GitHub's results storage: egress_github_results_storage_endpoints
		# above has the exact hosts, their source and what happens when GitHub
		# adds a shard (#1495).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			uploads.github.com:443 \
			actions.githubusercontent.com:443 \
			token.actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443
		egress_github_results_storage_endpoints
		printf '%s\n' \
			pypi.org:443 \
			registry.npmjs.org:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			oauth2.sigstore.dev:443 \
			ghcr.io:443 \
			pkg-containers.githubusercontent.com:443
		;;
	release-version-pr)
		# Default of reusable-release-version-pr.yml and
		# reusable-release-multi-ecosystem.yml: github-tooling plus every
		# registry an ecosystem bump script reaches under block policy.
		# `ecosystems: python` / kind `pep621` `pip install tomlkit` when the
		# runner lacks it (PyPI, #1093); `ecosystems: rust` installs the
		# toolchain via dtolnay/rust-toolchain (static.rust-lang.org) and
		# runs `cargo generate-lockfile` against the sparse index
		# (index.crates.io). crates.io / static.crates.io are not strictly
		# needed by those two commands; they stay for parity with the
		# rust-release and build-artifact presets so a cargo that falls back
		# to the git index or fetches a .crate does not fail opaquely. node,
		# ruby, swift, dart and kotlin edit files in place with no registry
		# access. reusable-release-multi-ecosystem.yml shares this preset
		# although its kinds (npm|raw|gemspec|pep621) only reach PyPI.
		egress_preset_endpoints github-tooling
		printf '%s\n' \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			static.rust-lang.org:443 \
			crates.io:443 \
			static.crates.io:443 \
			index.crates.io:443
		;;
	runner-governor)
		# Installer + CLI backend from v0.5.3; audit dispatch still required.
		egress_preset_endpoints github-minimal
		printf '%s\n' \
			clireleases.blacksmith.sh:443 \
			backend.blacksmith.sh:443
		;;
	external-canary)
		# .github/workflows/external-consumer-canary.yml (#1074): the canary
		# only talks to the GitHub API (fixture branch, dispatches, run polling)
		# and clones its own scripts over github.com. Nothing else, so a
		# compromised candidate cannot use the canary job as an egress path.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443
		;;
	duplication-scan)
		# Org blob reads and lgtm-ci issue reconciliation; no source execution.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443
		;;
	results-hosts-drift)
		# .github/workflows/results-hosts-drift.yml (#1498): checkout over
		# github.com, GET /meta and the tracking issue over api.github.com.
		# Deliberately none of the results storage hosts it compares.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443
		;;
	*)
		echo "unknown egress preset: $preset" >&2
		return 1
		;;
	esac
}

# Canonical harden-runner host matrix for one (provider, transport) pair.
# This function is NOT on the production harden path: harden-runner runs
# before any checkout, so reusable-ai-review.yml appends provider hosts via
# generated literal workflow expressions instead. ai_review_matrix.sh owns all
# tuple capabilities and hosts; sync_ai_review_matrix.py renders job-start egress.
# Incomplete/unsupported tuples grant no provider egress.
egress_ai_review_provider_endpoints() {
	# shellcheck source=../ai_review_matrix.sh
	source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai_review_matrix.sh"
	ai_review_matrix_field "${1:-}" "${2:-}" "${3-$(ai_review_default_auth "${1:-}" "${2:-}")}" 8 | tr ' ' '\n'
}
