# Python release publishing

Guide for composing lgtm-ci reusables and composites in Python package release
workflows (tag push or manual dispatch). Callers keep product-specific steps
(Homebrew binary, Docker images) local.

## Components

| Component | Purpose |
| --- | --- |
| `reusable-build-python-dist.yml` | Build sdist/wheel and upload workflow artifact |
| `upload-pypi-oidc` action | OIDC upload + best-effort attestation (caller job only) |
| `build-python-package` action | Build/validate (used inside build reusable) |
| `reusable-github-release.yml` | Attach artifacts to a GitHub Release |

There is **no orchestrator** workflow. Compose jobs in the caller repository.

## Production tag push (recommended layout)

Typical caller jobs:

1. **Quality** — `reusable-quality-lint.yml`
2. **SBOM** — `reusable-sbom.yml`
3. **Build** — `reusable-build-python-dist.yml`
4. **Upload** — local job with `upload-pypi-oidc` (OIDC)
5. **GitHub Release** — `reusable-github-release.yml` (`needs: upload`)
6. **Product-specific** — Homebrew, Docker, etc.

```yaml
permissions: {}

jobs:
  sbom:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha> # vX.Y.Z
    # ...

  pypi-build:
    needs: [sbom]
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-python-dist.yml@<sha>
    permissions:
      contents: read
    with:
      python-version: "3.12"
      tooling-ref: "<sha>"
      artifact-name: python-dist
      egress-policy: block
      # workflow-contract.md § PyPI build
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        codeload.github.com:443
        release-assets.githubusercontent.com:443
        objects.githubusercontent.com:443
        github-releases.githubusercontent.com:443
        raw.githubusercontent.com:443
        astral.sh:443
        releases.astral.sh:443

  pypi-upload:
    name: Upload to PyPI
    needs: [pypi-build]
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      contents: read
      id-token: write
      attestations: write
    steps:
      - uses: step-security/harden-runner@<pin>
        with:
          egress-policy: block
          # workflow-contract.md § PyPI upload (OIDC)
          allowed-endpoints: >
            github.com:443
            api.github.com:443
            ghcr.io:443
            pkg-containers.githubusercontent.com:443
            pypi.org:443
            upload.pypi.org:443
            files.pythonhosted.org:443
            fulcio.sigstore.dev:443
            rekor.sigstore.dev:443
            tuf-repo-cdn.sigstore.dev:443
            oauth2.sigstore.dev:443
      - uses: lgtm-hq/lgtm-ci/.github/actions/upload-pypi-oidc@<sha>
        with:
          artifact-name: python-dist
          tooling-ref: "<sha>"
          python-version: "3.12"

  github-release:
    needs: [pypi-upload]
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@<sha>
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      tooling-ref: "<sha>"
```

Use the same `artifact-name` for `reusable-build-python-dist.yml` and
`reusable-github-release.yml`.

## TestPyPI

Same split: build reusable + caller upload job with `test-pypi: true` on
`upload-pypi-oidc` and `environment: testpypi` (or your TestPyPI environment).

## Caller permissions summary

| Job | Required permissions |
| --- | --- |
| PyPI build (reusable) | `contents: read` |
| PyPI upload (local) | `contents: read`, `id-token: write`, `attestations: write` |
| GitHub Release | `contents: write` |

## PyPI trusted publishing

OIDC upload **must** run in a job defined in the **caller** workflow file (e.g.
`publish-pypi-on-tag.yml`), not inside a cross-repo `workflow_call` reusable.

Configure PyPI trusted publisher for:

- Repository: `your-org/your-repo`
- Workflow: **caller** workflow filename (e.g. `publish-pypi-on-tag.yml`)
- Environment: `pypi` (if used)

Do **not** register `lgtm-hq/lgtm-ci` as a trusted publisher.

Cross-repo reusables cannot perform OIDC upload until PyPI supports it
([warehouse#11096](https://github.com/pypi/warehouse/issues/11096)).

## Provenance attestation

`upload-pypi-oidc` runs `attest-build-provenance` with `continue-on-error: true`
after a successful PyPI upload. Sigstore outages must not fail the release job or
skip `published: true` — the wheel is already on the index and retries would not
be idempotent.

## Egress allowlists

Split allowlists between **build** (reusable `with:`) and **upload** (caller job
harden-runner). See [workflow-contract.md](workflow-contract.md) (§ PyPI build, §
PyPI upload).

## Product-specific jobs

Run Homebrew or Docker with `needs: [pypi-upload, github-release]` when they
depend on a published GitHub Release.

## Migration from v0.23.x

| Removed | Replacement |
| --- | --- |
| `reusable-publish-pypi-release.yml` | `reusable-build-python-dist.yml` + `upload-pypi-oidc` |
| `reusable-publish-pypi.yml` | Same pattern; set `test-pypi: true` on upload action |
| `publish-pypi` action | `build-python-package` + `upload-pypi-oidc` |
| `github-environment` on reusable `with:` | `environment:` on caller upload **job** |

## Related docs

- [workflow-contract.md](workflow-contract.md)
- [reusable-workflows.md](reusable-workflows.md)
