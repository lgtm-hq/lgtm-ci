# Rust testing

Rust CI follows the same model as Python and Node: **one language reusable per
stack**, composed in the consumer caller workflow. Clippy, rustfmt, and security
scans run through **`reusable-quality-lint`** (lintro); this repo only adds a
native reusable for **`cargo test`**, which lintro does not yet support.

| Language          | Reusable                     |
| ----------------- | ---------------------------- |
| Python            | `reusable-test-python.yml`   |
| Node / TypeScript | `reusable-test-node.yml`     |
| Rust (build)      | `reusable-rust-build.yml`    |
| Rust (coverage)   | `reusable-rust-coverage.yml` |
| Rust (test)       | `reusable-rust-test.yml`     |
| Rust (legacy)     | `reusable-test-rust.yml`     |

## Rust-only repository

```yaml
jobs:
  rust:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-rust.yml@<sha>
    with:
      tooling-ref: "<sha>"
    permissions:
      contents: read
      pull-requests: write
```

## Build and coverage as separate checks

Use the split workflows so PR checks do not show skipped sibling jobs:

```yaml
jobs:
  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Build"
      egress-policy: block
    permissions:
      contents: read

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-coverage.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Coverage"
      egress-policy: block
    permissions:
      contents: read
      pull-requests: write
```

`reusable-test-rust.yml` with `run-build` / `run-coverage` remains available but
may leave skipped jobs in the PR UI when only one mode is enabled.

## Cargo test (lint via lintro)

Use `reusable-rust-test.yml` for workspace `cargo test` with a PR comment.
Run clippy, rustfmt, and `cargo audit` / `cargo deny` through
`reusable-quality-lint` — do not duplicate those tools here.

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    with:
      tooling-ref: "<sha>"
      egress-policy: block
    permissions:
      contents: read
      packages: read

  quality-comment:
    needs: quality
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-pr-comment.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  rust-test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Tests"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        codeload.github.com:443
        static.rust-lang.org:443
        sh.rustup.rs:443
        crates.io:443
        static.crates.io:443
        index.crates.io:443
    permissions:
      contents: read
      pull-requests: write
```

When `egress-policy: block`, include `api.github.com:443` if PR comments are enabled.

`reusable-test-rust-test.yml` is the internal implementation; callers should
prefer the facade. The legacy name `reusable-test-rust.yml` is reserved for the
build/coverage orchestrator added in v0.15.0.

## Rust workspace with a frontend package

Use **`reusable-test-node`** for the web app (Vitest/Istanbul or a package
`test:coverage` script). Do not bundle web jobs into the Rust reusable.

```yaml
jobs:
  # See "Build and coverage as separate checks" above for rust-build / rust-coverage.
  web-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Web Coverage"
      working-directory: apps/web
      package-manager: bun
      node-version: "20"
      coverage: true
      test-command: bun run test:coverage
      coverage-pr-comment: true
      coverage-comment-marker: web-coverage-report
      coverage-comment-title: Web Coverage Report
      draft-pr-skip: true
      # Use node-versions (e.g. "20,22") to run a matrix; each version gets its own
      # PR comment marker suffix. A single node-version keeps the marker as-is.
    permissions:
      contents: read
      pull-requests: write
```

Pin `uses:` and `tooling-ref` to the same commit SHA. Path filters belong on the
caller workflow (`on.push.paths` / `on.pull_request.paths`).

## Example: Rustume

Rustume composes quality (lintro), build, coverage, and rust-test reusables.
Override `job-name` inputs to match org ruleset check names (for example
emoji-prefixed labels).

See [reusable-workflows.md](reusable-workflows.md) for quality and release
callers.
