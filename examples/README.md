# Examples

Sample caller layouts for lgtm-hq repositories. Copy and adapt into your
`.github/workflows/` directory.

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
