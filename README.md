# lgtm-ci

<!-- markdownlint-disable MD033 MD013 -->
<p align="center">
Reusable CI/CD components for GitHub Actions — composite actions, reusable workflows,
and shell utilities.
</p>

<!-- Badges: Build & Quality -->
<p align="center">
<a href="https://github.com/lgtm-hq/lgtm-ci/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/github/actions/workflow/status/lgtm-hq/lgtm-ci/ci.yml?label=ci&branch=main&logo=githubactions&logoColor=white" alt="CI"></a>
<a href="https://github.com/lgtm-hq/lgtm-ci/releases/latest"><img src="https://img.shields.io/github/v/release/lgtm-hq/lgtm-ci?label=release" alt="Release"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
</p>

<!-- Badges: Tech Stack -->
<p align="center">
<a href="https://github.com/features/actions"><img src="https://img.shields.io/badge/GitHub_Actions-2088FF?logo=githubactions&logoColor=white" alt="GitHub Actions"></a>
<a href="https://www.gnu.org/software/bash/"><img src="https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white" alt="Bash"></a>
</p>
<!-- markdownlint-enable MD033 MD013 -->

## 🚀 Quick Start

New repository? Follow the task-ordered consumer guide in
[docs/onboarding.md](docs/onboarding.md) — starter example selection, release
GitHub App secrets, building the egress allowlist in block mode, and
release-SHA pinning. For
the three consumption models (composite actions, reusable workflows, shell
libraries) and the pinning model, see
[docs/getting-started.md](docs/getting-started.md).

