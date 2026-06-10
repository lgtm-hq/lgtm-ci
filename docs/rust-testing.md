# Rust testing

Rust CI follows the same model as Python and Node: **one language reusable per
concern**, composed in the consumer caller workflow. Clippy, rustfmt, and security
scans run through **`reusable-quality-lint`** (lintro); this repo provides
**`reusable-rust-test.yml`** for workspace tests (cargo-nextest or
`cargo llvm-cov nextest` when `coverage: true`).

| Language          | Reusable                                                    |
| ----------------- | ----------------------------------------------------------- |
| Python            | `reusable-test-python.yml`                                  |
| Node / TypeScript | `reusable-test-node.yml` or `reusable-test-node-custom.yml` |
| Rust (build)      | `reusable-rust-build.yml`                                   |
| Rust (tests)      | `reusable-rust-test.yml`                                    |

## Nextest configuration (required)

The reusable expects **`.config/nextest.toml`** with a `ci` profile that writes
JUnit for result parsing and PR summaries and reports. Copy or merge from
`examples/nextest-ci.toml` in lgtm-ci:

```toml
[profile.ci]
retries = 0

[profile.ci.junit]
path = "target/nextest/ci/junit.xml"
```

## Fast tests vs coverage (one job, one mode)

Use the **`coverage`** input on a single `reusable-rust-test.yml` job. The workflow
never runs both uninstrumented nextest and llvm-cov in the same pipeline.

| `coverage` | What runs                        | PR comment contract       |
| ---------- | -------------------------------- | ------------------------- |
| `false`    | `cargo nextest run --profile ci` | Tests only (Python-style) |
| `true`     | `cargo llvm-cov nextest` + LCOV  | Tests + coverage line     |

### Runtime compat matrix

Use `rust-toolchains` (comma-separated) for multi-toolchain compat checks
(MSRV, stable, beta). Compat matrix runs require `coverage: false` and
`publish-test-summary: false`. Use `rust-toolchain` (or deprecated `toolchain`)
for single-toolchain coverage and PR comments.

```yaml
rust-compat:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
  with:
    rust-toolchains: "1.85.0,stable,beta"
    coverage: false
    publish-test-summary: false
```

test summaries use **`reusable-publish-test-summary`**: rich coverage tables via
`generate-coverage-comment` when the LCOV artifact is available; otherwise
`generate-test-summary.sh` (same fallback pattern as Python when
`upload-coverage: false`).

```yaml
jobs:
  rust-test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Tests"
      coverage: false
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

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Coverage"
      coverage: true
      upload-pages-coverage-html: true
      pages-coverage-artifact-name: rust-coverage-html
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

You may use one job with `coverage: true` only if a single required check is
enough; many repos keep **build** (`reusable-rust-build.yml`) and **coverage**
as separate jobs for ruleset granularity.

Run clippy, rustfmt, and `cargo audit` / `cargo deny` through
`reusable-quality-lint` — do not duplicate those tools in the test reusable.

When `egress-policy: block`, include `api.github.com:443` if PR summaries and reports are enabled.

## Rust-only repository

```yaml
jobs:
  rust-test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    with:
      tooling-ref: "<sha>"
      coverage: false
    permissions:
      contents: read
      pull-requests: write
```

## Rust workspace with a frontend package

Use **`reusable-test-node`** (Vitest) or **`reusable-test-node-custom`** (package
`test:coverage` scripts). Do not bundle web jobs into the Rust reusable.

Pin `uses:` and `tooling-ref` to the same commit SHA. Path filters belong on the
caller workflow (`on.push.paths` / `on.pull_request.paths`).

## Example: Rustume

Rustume composes quality (lintro), build, and rust-test reusables (test and
coverage as separate jobs with `coverage: false` / `true`). Pass `job-name` on
always-run jobs (Rust build/test, split Node workflows) to match org ruleset
check names. Matrix and internal Docker jobs use static inner names — set caller
job `name:` for branding; see [workflow-contract.md](workflow-contract.md).

See [reusable-workflows.md](reusable-workflows.md) for quality and release
callers.
