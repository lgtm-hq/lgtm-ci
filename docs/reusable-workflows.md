# Reusable Workflows

Use reusable workflows from consumer repositories with a thin caller job:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality.yml@<sha>
    permissions:
      contents: read
      packages: read
      pull-requests: write
```

Pass `tooling-ref` when testing an unreleased lgtm-ci branch. Production callers
should pin the workflow ref to a commit SHA.

See [workflow-contract.md](workflow-contract.md) for the standard input contract,
permissions by mode, egress allowlists, and Rustume migration examples.

## Quality And Validation

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality.yml@<sha>
    permissions:
      contents: read
      packages: read
      pull-requests: write
    with:
      post-pr-comment: true
      job-name: "Lintro Quality Checks"
      egress-policy: audit

  validate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      script: scripts/ci/validate.sh
```

## Tests

```yaml
jobs:
  node:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      node-versions: "20,22"
      pre-test-command: bun run build
      upload-build-artifact: true

  python:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      coverage: true
      upload-coverage: true

  shell:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-shell.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-path: tests/bats

  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      browsers: chromium

  e2e-matrix:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-matrix.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-suites: smoke,visual
      browsers: chromium,firefox
```

`reusable-test-pr-comment.yml` is the shared internal comment workflow used by
the language-specific test workflows.

### Rust

Prefer `reusable-rust-build.yml` and `reusable-rust-coverage.yml` for separate
required checks without skipped sibling jobs. `reusable-test-rust.yml` remains
for backward compatibility. See [rust-testing.md](rust-testing.md).

```yaml
jobs:
  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Build"
      egress-policy: block

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-coverage.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Coverage"
      egress-policy: block
```

## Release

```yaml
jobs:
  version-pr:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
    with:
      ecosystems: node,ruby,python
      skip-patterns: "^chore(release):"
      auto-merge-patch-only: false
    secrets: inherit

  auto-tag:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-auto-tag.yml@<sha>
    permissions:
      contents: write
    with:
      create-release: false
    secrets: inherit
```

## Publishing And Deployment

```yaml
jobs:
  npm:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm.yml@<sha>
    permissions:
      contents: read
      id-token: write
      attestations: write

  pypi:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-pypi.yml@<sha>
    permissions:
      contents: read
      id-token: write
      attestations: write

  gem:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-gem.yml@<sha>
    permissions:
      contents: read
      id-token: write

  homebrew:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-homebrew.yml@<sha>
    permissions:
      contents: write

  pages:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-pages.yml@<sha>
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      build-command: bun run build
      package-manager: bun
```

## Build, Coverage, And Supply Chain

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: true
      validate-on-pr: ${{ github.event_name == 'pull_request' }}
      scan: true
      scan-exit-code: "1"
      cosign-sign: true
      cache-registry-ref: ghcr.io/org/repo:cache
      no-cache: ${{ startsWith(github.ref, 'refs/tags/v') }}
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'

  sbom:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
      attestations: write

  coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@<sha>
    permissions:
      contents: read

  ghcr-cleanup:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ghcr-cleanup.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      package-name: my-image
    secrets: inherit
```

### Docker workflow inputs

| Input | Default | Description |
| ----- | ------- | ----------- |
| `validate-on-pr` | `false` | Use native split builds on PRs without pushing staging images |
| `scan-exit-code` | `"0"` | Trivy exit code; set `"1"` to block PRs on CRITICAL/HIGH CVEs |
| `cache-registry-ref` | `""` | Registry cache fallback (e.g. `ghcr.io/org/repo:cache`) |
| `cosign-sign` | `false` | Keyless Cosign signature on pushed manifests |
| `no-cache` | `false` | Disable GHA/registry cache for clean release builds |

All inputs are opt-in; existing callers keep current behavior without changes.

## PR Automation And Security

```yaml
jobs:
  label:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-labeler.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  assign:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-auto-assign.yml@<sha>
    permissions:
      pull-requests: write

  semantic-title:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-semantic-pr-title.yml@<sha>
    permissions:
      contents: read

  action-pinning:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate-action-pinning.yml@<sha>
    permissions:
      contents: read

  links:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-link-check.yml@<sha>
    permissions:
      contents: read

  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write

  dependency-review:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-dependency-review.yml@<sha>
    permissions:
      contents: read
      pull-requests: read

  scorecards:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-scorecards.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
```
