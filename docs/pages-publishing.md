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
site in the same pipeline (for example `reusable-test-python-publish` and
`reusable-test-node-publish` on one push), the **last** deployment wins and
**removes** content from earlier jobs. The old gh-pages branch model could keep
both `python/` and `vitest/` on one branch; the artifact model cannot without
merging files in a single publish job.

**Mitigation:** Use one publish job per site per event, or merge all subtrees
into one staging directory before calling `publish-test-results` once.

## Isolated publish jobs

`reusable-test-python-publish` and `reusable-test-node-publish` run in a fresh
workspace. Checkout order must be: harden runner → caller repo → lgtm-ci tooling.
See [workflow-contract.md](workflow-contract.md).
