# Deployment and supply-chain workflows

Docker builds, GitHub Pages deployment, SBOM/signing, and registry
maintenance. Full inputs/outputs/examples:
[reusable-workflows.md](../reusable-workflows.md#build-coverage-and-supply-chain).

## Docker

`reusable-docker.yml` builds and pushes multi-platform images with
provenance/SBOM attestations and optional Trivy scanning. Since #381 it is
a thin orchestrator: a `classify` job resolves the strategy and delegates
to `reusable-docker-build.yml` (single-platform / QEMU path) or
`reusable-docker-multiplatform.yml` (runner-map matrix + manifest merge +
signing); `reusable-docker-smoke-test.yml` validates an already published
image by digest. Existing callers keep working unchanged — see the
[migration path](../workflow-contract.md#docker-workflow-family-and-migration-path).
Callers only pin the workflow — no vendored `scripts/ci` tree required;
registry logins use the shared `docker-auth` composite resolved from the
lgtm-ci tooling checkout. Supports native per-platform split builds
(`runner-map`) with an optional per-platform smoke-test or
detached-container health check gating the final manifest merge. See
[Docker workflow inputs](../reusable-workflows.md#docker-workflow-inputs)
for caller examples (push, PR validation, health checks).

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@main
    with:
      context: "."
      platforms: "linux/amd64,linux/arm64"
      registry: "ghcr.io"
      push: true
      provenance: true
      sbom: true
      scan: true
      smoke-test: "--version"
```

**Inputs:** `context` (default '.'), `file` (default 'Dockerfile'),
`platforms` (default 'linux/amd64,linux/arm64'), `registry` (ghcr.io or
docker.io), `image-name` (default `github.repository`), `version` (semver
tags), `push` (default false), `provenance`/`sbom` (default true, apply
only when `push: true`), `scan` (default false), `runner-map` (JSON
platform → runner label; unmapped platforms use `ubuntu-24.04` + QEMU),
`smoke-test` (word-split command run inside each per-platform staging
image) or `smoke-test-script` (caller-owned script with env `IMAGE`,
`PLATFORM`, `REGISTRY`; mutually exclusive), `health-check-cmd` /
`health-check-port` / `health-check-timeout` (detached-container health
gate before publish), `tooling-ref`.

**Outputs:** `tags`, `digest`.

**Permissions:** `packages: write`, `id-token: write`,
`attestations: write`, `security-events: write` (when `scan` is enabled).
Docker Hub pushes additionally need `DOCKERHUB_USERNAME` /
`DOCKERHUB_TOKEN` secrets. Caller repos that previously vendored
`scripts/ci/actions/build-docker.sh`, `scripts/ci/lib/**`, or
`docker-login`/`docker-metadata` composites can delete those copies — the
workflows resolve all tooling (scripts and the `docker-auth` composite)
from the lgtm-ci checkout.

## GitHub Pages

Two models, see [pages-publishing.md](../pages-publishing.md) for the full
comparison:

- **Model A** (`reusable-deploy-pages.yml`): deploy-only — the caller
  builds the site and uploads the Pages artifact; this workflow deploys it.
- **Model B** (`reusable-deploy-site-with-reports.yml`): builds a site,
  bundles HTML report artifacts from other workflow runs via a manifest,
  and deploys once — for monorepos aggregating multiple CI reports.

Both use official OIDC Pages actions and share the
`pages-${{ github.repository }}-${{ github.ref }}` concurrency group.

### reusable-deploy-pages.yml

The caller builds and uploads via `actions/upload-pages-artifact` in a
prior job; this workflow deploys that named artifact.

**Inputs:** `artifact-name` (default 'github-pages'), `environment`
(default 'github-pages'), `runner-image` (default 'ubuntu-24.04'),
`tooling-ref`, `egress-policy`, `egress-preset` (default 'github-pages'),
`allowed-endpoints`, `allowed-endpoints-mode`, `timeout-minutes` (default
10).

**Outputs:** `page-url`. Requires `pages: write` and `id-token: write`;
`concurrency: { group: pages, cancel-in-progress: false }` serializes
deploys.

### reusable-deploy-site-with-reports.yml

**Inputs:** `site-root` (default `dist`), `build-command`,
`bundle-manifest` (inline JSON or path in caller repo),
`bundle-after-build` (default `true`), `commit-sha` (default
`github.sha`), `fallback-ref` (optional branch fallback), `strict-bundle`
(default `false`), `node-version` / `package-manager` /
`working-directory` / `frozen-lockfile` (build tooling), plus the standard
contract inputs (`tooling-ref`, `egress-policy`, `allowed-endpoints`,
`runner-image`, `timeout-minutes`, `artifact-name`, `environment`).

**Outputs:** `page-url`. Requires `contents: read`, `pages: write`,
`id-token: write`, and `actions: read` (artifact download in the build
job). Manifest schema and `workflow_run` caller patterns:
[pages-publishing.md](../pages-publishing.md).

## Supply chain

`reusable-sbom.yml` generates an SBOM (Syft), optionally scans it with Grype, and
can create a Sigstore attestation. `fail-on-severity` defaults to `critical` —
the job fails when Grype finds vulnerabilities at that severity or higher. Opt
out of the gate with `fail-on-severity: ""` (or `none`) for advisory-only scans.
See [workflow-contract.md](../workflow-contract.md#sbom--attestation) and
[reusable-workflows.md](../reusable-workflows.md#sbom-reusable-sbomyml).

### Rust release binaries

`reusable-build-rust-binaries.yml` cross-compiles a target matrix from
Linux (strict runner-policy tier, `rust-release` egress preset); called by
`reusable-publish-rust-release.yml` on tag pushes. See
[workflow-contract.md](../workflow-contract.md#rust-release-contract) for
artifact naming and the default target matrix.

## Documentation sites

`reusable-site-quality.yml` runs an Astro (or similar) docs build, a
lychee link check on the built HTML, and caller-provided check/test
commands in two parallel jobs. Consumer repo scripts (for example
`scripts/ci/site/build.sh`) stay in the consumer and are passed as command
inputs.

## Registry maintenance

`reusable-ghcr-cleanup.yml` prunes aged untagged container versions and
ephemeral build-cache tags (`pr-*`, `mq-*`, `dispatch-*`), skipping the
prune when referenced-digest collection is incomplete (protects multi-arch
manifest children and cosign/SLSA attestations from accidental deletion).
`reusable-registry-health-check.yml` scans workflow files for digest-pinned
images and verifies the digests still resolve, optionally opening an issue
on failure — used by lgtm-ci's own `registry-health-check.yml` caller.
