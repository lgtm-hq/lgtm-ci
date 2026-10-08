<!-- Generated from catalog/catalog.yml; do not edit. Regenerate with:
     python3 scripts/ci/catalog/render.py --write -->
<!-- markdownlint-disable MD013 -- generated tables and long list items -->

# Support catalog

Every public reusable workflow and composite action, with its support tier,
the evidence behind the tier, the caller permissions it needs, and what it
does not do.
`stable` means a green run from the external fixture [`TurboCoder13/lgtm-ci-consumer-fixture`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture),
which calls lgtm-ci from outside the org at an exact commit with no
`tooling-ref`.

## Tiers

| Tier | Meaning |
| ---- | ------- |
| `stable` | Green from the external consumer fixture at a commit on `main`; the run is linked. Inputs, outputs, permissions and check names change only with a documented migration. |
| `preview` | Shipped and maintained, but not yet proven from outside the org (or only partly). May change without a migration path. |
| `internal` | Exists for lgtm-ci's own workflows or lgtm-hq infrastructure. Not supported for other callers. |
| `deprecated` | Kept as a migration shim with a warning; use the named replacement. Removed only once every known consumer has migrated ([governance](governance.md#deprecation-lifecycle)). |

Permissions are the block the **calling job** must grant. For a reusable
workflow it is the union GitHub validates before any job runs (see
[Caller snippets and permissions](README.md#caller-snippets-and-permissions))
and the validator requires the catalog to equal it. For a composite action it
is maintained by hand; only the scopes the permissions validator derives
(`detect-changes`) are machine-checked.

Check names are the callee job names, which GitHub shows as
`<caller job> / <name>` with matrix values appended. A job that calls a
nested reusable is listed as `<job> / <nested job>`; when that job is skipped
by its `if:`, GitHub reports a single check named `<caller job> / <job>`.

Evidence names the lgtm-ci commit the fixture run was pinned to. The
validator requires that commit to be on lgtm-ci's `main` and in the history
of the commit being checked; the fixture branch the run happened on does not
matter. Evidence is a point-in-time claim: when an entry's file changes after
its evidence commit, the validator prints a notice until the run is refreshed.

Pin an exact release commit SHA with a `# vX.Y.Z` comment; floating refs and
the deprecation and removal rules are in [docs/governance.md](governance.md).

## Summary

| Kind | `stable` | `preview` | `internal` | `deprecated` | Total |
| ---- | ---- | ---- | ---- | ---- | ---- |
| Reusable workflows | 9 | 48 | 7 | 1 | 65 |
| Composite actions | 4 | 43 | 3 | 0 | 50 |

## Reusable workflows

| Entry | Tier | Summary |
| ----- | ---- | ------- |
| [`reusable-coverage`](#reusable-coverage) | `stable` | Coverage Workflow |
| [`reusable-release-version-pr`](#reusable-release-version-pr) | `stable` | Release Version PR |
| [`reusable-rust-test`](#reusable-rust-test) | `stable` | Rust Test Workflow |
| [`reusable-sbom-release-upload`](#reusable-sbom-release-upload) | `stable` | SBOM Release Upload |
| [`reusable-test-e2e-playwright`](#reusable-test-e2e-playwright) | `stable` | Playwright E2E Test Workflow |
| [`reusable-test-node`](#reusable-test-node) | `stable` | Node.js Vitest Test Workflow |
| [`reusable-test-node-run`](#reusable-test-node-run) | `stable` | Node.js Vitest Test Workflow (read-only) |
| [`reusable-test-python`](#reusable-test-python) | `stable` | Python Test Workflow |
| [`reusable-test-shell-run`](#reusable-test-shell-run) | `stable` | Shell Test Workflow (read-only) |
| [`reusable-auto-rerun-on-infra-failure`](#reusable-auto-rerun-on-infra-failure) | `preview` | Auto Re-run on Infra Failure |
| [`reusable-build-artifact`](#reusable-build-artifact) | `preview` | Build Artifact Workflow |
| [`reusable-build-python-dist`](#reusable-build-python-dist) | `preview` | Python Distribution Build Workflow |
| [`reusable-build-rust-binaries`](#reusable-build-rust-binaries) | `preview` | Rust Binary Build Workflow |
| [`reusable-codeql`](#reusable-codeql) | `preview` | CodeQL |
| [`reusable-dependency-review`](#reusable-dependency-review) | `preview` | Dependency Review |
| [`reusable-deploy-pages`](#reusable-deploy-pages) | `preview` | Deploy to GitHub Pages |
| [`reusable-deploy-site-with-reports`](#reusable-deploy-site-with-reports) | `preview` | Deploy Site With Reports Workflow |
| [`reusable-docker`](#reusable-docker) | `preview` | Docker Build and Push |
| [`reusable-docker-build`](#reusable-docker-build) | `preview` | Docker Build (single-platform) |
| [`reusable-docker-multiplatform`](#reusable-docker-multiplatform) | `preview` | Docker Build (multi-platform) |
| [`reusable-docker-smoke-test`](#reusable-docker-smoke-test) | `preview` | Docker Smoke Test |
| [`reusable-github-release`](#reusable-github-release) | `preview` | GitHub Release Workflow |
| [`reusable-link-check`](#reusable-link-check) | `preview` | Link Check |
| [`reusable-pr-auto-assign`](#reusable-pr-auto-assign) | `preview` | PR Auto Assign |
| [`reusable-pr-labeler`](#reusable-pr-labeler) | `preview` | PR Auto Label |
| [`reusable-publish-artifact-preview`](#reusable-publish-artifact-preview) | `preview` | Publish Artifact Preview Workflow |
| [`reusable-publish-artifact-report`](#reusable-publish-artifact-report) | `preview` | Publish Artifact Report Workflow |
| [`reusable-publish-file-breakdown`](#reusable-publish-file-breakdown) | `preview` | Publish File Breakdown Workflow |
| [`reusable-publish-gem`](#reusable-publish-gem) | `preview` | RubyGems Publishing Workflow |
| [`reusable-publish-npm-set`](#reusable-publish-npm-set) | `preview` | npm Package-Set Publishing |
| [`reusable-publish-quality-summary`](#reusable-publish-quality-summary) | `preview` | Publish Quality Summary Workflow |
| [`reusable-publish-rust-release`](#reusable-publish-rust-release) | `preview` | Rust Release Publish Workflow |
| [`reusable-publish-security-audit-comment`](#reusable-publish-security-audit-comment) | `preview` | Publish Security Audit Comment Workflow |
| [`reusable-publish-test-results-pages`](#reusable-publish-test-results-pages) | `preview` | Publish Test Results To Pages |
| [`reusable-publish-test-summary`](#reusable-publish-test-summary) | `preview` | Publish Test Summary Workflow |
| [`reusable-quality-lint`](#reusable-quality-lint) | `preview` | Quality Lint Workflow |
| [`reusable-release-auto-tag`](#reusable-release-auto-tag) | `preview` | Release Auto Tag |
| [`reusable-release-multi-ecosystem`](#reusable-release-multi-ecosystem) | `preview` | Release Multi-Ecosystem Version PR |
| [`reusable-release-recover`](#reusable-release-recover) | `preview` | Release Recovery |
| [`reusable-required-check`](#reusable-required-check) | `preview` | Required Check Gate |
| [`reusable-rust-build`](#reusable-rust-build) | `preview` | Rust Build Workflow |
| [`reusable-rust-test-run`](#reusable-rust-test-run) | `preview` | Rust Test Workflow (read-only) |
| [`reusable-sbom`](#reusable-sbom) | `preview` | SBOM Workflow |
| [`reusable-scorecards`](#reusable-scorecards) | `preview` | OpenSSF Scorecard |
| [`reusable-security-audit`](#reusable-security-audit) | `preview` | Security Audit Workflow |
| [`reusable-semantic-pr-title`](#reusable-semantic-pr-title) | `preview` | Semantic PR Title |
| [`reusable-site-quality`](#reusable-site-quality) | `preview` | Documentation Site Quality Workflow |
| [`reusable-test-e2e`](#reusable-test-e2e) | `preview` | E2E Test Workflow |
| [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix) | `preview` | E2E Matrix Test Workflow |
| [`reusable-test-node-custom`](#reusable-test-node-custom) | `preview` | Node.js Custom Test Workflow |
| [`reusable-test-node-publish`](#reusable-test-node-publish) | `preview` | Node.js Test Publish Workflow |
| [`reusable-test-python-publish`](#reusable-test-python-publish) | `preview` | Python Test Publish Workflow |
| [`reusable-test-rust-build`](#reusable-test-rust-build) | `preview` | Rust Build Only Workflow |
| [`reusable-test-shell`](#reusable-test-shell) | `preview` | Shell Test Workflow |
| [`reusable-validate`](#reusable-validate) | `preview` | Validation Script |
| [`reusable-validate-action-pinning`](#reusable-validate-action-pinning) | `preview` | Validate Action Pinning |
| [`reusable-vuln-suppression-check`](#reusable-vuln-suppression-check) | `preview` | Vulnerability Suppression Check Workflow |
| [`reusable-ai-review`](#reusable-ai-review) | `internal` | AI Review |
| [`reusable-ghcr-cleanup`](#reusable-ghcr-cleanup) | `internal` | GHCR Cleanup |
| [`reusable-main-failure-notifier`](#reusable-main-failure-notifier) | `internal` | Main Failure Notifier |
| [`reusable-prune-build-staging-tags`](#reusable-prune-build-staging-tags) | `internal` | Prune Build Staging Tags |
| [`reusable-registry-health-check`](#reusable-registry-health-check) | `internal` | Registry Health Check |
| [`reusable-release-failure-notifier`](#reusable-release-failure-notifier) | `internal` | Release Failure Notifier |
| [`reusable-validate-lintro-version`](#reusable-validate-lintro-version) | `internal` | Validate Lintro Version |
| [`reusable-publish-npm`](#reusable-publish-npm) | `deprecated` | npm Publishing Workflow (deprecated) |

### Reusable workflows: stable

#### `reusable-coverage`

Coverage Workflow

- **Path:** [`.github/workflows/reusable-coverage.yml`](../.github/workflows/reusable-coverage.yml)
- **Tier:** stable
- **Evidence:** [`coverage-lcov.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770062463) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Coverage`, `Publish test summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) in artifact `<coverage-artifact-name>-results`
- **Deprecated:** [output `pages-url`](#deprecation-coverage-pages-url), [input `publish-pages`](#deprecation-coverage-publish-pages), [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- Upload coverage as workflow artifacts in the same run before calling; the default `coverage-files` pattern matches the fixture's `node-lcov-coverage` artifact

**Limitations:**

- Line-only LCOV is kept as LCOV and branches/functions render `n/a`; an output format no converter implements fails with `unsupported coverage conversion` instead of passing silently (#1078)
- `publish-pages` and badge generation are untested from the fixture
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-release-version-pr`

Release Version PR

- **Path:** [`.github/workflows/reusable-release-version-pr.yml`](../.github/workflows/reusable-release-version-pr.yml)
- **Tier:** stable
- **Evidence:** [`release-version-pr.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37756143865) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `ea934b16`
- **Permissions:** `actions: read`, `contents: write`, `issues: write`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Prepare version update hook`, `Run version update hook`, `Create Version PR`, `Report release automation failure`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- A GitHub App installed on the caller repository only, with Contents, Pull requests, Issues and Workflows read & write; forward `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY` explicitly (no `secrets: inherit`). The minted token is scoped to the caller repository (#849, fixture `app-token-probe.yml`)
- A baseline version tag; the bump is computed from conventional commits after it
- `CHANGELOG.md` is created with a Keep a Changelog header when absent (#1092); the PyPI hosts the python updater needs are part of the job's allowlist (#1093)
- A `version-update-script` runs in its own job with no token and a read-only tooling checkout; its edits reach the version PR through a scope-checked diff artifact (#849)

**Limitations:**

- Proven with `ecosystems: python` only; the other ecosystems have no fixture run
- Stable covers calls without `version-update-script`. The hook path FAILS at `ea934b16` (fixture `release-benign-hook.yml`, run 37756136378): the hook job's `git add` exits 1 when the consumer's `.gitignore` lists `.lgtm-ci-tooling`. It was last green at the #1097 head `2339aa8a`
- `uv` is absent on ubuntu-24.04, so `uv.lock` is rewritten by the tomlkit fallback (`[WARN] uv not found`)
- Skips when a version PR is already open; close it before dispatching again
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-rust-test`

Rust Test Workflow

- **Path:** [`.github/workflows/reusable-rust-test.yml`](../.github/workflows/reusable-rust-test.yml)
- **Tier:** stable
- **Evidence:** [`rust.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770062859) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `actions: read`, `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `cargo`
- **Check names:** `Prepare Rust Matrix`, `Rust Tests`, `Aggregate Rust Results`, `publish-test-summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) per leg in artifact `<prefix>-results-<rust-toolchain>`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- `actions: read` is required by the aggregate job's artifact-availability wait (#803)
- Ship `.config/nextest.toml` with a `ci` profile writing JUnit to `junit.xml` (path relative to nextest's store dir); without it nextest fails with `profile 'ci' not found`. Starter: `examples/nextest-ci.toml` (#1086)
- cargo-nextest and cargo-llvm-cov are installed from releases verified against committed sha256 digests (#1096)
- Egress is enforced in block mode; hosts outside the selected `egress-preset` go in `allowed-endpoints` with `allowed-endpoints-mode: append` (#913, fixture `egress.yml`)
- Sibling calls in one run need distinct `artifact-prefix` values (#1091, fixture `siblings.yml`)
- Callers that do not need the PR comment can call `reusable-rust-test-run` instead and grant read scopes only (#1081)

**Limitations:**

- No bundled fallback nextest profile: a consumer without `.config/nextest.toml` fails (#1086 item 3 not done)
- Fixture proves both `coverage: false` and `coverage: true` calls; Pages coverage upload is untested
- A cached `~/.cargo/bin` at the pinned version is reused without re-verifying its digest; the cache is scoped to the consumer repository and ref (#1096)
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-sbom-release-upload`

SBOM Release Upload

- **Path:** [`.github/workflows/reusable-sbom-release-upload.yml`](../.github/workflows/reusable-sbom-release-upload.yml)
- **Tier:** stable
- **Evidence:** [`sbom-release-upload.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37756163922) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `ea934b16`
- **Permissions:** `contents: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Upload SBOM release assets`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- The release for `release-tag` exists and the run carries the SBOM artifact named `artifact-name` (the shape `reusable-sbom.yml` leaves in `release-assets` mode)

**Limitations:**

- Uploads with `github.token`; GitHub does not trigger workflows from events that token causes
- `reusable-sbom.yml` itself has no fixture run; the fixture fakes its artifact
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-test-e2e-playwright`

Playwright E2E Test Workflow

- **Path:** [`.github/workflows/reusable-test-e2e-playwright.yml`](../.github/workflows/reusable-test-e2e-playwright.yml)
- **Tier:** stable
- **Evidence:** [`playwright.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770062637) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`
- **Check names:** `${{ inputs.job-name }}`, `publish-test-summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) in artifact `results-artifact-name` (default `playwright-results-<run_id>`)
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- Pinned at v0.76.0 or earlier under `egress-policy: block`, append `azure.archive.ubuntu.com:80 storage.googleapis.com:443` (`allowed-endpoints-mode: append`): those `playwright` presets lack the runner apt mirror and the Chrome-for-Testing redirect host, so `playwright install --with-deps` is refused. Later releases include both (#1103)
- Set `upload-report-when: always` to keep the HTML report on green runs (#804)

**Limitations:**

- Proven with `package-manager: bun` only; npm and pnpm are accepted but have no fixture run
- The failure path is covered by the dispatch-only `playwright-negative.yml` (the HTML report is present in the failure artifact since #1104)
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-test-node`

Node.js Vitest Test Workflow

- **Path:** [`.github/workflows/reusable-test-node.yml`](../.github/workflows/reusable-test-node.yml)
- **Tier:** stable
- **Evidence:** [`node-bun.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770062303) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `actions: read`, `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Prepare Node Matrix`, `Node.js Tests`, `Pages coverage upload status`, `Aggregate Node.js Results`, `publish-test-summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) per leg in artifact `<prefix>-results-<node-version>`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- `actions: read` is required by the aggregate job's artifact-availability wait (#803)
- Commit the lockfile of the selected `package-manager` (`bun.lock`, `package-lock.json` or `pnpm-lock.yaml`); installs are frozen and the fixture asserts the lockfile is untouched (#1077)
- pnpm takes its version from the project's `packageManager` field (fixture `node-pnpm.yml`)
- Vitest must be a project dependency: it runs through the manager's no-install exec (`bun x --no-install`, `npx --no-install`, `pnpm exec`)
- Egress is enforced in block mode; hosts outside the selected `egress-preset` go in `allowed-endpoints` with `allowed-endpoints-mode: append` (#913, fixture `egress.yml`)
- Sibling calls in one run need distinct `artifact-prefix` values (#1091, fixture `siblings.yml`)
- Callers that do not need the PR comment can call `reusable-test-node-run` instead and grant read scopes only (#1081)

**Limitations:**

- npm and pnpm are proven by `node-npm.yml` and `node-pnpm.yml` at the same pin; yarn is not supported
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-test-node-run`

Node.js Vitest Test Workflow (read-only)

- **Path:** [`.github/workflows/reusable-test-node-run.yml`](../.github/workflows/reusable-test-node-run.yml)
- **Tier:** stable
- **Evidence:** [`readonly-node.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37852212819) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `16aa956b`
- **Permissions:** `actions: read`, `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Prepare Node Matrix`, `Node.js Tests`, `Pages coverage upload status`, `Aggregate Node.js Results`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) per leg in artifact `<prefix>-results-<node-version>`

**Prerequisites:**

- Grant the caller job `actions: read` and `contents: read`; the aggregate job's artifact-availability wait needs `actions: read` (#803)
- Same inputs, outputs and artifacts as `reusable-test-node.yml` without `comment-marker`, and its check names without `publish-test-summary / Publish test summary`: drop that context from required checks when switching
- No PR comment. To post one, call `reusable-publish-test-summary.yml` from a separate job with `pull-requests: write` and the same `artifact-prefix`
- Every other prerequisite of `reusable-test-node` applies unchanged: committed lockfile of the selected `package-manager`, Vitest as a project dependency, pnpm version from `packageManager`, egress block mode, distinct `artifact-prefix` per sibling call

**Limitations:**

- Yarn is not supported
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-test-python`

Python Test Workflow

- **Path:** [`.github/workflows/reusable-test-python.yml`](../.github/workflows/reusable-test-python.yml)
- **Tier:** stable
- **Evidence:** [`python.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770062309) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `actions: read`, `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `uv`
- **Check names:** `Prepare Python Matrix`, `Python Tests`, `Aggregate Python Results`, `publish-test-summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) per leg in artifact `<prefix>-results-<python-version>`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Grant the caller job every scope listed under Permissions; GitHub validates the union statically and a smaller block is a `startup_failure` (#735, fixture `perms-negative.yml`)
- `actions: read` is required by the aggregate job's artifact-availability wait (#803)
- Commit a current `uv.lock`: dependencies install with `uv sync --frozen`, so a stale lock is installed verbatim and never re-resolved; a `pyproject.toml` without `uv.lock` gets one warned `uv lock` (#1021)
- Egress is enforced in block mode; hosts outside the selected `egress-preset` go in `allowed-endpoints` with `allowed-endpoints-mode: append` (#913, fixture `egress.yml`)
- Sibling calls in one run need distinct `artifact-prefix` values (#1091, fixture `siblings.yml`)

**Limitations:**

- private git dependencies in installed groups require the explicit GIT_DEPS_TOKEN secret; uv.lock must be committed and current (frozen installs); see #1021
- `gh run rerun --job` on a reusable-call job re-runs every job of the caller run; convergence onto the same artifact names is proven (fixture `retry.yml`, `scripts/rerun-sibling.sh`), an isolated sibling re-run is not
- The PR test-summary comment path was last exercised from the fixture on `pull_request` before the current pin; push runs skip it
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-test-shell-run`

Shell Test Workflow (read-only)

- **Path:** [`.github/workflows/reusable-test-shell-run.yml`](../.github/workflows/reusable-test-shell-run.yml)
- **Tier:** stable
- **Evidence:** [`readonly-shell.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37854613092) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `52423571`
- **Permissions:** `actions: read`, `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Shell Tests`, `Coverage shard matrix`, `${{ inputs.job-name }} (shard ${{ matrix.shard }}/${{ inputs.coverage-shards }})`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) in artifact `<prefix>-results` (single and sharded path)

**Prerequisites:**

- Grant the caller job `actions: read` and `contents: read`; the sharded aggregate's artifact-availability wait needs `actions: read` (#803)
- Same inputs, outputs and artifacts as `reusable-test-shell.yml` without `publish-test-summary`, and its check names without `publish-test-summary / Publish test summary`: drop that context from required checks when switching
- No PR comment. To post one, call `reusable-publish-test-summary.yml` from a separate job with `pull-requests: write`, `comment-marker` and `results-artifact-pattern: <artifact-prefix>-results`

**Limitations:**

- The sharded check only appears with `coverage: true` and `coverage-shards` above 1; GitHub expands the listed template per leg, e.g. `Shell Tests (shard 1/4)`
- Fixture proves the single-job `coverage: false` path only; the kcov coverage and sharded paths are exercised by lgtm-ci's own CI through the facade, not by the external fixture

### Reusable workflows: preview

#### `reusable-auto-rerun-on-infra-failure`

Auto Re-run on Infra Failure

> [!WARNING]
> **Preview.** No external-fixture run yet; starter in `examples/` but never run from outside the org

- **Path:** [`.github/workflows/reusable-auto-rerun-on-infra-failure.yml`](../.github/workflows/reusable-auto-rerun-on-infra-failure.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `checks: read`, `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Re-run failed jobs on infra failure`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-build-artifact`

Build Artifact Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; generic multi-toolchain build matrix

- **Path:** [`.github/workflows/reusable-build-artifact.yml`](../.github/workflows/reusable-build-artifact.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Prepare Build Matrix`, `Build`
- **Deprecated:** [input `node-version-matrix`](#deprecation-build-artifact-node-version-matrix), [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-build-python-dist`

Python Distribution Build Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; PyPI dist build with attestations; only the direct `build-python-package` path is proven

- **Path:** [`.github/workflows/reusable-build-python-dist.yml`](../.github/workflows/reusable-build-python-dist.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `uv`
- **Check names:** `Build Python distribution`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-build-rust-binaries`

Rust Binary Build Workflow

> [!WARNING]
> **Preview.** Green from the fixture's dispatch-only `rust-release-build.yml` (Linux and windows-latest legs) but outside the initial stable set

- **Path:** [`.github/workflows/reusable-build-rust-binaries.yml`](../.github/workflows/reusable-build-rust-binaries.yml)
- **Tier:** preview
- **Evidence:** [`rust-release-build.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37756155710) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `ea934b16`
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `cargo`
- **Check names:** `Rust binaries (${{ matrix.target }})`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-codeql`

CodeQL

> [!WARNING]
> **Preview.** No external-fixture run yet; runs on `ubuntu-latest`

- **Path:** [`.github/workflows/reusable-codeql.yml`](../.github/workflows/reusable-codeql.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `security-events: write`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `Setup CodeQL matrix`, `CodeQL`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-dependency-review`

Dependency Review

> [!WARNING]
> **Preview.** No external-fixture run yet; pull_request-only gate

- **Path:** [`.github/workflows/reusable-dependency-review.yml`](../.github/workflows/reusable-dependency-review.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: read`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `Dependency Review`

#### `reusable-deploy-pages`

Deploy to GitHub Pages

> [!WARNING]
> **Preview.** No external-fixture run yet; Pages deployment needs a Pages-enabled fixture

- **Path:** [`.github/workflows/reusable-deploy-pages.yml`](../.github/workflows/reusable-deploy-pages.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`, `pages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Deploy to GitHub Pages`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-deploy-site-with-reports`

Deploy Site With Reports Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; Pages deployment needs a Pages-enabled fixture

- **Path:** [`.github/workflows/reusable-deploy-site-with-reports.yml`](../.github/workflows/reusable-deploy-site-with-reports.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`, `id-token: write`, `pages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Build site and bundle reports`, `Deploy to GitHub Pages`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-docker`

Docker Build and Push

> [!WARNING]
> **Preview.** No external-fixture run yet; image build and push need a registry the fixture owns

- **Path:** [`.github/workflows/reusable-docker.yml`](../.github/workflows/reusable-docker.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`, `packages: write`, `security-events: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Classify Platforms`, `Docker build / Build and Push`, `Docker build / Vulnerability Scan`, `Docker multi-platform / Docker build per platform`, `Docker multi-platform / Docker verify per platform`, `Docker multi-platform / Docker health check per platform`, `Docker multi-platform / Merge Manifests`, `Docker multi-platform / Validation Summary`, `Docker multi-platform / Vulnerability Scan`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-docker-build`

Docker Build (single-platform)

> [!WARNING]
> **Preview.** No external-fixture run yet; image build and push need a registry the fixture owns

- **Path:** [`.github/workflows/reusable-docker-build.yml`](../.github/workflows/reusable-docker-build.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`, `packages: write`, `security-events: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Build and Push`, `Vulnerability Scan`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-docker-multiplatform`

Docker Build (multi-platform)

> [!WARNING]
> **Preview.** No external-fixture run yet; multi-platform build needs arm64 runners and a registry

- **Path:** [`.github/workflows/reusable-docker-multiplatform.yml`](../.github/workflows/reusable-docker-multiplatform.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`, `packages: write`, `security-events: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Docker build per platform`, `Docker verify per platform`, `Docker health check per platform`, `Merge Manifests`, `Validation Summary`, `Vulnerability Scan`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-docker-smoke-test`

Docker Smoke Test

> [!WARNING]
> **Preview.** No external-fixture run yet; needs a published image

- **Path:** [`.github/workflows/reusable-docker-smoke-test.yml`](../.github/workflows/reusable-docker-smoke-test.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Docker Smoke Test`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-github-release`

GitHub Release Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; release-creation path; an issue #1079 stable candidate awaiting its fixture run

- **Path:** [`.github/workflows/reusable-github-release.yml`](../.github/workflows/reusable-github-release.yml)
- **Tier:** preview
- **Permissions:** `contents: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Create GitHub Release`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-link-check`

Link Check

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/workflows/reusable-link-check.yml`](../.github/workflows/reusable-link-check.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Link Check`, `Publish link-check report / Publish link-check report`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-pr-auto-assign`

PR Auto Assign

> [!WARNING]
> **Preview.** No external-fixture run yet; pull_request-only

- **Path:** [`.github/workflows/reusable-pr-auto-assign.yml`](../.github/workflows/reusable-pr-auto-assign.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `PR Auto Assign`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-pr-labeler`

PR Auto Label

> [!WARNING]
> **Preview.** No external-fixture run yet; pull_request-only

- **Path:** [`.github/workflows/reusable-pr-labeler.yml`](../.github/workflows/reusable-pr-labeler.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `PR Labeler`

#### `reusable-publish-artifact-preview`

Publish Artifact Preview Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; PR publisher

- **Path:** [`.github/workflows/reusable-publish-artifact-preview.yml`](../.github/workflows/reusable-publish-artifact-preview.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish artifact preview`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-artifact-report`

Publish Artifact Report Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; PR publisher; only exercised nested inside other reusables

- **Path:** [`.github/workflows/reusable-publish-artifact-report.yml`](../.github/workflows/reusable-publish-artifact-report.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish artifact report`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-file-breakdown`

Publish File Breakdown Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; PR publisher

- **Path:** [`.github/workflows/reusable-publish-file-breakdown.yml`](../.github/workflows/reusable-publish-file-breakdown.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish file breakdown`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-gem`

RubyGems Publishing Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; RubyGems trusted publishing

- **Path:** [`.github/workflows/reusable-publish-gem.yml`](../.github/workflows/reusable-publish-gem.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `Publish to RubyGems`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-npm-set`

npm Package-Set Publishing

> [!WARNING]
> **Preview.** No external-fixture run yet; npm trusted publishing needs a registry package the fixture owns

- **Path:** [`.github/workflows/reusable-publish-npm-set.yml`](../.github/workflows/reusable-publish-npm-set.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish npm package set`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-quality-summary`

Publish Quality Summary Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; PR publisher; skipped on the fixture's push runs

- **Path:** [`.github/workflows/reusable-publish-quality-summary.yml`](../.github/workflows/reusable-publish-quality-summary.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish quality summary`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-rust-release`

Rust Release Publish Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; tag-triggered release; builds on `reusable-build-rust-binaries.yml` (preview, fixture-green at `ea934b16`)

- **Path:** [`.github/workflows/reusable-publish-rust-release.yml`](../.github/workflows/reusable-publish-rust-release.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: write`, `id-token: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Verify release tag`, `Build release binaries / Rust binaries (${{ matrix.target }})`, `Create GitHub release`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-security-audit-comment`

Publish Security Audit Comment Workflow

> [!WARNING]
> **Preview.** Fixture-green at the #1109 head `ae41597c` only (`security-audit.yml`); no run at a `main` commit yet

- **Path:** [`.github/workflows/reusable-publish-security-audit-comment.yml`](../.github/workflows/reusable-publish-security-audit-comment.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish security audit comment`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-test-results-pages`

Publish Test Results To Pages

> [!WARNING]
> **Preview.** No external-fixture run yet; Pages deployment needs a Pages-enabled fixture

- **Path:** [`.github/workflows/reusable-publish-test-results-pages.yml`](../.github/workflows/reusable-publish-test-results-pages.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`, `id-token: write`, `pages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish Test Results`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-publish-test-summary`

Publish Test Summary Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; only exercised nested inside the stable test reusables, on `pull_request`

- **Path:** [`.github/workflows/reusable-publish-test-summary.yml`](../.github/workflows/reusable-publish-test-summary.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish test summary`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-quality-lint`

Quality Lint Workflow

> [!WARNING]
> **Preview.** Green from the fixture's verbatim Python starter (`starter-python.yml`) but outside the initial stable set; the PR summary path (`reusable-publish-quality-summary.yml`) is skipped on push

- **Path:** [`.github/workflows/reusable-quality-lint.yml`](../.github/workflows/reusable-quality-lint.yml)
- **Tier:** preview
- **Evidence:** [`starter-python.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770063208) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `🛠️ Lintro Code Quality`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-release-auto-tag`

Release Auto Tag

> [!WARNING]
> **Preview.** No external-fixture run yet; tag mutation path

- **Path:** [`.github/workflows/reusable-release-auto-tag.yml`](../.github/workflows/reusable-release-auto-tag.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `contents: write`, `issues: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Create Release`, `Report release automation failure`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-release-multi-ecosystem`

Release Multi-Ecosystem Version PR

> [!WARNING]
> **Preview.** No external-fixture run yet; multi-manifest variant of the version PR

- **Path:** [`.github/workflows/reusable-release-multi-ecosystem.yml`](../.github/workflows/reusable-release-multi-ecosystem.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `contents: write`, `issues: write`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Prepare version update hook`, `Run version update hook`, `Create Version PR`, `Report release automation failure`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-release-recover`

Release Recovery

> [!WARNING]
> **Preview.** No external-fixture run yet; recovery of a partially published release

- **Path:** [`.github/workflows/reusable-release-recover.yml`](../.github/workflows/reusable-release-recover.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `attestations: write`, `contents: write`, `id-token: write`, `issues: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Resolve tag, artifacts, and channels`, `Resume npm channel`, `Resume GitHub Release channel`, `Re-dispatch Homebrew`, `Record recovery outcome`

#### `reusable-required-check`

Required Check Gate

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/workflows/reusable-required-check.yml`](../.github/workflows/reusable-required-check.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `${{ inputs.job-name }}`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-rust-build`

Rust Build Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; wrapper over `reusable-test-rust-build.yml` with a fixed job name

- **Path:** [`.github/workflows/reusable-rust-build.yml`](../.github/workflows/reusable-rust-build.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `build / Rust Build`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-rust-test-run`

Rust Test Workflow (read-only)

> [!WARNING]
> **Preview.** Read-only variant of `reusable-rust-test.yml` generated by #1081; promoted to stable once the fixture's `readonly-rust.yml` runs green from the fixture's main

- **Path:** [`.github/workflows/reusable-rust-test-run.yml`](../.github/workflows/reusable-rust-test-run.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `cargo`
- **Check names:** `Prepare Rust Matrix`, `Rust Tests`, `Aggregate Rust Results`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) per leg in artifact `<prefix>-results-<rust-toolchain>`

**Prerequisites:**

- Grant the caller job `actions: read` and `contents: read`; the aggregate job's artifact-availability wait needs `actions: read` (#803)
- Same inputs, outputs and artifacts as `reusable-rust-test.yml` without `comment-marker`, and its check names without `publish-test-summary / Publish test summary`: drop that context from required checks when switching
- No PR comment. To post one, call `reusable-publish-test-summary.yml` from a separate job with `pull-requests: write`, `results-artifact-pattern: <artifact-prefix>-results-*` and `tests-total-excludes-skipped: true` (as the facade does); see docs/reusable-workflows.md "Read-only variants" for the LCOV coverage inputs
- Every other prerequisite of `reusable-rust-test` applies unchanged: `.config/nextest.toml` with a `ci` profile, digest-verified nextest / llvm-cov installs, egress block mode, distinct `artifact-prefix` per sibling call

**Limitations:**

- No bundled fallback nextest profile (#1086 item 3 not done)
- A cached `~/.cargo/bin` at the pinned version is reused without re-verifying its digest; the cache is scoped to the consumer repository and ref (#1096)
- Fixture proves a `coverage: false` call only; coverage and Pages coverage upload are untested through the variant
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `reusable-sbom`

SBOM Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; the SBOM upload fixture fakes this workflow's artifact

- **Path:** [`.github/workflows/reusable-sbom.yml`](../.github/workflows/reusable-sbom.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`, `security-events: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Validate SBOM inputs`, `SBOM & Supply Chain`
- **Deprecated:** [input `upload-release-assets`](#deprecation-sbom-upload-release-assets), [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-scorecards`

OpenSSF Scorecard

> [!WARNING]
> **Preview.** No external-fixture run yet; OpenSSF Scorecard needs a public default branch run

- **Path:** [`.github/workflows/reusable-scorecards.yml`](../.github/workflows/reusable-scorecards.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`, `security-events: write`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `OpenSSF Scorecard`

#### `reusable-security-audit`

Security Audit Workflow

> [!WARNING]
> **Preview.** Fixture-green at the #1109 head `ae41597c` only (`security-audit.yml`); no run at a `main` commit yet

- **Path:** [`.github/workflows/reusable-security-audit.yml`](../.github/workflows/reusable-security-audit.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Security Audit`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) in artifact `results-artifact-name` (default `security-audit-results`)
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-semantic-pr-title`

Semantic PR Title

> [!WARNING]
> **Preview.** No external-fixture run yet; pull_request-only

- **Path:** [`.github/workflows/reusable-semantic-pr-title.yml`](../.github/workflows/reusable-semantic-pr-title.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-latest`
- **Package managers:** —
- **Check names:** `Semantic PR Title`

#### `reusable-site-quality`

Documentation Site Quality Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/workflows/reusable-site-quality.yml`](../.github/workflows/reusable-site-quality.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Build and check documentation site`, `Test documentation site`, `publish-test-summary / Publish test summary`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-e2e`

E2E Test Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; single-project Playwright runner; `reusable-test-e2e-playwright.yml` is the proven path

- **Path:** [`.github/workflows/reusable-test-e2e.yml`](../.github/workflows/reusable-test-e2e.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `E2E Tests`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-e2e-matrix`

E2E Matrix Test Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; sharded Playwright matrix

- **Path:** [`.github/workflows/reusable-test-e2e-matrix.yml`](../.github/workflows/reusable-test-e2e-matrix.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Setup Matrix`, `E2E tests`, `Merge Reports`
- **Deprecated:** [input `pages-target-dir`](#deprecation-e2e-matrix-pages-target-dir), [input `publish-allowed-endpoints`](#deprecation-e2e-matrix-publish-allowed-endpoints), [input `publish-egress-preset`](#deprecation-e2e-matrix-publish-egress-preset), [input `publish-results`](#deprecation-e2e-matrix-publish-results), [output `report-url`](#deprecation-e2e-matrix-report-url), [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-node-custom`

Node.js Custom Test Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; custom test command variant of `reusable-test-node.yml`

- **Path:** [`.github/workflows/reusable-test-node-custom.yml`](../.github/workflows/reusable-test-node-custom.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `bun`, `npm`, `pnpm`
- **Check names:** `Prepare Node Matrix`, `Node.js Tests`, `Aggregate Node.js Results`, `Pages coverage upload status`, `publish-test-summary / Publish test summary`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-node-publish`

Node.js Test Publish Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; Pages publisher

- **Path:** [`.github/workflows/reusable-test-node-publish.yml`](../.github/workflows/reusable-test-node-publish.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`, `id-token: write`, `pages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish Results`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-python-publish`

Python Test Publish Workflow

> [!WARNING]
> **Preview.** No external-fixture run yet; Pages publisher

- **Path:** [`.github/workflows/reusable-test-python-publish.yml`](../.github/workflows/reusable-test-python-publish.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`, `id-token: write`, `pages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Publish Results`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-rust-build`

Rust Build Only Workflow

> [!WARNING]
> **Preview.** Green from the fixture's `rust-build-siblings.yml` (two sibling calls with distinct `concurrency-scope`) but outside the initial stable set

- **Path:** [`.github/workflows/reusable-test-rust-build.yml`](../.github/workflows/reusable-test-rust-build.yml)
- **Tier:** preview
- **Evidence:** [`rust-build-siblings.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061949) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `cargo`
- **Check names:** `Rust Build`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-test-shell`

Shell Test Workflow

> [!WARNING]
> **Preview.** No external-fixture run of the facade itself (only its publish job differs from the stable `reusable-test-shell-run`, whose jobs the fixture proves); input or check-name changes here also change that stable variant and need a migration note

- **Path:** [`.github/workflows/reusable-test-shell.yml`](../.github/workflows/reusable-test-shell.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Shell Tests`, `Coverage shard matrix`, `${{ inputs.job-name }} (shard ${{ matrix.shard }}/${{ inputs.coverage-shards }})`, `publish-test-summary / Publish test summary`
- **Results:** `results.v1` document (`schemas/results.v1.json`, #1080) in artifact `<prefix>-results` (single and sharded path)
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

**Prerequisites:**

- Callers that do not need the PR comment can call `reusable-test-shell-run` instead and grant read scopes only (#1081)

**Limitations:**

- The sharded check only appears with `coverage: true` and `coverage-shards` above 1; GitHub expands the listed template per leg, e.g. `Shell Tests (shard 1/4)`

#### `reusable-validate`

Validation Script

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/workflows/reusable-validate.yml`](../.github/workflows/reusable-validate.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Validation`, `Publish validation report / Publish validation report`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-validate-action-pinning`

Validate Action Pinning

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/workflows/reusable-validate-action-pinning.yml`](../.github/workflows/reusable-validate-action-pinning.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Validate Action Pinning`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-vuln-suppression-check`

Vulnerability Suppression Check Workflow

> [!WARNING]
> **Preview.** The scan path is green from the fixture (`vuln-suppression.yml`); the cleanup-PR mutation path has no external run

- **Path:** [`.github/workflows/reusable-vuln-suppression-check.yml`](../.github/workflows/reusable-vuln-suppression-check.yml)
- **Tier:** preview
- **Evidence:** [`vuln-suppression.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061794) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: write`, `pull-requests: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Check Vulnerability Suppressions`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

### Reusable workflows: internal

#### `reusable-ai-review`

AI Review

> [!NOTE]
> **Internal.** Org AI review posting as the lgtm-hq `lintro-review` GitHub App

- **Path:** [`.github/workflows/reusable-ai-review.yml`](../.github/workflows/reusable-ai-review.yml)
- **Tier:** internal
- **Permissions:** `actions: read`, `contents: read`, `pull-requests: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `uv`
- **Check names:** `AI Review`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-ghcr-cleanup`

GHCR Cleanup

> [!NOTE]
> **Internal.** Prunes lgtm-hq GHCR packages

- **Path:** [`.github/workflows/reusable-ghcr-cleanup.yml`](../.github/workflows/reusable-ghcr-cleanup.yml)
- **Tier:** internal
- **Permissions:** `contents: read`, `packages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Clean Untagged Images`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-main-failure-notifier`

Main Failure Notifier

> [!NOTE]
> **Internal.** Opens lgtm-hq failure issues for lgtm-ci's own `main`

- **Path:** [`.github/workflows/reusable-main-failure-notifier.yml`](../.github/workflows/reusable-main-failure-notifier.yml)
- **Tier:** internal
- **Permissions:** `actions: read`, `contents: read`, `issues: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Report main workflow failure`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-prune-build-staging-tags`

Prune Build Staging Tags

> [!NOTE]
> **Internal.** Prunes lgtm-hq GHCR build-staging tags

- **Path:** [`.github/workflows/reusable-prune-build-staging-tags.yml`](../.github/workflows/reusable-prune-build-staging-tags.yml)
- **Tier:** internal
- **Permissions:** `contents: read`, `packages: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Prune Build Staging Tags`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-registry-health-check`

Registry Health Check

> [!NOTE]
> **Internal.** Checks lgtm-hq registry pins

- **Path:** [`.github/workflows/reusable-registry-health-check.yml`](../.github/workflows/reusable-registry-health-check.yml)
- **Tier:** internal
- **Permissions:** `contents: read`, `issues: write`, `packages: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Registry Health Check`, `Open Registry Health Issue`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-release-failure-notifier`

Release Failure Notifier

> [!NOTE]
> **Internal.** Opens lgtm-hq release-failure issues

- **Path:** [`.github/workflows/reusable-release-failure-notifier.yml`](../.github/workflows/reusable-release-failure-notifier.yml)
- **Tier:** internal
- **Permissions:** `actions: read`, `contents: read`, `issues: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Report release tag publish outcome`
- **Deprecated:** [input `tooling-ref`](#deprecation-tooling-ref)

#### `reusable-validate-lintro-version`

Validate Lintro Version

> [!NOTE]
> **Internal.** Keeps lgtm-hq py-lintro pins in sync

- **Path:** [`.github/workflows/reusable-validate-lintro-version.yml`](../.github/workflows/reusable-validate-lintro-version.yml)
- **Tier:** internal
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Validate Lintro Version`

### Reusable workflows: deprecated

#### `reusable-publish-npm`

npm Publishing Workflow (deprecated)

> [!CAUTION]
> **Deprecated.** Wrapper kept as a migration shim; it emits a deprecation notice and calls `reusable-publish-npm-set.yml`
> Migrate to [`reusable-publish-npm-set`](#reusable-publish-npm-set).

- **Path:** [`.github/workflows/reusable-publish-npm.yml`](../.github/workflows/reusable-publish-npm.yml)
- **Tier:** deprecated
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`
- **Runners:** `ubuntu-24.04`
- **Package managers:** —
- **Check names:** `Deprecation notice`, `Publish to npm (deprecated wrapper) / Publish to npm (deprecated wrapper)`
- **Deprecated:** [entry point](#deprecation-publish-npm), [input `tooling-ref`](#deprecation-tooling-ref)

## Composite actions

| Entry | Tier | Summary |
| ----- | ---- | ------- |
| [`run-lighthouse`](#run-lighthouse) | `stable` | Run Lighthouse CI audits with configurable thresholds |
| [`run-playwright`](#run-playwright) | `stable` | Run E2E tests using Playwright |
| [`run-pytest`](#run-pytest) | `stable` | Run Python tests using pytest with coverage support |
| [`run-vitest`](#run-vitest) | `stable` | Run JavaScript/TypeScript tests using vitest with coverage support |
| [`attest-build`](#attest-build) | `preview` | Create build attestations using GitHub attestations |
| [`build-docker`](#build-docker) | `preview` | Build and optionally push Docker images with multi-platform support |
| [`build-python-package`](#build-python-package) | `preview` | Preflight tag checks, validate metadata, build sdist/wheel, and twine-check dist |
| [`bundle-workflow-artifacts`](#bundle-workflow-artifacts) | `preview` | Download CI workflow artifacts into a GitHub Pages site tree via manifest |
| [`calculate-version`](#calculate-version) | `preview` | Calculate the next semantic version based on conventional commits |
| [`check-coverage-threshold`](#check-coverage-threshold) | `preview` | Check if coverage meets a minimum threshold |
| [`collect-coverage`](#collect-coverage) | `preview` | Aggregate coverage from multiple sources and formats |
| [`create-github-release`](#create-github-release) | `preview` | Create a GitHub release with changelog and optional assets |
| [`create-release-tag`](#create-release-tag) | `preview` | Create an annotated git tag for release |
| [`create-signed-commit`](#create-signed-commit) | `preview` | Create a GitHub-signed commit from working-tree files via the GraphQL createCommitOnBranch mutation |
| [`deploy-pages`](#deploy-pages) | `preview` | Prepare and upload content for GitHub Pages deployment |
| [`detect-changes`](#detect-changes) | `preview` | Map changed paths to named filters so conditional jobs always run and early-exit green when their paths didn't change (required-check-safe replacement for on.&lt;event&gt;.paths) |
| [`docker-login`](#docker-login) | `preview` | Login to GHCR or Docker Hub based on registry input |
| [`egress-audit`](#egress-audit) | `preview` | Audit and restrict network egress from workflows |
| [`generate-changelog`](#generate-changelog) | `preview` | Generate changelog from conventional commits |
| [`generate-coverage-badge`](#generate-coverage-badge) | `preview` | Generate coverage badge SVG/JSON for README display |
| [`generate-coverage-comment`](#generate-coverage-comment) | `preview` | Generate coverage test summary markdown from coverage results |
| [`generate-lighthouse-comment`](#generate-lighthouse-comment) | `preview` | Generate Lighthouse audit summary markdown from CI results |
| [`generate-playwright-comment`](#generate-playwright-comment) | `preview` | Generate Playwright test summary markdown from test results |
| [`generate-sbom`](#generate-sbom) | `preview` | Generate Software Bill of Materials (SBOM) using Syft |
| [`merge-playwright-reports`](#merge-playwright-reports) | `preview` | Merge multiple Playwright reports from sharded or matrix test runs |
| [`notify-discord`](#notify-discord) | `preview` | Send a Discord notification via webhook |
| [`notify-slack`](#notify-slack) | `preview` | Send a Slack notification via incoming webhook |
| [`post-pr-comment`](#post-pr-comment) | `preview` | Post or update a comment on a pull request with marker-based identification |
| [`prepare-pypi-upload`](#prepare-pypi-upload) | `preview` | Download a workflow artifact, optionally validate with twine, and expose dist metadata for a caller-level pypa/gh-action-pypi-publish step |
| [`publish-gem`](#publish-gem) | `preview` | Build and publish Ruby gem to RubyGems using OIDC trusted publishing |
| [`publish-test-results`](#publish-test-results) | `preview` | Publish test results and coverage to GitHub Pages |
| [`run-quality`](#run-quality) | `preview` | Run lintro via full ghcr.io/lgtm-hq/py-lintro image (all bundled tools) |
| [`run-tests`](#run-tests) | `preview` | Generic test runner that delegates to language-specific runners |
| [`scan-vulnerabilities`](#scan-vulnerabilities) | `preview` | Scan for vulnerabilities using Grype |
| [`secure-checkout`](#secure-checkout) | `preview` | Checkout repository with security-hardened defaults |
| [`setup-env`](#setup-env) | `preview` | Configure common CI environment variables and PATH |
| [`setup-node`](#setup-node) | `preview` | Setup Node.js with bun package manager and caching |
| [`setup-python`](#setup-python) | `preview` | Setup Python with uv package manager and caching |
| [`setup-ruby`](#setup-ruby) | `preview` | Setup Ruby with bundler and gem caching |
| [`setup-rust`](#setup-rust) | `preview` | Setup Rust toolchain with cargo caching |
| [`sign-artifact`](#sign-artifact) | `preview` | Sign release artifacts with Sigstore/Cosign keyless signing |
| [`trigger-homebrew-update`](#trigger-homebrew-update) | `preview` | Dispatch an update-formula event to lgtm-hq/homebrew-tap (or another tap repository) after a release publishes to PyPI and GitHub Releases |
| [`validate-action-pinning`](#validate-action-pinning) | `preview` | Ensure GitHub Actions references use SHA pins with Renovate version comments |
| [`validate-package`](#validate-package) | `preview` | Validate package before publishing to PyPI, npm, or RubyGems |
| [`verify-attestation`](#verify-attestation) | `preview` | Verify build attestations using gh attestation verify |
| [`verify-signature`](#verify-signature) | `preview` | Verify Sigstore/Cosign signatures on artifacts |
| [`wait-for-package`](#wait-for-package) | `preview` | Wait for a package to be available on a registry |
| [`checkout-and-harden`](#checkout-and-harden) | `internal` | Shared reusable-workflow preamble: sparse-checkout lgtm-ci tooling into .lgtm-ci-tooling |
| [`docker-auth`](#docker-auth) | `internal` | Validate the target registry and log in to GHCR or a secondary registry (Docker Hub) |
| [`validate-runner-policy`](#validate-runner-policy) | `internal` | Enforce tiered egress policy (strict, hardened, permissive) before harden-runner |

### Composite actions: stable

#### `run-lighthouse`

Run Lighthouse CI audits with configurable thresholds

- **Path:** [`.github/actions/run-lighthouse/action.yml`](../.github/actions/run-lighthouse/action.yml)
- **Tier:** stable
- **Evidence:** [`actions-direct.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061230) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `npm`, `bun`, `pnpm`

**Prerequisites:**

- Check out the caller repository first; the action resolves lgtm-ci scripts from its own path (#1075)
- Pass `package-manager` (no default) and `url`; `@lhci/cli` must be a project dependency

**Limitations:**

- The direct path is proven with `npm` only (fixture `actions-direct.yml`)
- Runs without its own harden-runner step; egress policy is the calling job's responsibility
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `run-playwright`

Run E2E tests using Playwright

- **Path:** [`.github/actions/run-playwright/action.yml`](../.github/actions/run-playwright/action.yml)
- **Tier:** stable
- **Evidence:** [`actions-direct.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061230) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `npm`, `bun`, `pnpm`

**Prerequisites:**

- Check out the caller repository first; the action resolves lgtm-ci scripts from its own path (#1075)
- Pass `package-manager` (no default); browsers are installed by the action

**Limitations:**

- The direct path is proven with `bun` only (fixture `actions-direct.yml`)
- Runs without its own harden-runner step; egress policy is the calling job's responsibility
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `run-pytest`

Run Python tests using pytest with coverage support

- **Path:** [`.github/actions/run-pytest/action.yml`](../.github/actions/run-pytest/action.yml)
- **Tier:** stable
- **Evidence:** [`actions-direct.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061230) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `uv`

**Prerequisites:**

- Check out the caller repository first; the action resolves lgtm-ci scripts from its own path (#1075)
- Python project with a committed `uv.lock`; installs with `uv sync --frozen` (#1021)

**Limitations:**

- The direct path is proven with `uv` only (fixture `actions-direct.yml`)
- Runs without its own harden-runner step; egress policy is the calling job's responsibility
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

#### `run-vitest`

Run JavaScript/TypeScript tests using vitest with coverage support

- **Path:** [`.github/actions/run-vitest/action.yml`](../.github/actions/run-vitest/action.yml)
- **Tier:** stable
- **Evidence:** [`actions-direct.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061230) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** `ubuntu-24.04`
- **Package managers:** `npm`, `bun`, `pnpm`

**Prerequisites:**

- Check out the caller repository first; the action resolves lgtm-ci scripts from its own path (#1075)
- Pass `package-manager` (no default); Vitest must be a project dependency

**Limitations:**

- The direct path is proven with `npm` only (fixture `actions-direct.yml`)
- Runs without its own harden-runner step; egress policy is the calling job's responsibility
- Proven on GitHub-hosted ubuntu-24.04 only; macOS, Windows and GHES runners are untested (#1074)

### Composite actions: preview

#### `attest-build`

Create build attestations using GitHub attestations

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/attest-build/action.yml`](../.github/actions/attest-build/action.yml)
- **Tier:** preview
- **Permissions:** `attestations: write`, `contents: read`, `id-token: write`
- **Runners:** —
- **Package managers:** —

#### `build-docker`

Build and optionally push Docker images with multi-platform support

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/build-docker/action.yml`](../.github/actions/build-docker/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `packages: write`
- **Runners:** —
- **Package managers:** —

#### `build-python-package`

Preflight tag checks, validate metadata, build sdist/wheel, and twine-check dist

> [!WARNING]
> **Preview.** The direct build path is green from the fixture (`build-python-direct.yml`) but outside the initial stable set; tag preflight needs `fetch-depth: 0` (#1087)

- **Path:** [`.github/actions/build-python-package/action.yml`](../.github/actions/build-python-package/action.yml)
- **Tier:** preview
- **Evidence:** [`build-python-direct.yml`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/actions/runs/37770061099) in `TurboCoder13/lgtm-ci-consumer-fixture`, green at lgtm-ci `5185136b`
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** `uv`

#### `bundle-workflow-artifacts`

Download CI workflow artifacts into a GitHub Pages site tree via manifest

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/bundle-workflow-artifacts/action.yml`](../.github/actions/bundle-workflow-artifacts/action.yml)
- **Tier:** preview
- **Permissions:** `actions: read`, `contents: read`
- **Runners:** —
- **Package managers:** —

#### `calculate-version`

Calculate the next semantic version based on conventional commits

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/calculate-version/action.yml`](../.github/actions/calculate-version/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `check-coverage-threshold`

Check if coverage meets a minimum threshold

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/check-coverage-threshold/action.yml`](../.github/actions/check-coverage-threshold/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `collect-coverage`

Aggregate coverage from multiple sources and formats

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/collect-coverage/action.yml`](../.github/actions/collect-coverage/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `create-github-release`

Create a GitHub release with changelog and optional assets

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/create-github-release/action.yml`](../.github/actions/create-github-release/action.yml)
- **Tier:** preview
- **Permissions:** `contents: write`
- **Runners:** —
- **Package managers:** —

#### `create-release-tag`

Create an annotated git tag for release

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/create-release-tag/action.yml`](../.github/actions/create-release-tag/action.yml)
- **Tier:** preview
- **Permissions:** `contents: write`
- **Runners:** —
- **Package managers:** —

#### `create-signed-commit`

Create a GitHub-signed commit from working-tree files via the GraphQL createCommitOnBranch mutation

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/create-signed-commit/action.yml`](../.github/actions/create-signed-commit/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `deploy-pages`

Prepare and upload content for GitHub Pages deployment

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/deploy-pages/action.yml`](../.github/actions/deploy-pages/action.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`
- **Runners:** —
- **Package managers:** —

#### `detect-changes`

Map changed paths to named filters so conditional jobs always run and early-exit green when their paths didn't change (required-check-safe replacement for on.&lt;event&gt;.paths)

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/detect-changes/action.yml`](../.github/actions/detect-changes/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: read`
- **Runners:** —
- **Package managers:** —

#### `docker-login`

Login to GHCR or Docker Hub based on registry input

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/docker-login/action.yml`](../.github/actions/docker-login/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** —
- **Package managers:** —

#### `egress-audit`

Audit and restrict network egress from workflows

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/egress-audit/action.yml`](../.github/actions/egress-audit/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-changelog`

Generate changelog from conventional commits

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-changelog/action.yml`](../.github/actions/generate-changelog/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-coverage-badge`

Generate coverage badge SVG/JSON for README display

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-coverage-badge/action.yml`](../.github/actions/generate-coverage-badge/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-coverage-comment`

Generate coverage test summary markdown from coverage results

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-coverage-comment/action.yml`](../.github/actions/generate-coverage-comment/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-lighthouse-comment`

Generate Lighthouse audit summary markdown from CI results

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-lighthouse-comment/action.yml`](../.github/actions/generate-lighthouse-comment/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-playwright-comment`

Generate Playwright test summary markdown from test results

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-playwright-comment/action.yml`](../.github/actions/generate-playwright-comment/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `generate-sbom`

Generate Software Bill of Materials (SBOM) using Syft

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/generate-sbom/action.yml`](../.github/actions/generate-sbom/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `merge-playwright-reports`

Merge multiple Playwright reports from sharded or matrix test runs

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/merge-playwright-reports/action.yml`](../.github/actions/merge-playwright-reports/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `notify-discord`

Send a Discord notification via webhook

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/notify-discord/action.yml`](../.github/actions/notify-discord/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `notify-slack`

Send a Slack notification via incoming webhook

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/notify-slack/action.yml`](../.github/actions/notify-slack/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `post-pr-comment`

Post or update a comment on a pull request with marker-based identification

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/post-pr-comment/action.yml`](../.github/actions/post-pr-comment/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `pull-requests: write`
- **Runners:** —
- **Package managers:** —

#### `prepare-pypi-upload`

Download a workflow artifact, optionally validate with twine, and expose dist metadata for a caller-level pypa/gh-action-pypi-publish step

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/prepare-pypi-upload/action.yml`](../.github/actions/prepare-pypi-upload/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`
- **Runners:** —
- **Package managers:** —

#### `publish-gem`

Build and publish Ruby gem to RubyGems using OIDC trusted publishing

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/publish-gem/action.yml`](../.github/actions/publish-gem/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`
- **Runners:** —
- **Package managers:** `bundler`

#### `publish-test-results`

Publish test results and coverage to GitHub Pages

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/publish-test-results/action.yml`](../.github/actions/publish-test-results/action.yml)
- **Tier:** preview
- **Permissions:** `actions: write`, `contents: read`, `id-token: write`, `pages: write`
- **Runners:** —
- **Package managers:** —

#### `run-quality`

Run lintro via full ghcr.io/lgtm-hq/py-lintro image (all bundled tools)

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/run-quality/action.yml`](../.github/actions/run-quality/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** —
- **Package managers:** —

#### `run-tests`

Generic test runner that delegates to language-specific runners

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/run-tests/action.yml`](../.github/actions/run-tests/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `scan-vulnerabilities`

Scan for vulnerabilities using Grype

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/scan-vulnerabilities/action.yml`](../.github/actions/scan-vulnerabilities/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `secure-checkout`

Checkout repository with security-hardened defaults

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/secure-checkout/action.yml`](../.github/actions/secure-checkout/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `setup-env`

Configure common CI environment variables and PATH

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/setup-env/action.yml`](../.github/actions/setup-env/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `setup-node`

Setup Node.js with bun package manager and caching

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/setup-node/action.yml`](../.github/actions/setup-node/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** `bun`, `npm`, `pnpm`

#### `setup-python`

Setup Python with uv package manager and caching

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/setup-python/action.yml`](../.github/actions/setup-python/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** `uv`

#### `setup-ruby`

Setup Ruby with bundler and gem caching

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/setup-ruby/action.yml`](../.github/actions/setup-ruby/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** `bundler`

#### `setup-rust`

Setup Rust toolchain with cargo caching

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/setup-rust/action.yml`](../.github/actions/setup-rust/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** `cargo`

#### `sign-artifact`

Sign release artifacts with Sigstore/Cosign keyless signing

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/sign-artifact/action.yml`](../.github/actions/sign-artifact/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`, `id-token: write`
- **Runners:** —
- **Package managers:** —

#### `trigger-homebrew-update`

Dispatch an update-formula event to lgtm-hq/homebrew-tap (or another tap repository) after a release publishes to PyPI and GitHub Releases

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/trigger-homebrew-update/action.yml`](../.github/actions/trigger-homebrew-update/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `validate-action-pinning`

Ensure GitHub Actions references use SHA pins with Renovate version comments

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/validate-action-pinning/action.yml`](../.github/actions/validate-action-pinning/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `validate-package`

Validate package before publishing to PyPI, npm, or RubyGems

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/validate-package/action.yml`](../.github/actions/validate-package/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `verify-attestation`

Verify build attestations using gh attestation verify

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/verify-attestation/action.yml`](../.github/actions/verify-attestation/action.yml)
- **Tier:** preview
- **Permissions:** `attestations: read`, `contents: read`
- **Runners:** —
- **Package managers:** —

#### `verify-signature`

Verify Sigstore/Cosign signatures on artifacts

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/verify-signature/action.yml`](../.github/actions/verify-signature/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `wait-for-package`

Wait for a package to be available on a registry

> [!WARNING]
> **Preview.** No external-fixture run yet

- **Path:** [`.github/actions/wait-for-package/action.yml`](../.github/actions/wait-for-package/action.yml)
- **Tier:** preview
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

### Composite actions: internal

#### `checkout-and-harden`

Shared reusable-workflow preamble: sparse-checkout lgtm-ci tooling into .lgtm-ci-tooling

> [!NOTE]
> **Internal.** Preamble of every reusable; not an egress boundary and not for direct use

- **Path:** [`.github/actions/checkout-and-harden/action.yml`](../.github/actions/checkout-and-harden/action.yml)
- **Tier:** internal
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

#### `docker-auth`

Validate the target registry and log in to GHCR or a secondary registry (Docker Hub)

> [!NOTE]
> **Internal.** Registry login step shared by the Docker reusables

- **Path:** [`.github/actions/docker-auth/action.yml`](../.github/actions/docker-auth/action.yml)
- **Tier:** internal
- **Permissions:** `contents: read`, `packages: read`
- **Runners:** —
- **Package managers:** —

#### `validate-runner-policy`

Enforce tiered egress policy (strict, hardened, permissive) before harden-runner

> [!NOTE]
> **Internal.** Runner/egress tier gate used by the Rust release reusables

- **Path:** [`.github/actions/validate-runner-policy/action.yml`](../.github/actions/validate-runner-policy/action.yml)
- **Tier:** internal
- **Permissions:** `contents: read`
- **Runners:** —
- **Package managers:** —

## Deprecations

Every deprecated input, output and entry point. Each keeps working as a
shim that warns when used, and is removed only once no
[known consumer](governance.md#known-consumers) still uses it, or an
exception naming the approving issue is recorded
([removal gate](governance.md#removal-gate)).

### Deprecation `build-artifact-node-version-matrix`

- **Retires:** input `node-version-matrix`
- **Deprecated since:** v0.61.0 (#760)
- **Replacement:** Pass `matrix` (a JSON array of objects) instead; `node-version` covers a single version
- **Entries (1):** [`reusable-build-artifact`](#reusable-build-artifact)

### Deprecation `coverage-pages-url`

- **Retires:** output `pages-url`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Read the `pages-url` output of `reusable-publish-test-results-pages`
- **Entries (1):** [`reusable-coverage`](#reusable-coverage)

### Deprecation `coverage-publish-pages`

- **Retires:** input `publish-pages`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Call `reusable-publish-test-results-pages` from its own caller job
- **Entries (1):** [`reusable-coverage`](#reusable-coverage)

### Deprecation `e2e-matrix-pages-target-dir`

- **Retires:** input `pages-target-dir`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Pass it as `pages-target-dir` to `reusable-publish-test-results-pages`
- **Entries (1):** [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix)

### Deprecation `e2e-matrix-publish-allowed-endpoints`

- **Retires:** input `publish-allowed-endpoints`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Pass `allowed-endpoints` to `reusable-publish-test-results-pages`
- **Entries (1):** [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix)

### Deprecation `e2e-matrix-publish-egress-preset`

- **Retires:** input `publish-egress-preset`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Pass `egress-preset` to `reusable-publish-test-results-pages`
- **Entries (1):** [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix)

### Deprecation `e2e-matrix-publish-results`

- **Retires:** input `publish-results`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Call `reusable-publish-test-results-pages` from its own caller job
- **Entries (1):** [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix)

### Deprecation `e2e-matrix-report-url`

- **Retires:** output `report-url`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Read the `pages-url` output of `reusable-publish-test-results-pages`
- **Entries (1):** [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix)

### Deprecation `publish-npm`

- **Retires:** entry point
- **Deprecated since:** v0.72.0 (#965)
- **Replacement:** Call `reusable-publish-npm-set` with a one-package set
- **Entries (1):** [`reusable-publish-npm`](#reusable-publish-npm)

### Deprecation `sbom-upload-release-assets`

- **Retires:** input `upload-release-assets`
- **Deprecated since:** v0.62.0 (#770)
- **Replacement:** Call `reusable-sbom-release-upload` from its own caller job
- **Entries (1):** [`reusable-sbom`](#reusable-sbom)

### Deprecation `tooling-ref`

- **Retires:** input `tooling-ref`
- **Deprecated since:** v0.75.3 (#995)
- **Replacement:** Delete the input; the tooling checkout follows the workflow pin (`job.workflow_sha`)
- **Entries (56):** [`reusable-ai-review`](#reusable-ai-review), [`reusable-auto-rerun-on-infra-failure`](#reusable-auto-rerun-on-infra-failure), [`reusable-build-artifact`](#reusable-build-artifact), [`reusable-build-python-dist`](#reusable-build-python-dist), [`reusable-build-rust-binaries`](#reusable-build-rust-binaries), [`reusable-codeql`](#reusable-codeql), [`reusable-coverage`](#reusable-coverage), [`reusable-deploy-pages`](#reusable-deploy-pages), [`reusable-deploy-site-with-reports`](#reusable-deploy-site-with-reports), [`reusable-docker`](#reusable-docker), [`reusable-docker-build`](#reusable-docker-build), [`reusable-docker-multiplatform`](#reusable-docker-multiplatform), [`reusable-docker-smoke-test`](#reusable-docker-smoke-test), [`reusable-ghcr-cleanup`](#reusable-ghcr-cleanup), [`reusable-github-release`](#reusable-github-release), [`reusable-link-check`](#reusable-link-check), [`reusable-main-failure-notifier`](#reusable-main-failure-notifier), [`reusable-pr-auto-assign`](#reusable-pr-auto-assign), [`reusable-prune-build-staging-tags`](#reusable-prune-build-staging-tags), [`reusable-publish-artifact-preview`](#reusable-publish-artifact-preview), [`reusable-publish-artifact-report`](#reusable-publish-artifact-report), [`reusable-publish-file-breakdown`](#reusable-publish-file-breakdown), [`reusable-publish-gem`](#reusable-publish-gem), [`reusable-publish-npm`](#reusable-publish-npm), [`reusable-publish-npm-set`](#reusable-publish-npm-set), [`reusable-publish-quality-summary`](#reusable-publish-quality-summary), [`reusable-publish-rust-release`](#reusable-publish-rust-release), [`reusable-publish-security-audit-comment`](#reusable-publish-security-audit-comment), [`reusable-publish-test-results-pages`](#reusable-publish-test-results-pages), [`reusable-publish-test-summary`](#reusable-publish-test-summary), [`reusable-quality-lint`](#reusable-quality-lint), [`reusable-registry-health-check`](#reusable-registry-health-check), [`reusable-release-auto-tag`](#reusable-release-auto-tag), [`reusable-release-failure-notifier`](#reusable-release-failure-notifier), [`reusable-release-multi-ecosystem`](#reusable-release-multi-ecosystem), [`reusable-release-version-pr`](#reusable-release-version-pr), [`reusable-required-check`](#reusable-required-check), [`reusable-rust-build`](#reusable-rust-build), [`reusable-rust-test`](#reusable-rust-test), [`reusable-sbom`](#reusable-sbom), [`reusable-sbom-release-upload`](#reusable-sbom-release-upload), [`reusable-security-audit`](#reusable-security-audit), [`reusable-site-quality`](#reusable-site-quality), [`reusable-test-e2e`](#reusable-test-e2e), [`reusable-test-e2e-matrix`](#reusable-test-e2e-matrix), [`reusable-test-e2e-playwright`](#reusable-test-e2e-playwright), [`reusable-test-node`](#reusable-test-node), [`reusable-test-node-custom`](#reusable-test-node-custom), [`reusable-test-node-publish`](#reusable-test-node-publish), [`reusable-test-python`](#reusable-test-python), [`reusable-test-python-publish`](#reusable-test-python-publish), [`reusable-test-rust-build`](#reusable-test-rust-build), [`reusable-test-shell`](#reusable-test-shell), [`reusable-validate`](#reusable-validate), [`reusable-validate-action-pinning`](#reusable-validate-action-pinning), [`reusable-vuln-suppression-check`](#reusable-vuln-suppression-check)
