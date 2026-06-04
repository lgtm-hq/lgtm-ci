# Composite Actions

Reusable GitHub Actions for consistent CI/CD setup across repositories.

## Available Actions

### setup-env

Configure common CI environment variables and PATH.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main
  with:
    bin-dir: "${{ github.workspace }}/.local/bin" # optional
    add-to-path: "/custom/path1, /custom/path2" # optional
```

**Outputs:**

- `platform` - Detected platform (e.g., `linux-x86_64`, `darwin-arm64`)
- `os` - Detected OS (`linux`, `darwin`, `windows`)
- `arch` - Detected architecture (`x86_64`, `arm64`)
- `bin-dir` - The configured binary directory

**Environment variables set:**

- `CI=true`
- `NONINTERACTIVE=1`
- `DO_NOT_TRACK=1`
- Various telemetry opt-outs

---

### setup-python

Setup Python with [uv](https://github.com/astral-sh/uv) package manager.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@main
  with:
    python-version: "3.12" # optional, default: 3.12
    uv-version: "latest" # optional
    cache: "true" # optional, default: true
    install-dependencies: "true" # optional, default: true
```

**Outputs:**

- `python-version` - Installed Python version
- `uv-version` - Installed uv version
- `cache-hit` - Whether the cache was hit

**Features:**

- Automatic dependency installation from `pyproject.toml`, `uv.lock`, or
  `requirements.txt`
