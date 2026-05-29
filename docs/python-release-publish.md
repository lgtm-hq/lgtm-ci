# Python release publishing

Guide for composing lgtm-ci reusables in Python package release workflows (tag
push or manual dispatch). Callers keep product-specific steps (Homebrew binary,
Docker images, bootstrap actions) local and delegate the shared publish path to
lgtm-ci.

## Workflows

| Workflow | Purpose |
| --- | --- |
| `reusable-publish-pypi.yml` | Single-job TestPyPI or simple tag publish |
| `reusable-publish-pypi-release.yml` | Split build artifact + OIDC publish + attestation |
| `reusable-github-release.yml` | Attach artifacts to a GitHub Release |

There is **no orchestrator** workflow. Compose jobs in the caller repository,
matching the pattern from the split quality workflows PR
([#231](https://github.com/lgtm-hq/lgtm-ci/pull/231): `reusable-quality-lint.yml`
and `reusable-quality-pr-comment.yml` invoked directly).

## Production tag push (recommended layout)

Typical caller jobs:

1. **Quality** — `reusable-quality-lint.yml` (not the removed orchestrator)
2. **SBOM** — `reusable-sbom.yml` with `security-events: write`
3. **Build + publish** — `reusable-publish-pypi-release.yml`
4. **GitHub Release** — `reusable-github-release.yml` (`needs: publish`)
5. **Product-specific** — local workflows (Homebrew tap, Docker, etc.)

```yaml
permissions: {}

jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        ghcr.io:443

  sbom:
    needs: quality
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      security-events: write
      id-token: write
      attestations: write
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      egress-policy: block

  publish:
    needs: [quality, sbom]
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-pypi-release.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      python-version: "3.12"
      tooling-ref: "<sha>" # vX.Y.Z
      artifact-name: python-dist
      github-environment: pypi
      egress-policy: block
      # Full list: workflow-contract.md § PyPI publish (build + publish jobs).
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        codeload.github.com:443
        release-assets.githubusercontent.com:443
        objects.githubusercontent.com:443
        github-releases.githubusercontent.com:443
        raw.githubusercontent.com:443
        uploads.github.com:443
        ghcr.io:443
        pkg-containers.githubusercontent.com:443
        pypi.org:443
        upload.pypi.org:443
        files.pythonhosted.org:443
        astral.sh:443
        releases.astral.sh:443
        fulcio.sigstore.dev:443
        rekor.sigstore.dev:443
        tuf-repo-cdn.sigstore.dev:443
        oauth2.sigstore.dev:443

  github-release:
    needs: [publish]
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      tooling-ref: "<sha>" # vX.Y.Z
      generate-release-notes: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        uploads.github.com:443
        codeload.github.com:443
        release-assets.githubusercontent.com:443
        objects.githubusercontent.com:443
```

Use the same `artifact-name` for `reusable-publish-pypi-release.yml` and
`reusable-github-release.yml` so the release job downloads the wheel/sdist
uploaded by the build job. When `inputs.files` is empty, the release workflow
defaults asset globs to `{artifact-path}/*` (via `format('{0}/*',
inputs.artifact-path)`; default `artifact-path` is `dist`) for both the verify
step (`FILES`) and `create-github-release.sh` (`FILE_PATTERNS`). If you override
`inputs.files`, ensure those glob patterns match the files actually placed in
the artifact download path — you do not need to change `inputs.artifact-path`
just because you customized `files`. `ARTIFACT_PATH` is only used in verify
error messages.

## TestPyPI (single job)

For staging/manual publishes, keep the existing single-job reusable:

```yaml
jobs:
  publish:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-pypi.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      test-pypi: true
      update-homebrew: false
      python-version: "3.12"
      tooling-ref: "<sha>" # vX.Y.Z
```

## Caller permissions summary

| Job | Required permissions |
| --- | --- |
| Quality lint | `contents: read`, `packages: read` |
| SBOM | `contents: read`, `security-events: write`, `id-token: write`, `attestations: write` |
| PyPI publish | `contents: read`, `id-token: write`, `attestations: write` |
| GitHub Release | `contents: write` |

Nested reusable workflows validate permissions at parse time. Grant only what
each job needs; do not set top-level `permissions: write-all`.

## PyPI trusted publishing

Pass `github-environment` on the reusable workflow `with:` block. The publish
job inside `reusable-publish-pypi-release.yml` sets `environment` from that
input (caller jobs that use `uses:` cannot set `environment` themselves).

```yaml
jobs:
  publish:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-pypi-release.yml@<sha>
    with:
      github-environment: pypi
```

Ensure the PyPI project trusted publisher matches this repository, workflow
file name, and environment (if used).

## Egress allowlists

When `egress-policy: block`, pass `allowed-endpoints` from the caller for
**both** nested jobs (`build-artifacts` and `publish`). Use the canonical list
in [workflow-contract.md](workflow-contract.md) (§ PyPI publish).

| Endpoint | Why |
| --- | --- |
| `ghcr.io:443` | `pypa/gh-action-pypi-publish` Docker image pull |
| `pkg-containers.githubusercontent.com:443` | Container registry routing |
| `github-releases.githubusercontent.com:443` | `setup-python` / uv Python install |
| `raw.githubusercontent.com:443` | `setup-python` / uv Python install |
| `astral.sh:443`, `releases.astral.sh:443` | uv |
| `upload.pypi.org:443`, `pypi.org:443`, `files.pythonhosted.org:443` | PyPI upload |
| Sigstore hosts | OIDC publish + `attest-build-provenance` |

Run an end-to-end tag publish (or TestPyPI) in `audit` mode first, then copy
any additional hosts from the Harden Runner report into the allowlist.

## Product-specific jobs

Run Homebrew tap or other release-asset consumers **`needs: [publish,
github-release]`** when they expect GitHub Release assets to exist.

## Related docs

- [workflow-contract.md](workflow-contract.md) — standard inputs and permission matrix
- [reusable-workflows.md](reusable-workflows.md) — full workflow catalog
- [pages-publishing.md](pages-publishing.md) — test coverage Pages deploy (separate path)
