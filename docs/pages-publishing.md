# GitHub Pages Publishing

lgtm-ci uses a single deployment model: **GitHub Actions OIDC** via
`actions/configure-pages`, `actions/upload-pages-artifact`, and
`actions/deploy-pages`. Third-party branch-push actions (for example
`peaceiris/actions-gh-pages`) are not supported and are blocked by org policy.

## Model A vs Model B

| Model | Use when | Entry point |
| ----- | -------- | ----------- |
| **A — report subtree** | Single-report repos (py-lintro) | `publish-test-results` |
| **B — bundled site** | Docs site + CI HTML on one origin | `reusable-deploy-site-with-reports` |

**Model A** uploads one subtree (`python/`, `vitest/`, …) per job. Each deploy
replaces the **entire** published site.

**Model B** builds (or reuses) a static site tree, downloads HTML artifacts from
other workflows via a manifest, copies them into configured destinations under
`site-root`, then deploys once. Prefer Model B over parallel Model A publishers
when you need `/coverage/`, `/playwright/`, and a docs site on one `github.io`
origin.

Issue [#225](https://github.com/lgtm-hq/lgtm-ci/issues/225) (merge existing live
site on deploy) is a fallback for legacy multi-publisher Model A setups. New
monorepos should use Model B ([#226](https://github.com/lgtm-hq/lgtm-ci/issues/226))
instead.

## Entry points

| Workflow / action | Content | `target-dir` / `site-root` |
| ----------------- | ------- | -------------------------- |
| `publish-test-results` | Coverage, badges, test HTML | configurable (`target-dir`) |
| `deploy-pages` + `reusable-deploy-pages` | Built static sites | `dist` (site root) |
| `reusable-deploy-site-with-reports` | Site + CI HTML bundles | `site-root` |

Typical `publish-test-results` directories include `python`, `vitest`,
`coverage`, and `playwright`.

Typical Model B destinations include `coverage`, `playwright`, `lighthouse`,
`playwright-examples`, and language-specific coverage folders.

Both paths upload a **full site artifact** per deployment. Each deploy replaces
the entire published site with that artifact.

## Model B caller example

Deploy after CI completes (`workflow_run`), bundling turbo-themes-equivalent
reports:

```yaml
name: Deploy site with reports

on:
  workflow_run:
    workflows:
      - Quality Check - CI Pipeline
      - Quality Check - E2E Tests
    types: [completed]
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write
  actions: read # required to download workflow artifacts

jobs:
  deploy:
    if: >-
      github.event.workflow_run.conclusion == 'success'
      && github.event.workflow_run.head_branch == 'main'
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-site-with-reports.yml@<sha>
    with:
      site-root: apps/site/dist
      build-command: bun run build
      package-manager: bun
      bundle-manifest: examples/bundle-manifest-turbo-themes.json
      commit-sha: ${{ github.event.workflow_run.head_sha }}
      fallback-ref: main # optional; omit for strict commit-only resolution
      tooling-ref: "<sha>"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        actions.githubusercontent.com:443
        codeload.github.com:443
        objects.githubusercontent.com:443
```

See `examples/bundle-manifest-turbo-themes.json` for a manifest that mirrors
turbo-themes report destinations. Workflow fields match workflow **display names**
or file stems (for example `quality-ci-main` matches `.github/workflows/quality-ci-main.yml`).

### Bundle manifest schema

```json
{
  "strict": false,
  "bundles": [
    {
      "id": "vitest-coverage",
      "workflow": "quality-ci-main",
      "artifact": "coverage-html",
      "dest": "coverage",
      "require_success": true
    }
  ]
}
```

- `strict: true` (manifest or `strict-bundle` input) fails the step when any
  entry is missing.
- `fallback-ref` (for example `main`) retries lookup on a branch when no run
  exists for `commit-sha`. Default is strict (no fallback).
- `require_success: false` includes failed, cancelled, and timed-out runs
  (artifacts uploaded with `if: always()`).

## Caller permissions

Publish jobs require:

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

Model B build jobs also require `actions: read` on the caller workflow so the
bundle step can resolve and download artifacts from other workflow runs.

Do **not** grant `contents: write` for Pages publish; branch-push deploy is no
longer used.

When `egress-policy: block`, allow OIDC, artifact upload, and GitHub API access:

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
`reusable-deploy-pages`, `reusable-deploy-site-with-reports`, and coverage/test
publish workflows).

## Multi-publisher limitation (Model A)

If a repository runs **more than one** Model A publish workflow to the same GitHub Pages
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

| Mitigation | When |
| ---------- | ---- |
| One publish job per event | One `publish-test-results` with combined subtrees |
| Model B site bundle | Monorepos — `reusable-deploy-site-with-reports` [226] |
| Optional live-site merge | Legacy Model A multi-publisher fallback [225] — set `merge-existing-site: true` on `publish-test-results` (and optionally `base-site-path` to skip HTTP mirror) |

[225]: https://github.com/lgtm-hq/lgtm-ci/issues/225
[226]: https://github.com/lgtm-hq/lgtm-ci/issues/226

### Optional Model A merge (`merge-existing-site`)

When a repository must keep **separate** Model A publish jobs (for example python
then node on the same ref), enable merge on each job after the first:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-test-results@v0.23.0
  with:
    target-dir: vitest
    coverage-path: coverage/
    merge-existing-site: "true"
    # Optional: copy a local tree instead of mirroring the public Pages URL
    # base-site-path: /path/to/previous/site
```

By default the prepare step mirrors `https://<owner>.github.io/<repo>/` with
`wget`. That mirror can be **stale** (CDN/cache) and is unsuitable for private
Pages without supplying `base-site-path`. Prefer **Model B**
(`reusable-deploy-site-with-reports`) for monorepos that own the full site tree.

**Current org usage:** py-lintro calls only `reusable-test-python-publish`—not
affected.

## Isolated publish jobs

`reusable-test-python-publish` and `reusable-test-node-publish` run in a fresh
workspace. Checkout order must be: harden runner → caller repo → lgtm-ci tooling.
See [workflow-contract.md](workflow-contract.md).
