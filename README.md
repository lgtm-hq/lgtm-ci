# lgtm-ci

<!-- markdownlint-disable MD033 MD013 -->
<p align="center">
Reusable CI/CD components for GitHub Actions — composite actions, reusable workflows,
and shell utilities.
</p>

<!-- Badges: Build & Quality -->
<p align="center">
<a href="https://github.com/lgtm-hq/lgtm-ci/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/github/actions/workflow/status/lgtm-hq/lgtm-ci/ci.yml?label=ci&branch=main&logo=githubactions&logoColor=white" alt="CI"></a>
<a href="https://github.com/lgtm-hq/lgtm-ci/releases/latest"><img src="https://img.shields.io/github/v/release/lgtm-hq/lgtm-ci?label=release" alt="Release"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
</p>

<!-- Badges: Tech Stack -->
<p align="center">
<a href="https://github.com/features/actions"><img src="https://img.shields.io/badge/GitHub_Actions-2088FF?logo=githubactions&logoColor=white" alt="GitHub Actions"></a>
<a href="https://www.gnu.org/software/bash/"><img src="https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white" alt="Bash"></a>
</p>
<!-- markdownlint-enable MD033 MD013 -->

## 🚀 Quick Start

### Using a Composite Action

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1
        with:
          python-version: "3.13"
          node-version: "22"
```

### Using a Reusable Workflow

```yaml
jobs:
  quality:
    permissions:
      contents: read
      packages: read # pull ghcr.io/lgtm-hq/py-lintro in reusable-quality-lint
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@v1

  quality-pr-comment:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    permissions:
      contents: read
      pull-requests: write
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-pr-comment.yml@v1
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}
```

Reusable workflows share a standard contract (`tooling-ref`, `egress-policy`,
`job-name`, permissions by mode). See [docs/workflow-contract.md](docs/workflow-contract.md).

### Using Shell Libraries

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      repository: lgtm-hq/lgtm-ci
      path: .lgtm-ci
      sparse-checkout: scripts/ci/lib

  - name: Use utilities
    run: |
      source .lgtm-ci/scripts/ci/lib/log.sh
      log_info "Starting build..."
```

## 📦 Components

### Composite Actions

#### Environment Setup

| Action         | Description                                     |
| -------------- | ----------------------------------------------- |
| `setup-env`    | Unified Python/Node/Ruby/Rust environment setup |
| `setup-python` | Python + uv setup with caching                  |
| `setup-node`   | Node.js + Bun setup with Playwright caching     |
| `setup-ruby`   | Ruby + Bundler setup                            |
| `setup-rust`   | Rust toolchain setup                            |

#### Security & Hardening

| Action                 | Description                             |
| ---------------------- | --------------------------------------- |
| `harden-runner`        | Security hardening with egress presets  |
| `secure-checkout`      | Hardened git checkout                   |
| `scan-vulnerabilities` | Vulnerability scanning                  |
| `egress-audit`         | Network egress monitoring and reporting |

#### Quality & Testing

| Action              | Description                              |
| ------------------- | ---------------------------------------- |
| `run-quality`       | Lintro via full py-lintro Docker image   |
| `run-tests`         | Generic test runner                      |
| `run-vitest`        | Vitest test execution                    |
| `run-pytest`        | Pytest test execution                    |
| `run-playwright`    | Playwright E2E test execution            |
| `run-lighthouse`    | Lighthouse performance audits            |
| `semantic-pr-title` | Conventional commits PR title validation |

#### Reporting & Comments

| Action                        | Description                   |
| ----------------------------- | ----------------------------- |
| `post-pr-comment`             | Marker-based PR commenting    |
| `generate-coverage-badge`     | Coverage badge generation     |
| `generate-coverage-comment`   | Coverage report PR comments   |
| `generate-playwright-comment` | E2E test result comments      |
| `generate-lighthouse-comment` | Performance metric comments   |
| `publish-test-results`        | Test result publishing        |
| `check-coverage-threshold`    | Coverage threshold validation |
| `collect-coverage`            | Coverage data collection      |
| `merge-playwright-reports`    | Playwright report merging     |

#### Build & Release

| Action                  | Description                     |
| ----------------------- | ------------------------------- |
| `build-docker`          | Docker image building           |
| `attest-build`          | Build attestation with Sigstore |
| `sign-artifact`         | Artifact signing                |
| `verify-attestation`    | Attestation verification        |
| `verify-signature`      | Signature verification          |
| `calculate-version`     | Semantic version calculation    |
| `create-release-tag`    | Release tag creation            |
| `create-github-release` | GitHub release creation         |
| `generate-changelog`    | Changelog generation            |
| `generate-sbom`         | SBOM generation with CycloneDX  |

#### Publishing & Deployment

| Action                 | Description                   |
| ---------------------- | ----------------------------- |
| `publish-npm`          | npm package publishing        |
| `build-python-package` | Build Python sdist/wheel      |
| `upload-pypi-oidc`     | PyPI OIDC upload (caller job) |
| `publish-gem`          | RubyGems publishing           |
| `update-homebrew`      | Homebrew formula updates      |
| `validate-package`     | Package validation            |
| `wait-for-package`     | Package availability polling  |
| `deploy-pages`         | GitHub Pages deployment       |

### Reusable Workflows

