# Security actions

Hardening, egress control, pinning validation, and supply-chain
attestation/signing. See [workflow-contract.md](../workflow-contract.md) for
the full egress preset table and permission requirements.

## checkout-and-harden

Shared reusable-workflow preamble (#379): checks out lgtm-ci tooling into
`.lgtm-ci-tooling/`. It takes no part in egress enforcement — callers invoke
`step-security/harden-runner` as the first workflow step with an allowlist
composed from inputs and the workflow's literal preset map (#913). Requires a
prior bootstrap sparse checkout of `.github/actions/checkout-and-harden` (the
composite lives in lgtm-ci).

<!-- markdownlint-disable MD013 -- expression lines exceed the limit -->

```yaml
- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin>
  with:
    repository: ${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}
    sparse-checkout: |
      .github/actions/checkout-and-harden
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Checkout and harden
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
  with:
    # The composite never infers its source; pass the resolved ref, the
    # repository (with the GHES fallback) and the raw override for the warning.
    tooling-ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha }}
    tooling-repository: ${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}
    tooling-ref-override: ${{ inputs.tooling-ref }}
    sparse-checkout-extra: |
      scripts/ci/
```

<!-- markdownlint-enable MD013 -->

**Inputs:** `tooling-ref`, `tooling-repository`, `tooling-ref-override`,
`sparse-checkout-extra`, `persist-credentials` (default `false`).

**Outputs:** `scripts-dir` (absolute path to `.lgtm-ci-tooling/scripts`).

The former `resolve-egress-allowlist` composite and the bundled
`.github/actions/harden-runner/` resolver were removed in #913: their output
was consumed by nothing, because the harden-runner `pre` hook cannot see step
outputs.

## harden-runner

Security hardening using [StepSecurity](https://stepsecurity.io). Invoke
`step-security/harden-runner` as a **direct** workflow step (pinned SHA) so its
`pre` hook installs the egress agent.

The `pre` hook runs at **job start**, before any step exists. Reusable
workflows compose the allowlist from **workflow inputs** and a **literal
preset map** carried in the workflow's `env` (rendered from
`scripts/ci/lib/egress/presets.sh`, see
[workflow-contract.md](../workflow-contract.md#egress-allowlists)) — never
from `steps.*.outputs` (those are empty at `pre` time and block all egress).

Use a folded scalar (`>-`) so hosts are space-separated; a newline-separated
`|` block was observed to be treated as one token and block all egress (see
workflow-contract.md, "Egress presets").

Make this the **first step** in the job so the action `main` step applies the
allowlist before checkout or other network I/O. `pre` alone is not enough.

```yaml
- name: Harden runner
  uses: step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1 # v2.21.1
  with:
    egress-policy: ${{ inputs.egress-policy }} # block (default) or audit
    allowed-endpoints: >-
      ${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '')
      && inputs.allowed-endpoints
      || format('{0} {1}',
      fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'quality'],
      inputs.allowed-endpoints) }}
```

Do not nest step-security inside a local composite (GitHub skips nested
`pre`/`post`). Do not use `${{ }}` in remote action `@ref` segments inside
`uses:`.

## secure-checkout

Security-hardened repository checkout.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@main
  with:
    persist-credentials: "false" # default: false (secure)
    fetch-depth: "1" # default: 1 (shallow clone)
```

**Outputs:** `ref`, `commit`.

## egress-audit

Network egress configuration and reporting scaffolding.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/egress-audit@main
  with:
    mode: "audit" # 'audit', 'report', or 'block'
    report-format: "summary" # 'summary', 'json', or 'none'
```

Pre-configured allowlist for common package registries (GitHub, npm, PyPI,
Crates.io, RubyGems); generates a GitHub Step Summary report.

## validate-runner-policy

Enforces a tiered egress policy (`strict`, `hardened`, `permissive`) before
`harden-runner` and outputs whether egress enforcement should run on the
current leg.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/validate-runner-policy@main
  with:
    tier: "strict"
    egress-policy: "block"
    runner-environment: ${{ runner.environment }}
    runner-os: ${{ runner.os }}
```

**Outputs:** `enforce-egress`, `effective-policy`, `tier-warning`. See
[workflow-contract.md](../workflow-contract.md#runner-policy-tiers) for tier
semantics.

## validate-action-pinning

Ensures GitHub Actions references use SHA pins with Renovate version
comments.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/validate-action-pinning@main
  with:
    enforce: "true" # optional, default: true
    allow-tag-exceptions: "" # optional, comma-separated action names
    scan-paths: ".github/workflows .github/actions" # optional
    verify-tags: "true" # optional
```

Used by `reusable-validate-action-pinning.yml`. See
[workflow-contract.md](../workflow-contract.md#action-pinning-policy).

## Supply chain: SBOM, attestation, signing

### generate-sbom

Generate an SBOM using [Syft](https://github.com/anchore/syft).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-sbom@main
  with:
    target: "." # optional, default: current directory
    target-type: "dir" # 'dir', 'image', or 'file'
    format: "cyclonedx-json" # cyclonedx-json, spdx-json, cyclonedx-xml, spdx-tag-value
    upload-artifact: "true" # optional
```

**Outputs:** `sbom-file`, `sbom-format`.

Before calling `anchore/sbom-action`, the action runs
`scripts/ci/actions/prime-syft-tool-cache.sh`, which downloads Syft into the
Actions tool cache with retries and verifies it against the published
`checksums.txt`. `anchore/sbom-action` then finds Syft already cached and skips
its own no-retry download, so a transient GitHub CDN 5xx no longer fails the
job (#697). A checksum mismatch is never retried — it fails the job
immediately. The pinned Syft version lives in that script (Renovate-tracked)
and is passed to `anchore/sbom-action` via its `syft-version` input, so the two
cannot drift apart.

### scan-vulnerabilities

Scan for vulnerabilities using [Grype](https://github.com/anchore/grype).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/scan-vulnerabilities@main
  with:
    target: "sbom.cdx.json" # SBOM file, image, or directory
    target-type: "sbom" # 'sbom', 'image', or 'dir'
    fail-on: "high" # 'critical', 'high', 'medium', 'low', or ''
    upload-sarif: "true" # upload to GitHub Security tab
```

**Outputs:** `vulnerabilities-found`, `critical-count`, `high-count`,
`medium-count`, `low-count`, `sarif-file`.

### attest-build

Create build attestations via
[actions/attest-build-provenance](https://github.com/actions/attest-build-provenance).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/attest-build@main
  with:
    subject-path: "dist/myapp.tar.gz"
    subject-name: "myapp" # optional
    push-to-registry: "false"
```

**Outputs:** `attestation-id`, `attestation-url`, `bundle-path`. Requires
`id-token: write` and `attestations: write`.

### verify-attestation

Verify build attestations using `gh attestation verify`.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/verify-attestation@main
  with:
    target: "dist/myapp.tar.gz"
    target-type: "file" # 'file' or 'image'
```

**Outputs:** `verified`, `signer-identity`.

### sign-artifact

Sign release artifacts with Sigstore/Cosign keyless signing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/sign-artifact@main
  with:
    files: "dist/*.tar.gz"
    upload-signatures: "true"
    upload-to-release: "false"
```

**Outputs:** `signatures`, `certificate`, `signatures-dir`, `signed-count`.
Requires `id-token: write` (and `contents: write` when uploading to a
release). The release upload targets `repository` (default
`${{ github.repository }}`) through `GH_REPO` rather than whatever git remote
is in the workspace, so it works without a checkout (#935); set `repository`
when the release belongs to another repository.

Each blob is signed with a bounded, transient-only retry (shared with the
image-signing path via `scripts/ci/lib/cosign.sh`): only an ambient-OIDC
token-fetch flake is retried, with exponential backoff, and every other failure
stays fatal on the first attempt. The retry is scoped per file, so a flake on
one artifact never re-signs the ones that already succeeded. Tune with
`COSIGN_SIGN_MAX_ATTEMPTS` (default `3`) and `COSIGN_SIGN_MAX_DELAY` (default
`30` seconds) in the job environment.

### verify-signature

Verify Sigstore/Cosign signatures.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/verify-signature@main
  with:
    file: "dist/myapp.tar.gz"
    signature: "dist/myapp.tar.gz.sig"
    certificate: "dist/myapp.tar.gz.pem"
    certificate-identity: "https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
```

**Outputs:** `verified`.
