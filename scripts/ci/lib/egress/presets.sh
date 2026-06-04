#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Canonical egress allowlist presets for reusable workflows
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/presets.sh"
#   egress_preset_endpoints quality
#
# Host lists use printf continuations (not readonly arrays) so kcov attributes
# coverage when a preset is resolved during BATS runs.

[[ -n "${_LGTM_CI_EGRESS_PRESETS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_EGRESS_PRESETS_LOADED=1

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
	github-tooling)
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
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
		;;
	pypi)
		# PyPI / TestPyPI (reusable-publish-homebrew wait-for-package, python dist).
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
		# npm publish + Sigstore attestation (reusable-publish-npm.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			actions.githubusercontent.com:443 \
			codeload.github.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			registry.npmjs.org:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443
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
	sbom)
		# SBOM + Grype scan + Sigstore attestation (py-lintro sbom-on-main.yml).
		printf '%s\n' \
			github.com:443 \
			api.github.com:443 \
			codeload.github.com:443 \
			release-assets.githubusercontent.com:443 \
			objects.githubusercontent.com:443 \
			raw.githubusercontent.com:443 \
			anchore.io:443 \
			get.anchore.io:443 \
			toolbox-data.anchore.io:443 \
			grype.anchore.io:443 \
			pipelines.actions.githubusercontent.com:443 \
			fulcio.sigstore.dev:443 \
			rekor.sigstore.dev:443 \
			timestamp.sigstore.dev:443 \
			tuf-repo-cdn.sigstore.dev:443 \
			sigstore-tuf-root.storage.googleapis.com:443
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
	*)
		echo "unknown egress preset: $preset" >&2
		return 1
		;;
	esac
}
