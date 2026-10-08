# lgtm-ci documentation

Reusable CI/CD components for GitHub Actions: composite actions, reusable
workflows, and shell utilities. Start with
[getting-started.md](getting-started.md) for a first caller, or jump
straight to a component index below.

## Component index

| Area | Index | Covers |
| ---- | ----- | ------ |
| Composite actions | [actions/README.md](actions/README.md) | Setup, security, testing, coverage, publishing, release, PR comments |
| Reusable workflows | [workflows/README.md](workflows/README.md) | Full catalog + category deep-dives (testing, publishing, deployment) |
| Shell libraries | [libraries/README.md](libraries/README.md) | `scripts/ci/lib/` layout + [function reference](libraries/reference.md) |

## Guides

| Doc | Covers |
| --- | ------ |
| [getting-started.md](getting-started.md) | Installation, versioning/pinning model, first caller |
| [onboarding.md](onboarding.md) | Task-ordered consumer setup: starter examples, secrets, egress audit→block, SHA pinning |
| [workflow-contract.md](workflow-contract.md) | Standard inputs, permissions by mode, egress presets, action pinning policy, org ruleset check names |
| [reusable-workflows.md](reusable-workflows.md) | Full per-workflow inputs/outputs/examples |
| [pages-publishing.md](pages-publishing.md) | GitHub Pages Model A vs Model B, multi-publisher limits |
| [python-release-publish.md](python-release-publish.md) | Production tag-push layout, PyPI trusted publishing, Homebrew tap dispatch |
| [release-security-policy.md](release-security-policy.md) | Org-wide release policy: mandatory evidence per artifact class, build-then-publish ordering, blocking failures, partial states, recovery tiers, backfills |
| [rust-testing.md](rust-testing.md) | Nextest config, fast-tests-vs-coverage, Rust workspace layouts |
| [release-changelog.md](release-changelog.md) | Keep a Changelog migration for `reusable-release-version-pr.yml` |
| [org-rulesets.md](org-rulesets.md) | Org ruleset registry, required check-name contract, sync tooling |

## Documentation conventions

### Caller snippets and permissions

Every YAML snippet that calls a reusable workflow is one of two classes,
enforced by `scripts/ci/docs/validate-caller-permissions.py` (CI job
`caller-permissions`):

- **Complete snippets** have a top-level `jobs:` key and are meant to be copied
  wholesale (`examples/**`, [getting-started.md](getting-started.md),
  [onboarding.md](onboarding.md), and the full examples in reference docs).
  Every reusable-workflow call in them carries the exact `permissions:` block
  the called workflow declares: the union of its job-level and workflow-level
  blocks (`write` outranks `read`), which GitHub validates statically before
  any job `if:` runs. Print it with
  `python3 scripts/ci/docs/validate-caller-permissions.py --union <file>.yml`.
- **Fragments** have no top-level `jobs:` key and demonstrate inputs, not a
  whole caller. They may omit `permissions:` only when the prose line directly
  above the fence marks them non-copyable:

  `*Fragment: permissions omitted for brevity, not copyable as-is. See
  [Permissions by mode](workflow-contract.md#permissions-by-mode).*`

  An unmarked blockless fragment, or a complete snippet without the block,
  fails CI. A fragment that does carry a block is checked like a complete one.

Jobs whose steps use `lgtm-hq/lgtm-ci/.github/actions/detect-changes` must
grant `contents: read` and `pull-requests: read` (#669); the validator derives
that requirement as well.

## Versioning

lgtm-ci uses [semantic versioning](https://semver.org/) with
[conventional commits](https://www.conventionalcommits.org/) for automated
releases. See [getting-started.md](getting-started.md#pinning) for the
pinning model (`@v1`, `@v1.2.3`, commit SHA) and
[onboarding.md](onboarding.md#4-resolve-the-release-commit-sha) for
resolving a release tag to its commit SHA.

## Development

CI and `reusable-quality-lint.yml` run **lintro inside the pinned
`ghcr.io/lgtm-hq/py-lintro` image** so every bundled tool is available.
Mirror CI locally:

```bash
export STEP=check
export LINTRO_IMAGE='ghcr.io/lgtm-hq/py-lintro@sha256:21fdb887b00cf3ef3017eb7463e53e68a9c71b90012df657923331375a71ac2f'
bash scripts/ci/quality/run-lintro-docker.sh
```

Quick iteration without Docker (optional tools may SKIP):

```bash
git clone https://github.com/lgtm-hq/lgtm-ci.git
cd lgtm-ci
uv sync --dev
STEP=check bash scripts/ci/quality/lint-check.sh
```
