# Python release publishing

Guide for composing lgtm-ci reusables and composites in Python package release
workflows (tag push or manual dispatch). Callers keep product-specific steps
(Homebrew binary, Docker images) local.

## Components

| Component                        | Purpose                                           |
| -------------------------------- | ------------------------------------------------- |
| `reusable-build-python-dist.yml` | Build sdist/wheel and upload workflow artifact    |
| `prepare-pypi-upload` action     | Download artifact, validate, expose dist metadata |
| `pypa/gh-action-pypi-publish`    | OIDC upload (caller workflow step only)           |
| `build-python-package` action    | Build/validate (used inside build reusable)       |
| `reusable-github-release.yml`    | Attach artifacts to a GitHub Release              |

There is **no orchestrator** workflow. Compose jobs in the caller repository.

`pypa/gh-action-pypi-publish` **must not** be nested inside lgtm-ci composite
actions — GitHub resolves `github.action_repository` to the parent composite
(`lgtm-hq/lgtm-ci`), which breaks the pypa Docker action.

## Production tag push (recommended layout)

Typical caller jobs:

1. **Quality** — `reusable-quality-lint.yml`
2. **SBOM** — `reusable-sbom.yml`
3. **Build** — `reusable-build-python-dist.yml`
4. **Upload** — local job: `prepare-pypi-upload` → `pypa/gh-action-pypi-publish` → optional attestation
5. **GitHub Release** — `reusable-github-release.yml` (`needs: upload`)
6. **Product-specific** — Homebrew dispatch, Docker, etc.

