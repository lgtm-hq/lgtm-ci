# Security actions

Hardening, egress control, pinning validation, and supply-chain
attestation/signing. See [workflow-contract.md](../workflow-contract.md) for
the full egress preset table and permission requirements.

## checkout-and-harden

Shared reusable-workflow preamble (#379): checks out lgtm-ci tooling into
`.lgtm-ci-tooling/` and resolves the egress allowlist (callers invoke
`step-security/harden-runner` as the first workflow step). Requires a prior
bootstrap sparse checkout of `.github/actions/checkout-and-harden` (the
composite lives in lgtm-ci).

```yaml
- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin>
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.workflow_sha }}
    sparse-checkout: |
      .github/actions/checkout-and-harden
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Checkout and harden
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
  with:
    tooling-ref: ${{ inputs.tooling-ref }}
    egress-preset: quality
    sparse-checkout-extra: |
      scripts/ci/
```

**Inputs:** `tooling-ref`, `egress-policy` (default `block`), `egress-preset`,
`allowed-endpoints`, `allowed-endpoints-mode` (default `replace`),
`sparse-checkout-extra`, `persist-credentials` (default `false`).

**Outputs:** `allowed-endpoints` (resolved allowlist), `scripts-dir` (absolute
path to `.lgtm-ci-tooling/scripts`).

## resolve-egress-allowlist

Resolves `allowed-endpoints` from explicit lists or `egress-preset` names.
Useful for validating/merging lists; **do not** feed its step output into
`step-security/harden-runner` (the action `pre` hook runs at job start and
cannot see step outputs — use workflow inputs or literals instead).

```yaml
- name: Resolve egress allowlist
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
  with:
    egress-policy: block
    egress-preset: quality
    allowed-endpoints: |
      private.registry.example:443
    allowed-endpoints-mode: append # default: replace
```

`replace` drops the preset when `allowed-endpoints` is non-empty; `append`
merges preset + extras with deduplication. Presets are defined in
`scripts/ci/lib/egress/presets.sh`.

## harden-runner

Security hardening using [StepSecurity](https://stepsecurity.io). Invoke
`step-security/harden-runner` as a **direct** workflow step (pinned SHA) so its
`pre` hook installs the egress agent.

The `pre` hook runs at **job start**, before any step outputs exist. Pass
allowlists from **workflow inputs** (reusables bake the default preset into
`allowed-endpoints`) or a **literal** `host:port` block — never from
`steps.*.outputs` (those are empty at `pre` time and block all egress).

Use YAML `>` (folded) for literal lists so endpoints are space-separated;
harden-runner does not apply newline-separated `|` lists.

Make this the **first step** in the job so the action `main` step applies the
allowlist before checkout or other network I/O. `pre` alone is not enough.

```yaml
- name: Harden runner
  uses: step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0
  with:
    egress-policy: block # default; use audit to log only
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
    disable-sudo: "false" # optional
```

Reusable workflows check out lgtm-ci into `.lgtm-ci-tooling` for allowlist
resolution — consumers do not copy `resolve-egress-allowlist` into their repo.
Do not nest step-security inside a local composite (GitHub skips nested
`pre`/`post`). Do not use `${{ }}` in remote action `@ref` segments inside
`uses:`. Support scripts for allowlist resolution live under
`.github/actions/harden-runner/` (`lib/`, `resolve-egress-endpoints.sh`).

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
release).

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