| Workflow                               | Description                            |
| -------------------------------------- | -------------------------------------- |
| `reusable-quality-lint.yml`            | Lintro via full py-lintro Docker image |
| `reusable-quality-pr-comment.yml`      | Lintro PR summary comment              |
| `reusable-sbom.yml`                    | SBOM generation with Cosign signing    |
| `reusable-release-version-pr.yml`      | Release version PR with changelog      |
| `reusable-release-auto-tag.yml`        | Tag + GitHub release on merge          |
| `reusable-build-python-dist.yml`       | Build Python dist artifact             |
| `reusable-github-release.yml`          | GitHub Release with artifact assets    |
| `reusable-publish-npm.yml`             | npm publishing                         |
| `reusable-publish-gem.yml`             | RubyGems publishing                    |
| `reusable-publish-homebrew.yml`        | Homebrew formula publishing            |
| `reusable-deploy-pages.yml`            | GitHub Pages deployment                |
| `reusable-docker.yml`                  | Docker build and publish               |
| `reusable-coverage.yml`                | Test coverage collection               |
| `reusable-test-python.yml`             | Python tests with PR comments          |
| `reusable-test-node.yml`               | Node.js Vitest tests with PR comments  |
| `reusable-test-node-custom.yml`        | Node.js custom test command workflow   |
| `reusable-test-shell.yml`              | BATS shell tests with PR comments      |
| `reusable-test-pr-comment.yml`         | Shared test PR comment workflow        |
| `reusable-test-e2e.yml`                | E2E testing with Playwright            |
| `reusable-test-e2e-matrix.yml`         | Matrix E2E testing                     |
| `reusable-pr-auto-assign.yml`          | PR auto-assignment                     |
| `reusable-pr-labeler.yml`              | PR auto-labeling                       |
| `reusable-validate.yml`                | Generic repo validation script runner  |
| `reusable-codeql.yml`                  | CodeQL security analysis               |
| `reusable-dependency-review.yml`       | Dependency review gate                 |
| `reusable-scorecards.yml`              | OpenSSF Scorecard analysis             |
| `reusable-semantic-pr-title.yml`       | Conventional PR title validation       |
| `reusable-validate-action-pinning.yml` | GitHub Action SHA pinning validation   |
| `reusable-link-check.yml`              | Markdown and HTML link checking        |

Test workflows are self-contained for consumers: they check out lgtm-ci
tooling internally, run the configured test suite, and post/update the
standard PR comment when callers grant `pull-requests: write`.

### Shell Libraries

Located in `scripts/ci/lib/`:

| Library        | Description                                        |
| -------------- | -------------------------------------------------- |
| `log.sh`       | Colored logging with levels and GitHub annotations |
| `platform.sh`  | OS and architecture detection                      |
| `fs.sh`        | File system utilities                              |
| `git.sh`       | Git helper functions                               |
| `github.sh`    | GitHub API and Actions integration                 |
| `network.sh`   | Download, checksum, and retry utilities            |
| `installer.sh` | Tool installation framework                        |
| `docker.sh`    | Docker build and push utilities                    |
| `publish.sh`   | Package publishing utilities                       |
| `release.sh`   | Release management                                 |
| `sbom.sh`      | SBOM generation utilities                          |
| `testing.sh`   | Test execution utilities                           |
| `actions.sh`   | GitHub Actions helper functions                    |

## 📌 Versioning

lgtm-ci uses [semantic versioning](https://semver.org/) with
[conventional commits](https://www.conventionalcommits.org/) for automated releases.

| Ref       | Example                                                  | Description          |
| --------- | -------------------------------------------------------- | -------------------- |
| `@v1`     | `uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1`     | All v1.x.x updates   |
| `@v1.2.3` | `uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1.2.3` | Pinned exact version |
| `@main`   | `uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main`   | Latest, not for prod |

Releases are automated and PR-gated. Pushes to `main` with releasable
commits (`feat:`, `fix:`, etc.) trigger a release PR for human review;
merging that PR creates the tagged release and updates the floating
major version tag. See [Two-stage release model](#two-stage-release-model)
below for how the two workflows fit together.

### Two-stage release model

Release automation is split across two reusable workflows that work together:

1. **`reusable-release-version-pr.yml`** — Runs on pushes to `main`. When
   releasable commits land, it opens (or updates) a release PR that bumps
   version files and updates `CHANGELOG.md`. This PR is the human-review
   gate before a release happens.
2. **`reusable-release-auto-tag.yml`** — Runs after the release PR merges
   (it triggers on `CHANGELOG.md` changes). It extracts the version from
   the release commit, creates an annotated tag, publishes a GitHub
   release, and updates the floating major version tag.

```text
push to main
  ↓
version-pr workflow → opens "chore(release): version X.Y.Z" PR
  ↓
PR merged
  ↓
auto-tag workflow → creates tag + GitHub release
```

Consumers typically wire up **both** workflows. The version-pr caller
runs on every push; the auto-tag caller runs only on pushes that touch
`CHANGELOG.md` (i.e., the release PR merge). See
[`.github/workflows/release-version-pr.yml`](.github/workflows/release-version-pr.yml)
and
[`.github/workflows/release-auto-tag.yml`](.github/workflows/release-auto-tag.yml)
for working examples.

## 🔨 Development

CI and `reusable-quality-lint.yml` run **lintro inside the pinned `ghcr.io/lgtm-hq/py-lintro`
image** so every bundled tool is available. Mirror CI locally:

```bash
export STEP=check
export LINTRO_IMAGE='ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578'
bash scripts/ci/quality/run-lintro-docker.sh
```

Quick iteration without Docker (optional tools may SKIP — same as `lint-check.sh`):

```bash
git clone https://github.com/lgtm-hq/lgtm-ci.git
cd lgtm-ci
uv sync --dev
STEP=check bash scripts/ci/quality/lint-check.sh
```

## 🤝 Community

- 🐛 [Bug Reports](https://github.com/lgtm-hq/lgtm-ci/issues/new)
- 💡 [Feature Requests](https://github.com/lgtm-hq/lgtm-ci/issues/new)

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
