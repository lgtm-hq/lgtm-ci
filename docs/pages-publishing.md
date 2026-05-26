# GitHub Pages Publishing

lgtm-ci uses a single deployment model: **GitHub Actions OIDC** via
`actions/configure-pages`, `actions/upload-pages-artifact`, and
`actions/deploy-pages`. Third-party branch-push actions (for example
`peaceiris/actions-gh-pages`) are not supported and are blocked by org policy.

## Entry points

| Workflow / action                        | Content                     | `target-dir`       |
| ---------------------------------------- | --------------------------- | ------------------ |
| `publish-test-results`                   | Coverage, badges, test HTML | configurable       |
| `deploy-pages` + `reusable-deploy-pages` | Built static sites          | `dist` (site root) |

Typical `publish-test-results` directories include `python`, `vitest`,
`coverage`, and `playwright`.

Both paths upload a **full site artifact** per deployment. Each deploy replaces
the entire published site with that artifact.

## Caller permissions

Publish jobs require:

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

Do **not** grant `contents: write` for Pages publish; branch-push deploy is no
longer used.

When `egress-policy: block`, allow OIDC and artifact upload:

```yaml
allowed-endpoints: >
  github.com:443
  api.github.com:443
  actions.githubusercontent.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
```

## Concurrency

All Pages deploy jobs in lgtm-ci share:

```text
pages-${{ github.repository }}-${{ github.ref }}
```

This serializes deployments to the same site on the same ref (including
`reusable-deploy-pages` and coverage/test publish workflows).

## Multi-publisher limitation

If a repository runs **more than one** publish workflow to the same GitHub Pages
site in the same pipeline (for example `reusable-test-python-publish` deploying
`python/` and `reusable-test-node-publish` deploying `vitest/` on one push),
the shared concurrency group
`pages-${{ github.repository }}-${{ github.ref }}` **queues** those jobs—but
**does not merge** their artifacts. Each `upload-pages-artifact` +
`deploy-pages` run replaces the **entire** site. The **last** job wins and
**removes** subtrees from earlier jobs (for example only `vitest/` remains if
node publish runs after python publish).

The old `peaceiris/actions-gh-pages` model pushed to one branch with
`keep_files: true`, so `python/` and `vitest/` could coexist. The official
artifact model cannot do that without an explicit merge step.

| Mitigation                | When                                              |
| ------------------------- | ------------------------------------------------- |
| One publish job per event | One `publish-test-results` with combined subtrees |
| Model B site bundle       | Issue #226 (turbo-style bundle) [226]             |
| Optional live-site merge  | Issue #225 (multi Model A publishers) [225]       |

[225]: https://github.com/lgtm-hq/lgtm-ci/issues/225
[226]: https://github.com/lgtm-hq/lgtm-ci/issues/226

**Current org usage:** py-lintro calls only `reusable-test-python-publish`—not
affected.

## Isolated publish jobs

`reusable-test-python-publish` and `reusable-test-node-publish` run in a fresh
workspace. Checkout order must be: harden runner → caller repo → lgtm-ci tooling.
See [workflow-contract.md](workflow-contract.md).