Before adding shared CI or retaining local logic, apply
[Inclusion: what belongs in lgtm-ci](docs/governance.md#inclusion-what-belongs-in-lgtm-ci).

```yaml
jobs:
  quality:
    permissions:
      contents: read
      packages: read # pull ghcr.io/lgtm-hq/py-lintro in reusable-quality-lint
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha> # vX.Y.Z
```

Reusable workflows share a standard contract (`tooling-ref`,
`egress-policy`, `job-name`, permissions by mode). See
[docs/workflow-contract.md](docs/workflow-contract.md). You do **not** need
to copy anything into your repository for egress hardening — reusables carry
their allowlist presets and invoke `step-security/harden-runner` directly.

> **BREAKING (#1203): `egress-policy: audit` is no longer accepted.** Every
> reusable job now runs a `Verify harden-runner agent` step right after
> harden-runner, on every runner. It fails unless the policy is `block` and, on
> GitHub-hosted Linux, the agent has started. Callers passing `audit` must
> switch to `block` with an allow-list (`egress-preset`, `allowed-endpoints`).
> Each such job also ends with a `Recheck harden-runner agent` step that fails
> the job if the agent stopped enforcing mid-job, and the same recheck runs
> right before each irreversible external write (publish, push, release,
> attestation, PR creation or auto-merge, registry delete, publishing
> dispatch; #1551), so a stopped agent skips it. A step that writes several
> things is checked once, before it starts. The recheck decides from
> systemd state (`agent.service` active) and the agent's DNS redirection
> (`DNS=127.0.0.1` in `resolved.conf`), never `agent.log`; the startup check
> also reads the
> agent's own `agent.log` lines, which is safe only before any job step has run
> because the agent logs process arguments unescaped. It is the last declared step;
> action post hooks (cache save, checkout cleanup) run after it, outside it. A
> failed recheck blocks dependents that use the default success condition
> (`always()`/`failure()` dependents still run), and the `passed`/`status`
> outputs (and `reusable-quality-lint.yml`'s `exit-code`) these workflows export
> then report failure; other tools' `exit-code` outputs report the tool's own
> exit code. Self-hosted runners get a
> warning, also in the step summary, that egress enforcement is not verified
> and the job may run without it; hosted macOS/Windows get a notice.
> **A public repository on a self-hosted runner fails (#1552)**: the step reads
> `github.event.repository.private` and fails when it is `false`, since fork
> pull requests could run there. Private and internal repositories keep the
> warning. GHES is not exempt: a public repository there must be made internal
> or private. There is no opt-out.
> Limits: the two checks are snapshots at job start and job end, not
> continuous monitoring. They catch an agent that fails by accident, failing
> the job and blocking its default `needs:` dependents, but they cannot undo what
> steps already did unhardened, and they do not resist a malicious step with
> root or sudo, which can stop the agent and fake what the checks read. The
> Scorecards job cannot run either step, so its own agent is not verified (its
> `egress-preset` job still rejects audit first). See
> [Harden-runner agent verification](docs/workflow-contract.md#harden-runner-agent-verification-1203).

## 📦 Components

Full documentation: [docs/README.md](docs/README.md).

<!-- prettier-ignore-start -->
<!-- BEGIN catalog-index: generated by scripts/ci/catalog/render.py -->
<!-- markdownlint-disable MD013 -- component index table -->

| Area | Index | Support tiers | Highlights |
| ---- | ----- | ------------- | ---------- |
| Reusable workflows (69) | [docs/workflows/](docs/workflows/README.md) | 16 stable · 44 preview · 9 internal · 0 deprecated | Quality lint, per-language tests, Docker, Pages, release automation, security audit |
| Composite actions (50) | [docs/actions/](docs/actions/README.md) | 4 stable · 43 preview · 3 internal · 0 deprecated | Setup, security/egress, testing, coverage, publishing, release, PR comments |
| Shell libraries | [docs/libraries/](docs/libraries/README.md) | — | Logging, GitHub Actions helpers, installers, release/changelog, coverage parsing |

Stable entry points, each green from the external consumer fixture:

- Reusable workflows: [`reusable-all-checks-gate`](docs/catalog.md#reusable-all-checks-gate), [`reusable-coverage`](docs/catalog.md#reusable-coverage), [`reusable-docker-multiplatform`](docs/catalog.md#reusable-docker-multiplatform), [`reusable-docker-multiplatform-validate`](docs/catalog.md#reusable-docker-multiplatform-validate), [`reusable-release-recover`](docs/catalog.md#reusable-release-recover), [`reusable-release-recover-plan`](docs/catalog.md#reusable-release-recover-plan), [`reusable-release-version-pr`](docs/catalog.md#reusable-release-version-pr), [`reusable-required-check`](docs/catalog.md#reusable-required-check), [`reusable-rust-test`](docs/catalog.md#reusable-rust-test), [`reusable-rust-test-run`](docs/catalog.md#reusable-rust-test-run), [`reusable-sbom-release-upload`](docs/catalog.md#reusable-sbom-release-upload), [`reusable-test-e2e-playwright`](docs/catalog.md#reusable-test-e2e-playwright), [`reusable-test-node`](docs/catalog.md#reusable-test-node), [`reusable-test-node-run`](docs/catalog.md#reusable-test-node-run), [`reusable-test-python`](docs/catalog.md#reusable-test-python), [`reusable-test-shell-run`](docs/catalog.md#reusable-test-shell-run)
- Composite actions: [`run-lighthouse`](docs/catalog.md#run-lighthouse), [`run-playwright`](docs/catalog.md#run-playwright), [`run-pytest`](docs/catalog.md#run-pytest), [`run-vitest`](docs/catalog.md#run-vitest)

<!-- markdownlint-enable MD013 -->

Everything else is `preview`, `internal` or `deprecated`; tiers, evidence,
permissions, prerequisites and deprecations for every entry are in
[docs/catalog.md](docs/catalog.md). What each tier promises, how to pin and
when a deprecated input may be removed: [docs/governance.md](docs/governance.md).
<!-- END catalog-index -->
<!-- prettier-ignore-end -->

Caller starter examples live in [examples/](examples/README.md).

## 📌 Versioning

lgtm-ci uses [semantic versioning](https://semver.org/) with
[conventional commits](https://www.conventionalcommits.org/) for automated
releases. Pin the release commit SHA with a `# vX.Y.Z` comment; the floating
`@v0` tag moves to every release, breaking ones included, and is for trying
lgtm-ci out only. Releases are automated and PR-gated via the two-stage
model (`reusable-release-version-pr.yml` opens the release PR;
`reusable-release-auto-tag.yml` tags on merge). See
[docs/getting-started.md](docs/getting-started.md#pinning).

What each support tier promises, how deprecated inputs are retired, and the
known-consumer evidence a removal needs are in
[docs/governance.md](docs/governance.md).

Upgrading from v0.76.x? v0.77.0 renames the Docker multi-platform and
release-recovery check names; follow
[docs/migration/v0.77.md](docs/migration/v0.77.md) before moving the pin.
From v0.75.x, start with [docs/migration/v0.76.md](docs/migration/v0.76.md).

## 🔨 Development

CI runs **lintro inside the pinned `ghcr.io/lgtm-hq/py-lintro` image** so
every bundled tool is available. See
[docs/README.md](docs/README.md#development) for the local commands that
mirror CI.

## 🤝 Community

- 🐛 [Bug Reports](https://github.com/lgtm-hq/lgtm-ci/issues/new)
- 💡 [Feature Requests](https://github.com/lgtm-hq/lgtm-ci/issues/new)

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
