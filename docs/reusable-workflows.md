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

### Rust workspace

`reusable-test-rust-workspace.yml` runs a Cargo workspace build, optional
`llvm-cov` coverage with a PR comment, and an optional frontend coverage job.
Use for any Rust repo; set `enable-web-coverage: false` when there is no web
package. See [rust-workspace-testing.md](rust-workspace-testing.md).

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-rust-workspace.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      enable-web-coverage: true
      package-manager: bun
      web-working-directory: apps/web
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
    with:
      push: true

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
