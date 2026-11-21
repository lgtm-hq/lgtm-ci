# lgtm-ci documentation

Reusable CI/CD components for GitHub Actions: composite actions, reusable
workflows, and shell utilities. Start with
[getting-started.md](getting-started.md) for a first caller, or jump
straight to a component index below.

## Component index

| Area               | Index                                      | Covers                                                                  |
| ------------------ | ------------------------------------------ | ----------------------------------------------------------------------- |
| Composite actions  | [actions/README.md](actions/README.md)     | Setup, security, testing, coverage, publishing, release, PR comments    |
| Reusable workflows | [workflows/README.md](workflows/README.md) | Full catalog + category deep-dives (testing, publishing, deployment)    |
| Shell libraries    | [libraries/README.md](libraries/README.md) | `scripts/ci/lib/` layout + [function reference](libraries/reference.md) |

## Guides

| Doc                                                      | Covers                                                                                                                                                                           |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [getting-started.md](getting-started.md)                 | Installation, versioning/pinning model, first caller                                                                                                                             |
| [onboarding.md](onboarding.md)                           | Task-ordered consumer setup: starter examples, secrets, egress audit→block, SHA pinning                                                                                          |
| [catalog.md](catalog.md)                                 | Support tier, evidence, permissions, check names and deprecations of every workflow and action (generated)                                                                       |
| [governance.md](governance.md)                           | Tier promises, exact-SHA pinning, deprecation lifecycle, known-consumer registry, removal gate                                                                                   |
| [duplication-scan.md](duplication-scan.md)               | Scheduled cross-repository CI duplication audit, issue deduplication, privacy and rollout                                                                                        |
| [workflow-contract.md](workflow-contract.md)             | Standard inputs, permissions by mode, egress presets, action pinning policy, org ruleset check names                                                                             |
| [reusable-workflows.md](reusable-workflows.md)           | Full per-workflow inputs/outputs/examples                                                                                                                                        |
| [pages-publishing.md](pages-publishing.md)               | GitHub Pages Model A vs Model B, multi-publisher limits                                                                                                                          |
| [python-release-publish.md](python-release-publish.md)   | Production tag-push layout, PyPI trusted publishing, Homebrew tap dispatch                                                                                                       |
| [release-security-policy.md](release-security-policy.md) | Org-wide release policy: mandatory evidence per artifact class, build-then-publish ordering, blocking failures, partial states, recovery tiers, backfills                        |
| [reusable-splits.md](reusable-splits.md)                 | Permission/secret inventory of the high-branching reusables and their read-only variants (#1081)                                                                                 |
| [rust-testing.md](rust-testing.md)                       | Nextest config, fast-tests-vs-coverage, Rust workspace layouts                                                                                                                   |
| [migration/v0.113.md](migration/v0.113.md)               | Upgrading to v0.113.0 (breaking): harden-runner's eBPF fallback agent is refused; owners with StepSecurity TLS inspection set `LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT` to `true` |
| [migration/v0.112.md](migration/v0.112.md)               | Upgrading to v0.112.0 (breaking): the `playwright` preset drops the azureedge mirrors of Playwright 1.49 and older; upgrade or append them in `allowed-endpoints`                |
| [migration/v0.111.md](migration/v0.111.md)               | Upgrading to v0.111.0 (breaking): each reusable accepts only its own egress presets; pass extra hosts in `allowed-endpoints` with `allowed-endpoints-mode: append`               |
| [migration/v0.100.md](migration/v0.100.md)               | Upgrading to v0.100.0 (breaking): `reusable-release-multi-ecosystem.yml` is removed; call `reusable-release-version-pr.yml` without `job-name`                                   |
| [migration/v0.97.md](migration/v0.97.md)                 | Upgrading to v0.97.0 (breaking): `reusable-publish-npm.yml` is removed; call `reusable-publish-npm-set.yml` with a one-package set                                               |
| [migration/v0.95.md](migration/v0.95.md)                 | Upgrading to v0.95.0: private mirrors pass `LGTM_CI_TOOLING_TOKEN`; release hook tooling arrives as a digest-checked artifact                                                    |
| [migration/v0.94.md](migration/v0.94.md)                 | Upgrading to v0.94.0 (breaking): the version-PR token lists its permissions and requests `workflows: write` unless `request-workflows-permission: false`                         |
| [migration/v0.77.md](migration/v0.77.md)                 | Upgrading from v0.76.x to v0.77.0: Docker multi-platform and release-recovery check names, read-only entry points (#1081)                                                        |
| [migration/v0.76.md](migration/v0.76.md)                 | Upgrading from v0.75.x: every caller-visible change in v0.76.0 and the edit to make                                                                                              |
| [release-changelog.md](release-changelog.md)             | Keep a Changelog migration for `reusable-release-version-pr.yml`                                                                                                                 |
| [org-rulesets.md](org-rulesets.md)                       | Org ruleset registry, required check-name contract, sync tooling                                                                                                                 |
| [inline-shell.md](inline-shell.md)                       | Contributors: shell lives in script files; the two exceptions (generated copies, trivial steps) and the check that enforces them (#1624)                                         |
| [source-standard.md](source-standard.md)                 | Contributors: Python under `scripts/ci`: docstrings, the 400-line module limit and its exception list, the keyword-argument decision (#1626)                                     |
| [comment-fields.md](comment-fields.md)                   | Callers: `comment-fields`, labelled values on every pull request comment: format, rules and messages, limits, placement, history (#1677)                                         |
| [comment-formats.md](comment-formats.md)                 | Callers: `comment-format`, the test summary as `classic`, `compact` or `table`, with an example of each; the `comment.v1` model (#1678)                                          |
| [comment-sanitize.md](comment-sanitize.md)               | Contributors: the one sanitiser for untrusted text in pull request comments: modes, escaping rules, bash and Python use (#1676)                                                  |
| [junit-artifact.md](junit-artifact.md)                   | Callers: `junit-artifact` on `reusable-publish-test-summary.yml`, counting from JUnit XML: mapping, limits, untrusted XML, replacing a counting script (#1686)                   |

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

  <!-- prettier-ignore -->
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

Agents working in this repository load [AGENTS.md](../AGENTS.md) first: the commands, merge
contract and standing constraints in one page.

Workflow and action steps call script files under `scripts/`; inline shell is
limited to generated copies and trivial report-or-stop steps, enforced by the
`🐚 Inline Shell` CI job. See [inline-shell.md](inline-shell.md) for the rule,
both exceptions and the list of generated blocks.

Python tests are pytest functions that assert with `assertpy` and say in a
one-line docstring what they prove, enforced by the `🧪 Test Standard` CI job
(`scripts/ci/quality/validate_test_standard.py`). The bare-`assert` rule covers
every file under `tests/` except `tests/fixtures/`, helpers and `conftest.py`
included. Test files that predate the check are listed, with a count per file
and rule, in `scripts/ci/quality/test-standard-baseline.txt` until #1625
converts them. That file only shrinks: on a pull request or merge group the
job also compares it with the copy in `HEAD^1`, the base the merge commit was
built on, and fails on a new line or a raised count; a push skips the
comparison. The job reads that commit from the checkout, so the caller passes
`fetch-depth: 2` to `reusable-validate.yml`. With the default depth of 1 the
script fetches the commit itself, which fails in a private repository because
the checkout does not persist credentials.

Python under `scripts/ci` has a docstring on every module, class and function and no module over
400 lines without a recorded reason, enforced by the `🐍 Source Standard` CI job. See
[source-standard.md](source-standard.md) for the rules, the exception list and the keyword-argument
decision.

CI and `reusable-quality-lint.yml` run **lintro inside the pinned
`ghcr.io/lgtm-hq/py-lintro` image** so every bundled tool is available.
Mirror CI locally:

```bash
export STEP=check
export LINTRO_IMAGE='ghcr.io/lgtm-hq/py-lintro@sha256:979c965acbf8a57f862dd4fb35de557c4f0b0581771795a48b165d2f0873f11b'
bash scripts/ci/quality/run-lintro-docker.sh
```

Quick iteration without Docker (optional tools may SKIP):

```bash
git clone https://github.com/lgtm-hq/lgtm-ci.git
cd lgtm-ci
uv sync --dev
STEP=check bash scripts/ci/quality/lint-check.sh
```
