# Rust workspace testing

`reusable-test-rust-workspace.yml` is a **generic** drop-in for any lgtm-hq repo
with a Cargo workspace. It is not tied to a single consumer.

Typical layout it supports:

- **Rust**: workspace compile check + `cargo llvm-cov` LCOV coverage + PR comment
- **Web (optional)**: Vitest/Istanbul coverage in a package subdirectory + PR comment

[Rustume](https://github.com/lgtm-hq/Rustume) was the acceptance consumer for
issue 168; other Rust repos reuse the same workflow with different `with:` values.

Pin every `uses:` ref and `tooling-ref` to the same immutable lgtm-ci commit SHA.

## When to use it

| Repo shape | Suggested `with:` |
| --- | --- |
| Cargo workspace only | `enable-web-coverage: false` |
| Workspace + frontend package | `enable-web-coverage: true`, set `web-working-directory` |
| Custom scripts | Override `rust-*-script` / `web-*-script` paths |
| Org ruleset check names | Set `job-name-build`, `job-name-rust-coverage`, etc. |

## Minimal caller (Rust only)

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-rust-workspace.yml@<sha>
    with:
      tooling-ref: "<sha>"
      enable-web-coverage: false
    permissions:
      contents: read
      pull-requests: write
```

## Workspace + web package

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-rust-workspace.yml@<sha>
    with:
      tooling-ref: "<sha>"
      enable-web-coverage: true
      package-manager: bun
      web-working-directory: apps/web
    permissions:
      contents: read
      pull-requests: write
```

Path filters belong on the **caller** workflow (`on.push.paths` / `on.pull_request.paths`).

## Example: Rustume

Rustume enables web coverage and pins job names to match org ruleset
`checks-rustume`:

| Required context | Default job input |
| --- | --- |
| 🔨 Build Check | `job-name-build` |
| 🦀 Rust Coverage | `job-name-rust-coverage` |
| 🌐 Web Coverage | `job-name-web-coverage` |

Full Rustume migration examples (quality, test, release wrappers) lived in the
initial #168 plan; see also [reusable-workflows.md](reusable-workflows.md) for
release and quality callers.

```yaml
# Rustume: .github/workflows/test-ci.yml (excerpt)
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-rust-workspace.yml@<sha>
    with:
      tooling-ref: "<sha>"
      enable-web-coverage: true
      package-manager: bun
      web-working-directory: apps/web
```

Security audit, CodeQL, and Docker workflows stay bespoke per repo.