- Caching of uv dependencies and virtual environments
- Uses [astral-sh/setup-uv](https://github.com/astral-sh/setup-uv) under the hood

---

### setup-node

Setup Node.js with [bun](https://bun.sh) package manager.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-node@main
  with:
    node-version: "22" # optional, default: 22
    bun-version: "latest" # optional
    cache: "true" # optional, default: true
    install-dependencies: "true" # optional, default: true
    frozen-lockfile: "true" # optional, default: true
```

**Outputs:**

- `node-version` - Installed Node.js version
- `bun-version` - Installed bun version
- `cache-hit` - Whether the cache was hit

**Features:**

- Automatic dependency installation with `bun install`
- `--frozen-lockfile` by default for reproducible CI builds
- Caching of bun cache directory and node_modules

---

### setup-rust

Setup Rust toolchain with cargo caching.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-rust@main
  with:
    toolchain: "stable" # optional, default: stable
    components: "clippy, rustfmt" # optional
    targets: "wasm32-unknown-unknown" # optional
    cache: "true" # optional, default: true
```

**Outputs:**

- `rustc-version` - Installed rustc version
- `cargo-version` - Installed cargo version
- `cache-hit` - Whether the cache was hit

**Features:**

- Automatic cargo-binstall installation for faster binary installs
- Sparse registry protocol enabled by default
- Caching of cargo registry, git deps, and target directory
- Uses [dtolnay/rust-toolchain](https://github.com/dtolnay/rust-toolchain) under the
  hood

---

## Security Actions

### resolve-egress-allowlist

Resolves `allowed-endpoints` from explicit lists or `egress-preset` names. Run as a
**workflow step before** `harden-runner` so step-security's pre-hook receives the
allowlist (composite step outputs are not available at pre-hook time).

```yaml
- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin>
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: <sha>
    sparse-checkout: |
      .github/actions/harden-runner
      .github/actions/resolve-egress-allowlist
    sparse-checkout-cone-mode: true

- name: Resolve egress allowlist
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
  with:
    egress-policy: block
    egress-preset: quality
    allowed-endpoints: |
      private.registry.example:443
    allowed-endpoints-mode: append # default: replace

- uses: ./.lgtm-ci-tooling/.github/actions/harden-runner
  with:
    egress-policy: block
    allowed-endpoints: ${{ steps.egress.outputs['allowed-endpoints'] }}
```

`allowed-endpoints-mode`: `replace` drops the preset when `allowed-endpoints` is
non-empty; `append` merges preset + extras with deduplication.

Presets are defined in `scripts/ci/lib/egress/presets.sh` and bundled under
`.github/actions/harden-runner/lib/`.

### harden-runner

Security hardening using [StepSecurity](https://stepsecurity.io). Pass
**resolved** `allowed-endpoints` from a prior `resolve-egress-allowlist` step.

```yaml
- uses: ./.lgtm-ci-tooling/.github/actions/harden-runner
  with:
    egress-policy: block # default; use audit to log only
    allowed-endpoints: ${{ steps.egress.outputs['allowed-endpoints'] }}
    disable-sudo: "false" # optional
```

**Reusable workflows** checkout lgtm-ci into `.lgtm-ci-tooling` before egress steps.
Consumers do **not** copy `harden-runner` or `resolve-egress-allowlist` into their
repo. Do not use caller-local `./.github/actions/...` in cross-repo reusables, and
do not use `${{ }}` in remote action `@ref` segments inside `uses:`.

**Features:**

- Network egress monitoring and blocking
- Optional sudo disabling
- Integrates with StepSecurity dashboard

---

### secure-checkout

Security-hardened repository checkout with sensible defaults.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@main
  with:
    persist-credentials: "false" # default: false (secure)
    fetch-depth: "1" # default: 1 (shallow clone)
```

**Security defaults:**

- `persist-credentials: false` - Credentials not stored in git config
- Checkout integrity verification
- All standard checkout options supported

**Outputs:**

- `ref` - The resolved ref that was checked out
- `commit` - The commit SHA that was checked out

---

### egress-audit

Network egress configuration and reporting scaffolding.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/egress-audit@main
  with:
    mode: "audit" # 'audit', 'report', or 'block'
    report-format: "summary" # 'summary', 'json', or 'none'
```

**Features:**

- Pre-configured allowlist for common package registries
- GitHub Step Summary report generation
- Works alongside harden-runner for enforcement

**Default allowed domains:**

- GitHub (`github.com`, `api.github.com`, `ghcr.io`, etc.)
- npm (`registry.npmjs.org`)
- PyPI (`pypi.org`, `files.pythonhosted.org`)
- Crates.io (`crates.io`, `static.crates.io`)
- RubyGems (`rubygems.org`)

---

## SBOM & Supply Chain Security

### generate-sbom

Generate Software Bill of Materials (SBOM) using
[Syft](https://github.com/anchore/syft).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-sbom@main
  with:
    target: "." # optional, default: current directory
    target-type: "dir" # 'dir', 'image', or 'file'
    format: "cyclonedx-json" # see supported formats below
    upload-artifact: "true" # optional
    artifact-name: "sbom" # optional
```

**Outputs:**

- `sbom-file` - Path to the generated SBOM file
- `sbom-format` - Format of the generated SBOM

**Supported formats:**

- `cyclonedx-json` - CycloneDX JSON (default)
- `spdx-json` - SPDX JSON
- `cyclonedx-xml` - CycloneDX XML
- `spdx-tag-value` - SPDX Tag-Value

---

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

**Outputs:**

- `vulnerabilities-found` - Whether any vulnerabilities were found
- `critical-count` - Number of critical vulnerabilities
- `high-count` - Number of high-severity vulnerabilities
- `medium-count` - Number of medium-severity vulnerabilities
- `low-count` - Number of low-severity vulnerabilities
- `sarif-file` - Path to SARIF report (if generated)

**Features:**

- Scans SBOMs, container images, or directories
- Configurable failure threshold by severity
- SARIF report upload to GitHub Security tab
- Vulnerability summary in step summary

---

### attest-build

Create build attestations using
[GitHub attestations](https://github.com/actions/attest-build-provenance).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/attest-build@main
  with:
    subject-path: "dist/myapp.tar.gz" # artifact to attest
    subject-name: "myapp" # optional
    push-to-registry: "false" # push to container registry
```

**Outputs:**

- `attestation-id` - ID of the created attestation
- `attestation-url` - URL of the attestation
- `bundle-path` - Path to the attestation bundle

**Requirements:**

- `id-token: write` permission for OIDC signing
- `attestations: write` permission

---

### verify-attestation

Verify build attestations using `gh attestation verify`.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/verify-attestation@main
  with:
    target: "dist/myapp.tar.gz" # file or image to verify
    target-type: "file" # 'file' or 'image'
    owner: "my-org" # optional, defaults to repository owner
```

**Outputs:**

- `verified` - Whether the attestation was verified successfully
- `signer-identity` - Identity of the signer

---

### sign-artifact

Sign release artifacts (tarballs, binaries, SBOMs) with Sigstore/Cosign keyless signing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/sign-artifact@main
  with:
    files: "dist/*.tar.gz" # glob pattern(s) for files to sign
    upload-signatures: "true" # upload as GitHub Actions artifact
    upload-to-release: "false" # upload .sig/.pem to a release
    release-tag: "v1.0.0" # required if upload-to-release is true
```

**Outputs:**

- `signatures` - Multiline list of signature file paths
- `certificate` - Path to the last signing certificate
- `signatures-dir` - Directory containing all signature and certificate files
- `signed-count` - Number of files successfully signed

**Requirements:**

- `id-token: write` permission for OIDC keyless signing
- `contents: write` permission for release uploads (when `upload-to-release` is true)

---

### verify-signature

Verify Sigstore/Cosign signatures on artifacts.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/verify-signature@main
  with:
    file: "dist/myapp.tar.gz" # file to verify
    signature: "dist/myapp.tar.gz.sig" # signature file
    certificate: "dist/myapp.tar.gz.pem" # certificate file
    certificate-identity: "https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0"
    certificate-oidc-issuer: "https://token.actions.githubusercontent.com" # optional, this is the default
```

**Outputs:**

- `verified` - Whether the signature was verified successfully

---

## PR & Comment Actions

### post-pr-comment

Create or update PR comments with upsert behavior using unique markers.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@main
  with:
    marker: "lighthouse-results" # unique identifier for this comment
    body: |
      ## Results
      Your content here...
    mode: "upsert" # 'upsert', 'create', or 'update'
```

**Features:**

- Upsert behavior: updates existing comment or creates new one
- Marker-based identification using hidden HTML comments
- Auto-detects PR number from context
- Optional delete-on-empty behavior

**Outputs:**

- `comment-id` - ID of the created/updated comment
- `comment-url` - URL of the comment
- `action-taken` - "created", "updated", "deleted", or "skipped"

---

### semantic-pr-title

Validate PR title follows conventional commit format.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/semantic-pr-title@main
  with:
    types: "feat,fix,docs,chore" # optional, allowed types
    require-scope: "false" # optional
    max-length: "72" # optional
```

**Features:**

- Validates conventional commit format (`type(scope): description`)
- Configurable allowed types and scopes
- Length validation
- Extracts type, scope, and description

**Outputs:**

- `valid` - Whether the title is valid
- `type` - Extracted commit type
- `scope` - Extracted scope
- `description` - Extracted description

---

### run-lighthouse

Run Lighthouse CI audits with configurable score thresholds.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-lighthouse@main
  with:
    url: "http://localhost:3000"
    threshold-performance: "80"
    threshold-accessibility: "90"
    threshold-best-practices: "80"
    threshold-seo: "80"
```

**Inputs:**

- `url` - URL to audit (required)
- `node-version` - Node.js version (default: '20')
- `config-path` - Path to lighthouserc.json (optional)
- `output-dir` - Directory for results (default: 'lighthouse-reports')
- `threshold-performance` - Min performance score (default: 80)
- `threshold-accessibility` - Min accessibility score (default: 90, error level)
- `threshold-best-practices` - Min best practices score (default: 80)
- `threshold-seo` - Min SEO score (default: 80)

**Outputs:**

- `performance`, `accessibility`, `best-practices`, `seo` - Individual scores
- `passed` - Whether all thresholds are met
- `failed-categories` - Comma-separated list of failed categories
- `results-path` - Path to results JSON file

**Features:**

- Automatic @lhci/cli installation
- Chrome flags optimized for CI (--headless=new, --no-sandbox)
- Filesystem upload (no external services required)
- Artifact upload for HTML reports

---

### generate-lighthouse-comment

Generate formatted PR comment from Lighthouse CI results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-lighthouse-comment@main
  with:
    results-path: "lighthouse-results/"
    report-url: "https://example.github.io/lighthouse/"
    threshold-performance: "80"
```

**Features:**

- Parses Lighthouse JSON results
- Generates py-lintro-style PR report comments
- Color-coded score indicators
- Configurable thresholds
- Links to full report

**Outputs:**

- `comment-body` - Generated Markdown comment
- `performance-score`, `accessibility-score`, etc.
- `passed` - Whether all thresholds are met

---

### generate-playwright-comment

Generate formatted PR comment from Playwright test results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-playwright-comment@main
  with:
    results-path: "playwright-report/results.json"
    report-url: "https://example.github.io/playwright/"
    show-failed-tests: "true"
```

**Features:**

- Parses Playwright JSON results
- Generates py-lintro-style PR report comments
- Shows pass/fail/skip counts
- Lists failed tests (collapsible)
- Links to full report

**Outputs:**

- `comment-body` - Generated Markdown comment
- `total-tests`, `passed-tests`, `failed-tests`, `skipped-tests`
- `success` - Whether all tests passed

---

### generate-coverage-comment

Generate formatted PR comment from code coverage results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-comment@main
  with:
    coverage-file: "coverage/coverage-summary.json"
    format: "auto" # 'istanbul', 'coverage-py', 'lcov', or 'auto'
    threshold-lines: "80"
    threshold-branches: "70"
```

**Features:**

- Supports Istanbul (JS), coverage.py (Python), and LCOV formats
- Generates py-lintro-style PR report comments
- Color-coded coverage indicators
- Configurable thresholds
- Links to full report

**Outputs:**

- `comment-body` - Generated Markdown comment
- `lines-coverage`, `branches-coverage`, `functions-coverage`
- `passed` - Whether all thresholds are met

---

## Testing & Coverage Actions

### run-tests

Generic test runner that auto-detects and delegates to language-specific runners.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-tests@main
  with:
    runner: "auto" # 'pytest', 'vitest', 'playwright', or 'auto'
    coverage: "true" # optional
    coverage-format: "json" # 'xml', 'json', 'lcov'
    extra-args: "" # additional runner arguments
    working-directory: "." # optional
```

**Outputs:**

- `exit-code` - Exit code from the test runner
- `runner` - Test runner that was used
- `tests-passed` - Number of tests passed
- `tests-failed` - Number of tests failed
- `tests-skipped` - Number of tests skipped
- `coverage-file` - Path to coverage file

**Features:**

- Auto-detects test runner from project files
- Supports pytest, vitest, and Playwright
- Unified output format across runners

---

### run-pytest

Run Python tests using pytest with optional coverage.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@main
  with:
    python-version: "3.12" # optional
    test-path: "tests" # optional
    coverage: "true" # optional
    coverage-format: "json" # 'xml', 'json', 'lcov'
    markers: "not slow" # optional, pytest markers
    extra-args: "-v" # optional
    working-directory: "." # optional
```

**Outputs:**

- `exit-code` - Exit code from pytest
- `tests-passed`, `tests-failed`, `tests-skipped`, `tests-total`
- `coverage-file` - Path to coverage file
- `coverage-percent` - Coverage percentage

**Features:**

- Automatic pytest and pytest-cov installation
- JSON report generation for result parsing
- Coverage in XML, JSON, or LCOV formats

---

### run-vitest

Run JavaScript/TypeScript tests using vitest with optional coverage.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-vitest@main
  with:
    node-version: "20" # optional
    test-path: "." # optional
    coverage: "true" # optional
    coverage-format: "json" # 'json', 'lcov', 'html'
    extra-args: "" # optional
    working-directory: "." # optional
```

**Outputs:**

- `exit-code` - Exit code from vitest
- `tests-passed`, `tests-failed`, `tests-skipped`, `tests-total`
- `coverage-file` - Path to coverage file
- `coverage-percent` - Coverage percentage

**Features:**

- Automatic vitest and @vitest/coverage-v8 installation
- Uses bun for package management
- Istanbul-compatible coverage output

---

### run-playwright

Run E2E tests using Playwright with browser automation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-playwright@main
  with:
    node-version: "20" # optional
    project: "" # optional, Playwright project
    browser: "chromium" # 'chromium', 'firefox', 'webkit', 'all'
    reporter: "html" # 'json', 'html', 'junit'
    shard: "1/3" # optional, for parallel execution
    extra-args: "" # optional
    working-directory: "." # optional
```

**Outputs:**

- `exit-code` - Exit code from Playwright
- `tests-passed`, `tests-failed`, `tests-skipped`, `tests-total`
- `report-path` - Path to test report

**Features:**

- Automatic browser installation
- Support for sharding across multiple runners
- HTML report upload as artifact

---

### merge-playwright-reports

Merge multiple Playwright reports from sharded or matrix test runs.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/merge-playwright-reports@main
  with:
    input-dir: "playwright-reports"
    output-dir: "merged-report"
    report-format: "html"
```

**Inputs:**

- `input-dir` - Directory containing report artifacts (default: 'playwright-reports')
- `output-dir` - Directory for merged report (default: 'merged-report')
- `report-format` - Output format: json, html (default: 'html')

**Outputs:**

- `merged-path` - Path to merged report
- `report-count` - Number of reports merged
- `total-passed`, `total-failed`, `total-skipped` - Aggregated test counts

**Features:**

- Supports Playwright blob reports from sharded runs
- Merges JSON reports with aggregated statistics
- Compatible with matrix strategy workflows

---

### collect-coverage

Aggregate coverage from multiple sources and formats.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/collect-coverage@main
  with:
    coverage-files: "coverage/*.json" # glob or comma-separated
    input-format: "auto" # 'auto', 'istanbul', 'coverage-py', 'lcov'
    output-format: "json" # 'json', 'lcov'
    merge-strategy: "union" # 'union', 'intersection'
    working-directory: "." # optional
```

**Outputs:**

- `merged-coverage-file` - Path to merged coverage file
- `coverage-percent` - Overall coverage percentage
- `lines-coverage`, `branches-coverage`, `functions-coverage`

**Features:**

- Auto-detects coverage format from file content
- Merges coverage from Python and JavaScript projects
- Supports multiple input formats

---

### check-coverage-threshold

Check if coverage meets a minimum threshold.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/check-coverage-threshold@main
  with:
    coverage-percent: "85.5" # current coverage
    threshold: "80" # minimum required
    fail-on-error: "true" # optional, default: true
```

**Outputs:**

- `passed` - Whether coverage meets the threshold
- `message` - Human-readable result message

**Features:**

- Portable decimal comparison using awk
- Configurable failure behavior
- Clear error messages with GitHub annotations

---

### generate-coverage-badge

Generate coverage badge SVG/JSON for README display.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-badge@main
  with:
    coverage-file: "coverage.json" # or use coverage-percent
    coverage-percent: "85.5" # if not extracting from file
    format: "svg" # 'svg', 'json', 'shields'
    output-path: "badge.svg" # optional
    label: "coverage" # optional
    thresholds: "50,80" # red,yellow boundaries
```

**Outputs:**

- `badge-file` - Path to generated badge file
- `coverage-percent` - Coverage percentage used
- `badge-url` - Shields.io URL for badge
- `badge-color` - Badge color (red, yellow, green, brightgreen)

**Features:**

- Local SVG generation (no external dependencies)
- Shields.io-compatible JSON endpoint
- Configurable color thresholds

---

### publish-test-results

Publish test results and coverage to GitHub Pages via official OIDC deploy
actions.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-test-results@main
  with:
    results-path: "test-results/" # optional
    coverage-path: "coverage/" # optional
    badge-path: "coverage/badge.svg" # optional
    target-dir: "." # optional
    merge-existing-site: "false" # optional Model A multi-publisher merge
    base-site-path: "" # optional local site tree instead of HTTP mirror
```

**Outputs:**

- `pages-url` - GitHub Pages URL

**Features:**

- Stages coverage, badges, and test HTML under `target-dir`
- Optional `merge-existing-site` preserves sibling subtrees when multiple Model A
  publishers deploy to the same Pages site (see `docs/pages-publishing.md`)
- Deploys with `actions/configure-pages`, `upload-pages-artifact`, `deploy-pages`
- Generates index.html for coverage reports when missing

**Required Permissions (caller job):**

- `contents: read`
- `pages: write`
- `id-token: write`

See [docs/pages-publishing.md](../../docs/pages-publishing.md) for concurrency and
multi-publisher limits.

---

### deploy-pages

Prepare and upload content for GitHub Pages deployment using OIDC.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/deploy-pages@main
  with:
    source-path: "dist"
    build-command: "bun run build"
    artifact-name: "github-pages"
```

**Inputs:**

- `source-path` - Path to static content (default: 'dist')
- `build-command` - Optional build command to run first
- `artifact-name` - Name for pages artifact (default: 'github-pages')

**Outputs:**

- `artifact-id` - ID of the uploaded artifact
- `file-count` - Number of files in the deployment

**Features:**

- Automatic .nojekyll file creation
- Content validation (large files, symlinks)
- Uses actions/upload-pages-artifact for OIDC deployment
- Compatible with actions/deploy-pages

**Required Permissions:**

- `pages: write` - For GitHub Pages deployment
- `id-token: write` - For OIDC authentication

---

### bundle-workflow-artifacts

Download HTML report artifacts from other workflow runs into a site tree before
Pages deployment (Model B).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/bundle-workflow-artifacts@main
  with:
    commit-sha: ${{ github.sha }}
    site-root: apps/site/dist
    bundle-manifest: examples/bundle-manifest-turbo-themes.json
    fallback-ref: main
    strict: "false"
```

**Inputs:**

- `commit-sha` - Commit SHA to resolve workflow runs (default: `github.sha`)
- `site-root` - Site directory to copy bundled reports into (default: `dist`)
- `bundle-manifest` - Inline JSON or path to `.json`/`.yaml`/`.yml` manifest
- `fallback-ref` - Optional branch ref for fallback lookup (for example `main`)
- `strict` - Fail when any manifest entry cannot be resolved (default: `false`)

**Outputs:**

- `files-bundled` - Number of files copied from downloaded artifacts
- `bundles-applied` - Number of manifest entries successfully applied
- `bundle-warnings` - Number of manifest entries that logged warnings

**Required Permissions:**

- `actions: read` - Resolve and download artifacts from other workflow runs

See [pages-publishing.md](../../docs/pages-publishing.md) for Model A vs B and
manifest schema.

---

## Docker Actions

### build-docker

Build and push Docker images with multi-platform support.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/build-docker@main
  with:
    context: "."
    file: "Dockerfile"
    platforms: "linux/amd64,linux/arm64"
    registry: "ghcr.io"
    image-name: ${{ github.repository }}
    push: "true"
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

**Inputs:**

- `context` - Build context path (default: '.')
- `file` - Dockerfile path (default: 'Dockerfile')
- `platforms` - Target platforms (default: 'linux/amd64,linux/arm64')
- `registry` - Container registry (default: 'ghcr.io')
- `image-name` - Image name (default: github.repository)
- `tags` - Additional tags (comma-separated)
- `version` - Version for semver tags (e.g., v1.2.3)
- `push` - Push to registry (default: 'false')
- `load` - Load into local docker (default: 'false')
- `build-args` - Build arguments (comma-separated key=value)
- `cache-from` - Cache source (default: 'type=gha')
- `cache-to` - Cache destination (default: 'type=gha,mode=max')
- `github-token` - GitHub token for GHCR authentication

**Outputs:**

- `tags` - Generated image tags (newline-separated)
- `digest` - Image digest (if pushed)

**Features:**

- Multi-platform builds with QEMU
- Automatic tag generation (semver, SHA, branch)
- GitHub Actions cache integration
- OCI labels for traceability
- GHCR authentication support

**Required Permissions:**

- `packages: write` - For pushing to GHCR

---

## Quality Actions

### run-quality

Runs **lintro inside the full [`py-lintro`](https://github.com/lgtm-hq/py-lintro)
Docker image** (`docker pull` + `docker run` with the repo mounted at `/code`),
so every bundled CLI matches upstream docs — not `uv run lintro` on the runner.

Callers need **`permissions: packages: read`** (and GitHub logs into GHCR via
`GITHUB_TOKEN`) when pulling from GHCR.

```yaml
permissions:
  contents: read
  packages: read

jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@…
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-quality@main
        with:
          # Pin digest in production (default matches this repo’s CI pin)
          lintro-image: ghcr.io/lgtm-hq/py-lintro@sha256:1ff3db35939283734b859c7c5d95be87fd8fd62734b3434e0437769d50d53578
          tools: "" # optional, comma-separated list (empty = all)
          mode: "check" # 'check' or 'format'
          fail-on-error: "true" # optional
          working-directory: "." # optional
```

**Inputs:**

- `lintro-image` - Full `ghcr.io/lgtm-hq/py-lintro` reference (**digest recommended**)
- `tools` - Comma-separated list of lintro tools to run (empty = all)
- `mode` - Mode: 'check' (lint only) or 'format' (auto-fix)
- `fail-on-error` - Fail workflow if linting errors found (default: true)
- `working-directory` - Working directory for linting (default: '.')

**Features:**

- Same toolchain as the official py-lintro container (shellcheck, prettier, semgrep, etc.)
- Check or format mode with optional `--tools` filtering
- Writes `chk-output.txt` in `working-directory` when `mode` is `check` (for artifacts)

**Outputs:**

- `exit-code` - Exit code from lintro
- `status` - "passed" or "failed"

---

## Release Actions

**Required Permissions:**

Release actions typically need the following GitHub Actions permissions:

- `contents: write` - Required for creating tags and releases
- `packages: write` - Required if uploading assets to GitHub Packages

### calculate-version

Calculate the next semantic version based on conventional commits.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/calculate-version@main
  with:
    max-bump: "minor" # optional, clamp max bump type
```

**Outputs:**

- `current-version` - Current version from latest tag
- `next-version` - Calculated next version
- `bump-type` - Detected bump type (major, minor, patch, none)
- `release-needed` - Whether a release is needed

---

### generate-changelog

Generate changelog from conventional commits.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-changelog@main
  with:
    version: "1.2.0" # optional
    format: "full" # full, simple, or with-type
```

**Outputs:**

- `changelog` - Generated changelog content (Markdown)

---

### create-release-tag

Create an annotated git tag for release.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-release-tag@main
  with:
    version: "1.2.0"
    push: "true" # push tag to origin
```

**Outputs:**

- `tag-name` - Created tag name (e.g., v1.2.0)
- `tag-sha` - Tag SHA
- `commit-sha` - Commit SHA the tag points to

---

### create-github-release

Create a GitHub release with changelog and optional assets.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-github-release@main
  with:
    tag: "v1.2.0"
    draft: "false"
    prerelease: "false"
    files: "dist/*.tar.gz dist/*.whl" # optional
    token: ${{ steps.app-token.outputs.token }} # optional, see note below
```

> **Note:** By default, `token` uses the built-in `GITHUB_TOKEN`. Events created
> by `GITHUB_TOKEN` do not trigger other workflows (GitHub prevents recursive
> workflow runs). If downstream workflows need to react to the `release:published`
> event, pass a GitHub App installation token or PAT instead.

**Outputs:**

- `release-url` - URL of the created release
- `release-id` - ID of the created release

---

## Publishing Actions

### build-python-package

Build Python sdist/wheel and validate with twine. Does not upload to PyPI.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/build-python-package@main
  with:
    validate: "true"
    working-directory: "."
```

**Outputs:** `version`, `package-name`

---

### prepare-pypi-upload

Download a workflow artifact, validate distributions, and expose metadata for a
caller-level `pypa/gh-action-pypi-publish` step. Use only in a job defined in
the **caller** repository workflow (see
[python-release-publish.md](../../docs/python-release-publish.md)).

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

**Outputs:** `dist-path`, `validated`, `package-name`, `package-version`

**Requirements:** `contents: read`, `id-token: write`, `attestations: write` on the
job; `environment: pypi`; PyPI trusted publisher matches the caller workflow file.

When `validate: true` (default), distribution validation runs with
`VALIDATE_STRICT=true` — the step fails if twine check cannot run (via twine or
`uv run --with twine`).

Do **not** nest `pypa/gh-action-pypi-publish` inside lgtm-ci composites.

---

### publish-npm

Build and publish Node.js packages to npm with provenance attestation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-npm@main
  with:
    node-version: "22" # optional
    dist-tag: "latest" # optional, npm dist-tag
    provenance: "true" # optional, enable provenance attestation
    access: "public" # optional, package access level
    dry-run: "false" # optional, build only
    working-directory: "." # optional
```

**Outputs:**

- `published` - Whether the package was published
- `version` - Package version
- `package-name` - Package name
- `tarball` - Path to the built tarball

**Requirements:**

- `id-token: write` permission for provenance
- Must run on GitHub-hosted runners for provenance attestation
- `NPM_TOKEN` secret for authentication

---

### publish-gem

Build and publish Ruby gems to RubyGems using OIDC trusted publishing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-gem@main
  with:
    gemspec: "" # optional, auto-detected
    dry-run: "false" # optional, build only
    working-directory: "." # optional
```

**Outputs:**

- `published` - Whether the gem was published
- `version` - Gem version
- `gem-name` - Gem name
- `gem-file` - Path to the built gem file

**Requirements:**

- `id-token: write` permission for OIDC authentication
- Configure trusted publisher in RubyGems

---

### update-homebrew

Update a Homebrew formula with a new version from PyPI.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/update-homebrew@main
  with:
    tap-repository: "owner/homebrew-tap" # required
    formula: "mypackage" # required
    package-name: "my-pypi-package" # required
    version: "1.2.3" # required
    wait-for-availability: "true" # optional
    max-wait-minutes: "10" # optional
    test-pypi: "false" # optional
    push: "true" # optional
    create-pr: "false" # optional
```

**Outputs:**

- `updated` - Whether the formula was updated
- `commit-sha` - Commit SHA of the update
- `pr-url` - Pull request URL (if create-pr is true)

**Requirements:**

- Repository write access for pushing to tap (via `GITHUB_TOKEN` or PAT)
- `contents: write` permission when used in workflows

**Features:**

- Waits for package availability on PyPI
- Downloads and calculates SHA256 automatically
- Creates or updates existing formulas
- Supports direct push or PR workflow

---

### validate-package

Validate package metadata before publishing.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/validate-package@main
  with:
    type: "pypi" # 'pypi', 'npm', or 'gem'
    path: "." # optional
```

**Outputs:**

- `valid` - Whether the package is valid
- `name` - Package name
- `version` - Package version

**Features:**

- Validates PyPI packages with twine check
- Validates npm package.json required fields
- Validates gemspec syntax and required fields

---

### wait-for-package

Wait for a package to be available on a registry.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/wait-for-package@main
  with:
    registry: "pypi" # 'pypi', 'npm', or 'gem'
    package: "my-package" # package name
    version: "1.2.3" # version to wait for
    max-wait: "600" # optional, max wait in seconds
    test-pypi: "false" # optional
```

**Outputs:**

- `available` - Whether the package became available
- `elapsed` - Time elapsed waiting (seconds)

**Features:**

- Exponential backoff polling
- Supports PyPI, npm, and RubyGems registries
- Configurable timeout

---

## Usage Example

Caller-owned workflow: pin each action to a **commit SHA** (not a branch). Check out
lgtm-ci into `.lgtm-ci-tooling`, resolve egress in a step **before** `harden-runner`,
then pass `steps.egress.outputs['allowed-endpoints']` into harden-runner (see
[resolve-egress-allowlist](#resolve-egress-allowlist) above).

Prefer [reusable workflows](#reusable-workflows) when you want drop-in jobs without
copying `.github/actions/harden-runner` or `resolve-egress-allowlist` into your repo.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          repository: lgtm-hq/lgtm-ci
          path: .lgtm-ci-tooling
          ref: <sha> # vX.Y.Z
          sparse-checkout: |
            .github/actions/
          sparse-checkout-cone-mode: true
          persist-credentials: false

      - name: Resolve egress allowlist
        id: egress
        uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
        with:
          egress-policy: block
          egress-preset: github-tooling

      - uses: ./.lgtm-ci-tooling/.github/actions/harden-runner
        with:
          egress-policy: block
          allowed-endpoints: ${{ steps.egress.outputs['allowed-endpoints'] }}

      - uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@<sha> # vX.Y.Z

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@<sha> # vX.Y.Z

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@<sha> # vX.Y.Z
        with:
          python-version: "3.12"

      - name: Run tests
        run: uv run pytest
```

## Reusable Workflows

Reusable workflows provide complete CI/CD pipelines that can be called from other
workflows. They load egress composites from an internal `.lgtm-ci-tooling` checkout —
callers only pin the workflow `@sha` and optional `tooling-ref`; see
[docs/reusable-workflows.md](../../docs/reusable-workflows.md).

### reusable-test-python.yml

Complete Python testing workflow with pytest and optional coverage.

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@main
    with:
      python-version: "3.12"
      test-path: "tests"
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
```

**Inputs:**

- `python-version` - Python version (default: '3.12')
- `test-path` - Path to tests (default: 'tests')
- `coverage` - Collect coverage (default: false)
- `coverage-format` - Format: xml, json, lcov (default: 'json')
- `coverage-threshold` - Minimum coverage % (default: 0)
- `upload-coverage` - Upload as artifact (default: false)

**Outputs:**

- `tests-passed`, `tests-failed`, `tests-total`
- `coverage-percent`
- `passed` - Whether all tests passed

---

### reusable-test-node.yml

Node.js Vitest testing workflow with optional coverage and PR comments. Custom
package scripts (for example `bun run test:coverage`) use
`reusable-test-node-custom.yml` instead.

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@main
    with:
      job-name: "Web Unit Tests"
      node-version: "20"
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
```

**Inputs:**

- `job-name` - GitHub check name for the Vitest job (default: `Node.js Tests`)
- `node-version` - Node.js version (default: '20')
- `test-path` - Path to tests (default: '.')
- `coverage` - Collect coverage (default: false)
- `coverage-format` - Format: json, lcov, html (default: 'json')
- `coverage-threshold` - Minimum coverage % (default: 0)
- `upload-coverage` - Upload as artifact (default: false)

**Outputs:**

- `tests-passed`, `tests-failed`, `tests-total`
- `coverage-percent`
- `passed` - Whether all tests passed

---

### reusable-test-node-custom.yml

Node.js testing via a caller-provided shell command (after dependency install).
Use when Vitest is not the test runner or when a package script owns coverage.

```yaml
jobs:
  web-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node-custom.yml@main
    with:
      job-name: "Web Coverage"
      test-command: bun run test:coverage
      package-manager: bun
      coverage: true
      coverage-pr-comment: true
```

**Inputs:**

- `test-command` - **Required.** Shell command run in `working-directory`
- `job-name` - GitHub check name (default: `Node.js Tests`)
- `node-version`, `node-versions`, `package-manager`, `pre-test-command`
- Pages coverage HTML inputs (same as Vitest workflow)

**Outputs:**

- `passed` - Whether the custom command succeeded
- `pages-coverage-artifact-name`, `pages-coverage-uploaded`

---

### reusable-required-check.yml

Org ruleset gate: asserts an upstream reusable job succeeded (and optional
outputs) under a caller-controlled `job-name`. Replaces consumer-local shim
`runs-on` jobs. See `docs/workflow-contract.md` (Org ruleset check names).

```yaml
lintro-code-quality:
  needs: dogfooding-lint
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@main
  permissions:
    contents: read
  with:
    job-name: "🛠️ Lintro Code Quality"
    upstream-result: ${{ needs.dogfooding-lint.result }}
    status-output: ${{ needs.dogfooding-lint.outputs.status }}
```

**Inputs:**

- `job-name` - **Required.** GitHub check name for this gate
- `upstream-result` - **Required.** Upstream `needs.*.result`
- `passed-output` - When set, must be the string `true`
- `status-output` / `status-expected` - Optional status string gate (default
  expected `passed`)
- `draft-pr-skip` - Skip gate on draft PRs (default: false)
- `tooling-ref`, `egress-policy`, `allowed-endpoints`, `runner-image`,
  `timeout-minutes`

**Outputs:**

- `exit-code` - `0` or `1`
- `status` - `passed` or `failed`

---

### reusable-test-e2e.yml

E2E testing workflow with Playwright.

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@main
    with:
      browsers: "chromium"
      shard: "1/3" # optional, for parallel execution
      reporter: "html"
      upload-report: true
      publish-results: true
```

**Inputs:**

- `node-version` - Node.js version (default: '20')
- `project` - Playwright project (default: '')
- `browsers` - Browsers: chromium, firefox, webkit, all (default: 'chromium')
- `shard` - Shard configuration, e.g., "1/3" (default: '')
- `reporter` - Reporter: json, html, junit (default: 'html')
- `upload-report` - Upload report as artifact (default: true)
- `publish-results` - Publish to GitHub Pages (default: false)

**Outputs:**

- `tests-passed`, `tests-failed`
- `report-url` - URL to test report (if published)

---

### reusable-test-e2e-matrix.yml

Matrix-based E2E testing workflow with tag filtering and sharding.

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-matrix.yml@main
    with:
      test-suites: "smoke,visual,a11y"
      browsers: "chromium"
      tag-prefix: "@"
      shards: 1
      reporter: "html"
      publish-results: true
```

**Inputs:**

- `node-version` - Node.js version (default: '20')
- `test-suites` - Comma-separated suites (default: 'smoke')
- `browsers` - Comma-separated browsers (default: 'chromium')
- `tag-prefix` - Tag prefix for filtering (default: '@')
- `shards` - Number of shards per suite (default: 1)
- `reporter` - Reporter: json, html, blob (default: 'html')
- `upload-report` - Upload reports as artifacts (default: true)
- `publish-results` - Publish to GitHub Pages (default: false)
- `timeout-minutes` - Timeout per job (default: 30)

**Outputs:**

- `total-passed`, `total-failed` - Aggregated test counts
- `report-url` - URL to merged report (if published)

**Features:**

- Matrix strategy for parallel test execution
- Tag-based filtering (@smoke, @visual, @a11y)
- Browser caching for faster runs
- Automatic report merging from matrix jobs

---

### reusable-deploy-pages.yml

Deploy static content to GitHub Pages with OIDC authentication.

```yaml
jobs:
  deploy:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-pages.yml@main
    with:
      source-path: "dist"
      build-command: "bun run build"
      environment: "github-pages"
```

**Inputs:**

- `source-path` - Path to static content (default: 'dist')
- `build-command` - Optional build command
- `node-version` - Node.js version for build (default: '20')
- `environment` - GitHub environment name (default: 'github-pages')
- `artifact-name` - Pages artifact name (default: 'github-pages')

**Outputs:**

- `page-url` - URL of the deployed site

**Features:**

- Two-job workflow (build + deploy) for proper separation
- OIDC authentication (no secrets required)
- Configurable GitHub environment for deployment protection
- Concurrency control to prevent parallel deployments

**Permissions Required:**

- `pages: write` - For GitHub Pages deployment
- `id-token: write` - For OIDC authentication

---

### reusable-deploy-site-with-reports.yml

Build a static site, bundle HTML report artifacts from other workflows via a
manifest, and deploy once to GitHub Pages (Model B).

```yaml
jobs:
  deploy:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-site-with-reports.yml@main
    permissions:
      contents: read
      pages: write
      id-token: write
      actions: read
    with:
      site-root: apps/site/dist
      build-command: bun run build
      package-manager: bun
      bundle-manifest: examples/bundle-manifest-turbo-themes.json
      commit-sha: ${{ github.event.workflow_run.head_sha }}
      fallback-ref: main
```

**Inputs:**

- `site-root` - Deploy root (default: `dist`)
- `build-command` - Optional site build command
- `bundle-manifest` - Inline JSON or path to manifest in caller repo
- `bundle-after-build` - Run bundle after build (default: `true`)
- `commit-sha` - SHA for checkout and artifact resolution (default: `github.sha`)
- `fallback-ref` - Optional branch for fallback artifact lookup (default: strict)
- `strict-bundle` - Fail when any manifest entry is missing (default: `false`)
- `node-version`, `package-manager`, `working-directory`, `frozen-lockfile` -
  Same as `reusable-deploy-pages`
- `tooling-ref`, `egress-policy`, `allowed-endpoints`, `runner-image`,
  `timeout-minutes`, `artifact-name`, `environment` - Standard contract

**Outputs:**

- `page-url` - URL of the deployed site

**Features:**

- Manifest-driven cross-workflow artifact download (no repo-local API scripts)
- Optional `main` (or other branch) fallback per caller configuration
- Two-job workflow (build + deploy) with official OIDC Pages actions
- Shared `pages-${{ github.repository }}-${{ github.ref }}` concurrency

**Permissions Required (caller):**

- `contents: read` - Checkout repository
- `pages: write` - GitHub Pages deployment
- `id-token: write` - OIDC authentication
- `actions: read` - Download artifacts from other workflow runs (build job)

See [pages-publishing.md](../../docs/pages-publishing.md) for Model A vs B.

---

### reusable-docker.yml

Build and push Docker images with multi-platform support and attestations.

Caller repos only need to pin this workflow — **no vendored `scripts/ci`
tree is required**. The workflow sparse-checks the shared shell scripts
from lgtm-ci via a cross-repo checkout (same pattern as
`reusable-release-auto-tag.yml`), but composite actions are not resolved
from `.lgtm-ci-tooling`. The `docker-login` and `docker-metadata` logic is
inlined in this workflow instead.

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
      # Trivial smoke check (mutually exclusive with smoke-test-script)
      smoke-test: "--version"
      # Or escape hatch for flag/env/network needs:
      # smoke-test-script: "scripts/ci/smoke.sh"
```

**Inputs:**

- `context` - Build context path (default: '.')
- `file` - Dockerfile path (default: 'Dockerfile')
- `platforms` - Target platforms (default: 'linux/amd64,linux/arm64')
- `registry` - Registry: ghcr.io or docker.io (default: 'ghcr.io')
- `image-name` - Image name (default: github.repository)
- `version` - Version for semver tags
- `push` - Push to registry (default: false)
- `provenance` - Generate provenance attestation (default: true)
- `sbom` - Generate SBOM attestation (default: true)
- `scan` - Run vulnerability scan (default: false)
- `runner-map` - JSON object mapping platform → runner label. Platforms not
  in the map default to `ubuntu-24.04` with QEMU. Example:
  `{"linux/arm64":"ubuntu-24.04-arm"}` (default: `{}`)
- `smoke-test` - Shorthand command + args run inside each per-platform
  staging image as `docker run --rm --platform <p> <image> <smoke-test>`.
  Word-split; values with spaces or shell metacharacters need
  `smoke-test-script`. Mutually exclusive with `smoke-test-script`. Only
  applies to the split per-platform push path (default: '')
- `smoke-test-script` - Path (relative to checkout root) to a caller-owned
  script run on the runner with env `IMAGE`, `PLATFORM`, `REGISTRY`. Script
  owns the `docker run` invocation — full control over flags, env, network,
  tmpfs, etc. Mutually exclusive with `smoke-test` (default: '')
- `tooling-ref` - Git ref for the lgtm-ci tooling checkout. Defaults to the
  reusable workflow commit (the workflow's own pinned commit). Override to pin
  a specific tag or SHA (default: '')

**Outputs:**

- `tags` - Generated image tags
- `digest` - Image digest

**Features:**

- Multi-platform builds with QEMU or split native-runner per-platform builds
- Cross-repo tooling checkout — caller repos stay thin, no vendored scripts
- docker/metadata-action for intelligent tag generation
- GitHub Actions cache for layer caching
- Provenance and SBOM attestations
- Optional Trivy vulnerability scanning with SARIF upload
- Optional per-platform smoke-test gate — any failing platform blocks the
  manifest merge, so partial multi-arch manifests are never published

**Per-platform smoke tests:**

When `push` is true and two or more platforms are requested, the workflow
splits into per-platform native (or QEMU) build legs, then merges a
multi-arch manifest. Set `smoke-test` or `smoke-test-script` to gate the
merge on a per-platform health check against the freshly pushed staging
image. `smoke-test` is a convenience for trivial checks like `--version`;
reach for `smoke-test-script` when you need `-e`, `--network`, `--read-only`,
or any other `docker run` flag. Validation is performed in the `classify`
job, so setting both fails fast before any build runs.

**Migration from vendored scripts:**

If your caller repo previously vendored `scripts/ci/actions/build-docker.sh`,
`scripts/ci/lib/**`, or `.github/actions/docker-login` / `docker-metadata`,
you can safely delete those copies after updating the workflow pin. The
workflow now resolves all tooling from the lgtm-ci checkout.

**Permissions Required:**

- `packages: write` - For pushing to GHCR
- `id-token: write` - For provenance attestation
- `attestations: write` - For build attestations
- `security-events: write` - For vulnerability scan results (if enabled)

**Secrets:**

- `DOCKERHUB_USERNAME` - Docker Hub username (for docker.io registry)
- `DOCKERHUB_TOKEN` - Docker Hub token (for docker.io registry)

---

### reusable-coverage.yml

Unified coverage collection and publishing workflow.

```yaml
jobs:
  coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@main
    with:
      threshold: 80
      generate-badge: true
      publish-pages: true
```

**Inputs:**

- `coverage-files` - Glob or list of coverage files (default: auto-detect)
- `format` - Format: auto, istanbul, coverage-py, lcov (default: 'auto')
- `threshold` - Minimum coverage % (default: 0)
- `generate-badge` - Generate coverage badge (default: true)
- `publish-pages` - Publish to GitHub Pages (default: false)

**Outputs:**

- `coverage-percent` - Overall coverage percentage
- `badge-url` - URL to coverage badge
- `pages-url` - GitHub Pages URL
- `passed` - Whether coverage meets threshold

**Permissions Required (publish job):**

- `contents: read`
- `pages: write`
- `id-token: write`

---

### reusable-build-python-dist.yml

Build Python distribution and upload a workflow artifact. Pair with a caller job
using `prepare-pypi-upload` and caller-level `pypa/gh-action-pypi-publish`. See
[docs/python-release-publish.md](../../docs/python-release-publish.md).

**Outputs:** `version`, `package-name`

---

### reusable-github-release.yml

Download a workflow artifact and create a GitHub Release with attached assets
via `gh release create` (`scripts/ci/release/create-github-release.sh`).

```yaml
jobs:
  github-release:
    needs: publish
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@main
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      generate-release-notes: true
```

**Outputs:** `release-url`, `release-id`

**Permissions Required:**

- `contents: write` - Create release and upload assets

---

### reusable-publish-npm.yml

Publish Node.js packages to npm with provenance attestation.

```yaml
jobs:
  publish:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm.yml@main
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
    with:
      node-version: "22"
      dist-tag: "latest"
      provenance: true
      access: "public"
      dry-run: false
```

**Inputs:**

- `node-version` - Node.js version (default: '22')
- `dist-tag` - npm dist-tag (default: 'latest')
- `provenance` - Enable npm provenance attestation (default: true)
- `access` - Package access level (default: 'public')
- `dry-run` - Build only, do not publish (default: false)
- `working-directory` - Working directory containing the package (default: '.')

**Outputs:**

- `published` - Whether the package was published
- `version` - Published package version
- `package-name` - Published package name
- `tarball` - Path to the built tarball

**Permissions Required:**

- `contents: read` - For checkout
- `id-token: write` - For provenance attestation
- `attestations: write` - For build provenance

**Note:** Must run on GitHub-hosted runners for npm provenance to work.

---

### reusable-publish-gem.yml

Publish Ruby gems to RubyGems using OIDC trusted publishing.

```yaml
jobs:
  publish:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-gem.yml@main
    with:
      ruby-version: "3.3"
      dry-run: false
```

**Inputs:**

- `ruby-version` - Ruby version (default: '3.3')
- `gemspec` - Path to gemspec file (auto-detected if not specified)
- `dry-run` - Build only, do not publish (default: false)
- `working-directory` - Working directory containing the gem (default: '.')

**Outputs:**

- `published` - Whether the gem was published
- `version` - Published gem version
- `gem-name` - Published gem name
- `gem-file` - Path to the built gem file

**Permissions Required:**

- `contents: read` - For checkout
- `id-token: write` - For OIDC authentication

---

### reusable-publish-homebrew.yml

Update Homebrew formula with new version from PyPI.

```yaml
jobs:
  homebrew:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-homebrew.yml@main
    with:
      tap-repository: "owner/homebrew-tap"
      formula: "mypackage"
      package-name: "my-pypi-package"
      version: "1.2.3"
      wait-for-availability: true
      create-pr: false
```

**Inputs:**

- `tap-repository` - Homebrew tap repository (owner/repo) - required
- `formula` - Formula name - required
- `package-name` - PyPI package name - required
- `version` - Version to update to - required
- `wait-for-availability` - Wait for package on PyPI (default: true)
- `max-wait-minutes` - Maximum wait time in minutes (default: 10)
- `test-pypi` - Use TestPyPI instead of PyPI (default: false)
- `create-pr` - Create PR instead of direct push (default: false)

**Outputs:**

- `updated` - Whether the formula was updated
- `commit-sha` - Commit SHA of the update
- `pr-url` - Pull request URL (if create-pr is true)

**Permissions Required:**

- `contents: write` - For pushing to tap repository

---

## Pinning Versions

For production workflows, pin to a specific commit SHA:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@abc1234
```

Or use a release tag when available:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@v1
```
