# Composite actions

Reusable GitHub Actions for consistent CI/CD setup across repositories.
Full usage, inputs, and outputs live in the focused docs below; this page
is the index. Prefer [reusable workflows](../workflows/README.md) when you
want a drop-in job without wiring these composites by hand.

## Index

<!-- markdownlint-disable MD013 -- action catalog table -->

| Action | Doc | Description |
| ------ | --- | ------------ |
| `setup-env` | [setup](setup.md#setup-env) | Unified CI environment variables and PATH |
| `setup-python` | [setup](setup.md#setup-python) | Python + uv setup with caching |
| `setup-node` | [setup](setup.md#setup-node) | Node.js + Bun setup with caching |
| `setup-rust` | [setup](setup.md#setup-rust) | Rust toolchain setup with cargo caching |
| `setup-ruby` | [setup](setup.md#setup-ruby) | Ruby + Bundler setup with gem caching |
| `checkout-and-harden` | [security](security.md#checkout-and-harden) | Combined tooling checkout + egress resolve + harden |
| `resolve-egress-allowlist` | [security](security.md#resolve-egress-allowlist) | Resolve egress presets/endpoints before hardening |
| `harden-runner` | [security](security.md#harden-runner) | StepSecurity hardening with resolved allowlist |
| `secure-checkout` | [security](security.md#secure-checkout) | Hardened git checkout |
| `egress-audit` | [security](security.md#egress-audit) | Network egress monitoring and reporting |
| `validate-runner-policy` | [security](security.md#validate-runner-policy) | Tiered egress policy enforcement |
| `validate-action-pinning` | [security](security.md#validate-action-pinning) | GitHub Action SHA pinning validation |
| `generate-sbom` | [security](security.md#generate-sbom) | SBOM generation with Syft |
| `scan-vulnerabilities` | [security](security.md#scan-vulnerabilities) | Vulnerability scanning with Grype |
| `attest-build` | [security](security.md#attest-build) | Build attestation with Sigstore |
| `verify-attestation` | [security](security.md#verify-attestation) | Attestation verification |
| `sign-artifact` | [security](security.md#sign-artifact) | Artifact signing (Cosign) |
| `verify-signature` | [security](security.md#verify-signature) | Signature verification |
| `detect-changes` | [testing](testing.md#detect-changes) | Path-filter change detection (required-check-safe) |
| `run-quality` | [testing](testing.md#run-quality) | Lintro via full py-lintro Docker image |
| `run-tests` | [testing](testing.md#run-tests) | Generic test runner (auto-detect) |
| `run-pytest` | [testing](testing.md#run-pytest) | Pytest execution |
| `run-vitest` | [testing](testing.md#run-vitest) | Vitest execution |
| `run-playwright` | [testing](testing.md#run-playwright) | Playwright E2E execution |
| `merge-playwright-reports` | [testing](testing.md#merge-playwright-reports) | Merge sharded Playwright reports |
| `collect-coverage` | [coverage](coverage.md#collect-coverage) | Aggregate coverage across formats |
| `check-coverage-threshold` | [coverage](coverage.md#check-coverage-threshold) | Coverage threshold validation |
| `generate-coverage-badge` | [coverage](coverage.md#generate-coverage-badge) | Coverage badge SVG/JSON |
| `publish-test-results` | [coverage](coverage.md#publish-test-results) | Publish test/coverage to Pages |
| `post-pr-comment` | [pr-comments](pr-comments.md#post-pr-comment) | Marker-based PR comment transport |
| `run-lighthouse` | [pr-comments](pr-comments.md#run-lighthouse) | Lighthouse CI audits |
| `generate-lighthouse-comment` | [pr-comments](pr-comments.md#generate-lighthouse-comment) | Lighthouse result PR comment |
| `generate-playwright-comment` | [pr-comments](pr-comments.md#generate-playwright-comment) | Playwright result PR comment |
| `generate-coverage-comment` | [pr-comments](pr-comments.md#generate-coverage-comment) | Coverage result PR comment |
| `build-python-package` | [publishing](publishing.md#build-python-package) | Build Python sdist/wheel |
| `prepare-pypi-upload` | [publishing](publishing.md#prepare-pypi-upload) | Validate + expose dist metadata for PyPI upload |
| `publish-npm` | [publishing](publishing.md#publish-npm) | npm package publishing |
| `publish-gem` | [publishing](publishing.md#publish-gem) | RubyGems publishing |
| `trigger-homebrew-update` | [publishing](publishing.md#trigger-homebrew-update) | Dispatch Homebrew formula updates |
| `validate-package` | [publishing](publishing.md#validate-package) | Package metadata validation |
| `wait-for-package` | [publishing](publishing.md#wait-for-package) | Package availability polling |
| `build-docker` | [publishing](publishing.md#build-docker) | Docker image building |
| `docker-login` | [publishing](publishing.md#docker-login) | GHCR/Docker Hub login |
| `docker-auth` | [publishing](publishing.md#docker-auth) | Registry validate + login for the docker workflow family |
| `deploy-pages` | [publishing](publishing.md#deploy-pages) | GitHub Pages deployment (OIDC) |
| `bundle-workflow-artifacts` | [publishing](publishing.md#bundle-workflow-artifacts) | Bundle report artifacts before Pages deploy |
| `calculate-version` | [release](release.md#calculate-version) | Semantic version calculation |
| `generate-changelog` | [release](release.md#generate-changelog) | Changelog generation |
| `create-release-tag` | [release](release.md#create-release-tag) | Release tag creation |
| `create-github-release` | [release](release.md#create-github-release) | GitHub release creation |

<!-- markdownlint-enable MD013 -->

## Usage example

Caller-owned workflow: pin each action to a **commit SHA** (not a branch).
Check out lgtm-ci into `.lgtm-ci-tooling`, resolve egress in a step
**before** `harden-runner`, then pass
`steps.egress.outputs['allowed-endpoints']` into harden-runner (see
[resolve-egress-allowlist](security.md#resolve-egress-allowlist)).

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          repository: lgtm-hq/lgtm-ci
          path: .lgtm-ci-tooling
          ref: <sha> # vX.Y.Z
          sparse-checkout: |
            .github/actions/
          sparse-checkout-cone-mode: true
          persist-credentials: false

      - name: Resolve egress allowlist
        id: egress
        uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
        with:
          egress-policy: block
          egress-preset: github-tooling

      - uses: step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0
        with:
          egress-policy: block
          allowed-endpoints: ${{ steps.egress.outputs['allowed-endpoints'] }}

      - uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@<sha> # vX.Y.Z
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@<sha> # vX.Y.Z
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@<sha> # vX.Y.Z
        with:
          python-version: "3.12"

      - name: Run tests
        run: uv run pytest
```

## Pinning versions

For production workflows, pin to a specific commit SHA:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@abc1234
```

Or a release tag when available (`@v1`, `@v1.2.3`). See
[getting-started.md](../getting-started.md#pinning) for the full
versioning model.
