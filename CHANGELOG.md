# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **workflows**: compat/coverage contract validation for Rust, Node, and Python
  test reusables (#340)
- **workflows**: Rust runtime matrix via `rust-toolchain` / `rust-toolchains`
  with prepare/aggregate jobs (#340)
- **actions**: `test-suite-name` on `generate-coverage-comment` for distinct PR
  coverage headings (#340)

### Changed

- **workflows**: unify Node publish onto `publish-test-summary` →
  `reusable-publish-test-summary.yml`; closes #292 (#340)
- **workflows**: rich coverage headings append `test-suite-name` when set
  (`## 📊 Code Coverage Report — {name}`) (#340)

### Deprecated

- **workflows**: Rust `toolchain` input — use `rust-toolchain` instead (#340)

### Removed

- **workflows**: Node `publish-test-summary-coverage` inline matrix publish jobs
  (#340)
- **scripts**: `prepare-coverage-test-summary.sh` (superseded by
  `test-suite-name` on `generate-coverage-comment`) (#340)

### Fixed

### Security

### Breaking changes

- Callers combining multi-runtime matrices (`python-versions`, `node-versions`,
  `rust-toolchains`) with `coverage: true` or `publish-test-summary: true` will
  fail validation until split into separate compat and coverage jobs (#340).
- Node per-version coverage comment markers (`{marker}-{version}`) are removed
  with matrix publish (#340).
- Rich coverage PR comment headings now include the suite name when
  `test-suite-name` / `job-name` is wired through; upsert `comment-marker`
  values are unchanged (#340).

## [0.43.1] - 2026-06-10

### Fixed

- **release**: align changelog generator with Keep a Changelog sections (#344) (db268ab)

## [0.43.0] - 2026-06-09

### Added

- **workflows**: standardize runner-image and runner-map contract (#339) (6712308)
- **ci**: `validate-runner-contract.sh` and BATS contract tests for runner-image
  and runner-map policy (#338)

### Changed

- **workflows**: standardize `runner-image` across script-backed reusables with
  `ubuntu-24.04` default; add missing inputs and complete multi-job wiring (#338)
- **docs**: document `runner-map`, runner pinning exceptions, and consumer
  guidance in workflow contract (#338)

## [0.42.0] - 2026-06-09

### Features

- **workflows**: add reusable Docker health check testing between build and publish (#336) (1e6e8c9)

### Other Changes

- **release**: validate CHANGELOG-only caller for phase 6.1 (#55) (#335) (e2bd11f)

### Previously Unreleased

- **workflows**: optional detached-container health check in `reusable-docker.yml`
  gates publish on runtime validation (`health-check-cmd`, `health-check-port`,
  `health-check-timeout`) (#65)

## [0.41.0] - 2026-06-09

### Features

- **ci**: add reusable-vuln-suppression-check for stale OSV suppression cleanup (#332) (f9aeaff)

## [0.40.1] - 2026-06-08

### Bug Fixes

- **ci**: reusable-scorecards missing results_file breaks SARIF output (#331) (40f6e87)

## [0.40.0] - 2026-06-08

### Features

- **workflows**: add reusable-site-quality for docs site CI (#307 §2) (#327) (9a72ee4)

### Previously Unreleased

- **workflows**: add `reusable-site-quality` for Astro docs build, lychee link
  check, and mixed Node/Python site tests (#307)

- **workflows**: forward `package-manager` to site-quality Node install steps

- **workflows**: resolve first `lychee-path` for site artifact uploads

- **workflows**: upload `lychee-report` artifact on link-check failure in
  `reusable-site-quality`

- **workflows**: reject unsafe `build-env` lines in `reusable-site-quality`
  (`apply-build-env.sh` blocks `GITHUB_ENV` heredoc injection)

## [0.39.0] - 2026-06-08

### Features

- **ci**: add reusable-security-audit for lintro osv-scanner audits (#325) (c8ca808)

### Previously Unreleased

- **workflows**: add `reusable-security-audit` and
  `reusable-publish-security-audit-comment` for lintro/osv-scanner Docker audits
  with PR comment publish (#307)

## [0.38.0] - 2026-06-08

### Features

- **ci**: add per-language CodeQL build modes to reusable-codeql (#323) (5dd24bf)

### Documentation

- **ci**: document CodeQL build-mode and action-only reusable contracts (#321) (affec75)

### Other Changes

- **deps**: update digest (#322) (a493ad6)

## [0.37.0] - 2026-06-07

### Features

- **ci**: add Cargo auto-tag support for reusable-release-auto-tag (#319) (2888798)

### Previously Unreleased

- **ci**: Cargo auto-tag support in `reusable-release-auto-tag` with
  `version-source`, `version-file`, and `skip-if-unchanged` inputs (#307)

## [0.36.0] - 2026-06-07

### Features

- **ci**: block-only Rust release builds with OS-aware harden-runner (#317) (1fb3824)

### Other Changes

- **ci**: egress resolver and GITHUB_OUTPUT hygiene (#316) (063c7e4)

### Previously Unreleased

- **ci**: `validate-runner-policy` composite with `strict`, `hardened`, and
  `permissive` tiers (#313)

- **ci**: `rust-release` egress preset for cross-compile release builds (#313)

- **ci**: `reusable-build-rust-binaries` and `reusable-publish-rust-release`
  workflows with Linux-only strict tier (#313)

- **release**: `build-rust-binary.sh`, `package-rust-binary.sh`, and Cargo tag
  verification scripts (#313)

- **ci**: `harden-runner` Linux pre-step guarded with `runner.os == 'Linux'` (#313)

- **ci**: release reusables use `validate-runner-policy` before conditional
  harden-runner (#313)

- **ci**: replace O(n²) egress endpoint dedupe with an O(n) awk pass while
  preserving first-seen order

- **ci**: centralize `GITHUB_OUTPUT` / `GITHUB_ENV` multiline delimiter helpers
  and validate output keys before writing

- **ci**: reject newline injection in `add_github_path`; relative paths remain
  silently ignored (legacy behavior)

- **release**: external callers upgrading reusable release workflows must grant
  `actions: read` and `issues: write` on the caller job when using the default
  `report-failures: true`, or set `report-failures: false` to opt out

- **ci**: `setup-rust-nextest.sh` passes `--force` when reinstalling mismatched
  crate versions (#307, #313)

- **release**: declare `local -a labels` in `collect_existing_issue_label_args`
  to avoid leaking into global scope

- **ci**: `validate-runner-policy` rejects `egress-policy: audit` on `strict` and
  `hardened` tiers; release reusables default to block-only (#313)

## [0.35.0] - 2026-06-07

### Features

- **release**: surface reusable release workflow failures (#311) (dbbe6fc)

### Bug Fixes

- **release**: grant caller permissions for report-release-failure job (#314) (103e0b1)

### Previously Unreleased

- **release**: optional failure reporting for `reusable-release-version-pr` and
  `reusable-release-auto-tag` — step summary context plus deduplicated GitHub
  issues when release jobs fail on the default branch (#207)

- **release**: grant caller permissions for `report-release-failure` follow-up
  jobs so release workflows validate at startup (#312)

- **release**: deduplicate failure issues by title and visible tracking key
  instead of HTML comment search alone; fall back to tracking-key search when
  title search fails

- **release**: `report-failures` defaults to `true`; external callers must grant
  `actions: read` and `issues: write` on the caller job or pass
  `report-failures: false`

## [0.34.1] - 2026-06-06

### Bug Fixes

- **release**: sign release PR commits and request CODEOWNER review from release bot (#309) (9caa2b3)

## [0.34.0] - 2026-06-06

### Features

- **ci**: implement comprehensive version-drift prevention (#303) (a08c1c8)

## [0.33.0] - 2026-06-06

### Features

- **workflows**: unify semantic PR title on amannn reusable with PR comments (#305) (1c24827)

### Previously Unreleased

- **ci**: `reusable-semantic-pr-title` posts marker-based failure comments by default,
  with new `post-failure-comment`, `comment-marker`, and `max-length` inputs (#304).

- **ci**: dogfood semantic PR title validation via `.github/workflows/semantic-pr-title.yml`
  (#304).

- **ci**: `reusable-semantic-pr-title` requests `pull-requests: write` for PR comment
  upserts; callers using `post-failure-comment: false` may grant `read` only (#304).

- **Breaking:** Removed composite `semantic-pr-title` action and
  `scripts/ci/actions/semantic-pr-title.sh`. Migrate callers to
  `reusable-semantic-pr-title.yml` (#304).

## [0.32.4] - 2026-06-05

### Bug Fixes

- **ci**: pass github.token to composite actions that call gh (#300) (1199f97)

## [0.32.3] - 2026-06-05

### Bug Fixes

- **ci**: include scripts/ci/ in tooling sparse checkouts (#295) (19fb482)

## [0.32.2] - 2026-06-05

### Bug Fixes

- **ci**: pipe bundle workflow lookups through jq instead of gh api --arg (#297) (577b556)

## [0.32.1] - 2026-06-04

### Bug Fixes

- **ci**: include scripts/ci in coverage test summary sparse checkout (#290) (7bac65c)

## [0.32.0] - 2026-06-04

### Features

- **ci**: unify PR test/coverage summary publishing (#281) (#282) (f2b6c9c)

### Previously Unreleased

- **`reusable-publish-test-summary.yml`**: single workflow to publish test summaries for
  language test reusables and `reusable-coverage` (rich coverage table or test totals).

- **Breaking:** Renamed workflow input `post-pr-comment` → `publish-test-summary`; removed
  `coverage-pr-comment` and related marker/title inputs on Node reusables.

- **Breaking:** Renamed poster jobs to `publish-test-summary` / `publish-test-summary-coverage`
  (display name: Publish test summary).

- **Breaking:** Replaced `reusable-test-pr-comment.yml` and `reusable-coverage-pr-comment.yml`
  with `reusable-publish-test-summary.yml`.

- Rust/Python/coverage workflows use `generate-coverage-comment` for test summaries when
  coverage artifacts are available.

- Renamed `generate-test-comment.sh` → `generate-test-summary.sh` and
  `prepare-coverage-comment.sh` → `prepare-coverage-test-summary.sh`.

- **Breaking:** Renamed `prebuilt-comment-file` → `prebuilt-test-summary-file` on
  `reusable-publish-test-summary.yml`.

- Node matrix coverage artifacts use `node-coverage-test-summary` (was
  `node-coverage-pr-comment`).

- **Breaking:** Renamed `reusable-quality-pr-comment.yml` →
  `reusable-publish-quality-summary.yml`; caller job `quality-pr-comment` →
  `publish-quality-summary`.

- **Breaking:** Renamed `reusable-artifact-pr-comment.yml` →
  `reusable-publish-artifact-report.yml`; input `comment-file` → `report-file`.

- **Breaking:** Renamed `comment-on-failure` → `publish-validation-report` on
  `reusable-validate.yml`; validation artifact `validation-comment` →
  `validation-report`.

- **Breaking:** Renamed `comment-on-pr` → `publish-link-check-report` on
  `reusable-link-check.yml`.

- **Breaking:** `draft-pr-skip` default is now `true` on Python, Node, and Shell test
  reusables (aligned with Rust).

- `reusable-test-pr-comment.yml`, `reusable-coverage-pr-comment.yml`,
  `reusable-quality-pr-comment.yml`, `reusable-artifact-pr-comment.yml`,
  `generate-coverage-pr-comment.sh`, `generate-test-comment.sh`.

- Node reusables no longer require `post-pr-comment: true` when posting coverage-only
  summaries (`coverage-pr-comment: true` + `post-pr-comment: false` previously posted nothing).

## [0.31.0] - 2026-06-04

### Features

- **ci**: load egress composites via .lgtm-ci-tooling checkout (#280) (34293bb)

### Bug Fixes

- **ci**: retain egress composites in release tooling sparse checkout (#288) (13bcaaf)

### Previously Unreleased

- **workflows**: load `harden-runner` and `resolve-egress-allowlist` from an early
  `.lgtm-ci-tooling` sparse checkout instead of caller-local `./.github/actions/...`
  so cross-repo reusables work without vendoring (#279)

- **docs**: align README, actions catalog, workflow-contract, and examples with the
  `.lgtm-ci-tooling` egress pattern (#279)

## [0.30.1] - 2026-06-04

### Bug Fixes

- **harden-runner**: resolve egress before step-security pre-hook (#277) (7af7421)

### Previously Unreleased

- **actions**: `resolve-egress-allowlist` composite for preset/explicit egress resolution
  before `harden-runner` (#276)

- **egress**: `allowed-endpoints-mode` (`replace` | `append`) with deduped merge when
  appending project endpoints to presets (#276)

- **workflows**: Reusables resolve egress in a prior workflow step, then pass
  `steps.egress.outputs['allowed-endpoints']` into `harden-runner` (#276)

- **workflows**: Reusables accept `allowed-endpoints-mode` (default `replace`) (#276)

- **actions**: `harden-runner` passes `inputs['allowed-endpoints']` to step-security
  so the pre-hook receives the allowlist (fixes v0.30.0 blocking all egress) (#276)

## [0.30.0] - 2026-06-02

### Features

- **ci**: default reusable workflows to block egress with documented allowlist presets (#268) (295f6fe)

### Previously Unreleased

- **workflows**: Reusable workflows default `egress-policy` to `block`; add
  `egress-preset` (`github-minimal`, `github-pages`, `github-tooling`, `docker`,
  `playwright`, `pypi`, `rubygems`, `npm-publish`, `quality`, `sbom`, `scorecard`)
  resolved via `harden-runner` composite (#204). **Breaking:**
  callers that relied on audit defaults must set `egress-policy: audit` or pass
  `egress-preset` / `allowed-endpoints`.

- **actions**: Self-contained `harden-runner` bundle; reusables use
  `uses: ./.github/actions/harden-runner` (same-repo composite; manifest file is
  release bookkeeping only) (#204).

- **workflows**: Workflow-specific default presets (`docker`, `playwright`,
  `quality`, `pypi`, `rubygems`, `npm-publish`); summary/report publish jobs use
  `github-minimal` only (#204).

- **workflows**: `quality` preset covers full Docker-based `lintro chk` egress
  (GHCR, Docker Hub, PyPI, npm/crates, semgrep/OSV, tooling hosts) (#204).

- **workflows**: `reusable-quality-lint.yml` adds `timeout-minutes` (default 45) and
  defaults `egress-preset: quality` (#204).

- **workflows**: Most reusables default `egress-preset: github-tooling` for GitHub
  checkout/API under block (#204).

- **docs**: Egress preset catalog and SBOM example in `workflow-contract.md` (#204)

- **egress**: Add `github-pages` preset (`actions.githubusercontent.com` OIDC) for
  Pages deploy workflows; `reusable-test-e2e-matrix` publish job uses
  `publish-egress-preset` (#204).

- **egress**: Fail `resolve-egress-endpoints` when `egress-policy: block` has no
  allowlist or preset (#204).

## [0.29.2] - 2026-06-02

### Bug Fixes

- **ci**: set GH_TOKEN in reusable-github-release workflow (#273) (610c158)

## [0.29.1] - 2026-05-31

### Bug Fixes

- **ci**: split upload-pypi-oidc so pypa publish runs at caller level (#270) (c908c40)

### Previously Unreleased

- **actions**: `prepare-pypi-upload` composite for PyPI upload preparation (#269)

- **ci**: PyPI OIDC upload contract split — callers invoke
  `pypa/gh-action-pypi-publish` at workflow step level (#269)

- **actions**: `upload-pypi-oidc` — use `prepare-pypi-upload` plus caller-level
  `pypa/gh-action-pypi-publish` (#269)

- **ci**: nested `pypa/gh-action-pypi-publish` no longer resolves to
  `ghcr.io/lgtm-hq/lgtm-ci` (#269)

## [0.29.0] - 2026-05-31

### Features

- **ci**: finalize PyPI publish contract (#168 §5) (#266) (f9bdede)

### Previously Unreleased

- **examples**: `publish-python-release.yml` canonical caller template for PyPI tag
  releases (#168 §5)

- **ci**: `upload-pypi-oidc` fails upload validation when twine check cannot run
  (`VALIDATE_STRICT=true`) (#168 §5)

- **docs**: PyPI upload egress allowlist includes artifact download hosts (#168 §5)

## [0.28.0] - 2026-05-30

### Features

- **workflows**: add reusable-required-check for org ruleset gates (#168 §4) (#264) (8023cce)

### Previously Unreleased

- **workflows**: `reusable-required-check.yml` org-ruleset gate for branch-protection check
  names that differ from the reusable workflow `job-name`

- **ci**: `assert-required-check.sh` for reusable required-check upstream validation

- **ci**: `validate-static-job-names.sh` detects dynamic expressions in YAML block-scalar
  `job.name` continuations (#168 §12 guardrail)

## [0.27.0] - 2026-05-30

### Features

- **ci**: unify Rust test and coverage behind reusable-rust-test (#168 §13) (#261) (afddf97)

### Bug Fixes

- **ci**: hybrid job display names for skipped matrix jobs (#168 §12) (#263) (d4a5331)

### Previously Unreleased

- **rust**: `setup-rust-nextest.sh`, `run-rust-nextest.sh`, `run-rust-nextest-coverage.sh`,
  and `parse-rust-test-results.sh` (JUnit + optional LCOV) for unified Rust CI

- **examples**: `examples/nextest-ci.toml` profile for consumer `.config/nextest.toml`

- **workflows**: `reusable-test-node-custom.yml` for package-manager custom test commands

- **ci**: `validate-static-job-names.sh` and BATS contract tests for job display name policy

- **workflows**: `reusable-rust-test.yml` is the single entry point for Rust tests;
  `coverage: true` runs `cargo llvm-cov nextest` once; `coverage: false` runs
  `cargo nextest` only. PR summaries and reports align with Python via `reusable-test-pr-comment`
  (#168 §13)

- **workflows**: hybrid job display names (#168 §12) — `reusable-test-node.yml` is
  Vitest-only; custom commands use `reusable-test-node-custom.yml`; static inner
  names for Python, Docker per-platform, and E2E matrix jobs; `job-name` drives
  Vitest/custom check labels

- **workflows**: `test-command` on `reusable-test-node.yml` — use
  `reusable-test-node-custom.yml`

- **workflows**: `reusable-test-rust-test.yml`, `reusable-test-rust-coverage.yml`,
  `reusable-rust-coverage.yml`, `reusable-test-rust.yml`

- **scripts**: `run-cargo-test.sh`, `parse-cargo-test-results.sh`, `setup-rust-coverage.sh`,
  `run-rust-coverage.sh`

- **workflows**: skipped matrix jobs no longer show unevaluated `job.name` expressions
  in the GitHub checks UI (#168 §12)

## [0.26.0] - 2026-05-30

### Features

- **workflows**: add reusable Rust test workflow for cargo test (#258) (d7d5a7b)

### Previously Unreleased

- **workflows**: `reusable-rust-test` and `reusable-test-rust-test` for workspace
  `cargo test` with PR summaries and reports (#68). Clippy, rustfmt, and security scans remain
  in `reusable-quality-lint` (lintro).

## [0.25.0] - 2026-05-30

### Features

- **ci**: Pages Model B coverage HTML artifacts for Rust and Node reusables (#256) (1fb4bfe)

### Previously Unreleased

- **workflows**: `reusable-test-node` matrix job display names are now static
  (`Node.js tests (Vitest)` / `Node.js tests (custom command)`). Update branch
  protection required checks that matched the previous `inputs.job-name`-based
  names when upgrading.

## [0.24.1] - 2026-05-30

### Bug Fixes

- **ci**: checkout tooling for setup-python in upload-pypi-oidc (#252) (c6c2bf8)

## [0.24.0] - 2026-05-29

### Previously Unreleased

Target release: **v0.24.0** (breaking; `feat(ci)!`).

- **actions**: `build-python-package` and `upload-pypi-oidc` composites for PyPI
  releases (#248)
- **workflows**: `reusable-build-python-dist.yml` — build artifact only (#248)
- **ci**: PyPI OIDC upload must run in caller workflow jobs, not cross-repo
  reusables (#248)
- **workflows**: `reusable-publish-pypi.yml`, `reusable-publish-pypi-release.yml`
  (#248)
- **actions**: `publish-pypi` (#248)

### Breaking changes

- **ci**: split PyPI build/upload for OIDC (#248) (#249) (435f9a2)

| Removed                                  | Use instead                                           |
| ---------------------------------------- | ----------------------------------------------------- |
| `reusable-publish-pypi-release.yml`      | `reusable-build-python-dist.yml` + `upload-pypi-oidc` |
| `reusable-publish-pypi.yml`              | Same split; `test-pypi: true` on upload action        |
| `publish-pypi` action                    | `build-python-package` + `upload-pypi-oidc`           |
| `publish-pypi.sh`                        | `python-dist.sh`                                      |
| `github-environment` on reusable `with:` | `environment:` on caller upload job                   |

See [docs/python-release-publish.md](docs/python-release-publish.md).

## [0.23.1] - 2026-05-29

### Bug Fixes

- **ci**: validate PyPI dist with uv run twine (#246) (5661832)

### Previously Unreleased

- **docs**: document full PyPI publish egress (ghcr.io, setup-python hosts) and
  `github-environment` input for trusted publishing (#246)
- **workflows**: `reusable-publish-pypi-release.yml` adds `github-environment`
  input for publish-job OIDC environments (#246)
- **ci**: validate PyPI dist with twine when available, or `uv run --with twine
twine check` when only uv is present; `validate_pypi_package` warns and skips
  validation when neither tool is available (replaces PEP 668-breaking
  `uv pip install --system twine`) (#246)

## [0.23.0] - 2026-05-28

### Features

- **ci**: merge existing Pages site when multiple publishers deploy (#244) (ea34cc2)

### Previously Unreleased

- **actions**: optional `merge-existing-site` and `base-site-path` inputs on
  `publish-test-results` to merge existing Pages content before deploy (#225)

## [0.22.0] - 2026-05-28

### Features

- **ci**: bundle workflow artifacts into unified Pages site deploy (#242) (657ee6b)

### Previously Unreleased

- **workflows**: `reusable-deploy-site-with-reports.yml` for Model B Pages (site +
  bundled CI report artifacts) (#226)
- **actions**: `bundle-workflow-artifacts` composite and manifest-driven bundling
  script (#226)
- **docs**: Model A vs Model B in `docs/pages-publishing.md`; turbo-themes example
  manifest in `examples/bundle-manifest-turbo-themes.json` (#226)
- **release**: quote-safe glob expansion for release asset preflight and uploads
  (#232)
- **workflows**: download Python dist artifacts before setup-python in publish job
  (#232)
- **workflows**: create GitHub releases via `gh` in `reusable-github-release.yml`
  (#232)
- **workflows**: fail publish-pypi validate when twine cannot be installed (#232)

## [0.21.0] - 2026-05-27

### Features

- **workflows**: consolidate Python release publish reusables (#239) (4c96f35)

### Previously Unreleased

- **workflows**: `reusable-publish-pypi-release.yml` and
  `reusable-github-release.yml` for split Python release publishing (#232)
- **docs**: Python release publishing guide (`docs/python-release-publish.md`) (#232)
- **workflows**: `reusable-publish-pypi.yml` installs Python via `setup-python`
  before building (#232)

## [0.20.0] - 2026-05-27

### Features

- **workflows**: split PR-comment into dedicated reusables (#231) (#236) (720c9b5)

### Previously Unreleased

- **workflows**: `reusable-quality-lint.yml`, `reusable-publish-quality-summary.yml`,
  `reusable-coverage-pr-comment.yml`, and `reusable-publish-artifact-report.yml` (#231)
- **workflows**: split PR-comment jobs into dedicated reusables for least-privilege
  callers (#231)
- **workflows**: `reusable-quality.yml` orchestrator — invoke
  `reusable-quality-lint.yml` and `reusable-publish-quality-summary.yml` directly (#231)

## [0.19.3] - 2026-05-27

### Bug Fixes

- **workflows**: reusable-test-node test-custom checkout and Vitest 3 parse (#234) (26f993c)

## [0.19.2] - 2026-05-26

### Bug Fixes

- **ci**: use newline-delimited types in reusable-semantic-pr-title (#229) (f396eef)

## [0.19.1] - 2026-05-26

### Bug Fixes

- publish test results with official GitHub Pages actions (#223) (a240f51)

### Previously Unreleased

- **docs**: GitHub Pages publishing guide (`docs/pages-publishing.md`)
- **ci**: migrate `publish-test-results` from `peaceiris/actions-gh-pages` to official
  `configure-pages` / `upload-pages-artifact` / `deploy-pages` (#224)
- **workflows**: align Pages publish jobs (`reusable-test-*-publish`, `reusable-coverage`,
  `reusable-test-e2e-matrix`) with `github-pages` environment, OIDC permissions, and
  shared concurrency group
- **workflows**: unify `reusable-deploy-pages` concurrency with other Pages publishers
- **actions**: `publish-test-results` inputs `target-branch`, `keep-history`, and
  `retention-days` (peaceiris-only; no consumers)
- **ci**: unblock org repos where third-party Pages actions are denied (#224)

## [0.19.0] - 2026-05-25

### Features

- **ci**: require Renovate version comments on all SHA-pinned actions (#221) (17f9944)

## [0.18.4] - 2026-05-25

### Bug Fixes

- **ci**: reverse checkout order in test publish workflows for Pages deploy (#218) (862b139)

### Previously Unreleased

- **workflows**: reverse checkout order in test publish workflows so Pages deploy keeps tooling (#218)

## [0.18.3] - 2026-05-25

### Bug Fixes

- **ci**: resolve 3 main-branch failures after v0.18.2 adoption (#215) (e62885b)

### Other Changes

- **deps**: update digest (#213) (970c50a)

## [0.18.2] - 2026-05-24

### Bug Fixes

- **workflows**: merge per-version coverage artifacts for publish workflow (#211) (46c9a7a)

## [0.18.1] - 2026-05-24

### Bug Fixes

- **ci**: map host user and pass tool-options in run-lintro-docker (#206) (3631024)

## [0.18.0] - 2026-05-24

### Features

- **workflows**: add Python version matrix and expose lintro-image input (#201) (80dbd2f)

### Other Changes

- **deps**: update docker/build-push-action to v7.2.0 (minor) (#192) (aced4dd)

## [0.17.2] - 2026-05-22

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#185) (be997f8)

## [0.17.1] - 2026-05-22

### Bug Fixes

- **docker**: skip attestations when loading images locally (#197) (5200f16)

## [0.17.0] - 2026-05-22

### Features

- **docker**: enterprise-grade reusable Docker workflow enhancements (#194) (49cf79a)

### Previously Unreleased

- **workflows**: enterprise Docker CI enhancements for `reusable-docker.yml` (#193)
  - `validate-on-pr` — native split builds on PRs without registry push
  - `scan-exit-code` — block PRs on CRITICAL/HIGH Trivy findings
  - `cache-registry-ref` — registry cache fallback when GHA cache evicts
  - `cosign-sign` — keyless Sigstore image signing on push
  - `no-cache` — clean release builds without cache layers
  - Build observability via `$GITHUB_STEP_SUMMARY`

## [0.16.0] - 2026-05-20

### Features

- **workflows**: release standardized workflow contract (5e69e53)

### Bug Fixes

- **workflows**: swap checkout order in auto-assign to prevent clean wipe (39f296a)

### Other Changes

- standardize reusable workflow contract (#190) (028dc37)
- **deps**: update actions/dependency-review-action to v5.0.0 (major) (major) (#184) (5177dd6)
- **deps**: update actions/dependency-review-action to v4.9.0 (minor) (#183) (613b159)

## [0.15.0] - 2026-05-19

### Features

- **workflows**: add Rust workspace test reusable and consumer release extensions (#187) (11e23b4)

### Other Changes

- **deps**: update digest (#186) (a2033ae)

### Previously Unreleased

- **workflows**: `reusable-test-rust` for Cargo workspace build and `llvm-cov`
  coverage with PR summaries and reports (compose with `reusable-test-node` for frontends)
- **workflows**: extend `reusable-test-node` with `job-name`, `test-command`,
  and `coverage-pr-comment` for Vitest/Istanbul coverage reports
- **docs**: Rust testing guide (`docs/rust-testing.md`)
- **workflows**: `reusable-quality` accepts `egress-policy` and
  `allowed-endpoints` for hardened-runner passthrough
- **workflows**: `reusable-release-version-pr` adds `auto-merge-patch-only`,
  `release-branch-prefix`, and configurable release branch naming

## [0.14.0] - 2026-05-16

### Features

- **workflows**: standardize reusable workflows (#181) (d452d20)

## [0.13.4] - 2026-05-16

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#166) (68c7168)

### Other Changes

- **deps**: Update github/codeql-action action to v4.35.5 (#167) (71f2d86)

## [0.13.3] - 2026-05-15

### Bug Fixes

- repair Renovate custom manager config (#164) (bd880bc)

### Other Changes

- extract reusable release workflow helpers (#162) (7944462)
- centralize reusable test PR summaries and reports (#161) (984ebff)
- standardize Lintro Quality Checks reusable workflow (#160) (88ffb0f)
- run lintro via full py-lintro docker image (#147) (a64d972)

## [0.13.2] - 2026-05-15

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#155) (3b5c4b8)

### Other Changes

- **deps**: Update step-security/harden-runner action to v2.19.3 (#157) (8330615)
- **deps**: Lock file maintenance (#156) (880cd58)

## [0.13.1] - 2026-05-14

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#151) (422fdd6)

### Other Changes

- **deps**: update digest (#146) (88a328e)
- **deps**: update actions/create-github-app-token to v3.2.0 (minor) (#143) (61b1f1c)
- **deps**: update rubygems/configure-rubygems-credentials to v2.0.0 (major) (#135) (daf090a)

## [0.13.0] - 2026-05-14

### Features

- add unified coverage report comments (#152) (2d4fef5)

## [0.12.3] - 2026-05-12

### Bug Fixes

- make Docker build helper executable (#144) (5855bd4)

### Other Changes

- **deps**: update digest (#142) (e0dc2d6)
- **deps**: update digest (#140) (7bf1e96)

## [0.12.2] - 2026-05-10

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#133) (05d289b)

### Other Changes

- **deps**: update actions/labeler to v6.1.0 (minor) (#132) (a4a958d)

## [0.12.1] - 2026-05-10

### Bug Fixes

- **docker**: adopt cross-repo tooling checkout in reusable-docker (#138) (070cf3a)

### Other Changes

- **deps**: update digest (#136) (e4a33c3)
- **deps**: update digest (#134) (c923a2b)
- **deps**: update actions/setup-node to v6.4.0 (minor) (#131) (9c45c24)
- **deps**: update digest (#130) (68d7e31)
- **deps**: update astral-sh/setup-uv to v8.1.0 (minor) (#129) (bd46a80)

## [0.12.0] - 2026-04-17

### Features

- **docker**: add per-platform smoke tests before manifest merge (#127) (34758dd)

## [0.11.0] - 2026-04-16

### Features

- **docker**: support configurable per-platform runners to eliminate QEMU emulation (#123) (e13f578)

### Other Changes

- **deps**: update actions/cache to v5.0.5 (#124) (db0f9db)
- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#117) (ae3c968)
- **deps**: update digest (#121) (ab6e78a)
- **deps**: update actions/upload-pages-artifact to v5.0.0 (major) (#120) (52fb285)
- **deps**: update actions/attest-build-provenance to v4.1.0 (major) (major) (#119) (b986562)
- **deps**: update actions/attest-build-provenance to v2.4.0 (minor) (#118) (38b62d9)

## [0.10.2] - 2026-04-07

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#115) (477bd1a)

### Other Changes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#114) (cc5940b)

## [0.10.1] - 2026-04-06

### Bug Fixes

- **deps**: update ghcr.io/lgtm-hq/py-lintro digest (#104) (c34c5e8)

### Other Changes

- **ecosystems**: fix JSON default parsing and add config override tests (#113) (ff446f9)
- **deps**: update digest (#112) (ae47852)

## [0.10.0] - 2026-04-05

### Features

- **workflows**: add reusable release-version-pr with ecosystem-based version sync (#105) (8292382)

### Bug Fixes

- **actions**: refresh stale pinned SHAs after upstream tag rewrites (#109) (23bb227)
- **workflows**: avoid self-deadlock between caller and reusable concurrency (#108) (403f1aa)

### Other Changes

- **workflows**: harden reusable-release-auto-tag and align with version-pr (#107) (45015e3)
- standardize Renovate config with org-wide shared preset (#101) (87a3c1a)

## [0.9.0] - 2026-04-02

### Features

- **ci**: request review from CODEOWNER on bot-opened PRs (#99) (514c40e)

## [0.8.2] - 2026-03-22

### Bug Fixes

- **actions**: pin setup-trivy by SHA after upstream tag deletion (#95) (7baf38a)

## [0.8.1] - 2026-03-06

### Bug Fixes

- **ci**: fix changelog blank lines and Docker write permissions (#92) (ffeb674)
- **lint**: align enforce.line_length with tool configs (#91) (28a9850)
- **ci**: enforce lintro version consistency between Docker and pyproject (#90) (dcb5e93)
- **ci**: use proseWrap preserve to fix version PR prettier failure (#89) (c8aa55e)
- **ci**: propagate App token to release creation for event triggering (#88) (125c485)

## [0.8.0] - 2026-02-21

### Features

- add reusable GHCR cleanup workflow (#82) (0fb74a0)

## [0.7.0] - 2026-02-21

### Features

- add validate-action-pinning composite action (#81) (b401224)

## [0.6.4] - 2026-02-21

### Bug Fixes

- replace awk TOML parsing with Python tomllib (#80) (eb673af)

## [0.6.3] - 2026-02-21

### Bug Fixes

- add Renovate rule for container image digest pinning (#79) (e1d20a3)

## [0.6.2] - 2026-02-20

### Bug Fixes

- **actions**: normalize Windows paths in all composite actions (#77) (f31059e)

## [0.6.1] - 2026-02-20

### Bug Fixes

- **actions**: resolve secure-checkout path failure on Windows runners (#75) (27529c3)

### Documentation

- revamp README to match org standards (#72) (64dc59a)

### Other Changes

- add Renovate workflow (#71) (17e64ec)

## [0.6.0] - 2026-02-11

### Features

- **workflows**: add reusable release-auto-tag workflow (#60) (5d22dcb)

### Bug Fixes

- **release**: deduplicate changelog when same version is re-created (#63) (b7fef51)
- **workflows**: use github.sha as default tooling-ref in auto-tag workflow (#62) (b911193)

### Other Changes

- **release**: version 0.6.0 (#61) (3c6f9e9)

## [0.5.1] - 2026-02-10

### Bug Fixes

- **workflows**: fall back to full CODEOWNERS list when author is sole candidate (#58) (28790e7)

## [0.5.0] - 2026-02-10

### Features

- **workflows**: add reusable pr-auto-assign and pr-labeler (#53) (fd59e18)

## [0.4.1] - 2026-02-10

### Bug Fixes

- **lint**: add markdownlint config for MD013/MD024 (#50) (0073e65)
- **release**: lintro Docker permissions and v0.51.0 update (#49) (7e8aed1)
- **release**: let lintro auto-detect tools for fmt and chk (#48) (96bad24)
- **release**: add lintro formatting to version PR workflow (#47) (5cdd1e0)

## [0.4.0] - 2026-02-09

### Features

- **release**: adopt two-stage release-PR workflow (#43) (a3a0bba)

### Bug Fixes

- **release**: prevent changelog data loss in version PR workflow (#45) (974b2e1)

### Previously Unreleased

- Comprehensive BATS shell testing infrastructure ([#37])
- Advanced CI features including Docker, deploy-pages, and Homebrew workflows ([#12])
- Testing and publishing infrastructure with PyPI, npm, and gem support ([#11])
- Comprehensive testing and coverage infrastructure ([#8])
- SBOM generation and supply chain security actions ([#7])
- Release automation actions and reusable workflow ([#6])
- Quality workflow and linting infrastructure ([#5])
- PR comment and coverage reporting composite actions ([#4])
- Security composite actions with runner hardening and egress audit ([#3])
- Setup composite actions for Python, Node, Rust, and environment ([#2])
- Foundation structure and core shell libraries ([#1])

[Unreleased]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.43.1...HEAD
[0.43.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.43.0...v0.43.1
[0.43.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.40.1...v0.41.0
[0.40.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.40.0...v0.40.1
[0.40.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.39.0...v0.40.0
[0.39.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.38.0...v0.39.0
[0.38.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.37.0...v0.38.0
[0.37.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.36.0...v0.37.0
[0.36.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.35.0...v0.36.0
[0.35.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.34.1...v0.35.0
[0.34.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.34.0...v0.34.1
[0.34.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.33.0...v0.34.0
[0.33.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.32.4...v0.33.0
[0.32.4]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.32.3...v0.32.4
[0.32.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.32.2...v0.32.3
[0.32.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.32.1...v0.32.2
[0.32.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.32.0...v0.32.1
[0.32.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.31.0...v0.32.0
[0.31.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.30.1...v0.31.0
[0.30.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.29.2...v0.30.0
[0.29.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.29.1...v0.29.2
[0.29.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.29.0...v0.29.1
[0.29.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.24.1...v0.25.0
[0.24.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.23.1...v0.24.0
[0.23.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.23.0...v0.23.1
[0.23.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.19.3...v0.20.0
[0.19.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.19.2...v0.19.3
[0.19.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.19.1...v0.19.2
[0.19.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.19.0...v0.19.1
[0.19.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.18.4...v0.19.0
[0.18.4]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.18.3...v0.18.4
[0.18.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.18.2...v0.18.3
[0.18.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.18.1...v0.18.2
[0.18.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.17.2...v0.18.0
[0.17.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.17.1...v0.17.2
[0.17.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.13.4...v0.14.0
[0.13.4]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.13.3...v0.13.4
[0.13.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.13.2...v0.13.3
[0.13.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.13.1...v0.13.2
[0.13.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.12.3...v0.13.0
[0.12.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.12.2...v0.12.3
[0.12.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.10.2...v0.11.0
[0.10.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.4...v0.7.0
[0.6.4]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.3.0...v0.4.0
[#37]: https://github.com/lgtm-hq/lgtm-ci/pull/37
[#12]: https://github.com/lgtm-hq/lgtm-ci/pull/12
[#11]: https://github.com/lgtm-hq/lgtm-ci/pull/11
[#8]: https://github.com/lgtm-hq/lgtm-ci/pull/8
[#7]: https://github.com/lgtm-hq/lgtm-ci/pull/7
[#6]: https://github.com/lgtm-hq/lgtm-ci/pull/6
[#5]: https://github.com/lgtm-hq/lgtm-ci/pull/5
[#4]: https://github.com/lgtm-hq/lgtm-ci/pull/4
[#3]: https://github.com/lgtm-hq/lgtm-ci/pull/3
[#2]: https://github.com/lgtm-hq/lgtm-ci/pull/2
[#1]: https://github.com/lgtm-hq/lgtm-ci/pull/1
