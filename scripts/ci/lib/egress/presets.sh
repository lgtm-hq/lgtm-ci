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
		release-version-pr
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
		# (reusable-auto-rerun-on-infra-failure). `GET /actions/jobs/{id}/logs`
		# answers 302 straight to a sharded *.blob.core.windows.net host, so
		# without it every #794 ingestion probe dies at the network layer and
		# the evidence table reads "unavailable" for every job — a uniform
		# failure indistinguishable from "the raw endpoint has nothing". Kept
		# out of github-minimal: no other publish job needs blob egress (#911).
		egress_preset_endpoints github-minimal
		printf '%s\n' \
			'*.blob.core.windows.net:443'
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
		# Docker image pull/push (reusable-docker.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
			github-releases.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			ghcr.io:443 \
			pkg-containers.githubusercontent.com:443 \
			docker.io:443 \
			registry-1.docker.io:443 \
			auth.docker.io:443 \
			production.cloudflare.docker.com:443 \
			production.cloudfront.docker.com:443
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
			archive.ubuntu.com:80 \
			security.ubuntu.com:80
		# archive.ubuntu.com/security.ubuntu.com use :80 for apt HTTP mirrors in CI images.
		;;
	pypi)
		# PyPI / TestPyPI (python dist, wait-for-package).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			pypi.org:443 \
			files.pythonhosted.org:443 \
			test.pypi.org:443 \
			upload.pypi.org:443 \
			upload.test.pypi.org:443
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
		# pipelines.actions.githubusercontent.com + *.blob.core.windows.net
		# are the artifact service: the publish job downloads the built
		# tarball from the preceding build job.
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			actions.githubusercontent.com:443 \
			token.actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			pipelines.actions.githubusercontent.com:443 \
			'*.blob.core.windows.net:443' \
			registry.npmjs.org:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			oauth2.sigstore.dev:443
		;;
	quality)
		# Docker-based lintro chk (py-lintro docker-ci dogfooding lint; py-lintro#939).
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
		# CI images; security.ubuntu.com also answers on :443.
		egress_preset_endpoints github-tooling
		printf '%s\n' \
			archive.ubuntu.com:80 \
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
		# download/ redirects; install-cross.sh and the setup-rust binstall step
		# fetch their digest-verified release archives from it (#1096).
		egress_preset_endpoints github-minimal
		printf '%s\n' \
			raw.githubusercontent.com:443 \
			release-assets.githubusercontent.com:443 \
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
		# resume (registry + Sigstore).
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
			pipelines.actions.githubusercontent.com:443 \
			'*.blob.core.windows.net:443' \
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
	*)
		echo "unknown egress preset: $preset" >&2
		return 1
		;;
	esac
}

# Canonical harden-runner host matrix for one (provider, transport) pair.
# This function is NOT on the production harden path: harden-runner runs
# before any checkout, so reusable-ai-review.yml appends provider hosts via
# inline YAML expressions instead. Integration bats cross-check those inline
# lists against this function — edit them together, never one side alone.
# Empty provider prints nothing — no provider's hosts belong in the baseline.
# When transport is empty but provider is set, both that provider's api and
# cli hosts are included so an unresolved transport cannot silently block.
# A rotated Cursor shard (e.g. repo43.cursor.sh) is named in the failed run's
# harden-runner summary; add it here and in the workflow env list together.
egress_ai_review_provider_endpoints() {
	local provider="${1:-}"
	local transport="${2:-}"
	provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
	transport="$(printf '%s' "$transport" | tr '[:upper:]' '[:lower:]')"

	case "$provider" in
	anthropic)
		if [[ -n "$transport" && "$transport" != "api" && "$transport" != "cli" ]]; then
			return 0
		fi
		printf '%s\n' api.anthropic.com:443
		if [[ -z "$transport" || "$transport" == "cli" ]]; then
			printf '%s\n' \
				nodejs.org:443 \
				registry.npmjs.org:443
		fi
		;;
	cursor)
		# Cursor has no api transport. Empty transport keeps the fallback.
		if [[ -n "$transport" && "$transport" != "cli" ]]; then
			return 0
		fi
		printf '%s\n' \
			downloads.cursor.com:443 \
			api2.cursor.sh:443 \
			api3.cursor.sh:443 \
			agentn.global.api5.cursor.sh:443 \
			repo42.cursor.sh:443
		;;
	openai)
		if [[ -n "$transport" && "$transport" != "api" && "$transport" != "cli" ]]; then
			return 0
		fi
		printf '%s\n' api.openai.com:443
		if [[ -z "$transport" || "$transport" == "cli" ]]; then
			printf '%s\n' \
				nodejs.org:443 \
				registry.npmjs.org:443
		fi
		;;
	esac
}