Copy-paste starter: [`examples/publish-python-release.yml`](../examples/publish-python-release.yml).

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
            codeload.github.com:443
            objects.githubusercontent.com:443
            actions.githubusercontent.com:443
            *.blob.core.windows.net:443
            ghcr.io:443
            pkg-containers.githubusercontent.com:443
            pypi.org:443
            upload.pypi.org:443
            files.pythonhosted.org:443
            fulcio.sigstore.dev:443
            rekor.sigstore.dev:443
            tuf-repo-cdn.sigstore.dev:443
            oauth2.sigstore.dev:443
      - name: Prepare PyPI upload
        id: prepare
        uses: lgtm-hq/lgtm-ci/.github/actions/prepare-pypi-upload@<sha> # vX.Y.Z
        with:
          artifact-name: python-dist
          tooling-ref: "<sha>"
          python-version: "3.12"
      - name: Upload to PyPI
        uses: pypa/gh-action-pypi-publish@<pin> # v1.14.0
        with:
          repository-url: https://upload.pypi.org/legacy/
          packages-dir: ${{ steps.prepare.outputs.dist-path }}
      - name: Attest build provenance
        continue-on-error: true
        uses: actions/attest-build-provenance@<pin> # v4.1.0
        with:
          subject-path: ${{ steps.prepare.outputs.dist-path }}/*

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

`prepare-pypi-upload` checks out lgtm-ci tooling and calls sibling actions by local
path. See [workflow-contract.md](workflow-contract.md) for the composite action
local-path contract.

## TestPyPI

Same split: build reusable + caller upload job with
`repository-url: https://test.pypi.org/legacy/` on the pypa step and
`environment: testpypi` (or your TestPyPI environment).

## Caller permissions summary

| Job                   | Required permissions                                       |
| --------------------- | ---------------------------------------------------------- |
| PyPI build (reusable) | `contents: read`                                           |
| PyPI upload (local)   | `contents: read`, `id-token: write`, `attestations: write` |
| GitHub Release        | `contents: write`                                          |

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

Run `attest-build-provenance` as a **caller-level** step with
`continue-on-error: true` after a successful PyPI upload. Sigstore outages must
not fail the release job — the wheel is already on the index and retries would
not be idempotent.

## Upload validation

When `validate: true` (default), `prepare-pypi-upload` runs twine check with
`VALIDATE_STRICT=true` after `setup-python`. Validation tries `twine check`
directly, then `uv run --with twine twine check` when twine is not on PATH. The
upload job **fails** if neither method can run — distributions are never uploaded
without a passing check.

## Egress allowlists

Split allowlists between **build** (reusable `with:`) and **upload** (caller job
harden-runner). See [workflow-contract.md](workflow-contract.md) (§ PyPI build, §
PyPI upload).

## Homebrew tap dispatch (lgtm-hq/homebrew-tap)

Org products publish Homebrew formulas through a central tap. After PyPI upload
and GitHub Release succeed, dispatch an `update-formula` event to
[lgtm-hq/homebrew-tap](https://github.com/lgtm-hq/homebrew-tap). The tap
repository owns formula configuration, generation, and commit/PR logic (see
[homebrew-tap#44](https://github.com/lgtm-hq/homebrew-tap/issues/44)).

### Job ordering

Run the Homebrew dispatch job after both publish steps complete:

```yaml
homebrew-dispatch:
  needs: [pypi-upload, github-release]
```

### Required secret

Store a GitHub PAT or fine-grained token with `contents: write` on
`lgtm-hq/homebrew-tap` as `HOMEBREW_TAP_DISPATCH_TOKEN` in the caller
repository.

### Dispatch payload

The `trigger-homebrew-update` action sends `repository_dispatch` with
`event-type: update-formula`. Action inputs are mapped into `client_payload` as
follows:

| Action input        | `client_payload` field / location              |
| ------------------- | ---------------------------------------------- |
| `formula`           | `formula`                                      |
| `version`           | `version`                                      |
| `pypi-package`      | `pypi-package` (defaults to `formula`)         |
| `binary-arm64-sha`  | `binary-assets.arm64-sha` (when assets sent)   |
| `binary-x86-sha`    | `binary-assets.x86-sha` (when assets sent)     |

Omit `binary-arm64-sha` and `binary-x86-sha` for PyPI-only products — the action
then omits `binary-assets` from the payload entirely. When either SHA input is
non-empty, `binary-assets` is included with both keys.

Resulting `client_payload` schema:

| Field            | Required | Description                                      |
| ---------------- | -------- | ------------------------------------------------ |
| `formula`        | yes      | Homebrew formula name                            |
| `version`        | yes      | Release version                                  |
| `pypi-package`   | no       | PyPI project name (defaults to `formula`)        |
| `binary-assets`  | no       | Object with `arm64-sha` and `x86-sha` (optional) |

Version typically comes from `reusable-build-python-dist.yml` (`version` output),
not from `reusable-github-release.yml`.

### Example: PyPI-only (winnow)

```yaml
homebrew-dispatch:
  name: Update Homebrew formula
  needs: [pypi-upload, github-release, pypi-build]
  runs-on: ubuntu-latest
  steps:
    - uses: lgtm-hq/lgtm-ci/.github/actions/trigger-homebrew-update@<sha> # vX.Y.Z
      with:
        formula: winnow
        version: ${{ needs.pypi-build.outputs.version }}
        token: ${{ secrets.HOMEBREW_TAP_DISPATCH_TOKEN }}
```

### Example: PyPI + macOS binaries (lintro)

Wire SHA256 outputs from the caller's macOS release build job (names vary by
repository):

```yaml
homebrew-dispatch:
  name: Update Homebrew formula
  needs: [pypi-upload, github-release, pypi-build, macos-release]
  runs-on: ubuntu-latest
  steps:
    - uses: lgtm-hq/lgtm-ci/.github/actions/trigger-homebrew-update@<sha> # vX.Y.Z
      with:
        formula: lintro
        version: ${{ needs.pypi-build.outputs.version }}
        pypi-package: lintro
        binary-arm64-sha: ${{ needs.macos-release.outputs.arm64-sha256 }}
        binary-x86-sha: ${{ needs.macos-release.outputs.x86-sha256 }}
        token: ${{ secrets.HOMEBREW_TAP_DISPATCH_TOKEN }}
```

To add a new product, configure the formula in
[homebrew-tap](https://github.com/lgtm-hq/homebrew-tap) and wire a dispatch job
in the product repository release workflow.

### Same-repo tap (legacy)

For taps colocated with the product repository, `update-homebrew` and
`reusable-publish-homebrew.yml` still clone the tap and commit formula updates
directly. Prefer the dispatch model for `lgtm-hq/homebrew-tap`.

## Migration from v0.23.x

<!-- Wide migration table; MD013 disabled — row content cannot wrap without breaking pipes. -->
<!-- markdownlint-disable MD013 -->

| Removed                                  | Replacement                                            |
| ---------------------------------------- | ------------------------------------------------------ |
| `reusable-publish-pypi-release.yml`      | `reusable-build-python-dist.yml` + caller upload steps |
| `reusable-publish-pypi.yml`              | Same pattern; TestPyPI via `repository-url` on pypa    |
| `publish-pypi` action                    | `build-python-package` + `prepare-pypi-upload` + pypa  |
| `upload-pypi-oidc` action                | `prepare-pypi-upload` + caller-level pypa publish step |
| `github-environment` on reusable `with:` | `environment:` on caller upload **job**                |

<!-- markdownlint-enable MD013 -->

## Related docs

- [workflow-contract.md](workflow-contract.md)
- [reusable-workflows.md](reusable-workflows.md)
- [homebrew-tap](https://github.com/lgtm-hq/homebrew-tap) — formula config and dispatch handler
