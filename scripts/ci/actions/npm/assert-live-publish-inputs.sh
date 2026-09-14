#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail-closed preconditions for a LIVE npm package-set publish,
#          checked before anything is downloaded, verified, packed, or
#          written. Dry-runs stay permissive: they never touch the registry.
#
# A live run must
#   - run on a GitHub-hosted runner: npm trusted publishing and provenance
#     are not issued on self-hosted runners, and the job holds id-token: write;
#   - carry a checksums manifest plus signer-repo and signer-workflow, so the
#     artifacts are verified (sha256 + attestation) before npm pack — the
#     release security policy forbids publishing unverified artifacts;
#   - publish with `access: public` while provenance or post-publish
#     verification is on: npm issues automatic provenance only for public
#     packages from public repositories, and the post-publish step reads the
#     registry unauthenticated (`npm view` / `npm install`; trusted publishing
#     authenticates publish commands only), so a restricted package would be
#     published irreversibly and then always fail verification.
#
# Environment:
#   LIVE                 1 for a live publish; anything else is a dry-run
#   RUNNER_ENVIRONMENT   github-hosted or self-hosted (from runner.environment)
#   CHECKSUMS_FILE       checksums-file input
#   SIGNER_REPO          signer-repo input
#   SIGNER_WORKFLOW      signer-workflow input
#   ACCESS               access input (default public)
#   PROVENANCE           1 when the provenance input is on
#   POST_PUBLISH_VERIFY  1 when the post-publish-verify input is on

set -euo pipefail

LIVE="${LIVE:-0}"
RUNNER_ENVIRONMENT="${RUNNER_ENVIRONMENT:-}"
CHECKSUMS_FILE="${CHECKSUMS_FILE:-}"
SIGNER_REPO="${SIGNER_REPO:-}"
SIGNER_WORKFLOW="${SIGNER_WORKFLOW:-}"
ACCESS="${ACCESS:-public}"
PROVENANCE="${PROVENANCE:-1}"
POST_PUBLISH_VERIFY="${POST_PUBLISH_VERIFY:-1}"

if [[ "$LIVE" != "1" ]]; then
	echo "Dry-run: live-publish preconditions (hosted runner, checksums-file, signer-repo, signer-workflow) are not enforced."
	missing=()
	[[ -n "$CHECKSUMS_FILE" ]] || missing+=("checksums-file")
	[[ -n "$SIGNER_REPO" ]] || missing+=("signer-repo")
	[[ -n "$SIGNER_WORKFLOW" ]] || missing+=("signer-workflow")
	if ((${#missing[@]} > 0)); then
		echo "::notice::${missing[*]} empty; a live publish with these inputs would be refused. Set checksums-file, signer-repo and signer-workflow before switching dry-run off."
	fi
	if [[ "$ACCESS" != "public" && ("$PROVENANCE" == "1" || "$POST_PUBLISH_VERIFY" == "1") ]]; then
		echo "::notice::access is '$ACCESS' with provenance or post-publish-verify on; a live publish with these inputs would be refused (see the access input)."
	fi
	exit 0
fi

problems=()
if [[ "$RUNNER_ENVIRONMENT" != "github-hosted" ]]; then
	problems+=("runner-image must select a GitHub-hosted runner (runner.environment is '${RUNNER_ENVIRONMENT:-unset}'); npm trusted publishing and provenance are not available on self-hosted runners")
fi
if [[ -z "$CHECKSUMS_FILE" ]]; then
	problems+=("checksums-file is empty; live publishes must verify the staged artifacts (sha256 + attestation) before npm pack")
fi
if [[ -z "$SIGNER_REPO" ]]; then
	problems+=("signer-repo is empty; it names the repository the artifact attestations must come from")
fi
if [[ -z "$SIGNER_WORKFLOW" ]]; then
	problems+=("signer-workflow is empty; it names the workflow the artifact attestations must come from")
fi
if [[ "$ACCESS" != "public" && ("$PROVENANCE" == "1" || "$POST_PUBLISH_VERIFY" == "1") ]]; then
	problems+=("access is '$ACCESS' but provenance and/or post-publish-verify is on: npm issues automatic provenance only for public packages from public repositories, and post-publish verification reads the registry unauthenticated (trusted publishing authenticates publish commands only), so a restricted package would publish irreversibly and then always fail verification. Set access: public, or set provenance: false and post-publish-verify: false and verify the restricted package another way.")
	echo "::error::npm package-set: access '$ACCESS' is incompatible with provenance / post-publish verification (public packages only). Nothing was published."
fi

if ((${#problems[@]} > 0)); then
	echo "ERROR: refusing the live npm publish; nothing was downloaded, packed, or published:" >&2
	for problem in "${problems[@]}"; do
		echo "  - $problem" >&2
	done
	echo "ERROR: fix the inputs above, or set dry-run: true to exercise the pipeline without publishing." >&2
	exit 1
fi

echo "Live-publish preconditions satisfied: hosted runner, checksums-file, signer-repo, signer-workflow, access/verification compatible."
