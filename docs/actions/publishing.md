# Publishing and deployment actions

Package publishing (PyPI, npm, RubyGems, Homebrew), Docker builds, and
GitHub Pages deployment. See
[python-release-publish.md](../python-release-publish.md) for a full
production tag-push layout and
[pages-publishing.md](../pages-publishing.md) for Pages models.

## build-python-package

Build Python sdist/wheel and validate with twine. Does not upload to PyPI.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/build-python-package@main
  with:
    validate: "true"
```

**Outputs:** `version`, `package-name`.

## prepare-pypi-upload

Download a workflow artifact, validate distributions, and expose metadata
for a caller-level `pypa/gh-action-pypi-publish` step. Use only in a job
defined in the **caller** repository workflow.

```yaml
- name: Prepare PyPI upload
  id: prepare
  uses: lgtm-hq/lgtm-ci/.github/actions/prepare-pypi-upload@main
  with:
    artifact-name: python-dist
    tooling-ref: "<sha>"
    python-version: "3.12"

- name: Upload to PyPI
  uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
  with:
    repository-url: https://upload.pypi.org/legacy/
    packages-dir: ${{ steps.prepare.outputs.dist-path }}
```

**Outputs:** `dist-path`, `validated`, `package-name`, `package-version`.
Requires `contents: read`, `id-token: write`, `attestations: write`;
`environment: pypi`. When `validate: true` (default), the step fails if
twine check cannot run. Do **not** nest `pypa/gh-action-pypi-publish` inside
lgtm-ci composites.

## publish-npm

Build and publish Node.js packages to npm with provenance attestation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-npm@main
  with:
    dist-tag: "latest" # optional
    provenance: "true" # optional
    access: "public" # optional
    dry-run: "false" # optional, build only
```

**Outputs:** `published`, `version`, `package-name`, `tarball`. Requires
`id-token: write` and a GitHub-hosted runner for provenance; `NPM_TOKEN`
secret for authentication.

## publish-gem

Build and publish Ruby gems to RubyGems using OIDC trusted publishing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-gem@main
  with:
    gemspec: "" # optional, auto-detected
    dry-run: "false" # optional, build only
```

**Outputs:** `published`, `version`, `gem-name`, `gem-file`. Requires
`id-token: write`; configure a trusted publisher in RubyGems.

## trigger-homebrew-update

Dispatch a Homebrew formula update to a tap repository via
`repository_dispatch`. Use after PyPI and GitHub Release jobs complete.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/trigger-homebrew-update@main
  with:
    formula: winnow
    version: "1.2.3"
    token: ${{ secrets.HOMEBREW_TAP_DISPATCH_TOKEN }}
    tap-repository: lgtm-hq/homebrew-tap # optional, default
```

**Outputs:** `dispatched`, `tap-repository`. Token needs
`repository_dispatch` access to the tap repository. See
[python-release-publish.md](../python-release-publish.md) for payload
schema and examples.

## validate-package

Validate package metadata before publishing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/validate-package@main
  with:
    type: "pypi" # 'pypi', 'npm', or 'gem'
```

**Outputs:** `valid`, `name`, `version`.

## wait-for-package

Wait for a package to become available on a registry.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/wait-for-package@main
  with:
    registry: "pypi" # 'pypi', 'npm', or 'gem'
    package: "my-package"
    version: "1.2.3"
    max-wait: "600" # optional, seconds
```

**Outputs:** `available`, `elapsed`. Exponential backoff polling.

## build-docker

Build and push Docker images with multi-platform support. Prefer
[reusable-docker.yml](../workflows/deployment.md#docker) for a
complete workflow; this composite is the underlying build step.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/build-docker@main
  with:
    context: "."
    platforms: "linux/amd64,linux/arm64"
    registry: "ghcr.io"
    push: "true"
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

**Outputs:** `tags`, `digest`. Multi-platform builds with QEMU, automatic
semver/SHA/branch tag generation, GHA cache integration. Requires
`packages: write` for GHCR.

## docker-login

Login to GHCR or Docker Hub based on the `registry` input.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/docker-login@main
  with:
    registry: "ghcr.io" # or docker.io
    dockerhub-username: "" # required when registry is docker.io
    dockerhub-token: "" # required when registry is docker.io
```

Used internally by `build-docker` and `reusable-docker.yml`.

## deploy-pages

Prepare and upload content for GitHub Pages deployment using OIDC.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/deploy-pages@main
  with:
    source-path: "dist"
    build-command: "bun run build"
    artifact-name: "github-pages"
```

**Outputs:** `artifact-id`, `file-count`. Automatic `.nojekyll` creation and
content validation. Requires `pages: write`, `id-token: write`.

## bundle-workflow-artifacts

Download HTML report artifacts from other workflow runs into a site tree
before Pages deployment (Model B).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/bundle-workflow-artifacts@main
  with:
    commit-sha: ${{ github.sha }}
    site-root: apps/site/dist
    bundle-manifest: examples/bundle-manifest-turbo-themes.json
    fallback-ref: main
    strict: "false"
```

**Outputs:** `files-bundled`, `bundles-applied`, `bundle-warnings`. Requires
`actions: read`. See [pages-publishing.md](../pages-publishing.md) for
Model A vs B and the manifest schema.
