# Examples

Sample caller layouts for lgtm-hq repositories. Copy and adapt into your
`.github/workflows/` directory.

## Index

<!-- markdownlint-disable MD013 -- index table; row text exceeds default line length -->

| Example                                                                        | When to use                                                                    |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| [ci-python.yml](ci-python.yml)                                                 | Python repo CI: lint + pytest coverage with PR summaries                       |
| [ci-node-vitest.yml](ci-node-vitest.yml)                                       | Node.js repo CI with Vitest tests                                              |
| [ci-node-custom.yml](ci-node-custom.yml)                                       | Node.js CI with a custom test command (Bun, monorepo subdir)                   |
| [ci-rust.yml](ci-rust.yml)                                                     | Rust workspace CI: build check + coverage; explicit `allowed-endpoints`        |
| [ci-docker.yml](ci-docker.yml)                                                 | Docker image: multi-arch PR validation, push to GHCR on main                   |
| [ci-quality-only.yml](ci-quality-only.yml)                                     | Lint-only pipelines (tag/release or no PR comments)                            |
| [release-version-pr.yml](release-version-pr.yml)                               | Open `chore(release)` version-bump PRs from conventional commits               |
| [release-auto-tag.yml](release-auto-tag.yml)                                   | Tag + GitHub Release when the version PR merges                                |
| [release-version-pr-changelog-only.yml](release-version-pr-changelog-only.yml) | Version PRs for repos with no package version files                            |
| [publish-python-release.yml](publish-python-release.yml)                       | Publish to PyPI on tag (trusted publishing + attestation)                      |

<!-- markdownlint-enable MD013 -->

All starters pin reusable workflow `uses:` refs and `tooling-ref` to the same
lgtm-ci release commit SHA with a `# vX.Y.Z` comment (see
[docs/workflow-contract.md](../docs/workflow-contract.md), "Action pinning
policy"). Update both together when bumping releases.

## Reusable workflows (recommended)

Examples such as `publish-python-release.yml` and
`release-version-pr-changelog-only.yml` call `lgtm-hq/lgtm-ci` **reusable
workflows** at a pinned commit SHA and pass `tooling-ref` with the same SHA.

You do **not** need to vendor copies of:

- `.github/actions/harden-runner`
- `.github/actions/resolve-egress-allowlist`

Those composites are loaded inside the reusable job via a sparse checkout of
`lgtm-hq/lgtm-ci` into `.lgtm-ci-tooling`. See
[docs/reusable-workflows.md](../docs/reusable-workflows.md) and
[docs/workflow-contract.md](../docs/workflow-contract.md).

## Caller-owned composite actions

If you invoke lgtm-ci composites directly from your own workflow (instead of a
reusable), pin each action to a commit SHA and check out lgtm-ci tooling before
`resolve-egress-allowlist` and `harden-runner`. See
[.github/actions/README.md](../.github/actions/README.md#usage-example).
