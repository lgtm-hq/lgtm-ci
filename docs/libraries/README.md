# Shell libraries

Bash function libraries under `scripts/ci/lib/` back the composite actions
and reusable workflows in this repo. Consumer repos normally use them only
indirectly (through an action or reusable workflow); source them directly
only for a caller-owned custom script (for example a
`reusable-test-node-custom.yml` `test-command`, or a
`reusable-site-quality.yml` `build-command`).

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

Full function-level reference: [reference.md](reference.md).

## Layout

Single-file libraries at the top of `scripts/ci/lib/` are either standalone
(`log.sh`, `fs.sh`, `platform.sh`, `git.sh`, `egress.sh`,
`pages_coverage.sh`) or thin **aggregators** that source every module in a
same-named subdirectory, so callers can pick one file for a whole domain:

<!-- markdownlint-disable MD013 -- aggregator table; module lists exceed line length -->

| Aggregator | Sources | Domain |
| ---------- | ------- | ------ |
| `github.sh` | `github/env.sh`, `format.sh`, `output.sh`, `summary.sh` | GitHub Actions env, output, and step-summary helpers |
| `network.sh` | `network/checksum.sh`, `download.sh`, `port.sh` | Hardened downloads, checksums, port waits |
| `installer.sh` | `installer/args.sh`, `binary.sh`, `core.sh`, `fallbacks.sh`, `version.sh` | Generic tool-install framework with fallback chains |
| `docker.sh` | `docker/core.sh`, `registry.sh`, `tags.sh` | Docker build, registry login, tag generation |
| `publish.sh` | `publish/registry.sh`, `validate.sh`, `version.sh` | PyPI/npm/gem availability, validation, version extraction |
| `release.sh` | `release/analyze.sh`, `assets.sh`, `changelog.sh`, `changelog_merge.sh`, `conventional.sh`, `extract.sh`, `fileops.sh`, `version.sh` | Conventional-commit analysis, changelog, semver |
| `sbom.sh` | `sbom/format.sh`, `severity.sh`, `target.sh` | SBOM format/severity helpers |
| `testing.sh` | `testing/badge.sh`, `detect.sh`, `coverage/*`, `parse/*` | Test-runner detection, coverage merge/threshold, result parsing, badges |

<!-- markdownlint-enable MD013 -->

`ghcr/registry.sh` and `ghcr/tags.sh` (GHCR digest/tag helpers for cleanup
and multi-arch index safety) and `bundle/workflow_artifacts.sh` (Model B
manifest bundling) and `cargo/version.sh` (Cargo.toml version parsing) are
sourced directly by their consuming scripts rather than through a top-level
aggregator.

## Security-relevant helpers

`network/download.sh` and `installer/binary.sh` enforce HTTPS-only + TLS
>= 1.2 by default and support opt-in CA bundle / pinned public key
verification (`LGTM_CI_CA_BUNDLE`, `LGTM_CI_PINNED_PUBKEY`); functions fail
closed when a configured CA bundle is unreadable. `fs.sh`'s
`write_file_atomic` avoids partial-file commits on producer failure.
