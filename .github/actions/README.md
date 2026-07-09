# Composite Actions

Reusable GitHub Actions for consistent CI/CD setup across repositories.

Full documentation lives in [docs/actions/](../../docs/actions/README.md):

- [Index of all actions](../../docs/actions/README.md) — catalog with a
  hardened end-to-end usage example and version pinning guidance
- [Setup](../../docs/actions/setup.md) — `setup-env`, `setup-python`,
  `setup-node`, `setup-rust`, `setup-ruby`
- [Security](../../docs/actions/security.md) — `checkout-and-harden`,
  `resolve-egress-allowlist`, `harden-runner`, `secure-checkout`,
  `egress-audit`, `validate-runner-policy`, `validate-action-pinning`,
  `generate-sbom`, `scan-vulnerabilities`, `attest-build`,
  `verify-attestation`, `sign-artifact`, `verify-signature`
- [Testing and quality](../../docs/actions/testing.md) — `detect-changes`,
  `run-quality`, `run-tests`, `run-pytest`, `run-vitest`,
  `run-playwright`, `merge-playwright-reports`
- [Coverage](../../docs/actions/coverage.md) — `collect-coverage`,
  `check-coverage-threshold`, `generate-coverage-badge`,
  `publish-test-results`
- [PR comments](../../docs/actions/pr-comments.md) — `post-pr-comment`,
  `run-lighthouse`, `generate-lighthouse-comment`,
  `generate-playwright-comment`, `generate-coverage-comment`
- [Publishing and deployment](../../docs/actions/publishing.md) —
  `build-python-package`, `prepare-pypi-upload`, `publish-npm`,
  `publish-gem`, `trigger-homebrew-update`, `validate-package`,
  `wait-for-package`, `build-docker`, `docker-login`, `deploy-pages`,
  `bundle-workflow-artifacts`
- [Release](../../docs/actions/release.md) — `calculate-version`,
  `generate-changelog`, `create-release-tag`, `create-github-release`

Prefer [reusable workflows](../../docs/workflows/README.md) when you want
drop-in jobs without copying `.github/actions/harden-runner` or
`resolve-egress-allowlist` into your repo.

For production workflows, pin actions to a commit SHA (or a release tag)
— see [docs/getting-started.md](../../docs/getting-started.md#pinning).
