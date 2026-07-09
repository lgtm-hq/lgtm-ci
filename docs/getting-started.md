# Getting started

Three ways to consume lgtm-ci, and the versioning model that ties them
together. For the full task-ordered setup path (starter example selection,
release secrets, egress audit→block, org ruleset alignment), see
[onboarding.md](onboarding.md).

## Using a composite action

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

See the [actions index](actions/README.md) for the full catalog and a
hardened end-to-end example (egress resolve → harden-runner → checkout →
setup → test).

## Using a reusable workflow

```yaml
jobs:
  quality:
    permissions:
      contents: read
      packages: read # pull ghcr.io/lgtm-hq/py-lintro in reusable-quality-lint
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@v1

  publish-quality-summary:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    permissions:
      contents: read
      pull-requests: write
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-quality-summary.yml@v1
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}
```

Reusable workflows share a standard contract (`tooling-ref`,
`egress-policy`, `job-name`, permissions by mode) — see
[workflow-contract.md](workflow-contract.md). You do **not** need to copy
`.github/actions/harden-runner` or `resolve-egress-allowlist` into your
repository; reusables fetch them from lgtm-ci internally. See the
[workflows index](workflows/README.md) for the full catalog.

## Using shell libraries

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

See the [libraries index](libraries/README.md) for the aggregator layout
and the [function reference](libraries/reference.md).

## Pinning

<!-- markdownlint-disable MD013 -- pinning reference table -->

| Ref | Example | Use |
| --- | ------- | --- |
| `@v1` | `uses: .../setup-env@v1` | Floating major version — all v1.x.x updates |
| `@v1.2.3` | `uses: .../setup-env@v1.2.3` | Pinned exact version |
| `@<commit-sha>` | `uses: .../setup-env@4aaefe6...` | Production pin, paired with a `# vX.Y.Z` comment |
| `@main` | `uses: .../setup-env@main` | Latest, not for production |

<!-- markdownlint-enable MD013 -->

Releases are automated and PR-gated: pushes to `main` with releasable
commits (`feat:`, `fix:`, etc.) open a release PR; merging it tags the
release and moves the floating major version tag. Production callers pin
`uses:` refs **and** `tooling-ref` (on script-backed reusables) to the same
release commit SHA — see
[onboarding.md](onboarding.md#4-resolve-the-release-commit-sha) for the
`git ls-remote` / `gh api` commands that resolve a tag to its commit.

### Two-stage release model

`reusable-release-version-pr.yml` runs on every push to `main` and opens
the version-bump PR; `reusable-release-auto-tag.yml` runs after that PR
merges and creates the tag + GitHub release. See
[reusable-workflows.md](reusable-workflows.md#release) for wiring both
together, and
[.github/workflows/release-version-pr.yml](../.github/workflows/release-version-pr.yml)
/
[.github/workflows/release-auto-tag.yml](../.github/workflows/release-auto-tag.yml)
for this repo's own working example.

## Next steps

- First real repository: follow [onboarding.md](onboarding.md) end to end
  (starter example, secrets, egress, ruleset alignment).
- Full component catalogs: [actions/README.md](actions/README.md),
  [workflows/README.md](workflows/README.md),
  [libraries/README.md](libraries/README.md).
- Contract details: [workflow-contract.md](workflow-contract.md).
