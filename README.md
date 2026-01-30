# lgtm-ci

Reusable CI/CD components for GitHub Actions - composite actions, reusable workflows,
and shell utilities.

## Overview

**lgtm-ci** provides a collection of production-ready CI/CD building blocks:

- **Composite Actions** - Reusable actions for environment setup, security hardening, PR
  comments, and more
- **Reusable Workflows** - Complete workflow templates for quality gates, releases, and
  publishing
- **Shell Libraries** - Modular bash utilities for logging, platform detection, GitHub
  integration, and downloads

## Quick Start

### Using a Composite Action

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1
        with:
          python-version: '3.13'
          node-version: '22'
```

### Using a Reusable Workflow

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality.yml@v1
    with:
      python-version: '3.13'
```

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

## Components

### Composite Actions

| Action                        | Description                                 |
| ----------------------------- | ------------------------------------------- |
| `setup-env`                   | Unified Python/Node/Ruby environment setup  |
| `setup-python`                | Python + uv setup with caching              |
| `setup-node`                  | Node.js + Bun setup with Playwright caching |
| `setup-rust`                  | Rust toolchain setup                        |
| `harden-runner`               | Security hardening with egress presets      |
| `secure-checkout`             | Hardened git checkout                       |
| `post-pr-comment`             | Marker-based PR commenting                  |
| `semantic-pr-title`           | Conventional commits validation             |
| `extract-version`             | Version extraction from multiple sources    |
| `generate-coverage-comment`   | Coverage report PR comments                 |
| `generate-playwright-comment` | E2E test result comments                    |
| `generate-lighthouse-comment` | Performance metric comments                 |
| `run-quality`                 | Lintro quality checks with actionlint       |
| `egress-audit`                | Network egress monitoring and reporting     |

### Reusable Workflows

| Workflow                    | Description                          |
| --------------------------- | ------------------------------------ |
| `reusable-quality.yml`      | Lintro + shellcheck + action pinning |
| `reusable-sbom.yml`         | SBOM generation with Cosign signing  |
| `reusable-release.yml`      | Semantic release automation          |
| `reusable-publish-pypi.yml` | PyPI publishing with OIDC            |

### Shell Libraries

Located in `scripts/ci/lib/`:

| Library        | Description                     |
| -------------- | ------------------------------- |
| `log.sh`       | Colored logging functions       |
| `platform.sh`  | OS and architecture detection   |
| `fs.sh`        | File system utilities           |
| `git.sh`       | Git helper functions            |
| `github.sh`    | GitHub Actions integration      |
| `network.sh`   | Download and checksum utilities |
| `installer.sh` | Tool installation framework     |

## Versioning

lgtm-ci uses semantic versioning:

- `v1.0.0` - Specific version
- `v1` - Latest v1.x.x (recommended for stability)
- `main` - Latest development (use with caution)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `uv run lintro chk` to validate
5. Submit a PR

## License

MIT License - see [LICENSE](LICENSE) for details.
