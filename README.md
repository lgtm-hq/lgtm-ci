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

New repository? Follow the task-ordered consumer guide in
[docs/onboarding.md](docs/onboarding.md) — starter example selection, release
GitHub App secrets, egress audit→block flow, and release-SHA pinning. For
the three consumption models (composite actions, reusable workflows, shell
libraries) and the pinning model, see
[docs/getting-started.md](docs/getting-started.md).

```yaml
jobs:
  quality:
    permissions:
      contents: read
      packages: read # pull ghcr.io/lgtm-hq/py-lintro in reusable-quality-lint
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@v1
```

Reusable workflows share a standard contract (`tooling-ref`,
`egress-policy`, `job-name`, permissions by mode). See
[docs/workflow-contract.md](docs/workflow-contract.md). You do **not** need
to copy `.github/actions/harden-runner` or `resolve-egress-allowlist` into
your repository — reusables fetch them from lgtm-ci internally.

## 📦 Components

Full documentation: [docs/README.md](docs/README.md).

<!-- markdownlint-disable MD013 -- component index table -->

| Area | Index | Highlights |
| ---- | ----- | ---------- |
| Composite actions (40+) | [docs/actions/](docs/actions/README.md) | Setup, security/egress, testing, coverage, publishing, release, PR comments |
| Reusable workflows (47+) | [docs/workflows/](docs/workflows/README.md) | Quality lint, per-language tests, Docker, Pages, release automation, security audit |
| Shell libraries | [docs/libraries/](docs/libraries/README.md) | Logging, GitHub Actions helpers, installers, release/changelog, coverage parsing |

<!-- markdownlint-enable MD013 -->

Caller starter examples live in [examples/](examples/README.md).

## 📌 Versioning

lgtm-ci uses [semantic versioning](https://semver.org/) with
[conventional commits](https://www.conventionalcommits.org/) for automated
releases. Pin `@v1` (floating major), `@v1.2.3`, or — for production — the
release commit SHA with a `# vX.Y.Z` comment. Releases are automated and
PR-gated via the two-stage model (`reusable-release-version-pr.yml` opens
the release PR; `reusable-release-auto-tag.yml` tags on merge). See
[docs/getting-started.md](docs/getting-started.md#pinning).

## 🔨 Development

CI runs **lintro inside the pinned `ghcr.io/lgtm-hq/py-lintro` image** so
every bundled tool is available. See
[docs/README.md](docs/README.md#development) for the local commands that
mirror CI.

## 🤝 Community

- 🐛 [Bug Reports](https://github.com/lgtm-hq/lgtm-ci/issues/new)
- 💡 [Feature Requests](https://github.com/lgtm-hq/lgtm-ci/issues/new)

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
