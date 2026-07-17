# Reusable workflows

Complete CI/CD pipelines callable from consumer workflows with a thin
caller job (`uses:` + `permissions:` + `with:`). They load egress
composites from an internal `.lgtm-ci-tooling` checkout — callers only pin
the workflow `@sha` and optional `tooling-ref`.

- **Full per-workflow reference** (inputs, outputs, examples):
  [reusable-workflows.md](../reusable-workflows.md)
- **Standard contract** (inputs, permissions by mode, egress presets, action
  pinning policy): [workflow-contract.md](../workflow-contract.md)
- **Category deep-dives**: [testing.md](testing.md) ·
  [publishing.md](publishing.md) · [deployment.md](deployment.md)

Test workflows are self-contained for consumers: they check out lgtm-ci
tooling internally, run the configured test suite, and post/update the
standard summary comment when callers grant `pull-requests: write`.

## Catalog

<!-- markdownlint-disable MD013 MD060 -- workflow catalog table -->

### Quality and validation

| Workflow | Description |
| -------- | ------------ |
| `reusable-quality-lint.yml` | Lintro via full py-lintro Docker image |
| `reusable-publish-quality-summary.yml` | Publish lintro quality PR summary |
| `reusable-validate.yml` | Generic repo validation script runner |
| `reusable-required-check.yml` | Org ruleset aggregate-status gate |
| `reusable-validate-action-pinning.yml` | GitHub Action SHA pinning validation |
| `reusable-validate-lintro-version.yml` | Resolve/validate the pinned py-lintro image digest |

### Testing — see [testing.md](testing.md)

| Workflow | Description |
| -------- | ------------ |
| `reusable-test-python.yml` | Python tests (pytest) with optional coverage |
| `reusable-test-node.yml` | Node.js Vitest tests with optional coverage |
| `reusable-test-node-custom.yml` | Node.js tests via caller-provided command |
| `reusable-test-shell.yml` | BATS shell tests with optional summaries |
| `reusable-test-e2e.yml` | E2E testing with Playwright |
| `reusable-test-e2e-matrix.yml` | Matrix E2E testing with tag filtering |
| `reusable-rust-build.yml` | Rust compile check |
| `reusable-rust-test.yml` | Rust tests (nextest) with optional coverage |
| `reusable-test-rust-build.yml` | Low-noise Rust build-only check (no PR context) |
| `reusable-coverage.yml` | Unified coverage collection and publishing |
| `reusable-publish-test-summary.yml` | Shared test/coverage summary comment publisher |
| `reusable-test-node-publish.yml` | Node tests + isolated Pages/coverage-badge publish |
| `reusable-test-python-publish.yml` | Python tests + isolated Pages/coverage-badge publish |

### Publishing — see [publishing.md](publishing.md)

| Workflow | Description |
| -------- | ------------ |
| `reusable-build-python-dist.yml` | Build Python dist artifact |
| `reusable-github-release.yml` | GitHub Release with artifact assets |
| `reusable-publish-npm.yml` | npm publishing with provenance |
| `reusable-publish-gem.yml` | RubyGems publishing (OIDC) |
| `reusable-publish-rust-release.yml` | Rust cross-compile release binaries |
| `reusable-release-version-pr.yml` | Release version PR with changelog |
| `reusable-release-multi-ecosystem.yml` | Multi-manifest version PR (npm/raw/gemspec/pep621) |
| `reusable-release-auto-tag.yml` | Tag + GitHub release on merge |
| `reusable-main-failure-notifier.yml` | Dedup'd issue on any main-branch workflow failure |
| `reusable-auto-rerun-on-infra-failure.yml` | Re-run failed jobs once on transient infra outage signatures |
| `reusable-publish-artifact-preview.yml` | Sticky PR comment linking a build artifact |
| `reusable-publish-artifact-report.yml` | Publish markdown report from an artifact |
| `reusable-publish-file-breakdown.yml` | PR changed-files breakdown comment |
| `reusable-semantic-pr-title.yml` | Conventional PR title validation + comments |
| `reusable-security-audit.yml` | lintro/osv-scanner audit + comment artifact |
| `reusable-publish-security-audit-comment.yml` | Publish security audit PR comment |
| `reusable-ai-review.yml` | Org-wide AI code review (sticky PR comment) |
| `reusable-pr-auto-assign.yml` | PR auto-assignment |
| `reusable-pr-labeler.yml` | PR auto-labeling |

### Deployment and supply chain — see [deployment.md](deployment.md)

| Workflow | Description |
| -------- | ------------ |
| `reusable-docker.yml` | Docker build, push, attestations |
| `reusable-deploy-pages.yml` | GitHub Pages deploy-only (caller builds) |
| `reusable-deploy-site-with-reports.yml` | Build + bundle CI reports + deploy Pages (Model B) |
| `reusable-sbom.yml` | SBOM generation with Cosign signing |
| `reusable-build-rust-binaries.yml` | Cross-compiled Rust release binaries matrix |
| `reusable-site-quality.yml` | Docs site build, lychee, and site tests |
| `reusable-ghcr-cleanup.yml` | Prune aged untagged GHCR images and build-cache tags |

### Security and repo hygiene

| Workflow | Description |
| -------- | ------------ |
| `reusable-codeql.yml` | CodeQL security analysis |
| `reusable-dependency-review.yml` | Dependency review gate |
| `reusable-scorecards.yml` | OpenSSF Scorecard analysis |
| `reusable-link-check.yml` | Markdown and HTML link checking |
| `reusable-vuln-suppression-check.yml` | Weekly stale OSV suppression cleanup + auto-PR |
| `reusable-registry-health-check.yml` | Verify digest-pinned images in workflows still resolve; opens an issue on failure |

<!-- markdownlint-enable MD013 -->

## Runner and tooling pinning

Script-backed reusables accept `runner-image` on every job; pin explicitly
in production. Pass `tooling-ref` when testing an unreleased lgtm-ci branch.
Multi-arch Docker builds use `runner-map` instead. Action-only reusables
(labeler, dependency review, semantic PR title, CodeQL, Scorecard) do not
run the full `scripts/ci/` suite, so `tooling-ref` mainly pins egress
composites for them. See
[reusable-workflows.md](../reusable-workflows.md#runner-pinning) and
[workflow-contract.md](../workflow-contract.md#runner-pinning).

Consumers do **not** need to vendor `.github/actions/harden-runner` or
`resolve-egress-allowlist` — reusables sparse-checkout lgtm-ci into
`.lgtm-ci-tooling/` for allowlist resolution and invoke
`step-security/harden-runner` directly.

Caller examples live under [examples/](../../examples/) (see
[examples/README.md](../../examples/README.md)); the task-ordered setup
path is in [getting-started.md](../getting-started.md) and
[onboarding.md](../onboarding.md).
