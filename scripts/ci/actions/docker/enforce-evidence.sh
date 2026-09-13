#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Warn when a pushed image build opted out of provenance or SBOM.
#
# The Docker reusables always attach provenance and an SBOM to a pushed image
# (lgtm-ci release-security policy, section 1); the opt-out inputs apply only
# to builds that do not push. This step makes the override visible in the run
# annotations so a caller learns its input was ignored.
#
# Environment variables:
#   PUSH       - "true" when the build pushes (required)
#   PROVENANCE - the caller's provenance input (default: true)
#   SBOM       - the caller's sbom input (default: true)
#
# Sourced by build-docker.sh (STEP=enforce-evidence); log helpers come from it.

: "${PUSH:?PUSH is required}"
: "${PROVENANCE:=true}"
: "${SBOM:=true}"

if [[ "$PUSH" != "true" ]]; then
	log_info "Build does not push; provenance=${PROVENANCE} sbom=${SBOM} honoured as given"
else
	if [[ "$PROVENANCE" != "true" ]]; then
		echo "::warning title=provenance enforced on push::provenance=${PROVENANCE} ignored: a pushed image must carry build provenance (lgtm-ci release-security policy, section 1); attesting anyway"
		log_warn "provenance=${PROVENANCE} overridden to true for a pushed image (release-security policy)"
	fi
	if [[ "$SBOM" != "true" ]]; then
		echo "::warning title=sbom enforced on push::sbom=${SBOM} ignored: a pushed image must carry an SBOM (lgtm-ci release-security policy, section 1); generating anyway"
		log_warn "sbom=${SBOM} overridden to true for a pushed image (release-security policy)"
	fi
fi
