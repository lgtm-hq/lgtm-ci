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
#     release security policy forbids publishing unverified artifacts.
#
# Environment:
#   LIVE                1 for a live publish; anything else is a dry-run
#   RUNNER_ENVIRONMENT  github-hosted or self-hosted (from runner.environment)
#   CHECKSUMS_FILE      checksums-file input
#   SIGNER_REPO         signer-repo input
#   SIGNER_WORKFLOW     signer-workflow input

set -euo pipefail

LIVE="${LIVE:-0}"
RUNNER_ENVIRONMENT="${RUNNER_ENVIRONMENT:-}"
CHECKSUMS_FILE="${CHECKSUMS_FILE:-}"
SIGNER_REPO="${SIGNER_REPO:-}"
SIGNER_WORKFLOW="${SIGNER_WORKFLOW:-}"

if [[ "$LIVE" != "1" ]]; then
	echo "Dry-run: live-publish preconditions (hosted runner, checksums-file, signer-repo, signer-workflow) are not enforced."
	if [[ -z "$CHECKSUMS_FILE" ]]; then
		echo "::notice::checksums-file is empty; a live publish with these inputs would be refused. Set checksums-file, signer-repo and signer-workflow before switching dry-run off."
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

if ((${#problems[@]} > 0)); then
	echo "ERROR: refusing the live npm publish; nothing was downloaded, packed, or published:" >&2
	for problem in "${problems[@]}"; do
		echo "  - $problem" >&2
	done
	echo "ERROR: fix the inputs above, or set dry-run: true to exercise the pipeline without publishing." >&2
	exit 1
fi

echo "Live-publish preconditions satisfied: hosted runner, checksums-file, signer-repo, signer-workflow."
