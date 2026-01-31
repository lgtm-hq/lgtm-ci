# Composite Actions

Reusable GitHub Actions for consistent CI/CD setup across repositories.

## Available Actions

### setup-env

Configure common CI environment variables and PATH.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main
  with:
    bin-dir: '${{ github.workspace }}/.local/bin' # optional
    add-to-path: '/custom/path1, /custom/path2' # optional
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
    python-version: '3.12' # optional, default: 3.12
    uv-version: 'latest' # optional
    cache: 'true' # optional, default: true
    install-dependencies: 'true' # optional, default: true
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
    node-version: '22' # optional, default: 22
    bun-version: 'latest' # optional
    cache: 'true' # optional, default: true
    install-dependencies: 'true' # optional, default: true
    frozen-lockfile: 'true' # optional, default: true
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
    toolchain: 'stable' # optional, default: stable
    components: 'clippy, rustfmt' # optional
    targets: 'wasm32-unknown-unknown' # optional
    cache: 'true' # optional, default: true
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

### harden-runner

Security hardening using [StepSecurity](https://stepsecurity.io).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/harden-runner@main
  with:
    egress-policy: 'audit' # or 'block' to enforce allowlist
    disable-sudo: 'false' # optional
```

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
    persist-credentials: 'false' # default: false (secure)
    fetch-depth: '1' # default: 1 (shallow clone)
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
    mode: 'audit' # 'audit', 'report', or 'block'
    report-format: 'summary' # 'summary', 'json', or 'none'
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
    target: '.' # optional, default: current directory
    target-type: 'dir' # 'dir', 'image', or 'file'
    format: 'cyclonedx-json' # see supported formats below
    upload-artifact: 'true' # optional
    artifact-name: 'sbom' # optional
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
    target: 'sbom.cdx.json' # SBOM file, image, or directory
    target-type: 'sbom' # 'sbom', 'image', or 'dir'
    fail-on: 'high' # 'critical', 'high', 'medium', 'low', or ''
    upload-sarif: 'true' # upload to GitHub Security tab
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
    subject-path: 'dist/myapp.tar.gz' # artifact to attest
    subject-name: 'myapp' # optional
    push-to-registry: 'false' # push to container registry
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
    target: 'dist/myapp.tar.gz' # file or image to verify
    target-type: 'file' # 'file' or 'image'
    owner: 'my-org' # optional, defaults to repository owner
```

**Outputs:**

- `verified` - Whether the attestation was verified successfully
- `signer-identity` - Identity of the signer

---

## PR & Comment Actions

### post-pr-comment

Create or update PR comments with upsert behavior using unique markers.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/post-pr-comment@main
  with:
    marker: 'lighthouse-results' # unique identifier for this comment
    body: |
      ## Results
      Your content here...
    mode: 'upsert' # 'upsert', 'create', or 'update'
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
    types: 'feat,fix,docs,chore' # optional, allowed types
    require-scope: 'false' # optional
    max-length: '72' # optional
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

### generate-lighthouse-comment

Generate formatted PR comment from Lighthouse CI results.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-lighthouse-comment@main
  with:
    results-path: 'lighthouse-results/'
    report-url: 'https://example.github.io/lighthouse/'
    threshold-performance: '80'
```

**Features:**

- Parses Lighthouse JSON results
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
    results-path: 'playwright-report/results.json'
    report-url: 'https://example.github.io/playwright/'
    show-failed-tests: 'true'
```

**Features:**

- Parses Playwright JSON results
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
    coverage-file: 'coverage/coverage-summary.json'
    format: 'auto' # 'istanbul', 'coverage-py', or 'auto'
    threshold-lines: '80'
    threshold-branches: '70'
```

**Features:**

- Supports Istanbul (JS) and coverage.py (Python) formats
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
    runner: 'auto' # 'pytest', 'vitest', 'playwright', or 'auto'
    coverage: 'true' # optional
    coverage-format: 'json' # 'xml', 'json', 'lcov'
    extra-args: '' # additional runner arguments
    working-directory: '.' # optional
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
    python-version: '3.12' # optional
    test-path: 'tests' # optional
    coverage: 'true' # optional
    coverage-format: 'json' # 'xml', 'json', 'lcov'
    markers: 'not slow' # optional, pytest markers
    extra-args: '-v' # optional
    working-directory: '.' # optional
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
    node-version: '20' # optional
    test-path: '.' # optional
    coverage: 'true' # optional
    coverage-format: 'json' # 'json', 'lcov', 'html'
    extra-args: '' # optional
    working-directory: '.' # optional
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
    node-version: '20' # optional
    project: '' # optional, Playwright project
    browser: 'chromium' # 'chromium', 'firefox', 'webkit', 'all'
    reporter: 'html' # 'json', 'html', 'junit'
    shard: '1/3' # optional, for parallel execution
    extra-args: '' # optional
    working-directory: '.' # optional
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

### collect-coverage

Aggregate coverage from multiple sources and formats.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/collect-coverage@main
  with:
    coverage-files: 'coverage/*.json' # glob or comma-separated
    input-format: 'auto' # 'auto', 'istanbul', 'coverage-py', 'lcov'
    output-format: 'json' # 'json', 'lcov'
    merge-strategy: 'union' # 'union', 'intersection'
    working-directory: '.' # optional
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

### generate-coverage-badge

Generate coverage badge SVG/JSON for README display.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-coverage-badge@main
  with:
    coverage-file: 'coverage.json' # or use coverage-percent
    coverage-percent: '85.5' # if not extracting from file
    format: 'svg' # 'svg', 'json', 'shields'
    output-path: 'badge.svg' # optional
    label: 'coverage' # optional
    thresholds: '50,80' # red,yellow boundaries
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

Publish test results and coverage to GitHub Pages.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/publish-test-results@main
  with:
    results-path: 'test-results/' # optional
    coverage-path: 'coverage/' # optional
    badge-path: 'coverage/badge.svg' # optional
    target-branch: 'gh-pages' # optional
    target-dir: '.' # optional
    keep-history: 'false' # optional
```

**Outputs:**

- `pages-url` - GitHub Pages URL

**Features:**

- Deploys to gh-pages branch
- Optional historical report retention
- Generates index.html for coverage reports

**Required Permissions:**

- `contents: write` - For gh-pages deployment
- `pages: write` - For GitHub Pages

---

## Quality Actions

### run-quality

Run lintro quality checks with optional actionlint validation.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/run-quality@main
  with:
    tools: '' # optional, comma-separated list (empty = all)
    mode: 'check' # 'check' or 'format'
    fail-on-error: 'true' # optional
    run-actionlint: 'true' # optional, run actionlint on GitHub Actions
    working-directory: '.' # optional, working directory for linting
```

**Inputs:**

- `tools` - Comma-separated list of lintro tools to run (empty = all)
- `mode` - Mode: 'check' (lint only) or 'format' (auto-fix)
- `fail-on-error` - Fail workflow if linting errors found (default: true)
- `run-actionlint` - Run actionlint validation on GitHub Actions (default: true)
- `working-directory` - Working directory for linting (default: '.')

**Features:**

- Runs all configured lintro tools (shellcheck, shfmt, prettier, yamllint, etc.)
- Optional actionlint validation for GitHub Actions workflows
- Support for check mode (lint only) or format mode (auto-fix)
- Configurable tool selection
- Respects fail-on-error for both lintro and actionlint

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
    max-bump: 'minor' # optional, clamp max bump type
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
    version: '1.2.0' # optional
    format: 'full' # full, simple, or with-type
```

**Outputs:**

- `changelog` - Generated changelog content (Markdown)

---

### create-release-tag

Create an annotated git tag for release.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-release-tag@main
  with:
    version: '1.2.0'
    push: 'true' # push tag to origin
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
    tag: 'v1.2.0'
    draft: 'false'
    prerelease: 'false'
    files: 'dist/*.tar.gz dist/*.whl' # optional
```

**Outputs:**

- `release-url` - URL of the created release
- `release-id` - ID of the created release

---

## Usage Example

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
      # Security hardening (should be first)
      - uses: lgtm-hq/lgtm-ci/.github/actions/harden-runner@main
        with:
          egress-policy: audit

      # Secure checkout (replaces actions/checkout)
      - uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@main

      # Environment setup
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@main
        with:
          python-version: '3.12'

      - name: Run tests
        run: uv run pytest
```

## Reusable Workflows

Reusable workflows provide complete CI/CD pipelines that can be called from other
workflows.

### reusable-test-python.yml

Complete Python testing workflow with pytest and optional coverage.

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@main
    with:
      python-version: '3.12'
      test-path: 'tests'
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
      publish-results: false
```

**Inputs:**

- `python-version` - Python version (default: '3.12')
- `test-path` - Path to tests (default: 'tests')
- `coverage` - Collect coverage (default: false)
- `coverage-format` - Format: xml, json, lcov (default: 'json')
- `coverage-threshold` - Minimum coverage % (default: 0)
- `upload-coverage` - Upload as artifact (default: false)
- `publish-results` - Publish to GitHub Pages (default: false)

**Outputs:**

- `tests-passed`, `tests-failed`, `tests-total`
- `coverage-percent`
- `passed` - Whether all tests passed

---

### reusable-test-node.yml

Complete Node.js testing workflow with vitest and optional coverage.

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@main
    with:
      node-version: '20'
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
```

**Inputs:**

- `node-version` - Node.js version (default: '20')
- `test-path` - Path to tests (default: '.')
- `coverage` - Collect coverage (default: false)
- `coverage-format` - Format: json, lcov, html (default: 'json')
- `coverage-threshold` - Minimum coverage % (default: 0)
- `upload-coverage` - Upload as artifact (default: false)
- `publish-results` - Publish to GitHub Pages (default: false)

**Outputs:**

- `tests-passed`, `tests-failed`, `tests-total`
- `coverage-percent`
- `passed` - Whether all tests passed

---

### reusable-test-e2e.yml

E2E testing workflow with Playwright.

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@main
    with:
      browsers: 'chromium'
      shard: '1/3' # optional, for parallel execution
      reporter: 'html'
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

**Permissions Required:**

- `contents: write` - For gh-pages deployment
- `pages: write` - For GitHub Pages
- `id-token: write` - For pages deployment

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
