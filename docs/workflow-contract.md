# Reusable Workflow Contract

All `lgtm-ci` reusable workflows share a common consumer contract.

Upgrading from v0.75.x: v0.76.0 changes caller permissions, egress
enforcement, Node runner inputs and artifact names. See the
[v0.76 migration guide](migration/v0.76.md).

## Standard inputs

Where applicable, workflows accept:

<!-- markdownlint-disable MD013 -- wide input reference table; row text exceeds default line length -->

| Input                              | Purpose                                                                |
| ---------------------------------- | ---------------------------------------------------------------------- |
| `tooling-ref`                      | Optional tooling override (default: the called workflow's commit)      |
| `egress-policy`                    | `block` (default) or `audit` for StepSecurity harden-runner            |
| `egress-preset`                    | Named baseline allowlist (see [Egress allowlists](#egress-allowlists)) |
| `allowed-endpoints`                | `host:port` list, default empty (see `allowed-endpoints-mode`)         |
| `allowed-endpoints-mode`           | `replace` (default): non-empty list replaces the preset; `append`      |
| `job-name`                         | Check name on always-run jobs; test summary suite title                |
| `runner-image`                     | GitHub-hosted runner OS label (default `ubuntu-24.04`)                 |
| `runner-map`                       | JSON platform→runner map for multi-arch Docker (default `{}`)          |
| `timeout-minutes`                  | Job timeout                                                            |
| `publish-test-summary`             | Publish test/coverage summary comment on the pull request              |
| `comment-marker` / `comment-title` | Upsert identity for summary comments (marker + heading)                |
| `draft-pr-skip`                    | Skip PR jobs on draft pull requests (default `true` on test reusables) |
| `pipeline-skip`                    | Skip test jobs on pipeline-irrelevant diffs (default `false`)          |

<!-- markdownlint-enable MD013 -->

`tooling-ref` is listed above for workflows that accept it. See
[Action-only reusables](#action-only-reusables) for workflows where the input
pins the `checkout-and-harden` composite only (not `scripts/ci/`).

## Deprecated inputs and removal

An input, output or workflow that is being retired keeps parsing and warns:
an inert input emits `::warning title=Deprecated input::` when set to a
non-default value, an output stays declared with an empty value, and a
deprecated workflow wraps its replacement. Every such item has a record in
the `deprecations` list of `catalog/catalog.yml`, listed with its replacement
in [catalog.md](catalog.md#deprecations). It is removed only once no
[known consumer](governance.md#known-consumers) still uses it, which the
`🧭 Deprecation Gate` CI job checks; time since the deprecation does not
count. The full lifecycle and the pinning rules are in
[governance.md](governance.md).

## Egress allowlists

Every reusable job starts with a direct, SHA-pinned
`step-security/harden-runner` step. That action installs its egress agent in
its **pre hook**, before any step runs, so the allowlist it enforces must be
fully known at job start: nothing a later step computes — including anything a
composite action resolves — can reach it (#412/#420/#913).

The three egress inputs are therefore composed **inside** the harden-runner
step from job-start values only:

<!-- markdownlint-disable MD013 -->

| Inputs                                                         | Enforced allowlist                              |
| -------------------------------------------------------------- | ----------------------------------------------- |
| defaults                                                       | the workflow's default `egress-preset`          |
| `egress-preset: <name>`                                        | that preset                                     |
| `allowed-endpoints: <list>` (mode `replace`, the default)      | that list **alone** — the preset is not applied |
| `allowed-endpoints: <list>` + `allowed-endpoints-mode: append` | the preset **plus** the list                    |
| `egress-policy: audit`                                         | nothing is blocked; the same list is logged     |

<!-- markdownlint-enable MD013 -->

Presets are defined once in `scripts/ci/lib/egress/presets.sh`
(`egress_preset_names` lists them). Because the workflow cannot read that file
at run time, `scripts/ci/egress/render-presets.sh` renders every preset into a
JSON map and `scripts/ci/egress/sync-workflow-presets.sh` writes it into each
reusable as the workflow-level literal `env.LGTM_CI_EGRESS_PRESETS` (between
`# lgtm-ci-egress-presets:begin/end` markers). Each harden-runner step then
selects by expression:

```yaml
- name: Harden runner
  uses: step-security/harden-runner@<pinned SHA>
  with:
    egress-policy: ${{ inputs.egress-policy }}
    allowed-endpoints: >-
      ${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '')
      && inputs.allowed-endpoints
      || format('{0} {1}',
      fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || '<workflow default>'],
      inputs.allowed-endpoints) }}
```

Consequences of the contract:

- **Add hosts to a preset, not to a workflow.** Edit `presets.sh`, run
  `bash scripts/ci/egress/sync-workflow-presets.sh`, commit both. The BATS
  contract test (`tests/bats/integration/test_egress_presets_rendered.bats`)
  and `scripts/ci/actions/validate-harden-runner-action-ref.sh` fail on any
  embedded copy that differs from the render, on any harden-runner block that
  carries a literal host list, and on any block that reads `steps.*`,
  `needs.*` or other non-job-start context.
- Every harden-runner block in a workflow honours the same caller inputs,
  coordinator jobs (`prepare`, `aggregate`, …) included. A few jobs that
  must never be widened by a caller (failure reporters, the Rust release tag
  verification / GitHub release jobs) select a fixed preset:
  `fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal']`.
- `allowed-endpoints` defaults to `""` everywhere. A caller who passes a list
  without `allowed-endpoints-mode: append` opts out of the preset entirely,
  so the list must include the GitHub hosts the job needs (see the
  `github-minimal` preset for the floor).
- An unknown `egress-preset` name selects nothing from the map (the pre hook
  cannot refuse it), so the step right after harden-runner — `Fail on unknown
  egress-preset` — fails the job by name under `block`, before any checkout or
  install can die with an opaque network error. The guard is skipped under
  `audit` and in `replace` mode with a non-empty `allowed-endpoints` (the
  preset is not consulted then).
- Coordinator jobs (`prepare`, `aggregate`, `setup`, `merge`) honour the same
  inputs as the work job. On `main` some of them carried a literal that also
  listed `uploads.github.com:443`; they now select the workflow's preset, which
  omits it — none of those jobs uploads release assets.
- `checkout-and-harden` is a tooling checkout only. It takes no egress inputs
  and produces no allowlist; the former `resolve-egress-allowlist` composite
  and the bundled `.github/actions/harden-runner/` resolver were removed
  because nothing they produced could reach the pre hook.

## Action-only reusables

Some reusables wrap a third-party GitHub Action for a single check. They do
**not** run the full lgtm-ci script suite — only the `checkout-and-harden`
tooling checkout from a sparse lgtm-ci checkout, where they need
`scripts/ci/actions`.

<!-- markdownlint-disable MD013 -->

| Reusable                             | Third-party action                         |
| ------------------------------------ | ------------------------------------------ |
| `reusable-pr-labeler.yml`            | `actions/labeler`                          |
| `reusable-dependency-review.yml`     | `actions/dependency-review`                |
| `reusable-semantic-pr-title.yml`     | `amannn/action-semantic-pull-request`      |
| `reusable-codeql.yml`                | `github/codeql-action/*`                   |
| `reusable-scorecards.yml`            | OpenSSF Scorecard action                   |

<!-- markdownlint-enable MD013 -->

For these workflows:

- Pin the reusable `uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-*.yml@<sha>`
  ref in production.
- `tooling-ref` is **optional** on the action-only wrappers that still expose it
  (labeler, dependency-review, semantic-pr-title, codeql) and pins the
  tooling composite only — not CI scripts. When omitted, those reusables
  resolve their own source through `job.workflow_sha` (the called workflow's
  commit). Setting it emits a deprecation warning; use it only when testing
  unreleased composite changes on a branch.
- `reusable-scorecards.yml` does **not** accept `tooling-ref`: the scorecard
  publish allowlist forbids lgtm-ci composites (#540). Its egress inputs
  (`egress-preset` default `scorecard`, `allowed-endpoints`,
  `allowed-endpoints-mode`) still work because the preset map is a workflow
  literal, not a composite.
- Do **not** assume `tooling-ref` pins the third-party action inside the
  reusable; those actions are pinned by SHA inside the workflow YAML.

`reusable-semantic-pr-title.yml` also sparse-checkouts `scripts/ci/` for small
helper scripts (`prepare-semantic-pr-lists.sh`, `validate-pr-title-length.sh`).
Pass `tooling-ref` when testing unreleased fixes to those helpers.

Script-backed reusables (quality, test-*, validate-*, pr-auto-assign,
release-*, publish-*, etc.) resolve `scripts/ci/` and composites from their own
commit (`job.workflow_sha`), so `tooling-ref` is only needed on GHES or when
testing unreleased tooling from a branch; passing it otherwise emits a
deprecation warning.

### Runner pinning

Script-backed reusables expose `runner-image` on **every** job so callers can
pin OS reproducibility (for example `ubuntu-24.04`). Defaults are
`ubuntu-24.04`; production callers **should** pass an explicit pin.

Multi-arch Docker builds use `runner-map` instead of `runner-image`. Pass a JSON
object mapping platform to runner label (for example
`{"linux/arm64":"ubuntu-24.04-arm"}`). Platforms not in the map default to
`ubuntu-24.04` with QEMU. Coordinator jobs inside the Docker workflow family
(`classify`, `merge`, summaries, scan) stay on fixed `ubuntu-24.04`
coordinators and are not caller-pinnable.

#### Docker workflow family and migration path

Since #381 `reusable-docker.yml` is a thin orchestrator: its `classify` job
resolves the build strategy from `platforms`/`push`/`validate-on-pr` and
`runner-map`, then delegates to the focused reusables. Existing callers keep
working unchanged.

<!-- markdownlint-disable MD013 -->

| Workflow                            | Responsibility                                                         | `runner-map`?                      |
| ----------------------------------- | ---------------------------------------------------------------------- | ---------------------------------- |
| `reusable-docker.yml`               | Orchestrator: classify + delegate (supported entry point)              | Yes (resolved by `classify`)       |
| `reusable-docker-build.yml`         | Single-platform or QEMU multi-platform build + scan (non-split path)   | No (fixed `ubuntu-24.04` + QEMU)   |
| `reusable-docker-multiplatform.yml` | Per-platform matrix build + smoke/health gates + manifest merge + sign | No (takes classify `matrix` input) |
| `reusable-docker-smoke-test.yml`    | Standalone validation of a published image by immutable digest         | No (`runner-image` input)          |

<!-- markdownlint-enable MD013 -->

Migration: callers that only ever hit one path can pin the focused reusable
directly and skip the classify hop — single-platform (or QEMU) consumers call
`reusable-docker-build.yml`; multi-arch consumers that already know their
platform split call `reusable-docker-multiplatform.yml` and pass the matrix
JSON themselves (an array of
`{"platform": ..., "slug": ..., "runner": ..., "qemu": ...}` entries, the
same shape `classify` emits). Post-publish image validation is available
standalone via `reusable-docker-smoke-test.yml`. The staging-tag scheme
(`build-<run_id>-<slug>` children of the release index) is part of the
contract and must not change; the GHCR staging pruner depends on it.

Nested job names: when called through the orchestrator, GitHub prefixes check
names with the delegating job (for example
`<caller-job> / Docker build / Build and Push` or
`<caller-job> / Docker multi-platform / Merge Manifests`). Update branch
protection / merge-queue required checks accordingly when upgrading across
the #381 split.

#### Opt-in runner disk and resource observability

Two boolean inputs (default `false`, so existing callers are unchanged) on
`reusable-docker.yml`, `reusable-docker-build.yml`, and
`reusable-docker-multiplatform.yml`:

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input              | Default | Behavior                                                                                          |
| ------------------ | ------- | ------------------------------------------------------------------------------------------------- |
| `free-disk-space`  | `false` | Before the build, run `scripts/ci/docker/free-disk-space.sh` on `github-hosted` runners only: print `df -h /` before/after and remove unused ubuntu-24.04 amd64 toolchains (`/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, `/usr/local/share/powershell`, and unused `$AGENT_TOOLSDIRECTORY` entries: CodeQL, go, Java_Temurin-Hotspot_jdk, PyPy, Python, Ruby, node). Existence-guarded; no-op on lean/ARM images. |
| `resource-monitor` | `false` | Before the build, start `scripts/ci/actions/resource-monitor.sh start` (30s loop of `date` + `free -m` + `df -h /`, each line prefixed `[resource-monitor]` and teed to stdout plus `$RUNNER_TEMP/resource-monitor.log`). Start is best-effort (`continue-on-error`) so a sampler fault does not skip the image build. Stdout is the kill-case signal: a VM shutdown cancels remaining steps, so the `if: always()` dump of the last ~100 lines only runs when the runner survives. |

<!-- markdownlint-enable MD013 MD060 -->

Scripts resolve from the `.lgtm-ci-tooling` checkout — callers do not vendor
them. Example consumer opt-in:

```yaml
with:
  free-disk-space: true
  resource-monitor: true
```

#### Runner pinning exceptions

These reusables intentionally omit `runner-image`:

<!-- markdownlint-disable MD013 -->

| Reusable                             | Rationale                                              |
| ------------------------------------ | ------------------------------------------------------ |
| `reusable-codeql.yml`                | Action-only wrapper (`github/codeql-action/*`)         |
| `reusable-dependency-review.yml`     | Action-only wrapper                                    |
| `reusable-scorecards.yml`            | Action-only wrapper                                    |
| `reusable-semantic-pr-title.yml`     | Action-only wrapper                                    |
| `reusable-pr-labeler.yml`            | Action-only wrapper                                    |
| `reusable-publish-gem.yml`           | OIDC publish; runner pin under attestation review      |

<!-- markdownlint-enable MD013 -->

Contract enforcement: `scripts/ci/quality/validate-runner-contract.sh` (covered
by BATS). See [reusable-workflows.md](reusable-workflows.md#runner-pinning) for
caller examples including `runner-map`.

### Job timeouts

Every reusable exposes a `timeout-minutes` input (type: number) wired to
`timeout-minutes:` on its primary job so callers can bound runtime. Defaults
are sized per workflow (small API wrappers 5–10, builds/tests 15–60;
scan-style workflows such as CodeQL and Scorecard get larger defaults). Jobs
that compose another reusable via `uses:` rely on the called workflow's own
`timeout-minutes` default instead.

Beyond the caller-facing input, **every job with `runs-on` must declare a
`timeout-minutes`** — either wired to `${{ inputs.timeout-minutes }}` (the
main workload) or a literal cap. Lightweight coordinator legs (matrix
`prepare`/`setup`, result `aggregate`/`merge`/`publish`, and pages-status
jobs) and the failure-reporter legs keep an **independent literal cap**
(`timeout-minutes: 10`): the caller's `timeout-minutes` bounds the main test
job, and lowering it must not silently uncap — or, for reporters, cancel —
these short-running legs. Only jobs that hand off to another reusable via
`uses:` are exempt, because they carry no `runs-on` of their own.

`scripts/ci/quality/validate-runner-contract.sh` enforces both the input's
presence and the per-job cap. It maintains two exception mechanisms mirroring
the runner-image exceptions: `TIMEOUT_MINUTES_EXCEPTIONS` (file-level, exempt
from exposing the input) and `TIMEOUT_PER_JOB_EXCEPTIONS` (job-level, keyed by
`<file>.yml:<job-id>`, exempt from the per-job cap). Both are currently empty;
add an entry here with justification before adding one to the script.

#### Egress policy exceptions

`reusable-publish-rust-release.yml` intentionally omits the `egress-policy`
input. Every job hardcodes `egress-policy: block` and validates the runner
policy at tier `strict`, so callers cannot downgrade release publishing to
`audit`. Callers can still extend the allowlist for the binary build job
through `allowed-endpoints` and `allowed-endpoints-mode`; the tag
verification and GitHub release jobs keep their fixed presets
(`github-minimal` and `github-tooling`) and do not accept caller endpoints.
Contract checks should not flag the missing input.

See [reusable-workflows.md](reusable-workflows.md) (CodeQL build-mode) for
interpreted-language scanning guidance.

## Migration: test summary publishing (#281)

Breaking renames unify test/coverage PR comments behind **`publish-test-summary`**
and dedicated publish reusables. Transport (marker upsert) stays on
`post-pr-comment` action/script.

### Caller inputs and jobs

- `post-pr-comment: true` → `publish-test-summary: true`
- `post-pr-comment: false` → `publish-test-summary: false`
- `coverage-pr-comment: true` (with or without `post-pr-comment`) →
  `publish-test-summary: true` only
- `coverage-pr-comment: false` and `post-pr-comment: true` →
  `publish-test-summary: true`
- Caller job `quality-pr-comment` → `publish-quality-summary`
- `comment-on-failure` on `reusable-validate` → `publish-validation-report`
- `comment-on-pr` on `reusable-link-check` → `publish-link-check-report`

### Reusable workflows and scripts

- `reusable-test-pr-comment.yml` → `reusable-publish-test-summary.yml`
- `reusable-coverage-pr-comment.yml` → `reusable-publish-test-summary.yml`
- `reusable-quality-pr-comment.yml` → `reusable-publish-quality-summary.yml`
- `reusable-artifact-pr-comment.yml` → `reusable-publish-artifact-report.yml`
- `generate-coverage-pr-comment.sh` and `generate-test-comment.sh` →
  `generate-test-summary.sh` with `generate-coverage-comment` for rich tables
- Input `prebuilt-comment-file` → `prebuilt-test-summary-file`
- Input `comment-file` on artifact report reusable → `report-file`
- Validation artifact `validation-comment` → `validation-report`

### Comment body selection

When `publish-test-summary: true` on a language test reusable or
`reusable-coverage`:

- Coverage not requested (`coverage: false` / `coverage-enabled: false`):
  `generate-test-summary.sh` posts pass/fail totals only — **no** Coverage /
  Code Coverage / Coverage Details sections and **no** “Unable to retrieve
  coverage…” warning (disabled coverage must not look like a broken run)
- Coverage collected with a downloadable artifact (Rust LCOV, Python JSON when
  `upload-coverage: true`): `generate-coverage-comment` (rich table)
- Coverage collected without an artifact (e.g. Python with `upload-coverage: false`):
  `generate-test-summary.sh` (pass/fail totals with coverage percent; requires
  `coverage-enabled: true`)
- Coverage requested but the report/percent is missing: totals summary keeps the
  warning-flavored “Unable to retrieve coverage…” UX
- Shell/kcov: totals only (rich table not yet supported); with `coverage: false`
  the coverage block is omitted like other languages

Callers thread `inputs.coverage` (or `true` for `reusable-coverage`) into
`reusable-publish-test-summary.yml` as `coverage-enabled`, which sets
`COVERAGE_ENABLED` for `generate-test-summary.sh`.

Rich coverage comments use `generate-coverage-comment` with an optional
`test-suite-name` input. When set, the visible heading becomes
`## 📊 Code Coverage Report — {test-suite-name}`; `comment-marker` remains the
upsert identity.

### Coverage format integrity (#1078)

`reusable-coverage.yml` keeps the merged report in its input format unless
`output-format` requests another one; LCOV is preserved end-to-end (merge,
threshold, badge, comment). `collect-coverage` checks a detected format
against the file's content before merging and fails by name on a mismatch,
and exits 2 with `unsupported coverage conversion: <src> -> <dst>` when the
requested output has no converter — it never falls through to an empty
report. Line-only LCOV (no `BRF`/`BRH`/`FNF`/`FNH` records) is a supported
input: branch and function coverage are reported as `n/a`, not `0%`, and the
rich comment skips those two thresholds. Coverage stays single-runtime; this
does not reintroduce matrix merging (#756). Artifact names and the
`merged-coverage.json` path for JSON inputs are unchanged; LCOV inputs now
produce `merged-coverage.lcov`.

Node test reusables upload the coverage payload from
`{working-directory}/{coverage-summary-file}` under `coverage-artifact-name`.
Since #1091 that input defaults to empty and resolves to
`<artifact-prefix>-coverage` at both the upload and the publisher, so the
effective defaults are `node-coverage` on `reusable-test-node` and
`node_custom-coverage` on `reusable-test-node-custom` (the prefixes default
to `node` and `node_custom`), and the two cannot collide in one run (see
[reusable-workflows.md](reusable-workflows.md#calling-a-language-test-reusable-twice-in-one-run-1091)).
`publish-test-summary` must pass the same path (including the `working-directory`
prefix when it is not `.`) as `coverage-file` to
`reusable-publish-test-summary.yml` so `download-artifact` resolves the summary
inside `coverage-test-summary/`.

### Compat vs coverage contract (#340)

Rust, Node, and Python test reusables share a **two-mode contract**:

<!-- markdownlint-disable MD013 -- compat/coverage table; column text exceeds default line length -->

| Mode         | Multi-runtime input                   | `coverage` | `publish-test-summary` | PR comment |
| ------------ | ------------------------------------- | ---------- | ---------------------- | ---------- |
| **Compat**   | `*-versions` / `rust-toolchains`      | `false`    | `false`                | none       |
| **Coverage** | single `*-version` / `rust-toolchain` | `true`     | `true` (optional)      | one        |

<!-- markdownlint-enable MD013 -->

Multi-runtime matrix inputs:

- Python: `python-versions` (comma-separated)
- Node: `node-versions` (comma-separated)
- Rust: `rust-toolchains` (comma-separated)

Single-runtime inputs (`python-version`, `node-version`, `rust-toolchain`, or
deprecated Rust `toolchain`) allow `coverage: true` and `publish-test-summary:
true`.

**Enforcement:** `validate-test-compat-coverage-contract.sh` runs in each
reusable `prepare` job and fails when a non-empty multi-version matrix is
combined with `coverage: true` or `publish-test-summary: true`.

**Permissions split:** test/matrix jobs use `contents: read` only; PR comments
run in a separate `publish-test-summary` job (`pull-requests: write`) that
delegates to `reusable-publish-test-summary.yml`.

### `draft-pr-skip`

All language test reusables (`reusable-rust-test`, `reusable-test-python`,
`reusable-test-node`, `reusable-test-node-custom`, `reusable-test-shell`) default
`draft-pr-skip: true` so draft PRs skip test and summary jobs unless callers set
`draft-pr-skip: false`.

### `pipeline-skip`

`reusable-test-python` accepts `pipeline-skip` (default `false`). Callers that
classify a pull request diff as pipeline-irrelevant (docs-only, verified
version-bump PRs) set `pipeline-skip: true` so prepare/test/aggregate/summary
jobs skip **inside** the running reusable. Those jobs still report their
required nested check contexts as skipped — unlike skipping the reusable caller
at the workflow level, which collapses nested contexts and deadlocks merges
(py-lintro#1359). Pair with an always-green `reusable-required-check` gate in
the caller when the org ruleset requires both nested and gate contexts.

### Frozen installs and private git dependencies (#1021)

`reusable-test-python` (and the `setup-python` composite) install with
`uv sync --frozen`. A plain `uv sync` first validates `uv.lock` against
`pyproject.toml`; when the lock is out of date (a version bump that skipped
`uv lock` is the usual cause) it re-resolves the project, and re-resolution
fetches **every** locked git source, including dependency groups the job never
installs. On a cold cache a private host with no credentials fails the install
with `could not read Username for 'https://github.com'`. `--frozen` installs
the committed lock verbatim: only the groups being installed are fetched, and
nothing is re-resolved.

Consequences for callers:

- **Commit `uv.lock` and keep it current.** The workflow does not refresh it;
  run `uv lock --check` in your own CI. A project with `pyproject.toml` but no
  `uv.lock` gets one `uv lock` in the job (with a warning) and then the frozen
  install.
- **Private git dependencies in groups you install** still need credentials.
  Pass the named optional secret `GIT_DEPS_TOKEN`; the workflow configures a
  host-scoped `url.https://<user>:<token>@<host>/.insteadOf https://<host>/`
  rewrite in a dedicated step immediately before the install and removes it
  right after. Both steps are skipped when the secret is empty.
  `git-deps-host` (default `github.com`, lower-cased) scopes the rewrite to
  one host; `git-deps-username` (default `x-access-token`, the username
  GitHub App installation tokens and fine-grained PATs expect) pairs with
  the token. Cleanup removes only entries for that user@host. The token
  must match `[A-Za-z0-9._~-]+`. Between the two steps the rewrite sits in
  the runner's global git config, so a build backend of a dependency being
  built during the install could read it; scope the token to the
  repositories the dependency lives in.
- **The `setup-python` composite** runs the same frozen install but has no
  `GIT_DEPS_TOKEN` path of its own; callers of the composite configure git
  auth in their own step when an installed extra is private.
- **Egress.** The host must be reachable under the job's allowlist.
  `github.com:443` is in the `pypi` preset; any other host goes through
  `allowed-endpoints` with `allowed-endpoints-mode: append`.
- **Never `secrets: inherit`.** The workflow declares exactly one optional
  secret for this purpose and no generic pre-sync hook; a caller forwards the
  token explicitly, scoped to the repositories the dependency lives in.

The workflow selects optional dependencies through `extras`, which maps to
`uv sync --extra`, so a private git dependency the job must install has to
live in a `[project.optional-dependencies]` extra (not a
`[dependency-groups]` group, which `extras` cannot select):

```toml
[project.optional-dependencies]
engine = ["trading @ git+https://github.com/acme/trading@<sha>"]
```

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      actions: read
      contents: read
      pull-requests: write
    with:
      extras: "engine" # the extra that pulls the private git dependency
      git-deps-host: github.com
    secrets:
      GIT_DEPS_TOKEN: ${{ secrets.ENGINE_REPO_TOKEN }}
```

The same frozen discipline applies to every `uv` invocation after the
install: `run-pytest.sh` uses `uv run --frozen`, because a plain `uv run`
re-locks and re-syncs the project on every call and would reintroduce the
cold-cache fetch the install step just avoided.

## Permissions by mode

GitHub validates **all** jobs in a called reusable workflow at parse time,
regardless of job `if:` conditions. Workflows that bundle lint/test/coverage with
optional PR summaries and reports therefore split comment posting into dedicated reusables
(for example `reusable-quality-lint.yml` + `reusable-publish-quality-summary.yml`).
Callers that disable comments or run on tag/release events should invoke the
lint/test/coverage reusable only and omit the publish reusable entirely.

### Direct caller pattern (no orchestrator)

Callers invoke `reusable-quality-lint.yml` and `reusable-publish-quality-summary.yml`
directly — there is no intermediate orchestrator workflow. This produces a single
nesting hop (`ci.yml` → `reusable-quality-lint.yml`) so check names read
`quality / Lintro Quality Checks` instead of `quality / quality / Lintro Quality
Checks`. The pattern matches `reusable-test-python.yml` +
`reusable-publish-test-summary.yml`.

All language test reusables route PR summaries through a single
`publish-test-summary` job → `reusable-publish-test-summary.yml` (no skipped
sibling when `coverage: true`). Node no longer uses inline matrix publish jobs
(#292).

<!-- markdownlint-disable MD013 -- permissions matrix; workflow column lists exceed default line length -->

| Mode                  | Caller permissions                                   | Workflow                                     |
| --------------------- | ---------------------------------------------------- | -------------------------------------------- |
| Quality / lint only   | `contents: read`, `packages: read`                   | `reusable-quality-lint.yml`                  |
| Quality summary       | `contents: read`, `pull-requests: write`             | `reusable-publish-quality-summary.yml`       |
| Test / coverage only  | `contents: read`                                     | Reusables with `publish-test-summary: false` |
| Test / report publish | `contents: read`, `pull-requests: write`             | `reusable-publish-test-summary.yml`,         |
|                       |                                                      | `reusable-publish-artifact-report.yml`       |
| Publish to Pages      | `contents: read`, `pages: write`, `id-token: write`, | Separate publish job; `actions: write`       |
|                       | `actions: write`                                     | clears stale Pages artifacts (#415)          |
| Release version       | `contents: write`, `pull-requests: write`,           | `reusable-release-version-pr.yml`            |
|                       | `actions: read`, `issues: write`                     |                                              |
| Release multi-eco     | `contents: write`, `pull-requests: write`,           | `reusable-release-multi-ecosystem.yml`       |
|                       | `actions: read`, `issues: write`                     |                                              |
| Release auto-tag      | `contents: write`, `actions: read`, `issues: write`  | `reusable-release-auto-tag.yml`              |
| Release failure issue | `actions: read`, `contents: read`, `issues: write`   | `report-release-failure` follow-up job       |
| PyPI upload (OIDC)    | `contents: read`, `id-token: write`                  | `prepare-pypi-upload` + pypa step            |
| PyPI build            | `contents: read`, `id-token: write`,                 | `reusable-build-python-dist.yml`             |
|                       | `attestations: write`                                | (attests `dist/*`; policy section 2)         |
| Build artifact        | `contents: read`                                     | `reusable-build-artifact.yml`                |
| GitHub Release assets | `contents: write`                                    | `reusable-github-release.yml`                |
| SBOM (any mode)       | `contents: read`, `security-events: write`,          | `reusable-sbom.yml`; no job in it requests   |
|                       | `id-token: write`, `attestations: write`             | contents write since #770                    |
| SBOM release upload   | `contents: write`                                    | `reusable-sbom-release-upload.yml`, called   |
|                       |                                                      | by the caller when it attaches assets (#770) |
| Pages report publish  | `contents: read`, `pages: write`,                    | `reusable-publish-test-results-pages.yml`,   |
|                       | `id-token: write`, `actions: write`                  | called by the caller when it publishes (#770)|
| Coverage              | `contents: read`, `pull-requests: write`             | `reusable-coverage.yml` (#770)               |
| E2E matrix            | `contents: read`                                     | `reusable-test-e2e-matrix.yml` (#770)        |

<!-- markdownlint-enable MD013 -->

`reusable-test-node.yml` does not include a publish job. Use
`reusable-test-node-publish.yml` in a separate caller job for Pages publishing.

Contract enforcement: `scripts/ci/docs/validate-caller-permissions.py` (CI job
`caller-permissions`, covered by
`tests/bats/integration/test_validate_caller_permissions.bats`) checks every
`uses: lgtm-hq/lgtm-ci/.github/workflows/<file>.yml` call in `examples/**`,
`docs/**` and `README.md`: the governing `permissions:` block must be a
superset of the called workflow's declared union — its workflow-level block
plus every job-level block, nested calls included, `write` outranking `read`.
A call with no block fails unless the snippet is a fragment marked
`permissions omitted for brevity`; the rule is in
[docs/README.md](README.md#caller-snippets-and-permissions). Print a union
with `--union reusable-test-python.yml`.

### Isolated publish jobs (Pages / coverage badge)

`reusable-test-python-publish.yml` and `reusable-test-node-publish.yml` run in a
**fresh workspace** (separate reusable-workflow job from the test matrix). The
caller repository checkout must initialize `.git` before tooling is added:

1. Harden runner (`uses: step-security/harden-runner@<pinned SHA>` — first step;
   allowlist composed from inputs and the workflow's preset map, see
   [Egress allowlists](#egress-allowlists))
2. Checkout repository (caller repo at workspace root)
3. Checkout lgtm-ci tooling (`.lgtm-ci-tooling/` — sparse-checkout must include
   `checkout-and-harden` and any scripts/actions the job needs)
4. checkout-and-harden (scripts-dir only; it plays no part in egress)
5. Download artifacts, badge generation, GitHub Pages publish (local tooling actions)

Deploy uses official `actions/deploy-pages` (not gh-pages branch push). See
[pages-publishing.md](pages-publishing.md) for permissions, egress, and
multi-publisher limits.

`clean: false` on the repository checkout does **not** help here: without an
existing `.git`, `actions/checkout` wipes the workspace and deletes
`.lgtm-ci-tooling/` if tooling was checked out first. Match
`reusable-build-python-dist.yml` and `reusable-pr-auto-assign.yml`.

## Low-noise Rust and Node checks

Prefer split workflows to avoid skipped checks in PR UI:

| Use case            | Workflow                                                    |
| ------------------- | ----------------------------------------------------------- |
| Rust build only     | `reusable-rust-build.yml` or `reusable-test-rust-build.yml` |
| Rust test (fast)    | `reusable-rust-test.yml` with `coverage: false`             |
| Rust test + cov     | `reusable-rust-test.yml` with `coverage: true`              |
| Node Vitest tests   | `reusable-test-node.yml` (Vitest)                           |
| Node custom command | `reusable-test-node-custom.yml` (required `test-command`)   |

Use separate caller jobs (different `name:` and/or `job-name`) when rulesets
require distinct required checks; the reusable never runs nextest and llvm-cov in
one job.

**Concurrency (#1076).** `reusable-test-rust-build`, `reusable-rust-test` and
`reusable-build-rust-binaries` key their concurrency group on the callee name,
the caller repository, the caller workflow (`github.workflow`) and the ref, so
two caller workflows on one ref (a CI wrapper and a release wrapper, say) no
longer cancel each other. One caller workflow that invokes the same reusable
twice on one ref should give each call a distinct `concurrency-scope` string.
Without it, the build-only and test workflows cancel the first call's
in-progress run when the second starts; the binary build never cancels a
running leg, so the second call queues behind the first, but GitHub keeps
only one pending run per group and may replace a queued binary build with a
newer one before it starts.

**Prerequisite — nextest `ci` profile (#1086).** Both paths run
`cargo nextest run --profile ci` and then parse `target/nextest/ci/junit.xml`,
so the consumer repository must carry `.config/nextest.toml` (under
`working-directory`) with a `ci` profile that emits JUnit. Copy
[`examples/nextest-ci.toml`](../examples/nextest-ci.toml) verbatim. nextest
resolves `junit.path` relative to the profile's store directory
(`target/nextest/ci/`), so the path must be the bare file name `junit.xml`;
a directory-qualified value writes the report under
`target/nextest/ci/target/nextest/ci/` and the parser fails with
`JUnit file not found` after a green test run. Without the file at all the run
fails earlier with `profile 'ci' not found`.

## Node package-manager contract (#1077)

The Node family (`reusable-test-node`, `reusable-test-node-custom`,
`reusable-test-e2e`, `reusable-test-e2e-matrix`, `reusable-test-e2e-playwright`)
takes one `package-manager` input: `npm` (default), `bun`, or `pnpm`. The
value is **never inferred from lockfiles** (#181) and Yarn is not in the
contract. It drives three things in one job:

1. **Toolchain setup** — `actions/setup-node` always; `oven-sh/setup-bun` only
   for `bun`; `pnpm/action-setup` only for `pnpm` (reads the pnpm version from
   the project's `package.json` `packageManager` field). An npm consumer never
   gets Bun on the runner.
2. **Install** — `scripts/ci/actions/setup-package-manager.sh` with
   `FROZEN_LOCKFILE=true`: `bun install --frozen-lockfile`, `npm ci`, or
   `pnpm install --frozen-lockfile`, failing when the matching lockfile is
   absent. No manager touches another manager's lockfile.
3. **Execution** — the runner scripts `run-vitest.sh`, `run-playwright.sh`,
   and `run-lighthouse.sh` dispatch through `scripts/ci/lib/node/pm.sh`
   (`pm_run`, `pm_exec`, `pm_add_dev`, `pm_has`). `pm_exec` only runs
   binaries already in the project tree (`bun x --no-install <bin>`,
   `npx --no-install <bin>`, `pnpm exec <bin>`) and never installs a missing
   one (npx may still query the registry to resolve the name before it
   refuses, so under an egress block a missing binary can surface as a
   network error); an empty `PACKAGE_MANAGER` fails with
   `package-manager is required for execution actions`.

**Test tooling is a consumer prerequisite.** The runners never install into
the project: `vitest` (plus `@vitest/coverage-v8` or
`@vitest/coverage-istanbul` when `coverage: true`), `@playwright/test`, and
`@lhci/cli` (unless `lhci` is already on `PATH`) must be devDependencies in
the committed lockfile, or the setup step fails naming the package to add.

The same inputs exist on the direct composites `run-vitest`, `run-playwright`,
and `run-lighthouse`, where `package-manager` is **required** and
`install-dependencies` (default `true`) runs the frozen install before the
tests. The generic `run-tests` composite forwards an optional
`package-manager` to its Vitest/Playwright branches.

The direct composites do **not** cache dependencies: the Bun/`node_modules`
cache that the former `setup-node` nesting restored is gone, deliberately —
one composite cannot key a cache correctly for three managers, and npm/pnpm
never had one there. Callers that want install caching should either call
`reusable-test-node.yml` / `reusable-test-node-custom.yml` (which keep their
Bun cache; the e2e reusables go through `run-playwright` and only cache
Playwright browsers) or add their own `actions/cache` step in front and pass
`install-dependencies: "false"`.

### Migration (#1077)

- `reusable-test-e2e.yml` and `reusable-test-e2e-matrix.yml` now honour
  `package-manager` (default `npm`). Before #1077 the e2e path always ran
  Bun regardless of the input, so a Bun project that never set it must now
  pass `package-manager: bun` or the frozen `npm ci` fails for want of a
  `package-lock.json`.
- The direct `run-vitest`, `run-playwright`, `run-lighthouse` composites
  require `package-manager`; `run-tests` needs it whenever the vitest or
  playwright runner is selected.
- Test tooling (`vitest`, a coverage provider, `@playwright/test`,
  `@lhci/cli`) must be a committed devDependency; nothing is installed.

### Tested runtime matrix

<!-- markdownlint-disable MD013 -- matrix table -->

| Runtime | Default                                                        | Tested                                         | Source of truth                                                                          |
| ------- | -------------------------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Node    | `node-version: "22"` (active LTS)                              | 22, 24                                         | `actions/setup-node`; override per call or via `node-versions` for a compat matrix       |
| Bun     | exact pin (`# renovate: datasource=npm depName=bun`), no `latest` | the pinned release                             | `bun-version` default in the e2e reusables and the three composites; grouped by Renovate |
| npm     | bundled with the Node release                                  | npm 10 (Node 22), npm 11 (Node 24)             | `actions/setup-node`                                                                     |
| pnpm    | `packageManager` field in the consumer's `package.json`        | pnpm 9 and 10 (via `pnpm/action-setup`/Corepack) | `pnpm/action-setup`                                                                      |

<!-- markdownlint-enable MD013 -->

The external fixture `TurboCoder13/lgtm-ci-consumer-fixture` runs
`node-npm.yml`, `node-bun.yml`, and `node-pnpm.yml` against one project that
carries all three lockfiles, and each ends with
`test -z "$(git status --porcelain)"` so a runner that writes another
manager's lockfile fails the fixture.

## Job display names

GitHub can render unevaluated `job.name` expressions in the checks UI when a job
is skipped by `if:`. lgtm-ci uses a **hybrid** policy (issue #168 §12):

<!-- markdownlint-disable MD013 -->

| Pattern                | When                                                      | Check name behavior                                                   |
| ---------------------- | --------------------------------------------------------- | --------------------------------------------------------------------- |
| **Split reusables**    | Consumer-facing modes (Vitest vs custom Node)             | Matching workflow only; `job-name` drives test check name.            |
| **`job-name` input**   | Always-run jobs (quality, publish, Rust test, split Node) | Caller passes the visible check label.                                |
| **Static inner names** | Internal matrix legs (Python, Docker, E2E)                | Fixed labels; GitHub appends matrix suffix. Brand via caller `name:`. |

<!-- markdownlint-enable MD013 -->

Contract enforcement: `scripts/ci/quality/validate-static-job-names.sh` (also
covered by BATS). Do not use `matrix.`, `format(`, or ternary `&& … ||`
expressions in `job.name` on jobs that have `if:`. Documented exceptions live
in that script; `reusable-test-shell.yml` `test-sharded` and `aggregate` are
excepted so coverage shards can use derived names while the fan-in job keeps
the caller `job-name` required-check context (#874). Sharded TAP/coverage
artifacts include `inputs.comment-marker` so two workflow calls in one run
cannot mix load-bearing fan-in inputs.

### Tooling sparse-checkout

When a reusable workflow job invokes a script-backed composite from
`.lgtm-ci-tooling/.github/actions/`, the job's `Checkout lgtm-ci tooling` step
must sparse-checkout `scripts/ci/` alongside `.github/actions/` (cone mode).

Contract enforcement: `scripts/ci/quality/validate-tooling-sparse-checkout.sh`
(covered by BATS).

**Node testing:** Vitest callers use `reusable-test-node.yml` with `job-name`.
Custom package scripts use `reusable-test-node-custom.yml` with required
`test-command` and `job-name`.

## Org ruleset check names

Reusable workflows report checks as **`caller_job_id / inner_job_name`**. Org
rulesets **must require that exact prefixed path** for every `uses:` gate —
the inner `job-name` alone is never sufficient. Inline `runs-on` jobs are the
only unprefixed contexts: the ruleset matches their `name:` directly (for
example `🔐 Security Audit`). A ruleset that requires an unprefixed name for a
`uses:` gate leaves the PR stuck on **Expected** while Actions shows the green
prefixed check.

The registry of org rulesets, their GitHub ids, and the exact required
contexts lives in [org-rulesets.md](org-rulesets.md), together with the
export/sync tooling under `scripts/ci/org/`. When a check name must change,
update the org ruleset to the new `{caller_job_id} / {job-name}` path in the
same change.

**Aggregate gate:** The matrix test reusables (`reusable-test-python.yml`,
`reusable-rust-test.yml`, `reusable-test-node.yml`,
`reusable-test-node-custom.yml`) fail their `Aggregate … Results` job whenever
the tests did not pass, so that context (for example
`test / Aggregate Python Results`) is a valid required check on its own (#1058).
It fails closed rather than skipping, because a ruleset treats a skipped
required check as passing:

- a failed or cancelled matrix leg, or missing / empty matrix summaries;
- a failed or cancelled `prepare` job (the matrix never ran);
- single-version calls (`python-version` / `rust-toolchain` with an empty
  `python-versions` / `rust-toolchains`) are gated too, on the test job result
  alone. The summary download is matrix-only, because a second call in the
  same run can upload summaries under the same artifact names.

The job is skipped only on the explicit skip paths: a draft PR with
`draft-pr-skip`, and `pipeline-skip` (Python). The job still exposes the
`passed` output for callers that combine it with other jobs.

### Matrix legs and check-run names

The context a ruleset sees is `{caller_job_id} / {inner job name}`, and the
inner name is the called job's `name:` rendered verbatim. GitHub appends the
matrix values as a `(…)` suffix only when a matrix job's `name:` contains no
`${{ }}` expression (or is absent). The test and build reusables name their
work jobs `${{ inputs.job-name }}`, an expression, so a matrix call
(`python-versions`, `node-versions`, `rust-toolchains`,
`reusable-build-artifact.yml`'s `matrix`) produces **one check run per leg
under one shared name**, with no per-leg suffix: `python-versions:
"3.12,3.13"` under caller job `compat` reports two check runs both named
`compat / Python Compat` (observed on the external fixture, #1074; the same
shape #623 recorded for `build / 🏗️ Build & Quality Checks` on
turbo-themes#598). The only way a leg value reaches such a context is the
caller putting it in `job-name` itself. The Docker per-platform jobs in
`reusable-docker-multiplatform.yml` use literal names (`Docker build per
platform`, `Docker verify per platform`, `Docker health check per platform`),
so their legs **do** carry the platform values as a suffix.

When several check runs on the head commit share a required name, GitHub
evaluates the most recently created one (see
[Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)):
a failing leg can be masked by a later passing leg, and re-running one leg
replaces the verdict. Require a matrix work context directly only when every
leg is green by construction; otherwise require the gate that fails closed —
the `Aggregate … Results` job of the matrix test reusables (#1058), or a
`reusable-required-check.yml` caller job fed by `needs.<job>.result` for
`reusable-build-artifact.yml`, whose only jobs are `prepare` and `build`.
Callers migrating from bespoke suffixed contexts (`… (20)` / `… (22)`) must
require the unsuffixed name; the suffixed form never appears. Check names are
deployment interfaces (#461, #796): nothing here renames a check, and the
reusables will not add per-leg names without a migration.

When a single ruleset context should summarize **multiple** work jobs, add a
thin caller job that calls `reusable-required-check.yml` instead of
hand-rolled `runs-on` shims. The gate itself is a `uses:` job, so
the ruleset must require its prefixed path too (below:
`test-suite-coverage / 🧪 Test Suite & Coverage`). Pass `upstream-result` and
optional `passed-output` / `status-output` from the work job. Use `always()`
on the caller job so the gate still runs when the upstream job fails.

*Fragment: permissions omitted for brevity, not copyable as-is. See
[Permissions by mode](#permissions-by-mode).*

```yaml
test:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
  with:
    job-name: Python Compatibility

test-suite-coverage:
  needs: test
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@<sha>
  with:
    job-name: "🧪 Test Suite & Coverage"
    upstream-result: ${{ needs.test.result }}
    passed-output: ${{ needs.test.outputs.passed }}
```

Do not add per-consumer `job-name` aliases inside work reusables.

## Harden-runner distribution

<!-- markdownlint-disable MD013 -->

Egress **enforcement** requires a **direct** remote
`step-security/harden-runner@<pinned SHA>` workflow step. GitHub skips `pre`/`post`
hooks for workspace-local actions and for actions nested inside composites, and
step-security installs its monitoring agent only in `pre` (v2.20.0).

`allowed-endpoints` is composed from workflow **inputs** and the workflow's
literal preset map (`env.LGTM_CI_EGRESS_PRESETS`) — never `steps.*.outputs`,
which are empty when `pre` runs. See [Egress allowlists](#egress-allowlists)
for the expression and the generator. No lgtm-ci composite takes part in
enforcement; hardening is always the remote step-security action.

Do **not** use `lgtm-hq/lgtm-ci/.github/actions/...@\${{ }}` in `steps[*].uses` —
GitHub does not allow expressions in action `@ref` segments
([runner#895](https://github.com/actions/runner/issues/895)).

Most reusable workflows call step-security directly as the first step, then use
the shared `checkout-and-harden` composite (#379) to check out tooling:

```yaml
- name: Checkout repository
  uses: actions/checkout@<pin> # v7.0.0
  with:
    persist-credentials: false

- name: Checkout lgtm-ci tooling
  uses: actions/checkout@<pin> # v7.0.0
  with:
    # job.workflow_* identify the repository and commit of the workflow file
    # that defines this job — the reusable itself, not the caller (#995).
    # The final 'tooling-ref-required' fallback makes checkout fail loudly on
    # GHES (no job context) when the caller omits tooling-ref, instead of
    # fetching the tooling default branch.
    repository: ${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha || 'tooling-ref-required' }}
    sparse-checkout: |
      .github/actions/checkout-and-harden
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Harden runner
  uses: step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1 # v2.21.1
  with:
    egress-policy: ${{ inputs.egress-policy }}
    # Composed from inputs and the literal map in env only: harden-runner's
    # pre hook runs before any step, so nothing computed later can reach it.
    allowed-endpoints: >-
      ${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '')
      && inputs.allowed-endpoints
      || format('{0} {1}',
      fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'github-tooling'],
      inputs.allowed-endpoints) }}

- name: Checkout and harden
  id: egress
  uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
  with:
    # The composite never infers its source; pass the resolved ref, the
    # repository (with the GHES fallback) and the raw override for the warning.
    tooling-ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || job.workflow_sha }}
    tooling-repository: ${{ job.workflow_repository || 'lgtm-hq/lgtm-ci' }}
    tooling-ref-override: ${{ inputs.tooling-ref }}
    sparse-checkout-extra: |
      scripts/ci/
```

Workflows that cannot use the composite (the release workflows
`reusable-release-auto-tag`, `reusable-release-version-pr`,
`reusable-release-multi-ecosystem`; the tiered Rust workflows
`reusable-build-rust-binaries`, `reusable-publish-rust-release`; the
bootstrap/fallback flow in `reusable-validate-lintro-version`) use the same
harden-runner block — the allowlist never depends on the tooling checkout.

Pin the reusable workflow `uses:` line to a commit SHA in production. Reusables
locate their own tooling through `job.workflow_repository` / `job.workflow_sha`,
so `tooling-ref` is no longer needed; passing it emits a deprecation warning and
is reserved for testing unreleased tooling on a branch. Never derive the tooling
ref from the `github` context: inside a called workflow it belongs to the caller
(#995). The `job.workflow_*` properties are GitHub.com only; on GHES the
repository falls back to `lgtm-hq/lgtm-ci` and callers must pass `tooling-ref`
explicitly.

Callers may still pin **other** lgtm-ci composites with
`lgtm-hq/lgtm-ci/.github/actions/foo@<static-sha>` from their own workflow files;
that pattern does not apply inside reusable workflow steps that need dynamic refs.

### Release workflows (`reusable-release-auto-tag`, `reusable-release-version-pr`, `reusable-release-multi-ecosystem`)

`reusable-release-auto-tag` uses **two** lgtm-ci checkouts:

1. **Bootstrap tooling** (before the GitHub App token) — sparse-checkout
   `scripts/ci/` for the tooling-ref resolution and deprecation-warning
   scripts.
2. **Scripts tooling** (after `create-github-app-token` and the full repository
   checkout) — sparse-checkout `scripts/ci/` again with the app installation
   token.

`reusable-release-version-pr` and `reusable-release-multi-ecosystem` need no
tooling before the App token and check out `scripts/ci/` once, after it. (Their
former pre-token checkout only fed the removed egress resolver.)

Both version-PR reusables split on privilege (#849): `prepare` and
`version-pr` mint the App token and run lgtm-ci code only; the caller's
`version-update-script` runs in `version-update-hook` (`contents: read`, no
secrets, no token) and its edits reach `version-pr` as a scope-checked diff
artifact. `version-pr` carries `needs: [prepare, version-update-hook]` with
an `if:` that only propagates dependency failure, which is why
`reusable-release-multi-ecosystem.yml:version-pr` (dynamic `job-name`) is an
exception in `validate-static-job-names.sh`. Contract:
`tests/bats/integration/test_reusable_release_hook_isolation.bats`. See
[reusable-workflows.md](reusable-workflows.md#version-update-hook-version-update-script).

Keep `Create GitHub App installation token` before any step that uses
`steps.app-token.outputs` (actionlint enforces step order). Every mint passes
`repositories: ${{ github.event.repository.name }}`.

**Egress (#1093):** both version-PR reusables default to
`egress-preset: release-version-pr` — `github-tooling` plus the registries the
ecosystem bump scripts reach under `block`: `pypi.org` /
`files.pythonhosted.org` (`ecosystems: python` and kind `pep621` run
`pip install tomlkit` when the runner lacks it) and `static.rust-lang.org` +
the crates.io hosts (`ecosystems: rust` installs the toolchain and regenerates
`Cargo.lock`). Selecting an ecosystem is therefore enough; the pre-#913 advice
to paste the PyPI hosts into `allowed-endpoints` is obsolete. Callers that
pinned `egress-preset: github-tooling` explicitly (the previous starter
example) keep that narrower baseline and must switch to `release-version-pr`
or drop the input. Callers that still pass `allowed-endpoints` in the default
`replace` mode substitute their list for the preset and must carry those
registry hosts themselves; `append`-mode callers without an explicit
`egress-preset` now merge onto `release-version-pr` instead of
`github-tooling` (pin `egress-preset: github-tooling` to keep the old base).

**First release without a `CHANGELOG.md` (#1092):**
`scripts/ci/release/update-changelog.sh` no longer fails when the file is
absent. It seeds a Keep a Changelog header with an empty `## [Unreleased]`
section, registers the file with `git add --intent-to-add` (so
`check-version-files-changed.sh` sees an added path rather than an ignored
`??` entry), and writes the first release section into it; the file lands in
the same version PR as its first entry. Contract:
`tests/bats/integration/test_update_changelog.bats`.

<!-- markdownlint-enable MD013 -->

Canonical preset definitions live in `scripts/ci/lib/egress/presets.sh`;
after editing them run `bash scripts/ci/egress/sync-workflow-presets.sh` so
every reusable's embedded map matches (the BATS contract test fails otherwise).

Do **not** use `.lgtm-ci-egress` sparse checkouts for the composite.

### Runner policy tiers {#runner-policy-tiers}

Reusable workflows that support multi-platform or release builds declare a **tier**
via `validate-runner-policy` after the job-start `harden-runner` step.
Consumers cannot override the tier — it is baked into the reusable contract.

<!-- markdownlint-disable MD013 MD060 -->

| Tier         | `block` on GH Linux | `block` on GH Win/macOS | `block` on self-hosted | `audit` (any) |
| ------------ | ------------------- | ----------------------- | ---------------------- | ------------- |
| `strict`     | Enforce             | Hard fail               | Enforce                | Hard fail     |
| `hardened`   | Enforce             | Skip + warn             | Enforce                | Hard fail     |
| `permissive` | Enforce (advisory)  | Skip + log              | Skip + log             | Skip          |

**Egress capabilities** ([StepSecurity harden-runner](https://github.com/step-security/harden-runner)):

| Runner type                  | `egress-policy: block` |
| ---------------------------- | ---------------------- |
| GitHub-hosted Linux          | Supported              |
| GitHub-hosted Windows/macOS  | Audit only today       |
| Self-hosted (agent in image) | Supported on any OS    |

<!-- markdownlint-enable MD013 MD060 -->

New reusables start with the direct `step-security/harden-runner@<pinned SHA>`
step (its `if:` gates the platforms the tier supports), then call
`validate-runner-policy` to hard-fail or warn per the table above.

**Usage guidance:**

- `strict` — Rust CLI releases, Node/Python CI, Docker builds (Linux-only matrices)
- `hardened` — Native desktop verification (Tauri, Electron), weekly native test legs
- `permissive` — Exotic builds (iOS/Xcode, Android signing); document justification
  in the workflow YAML

```yaml
- name: Validate runner policy
  id: policy
  uses: ./.lgtm-ci-tooling/.github/actions/validate-runner-policy
  with:
    tier: hardened
    egress-policy: block
    runner-environment: ${{ runner.environment }}
    runner-os: ${{ runner.os }}

- name: Harden runner
  if: steps.policy.outputs['enforce-egress'] == 'true'
  uses: step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1 # v2.21.1
  with:
    egress-policy: block
    allowed-endpoints: ${{ inputs.allowed-endpoints }}
```

### Rust release contract

`reusable-build-rust-binaries.yml` (tier `strict`) cross-compiles from Linux
runners under block mode. `reusable-publish-rust-release.yml` orchestrates
tag verification → binary build → GitHub release.

**Default target matrix (v1):** `x86_64-unknown-linux-musl` (`builder: native`),
`aarch64-unknown-linux-gnu` (`builder: cross`), `x86_64-pc-windows-msvc`
(`builder: xwin`). Darwin targets are excluded from the default matrix; pass a
JSON `targets` override for unsigned macOS binaries.

#### Windows targets and runner tiers

Every `targets` entry names its builder: `{"target": ..., "builder":
"native|cross|xwin", "archive": ...}`. The legacy `"cross": true` key still
selects `cross`. `scripts/ci/release/build-rust-binary.sh` validates the pair
before cargo runs and exits 2 with
`cross cannot build MSVC targets; use builder=xwin or a native Windows runner`
for `cross` + `*-msvc`; `xwin` is accepted only for `*-pc-windows-msvc`. The
previous default paired `x86_64-pc-windows-msvc` with `cross`, which ships no
MSVC toolchain and never compiled (#1076).

<!-- markdownlint-disable MD013 MD060 -- wide tier table -->

| Tier (strict Linux unless noted) | Target / builder                                   | What it proves                                                                                   |
| -------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Default                          | `x86_64-pc-windows-msvc` / `xwin` on `ubuntu-24.04` | Block-mode egress, digest-verified `cargo-xwin`, attested archive; the consumer fixture's `rust-release-build.yml` executes the `.exe` on `windows-latest` on every lgtm-ci pin (#1076) |
| Alternative, strict              | `x86_64-pc-windows-gnu` / `cross`                  | MinGW binary from the `cross` Docker image; no Microsoft SDK download                            |
| Opt-in, hardened (`reusable-build-artifact.yml`) | `x86_64-pc-windows-msvc` / `native` on `windows-latest` via `runner-map` | Native MSVC link; `harden-runner` cannot block egress on Windows, so the leg runs without block-mode egress and is never the silent default (#313) |

<!-- markdownlint-enable MD013 MD060 -->

`xwin` builds run under the `rust-release` preset, which allows `aka.ms:443`
and `download.visualstudio.microsoft.com:443` for the Windows SDK and CRT
manifest and payloads. The SDK cache (`~/.cache/cargo-xwin`) is restored from
the Actions cache keyed on the `cargo-xwin` pin, and the build restricts the
download to the target's architecture (`XWIN_ARCH` derived from the target
triple; export it to override). `cargo-xwin` itself is pinned in
`scripts/ci/versions.env` and installed from a release archive whose sha256 is
committed there (`scripts/ci/release/install-cargo-xwin.sh`).

`reusable-build-rust-binaries.yml` is strict-only: its tier is baked in and
`validate-runner-policy` hard-fails on a GitHub-hosted Windows runner, so it
cannot run a native Windows leg at all. The native tier is a deliberate,
separate call to `reusable-build-artifact.yml` (tier `hardened`) with
`toolchain: rust`, a `matrix` entry for `x86_64-pc-windows-msvc` and a
`runner-map` that sends it to `windows-latest`; see the Rustume example in
[reusable-workflows.md](reusable-workflows.md). Switching this reusable's
default to a native leg needs an owner decision recorded in the PR that makes
it.

Caller `build-script` overrides should read `BUILDER` (`native`, `cross` or
`xwin`); `USE_CROSS` is still exported, and is `true` whenever the effective
builder is `cross`, whichever key selected it.

**Artifact naming:** `{artifact-prefix}-{target}` per matrix leg. Each artifact
contains `{package}-{version}-{target}.tar.gz` or `.zip` with the binary at the
archive root (`cargo-binstall` compatible) plus a `SHA256SUMS` manifest.

*Fragment: permissions omitted for brevity, not copyable as-is. See
[Permissions by mode](#permissions-by-mode).*

```yaml
release:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-rust-release.yml@<sha>
  with:
    tooling-ref: "<sha>"
    packages: "my-cli,my-server"
```

### Release failure reporting

What a release must guarantee before and after its first irreversible publish,
and how a partial release is recovered, is defined by the
[release security policy](release-security-policy.md); this section covers how
a failure is reported.

Both release reusables include an optional `report-release-failure` follow-up job
that runs when the primary job fails (`needs.<job>.result == 'failure'`). The
job uses `egress-preset: github-minimal` (GitHub API only) and declares its own
`actions: read`, `contents: read`, and `issues: write` permissions. Callers
must grant at least `actions: read` and `issues: write` on the reusable-workflow
call job (in addition to the primary release permissions above) or GitHub rejects
the workflow at startup.

<!-- markdownlint-disable MD013 -->

| Input                   | Default                                    | Purpose                                       |
| ----------------------- | ------------------------------------------ | --------------------------------------------- |
| `report-failures`       | `true`                                     | Opt out when the repo handles alerting itself |
| `failure-issue-labels`  | `bug,ci,release,automation,infrastructure` | Labels on auto-opened failure issues          |
| `failure-target-branch` | *(empty → repository default branch)*      | Branch filter for issue notifications         |

<!-- markdownlint-enable MD013 -->

Failure issues deduplicate by deterministic issue title
(`fix(release): release automation failed on <branch> (<workflow-key>)`), then
fall back to a visible tracking key footer
(`release-automation-failure:<workflow-key>:<branch>`). A hidden HTML comment
marker is retained for backward compatibility. Recurring failures add comments
to the same open issue.

### Tag publish failure reporting (release mode)

Every workflow performing an irreversible publish from a tag MUST end with the
release-mode notifier, `reusable-release-failure-notifier.yml`
(`## Closes #964`). The branch-keyed reporting above is silent on tag runs:
`GITHUB_REF_NAME` is the tag, so the branch gate never matches. The
release-mode notifier bypasses the gate and deduplicates by tag instead. Wire
one call with `needs` covering every publish job and `if: always()` (see
`examples/publish-python-release.yml`); the job grants itself only
`actions: read`, `contents: read`, and `issues: write` — publish jobs keep
their least-privilege sets.

<!-- markdownlint-disable MD013 -->

| Input                  | Default                                    | Purpose                                                          |
| ---------------------- | ------------------------------------------ | ---------------------------------------------------------------- |
| `workflow-key`         | *(required)*                               | Stable key namespacing the dedup marker and issue title          |
| `tag`                  | *(required)*                               | Tag whose publish is reported (usually `github.ref_name`)        |
| `channels`             | `[]`                                       | JSON of publish-job results; `toJson(needs)` works directly      |
| `max-reruns`           | `0`                                        | Opt-in; match the auto-rerun input only when it is wired         |
| `signatures`           | *(empty)*                                  | Extra infra signatures; pass the auto-rerun reusable's value     |
| `failure-issue-labels` | `bug,ci,release,automation,infrastructure` | Labels on auto-opened failure issues (missing labels skipped)    |

<!-- markdownlint-enable MD013 -->

Behavior: every channel `success`/`skipped` comments on and closes the tag's
issue; a failure on an attempt within `max-reruns` whose failed-job logs match
an infra signature (the same classifier as the auto-rerun reusable) stays
quiet; otherwise it files or updates one issue titled
`fix(release): tag publish failed: <tag> (<workflow-key>)` with tracking key
`release-failure:<workflow-key>:<tag>` and a channel/result/job-link/probe
table (a channel without a job URL links to the run). Suppression is opt-in:
with the default `max-reruns: 0` every failure files, because a caller that
has not wired `reusable-auto-rerun-on-infra-failure.yml` has nothing that
would re-run. The log fetch behind the classification is bounded
(`GH_CMD_TIMEOUT`, `LOG_FETCH_DEADLINE`, as in the auto-rerun script) and an
unclassifiable failure files with a `reason` that the issue summary states.
The issue body names the recovery tier per the
[release security policy](release-security-policy.md); a later successful
attempt or recovery run closes it.

### Cargo auto-tag contract

`reusable-release-auto-tag.yml` supports Rust monorepos that tag from
`Cargo.toml` workspace versions instead of parsing `chore(release): version`
from the commit subject.

<!-- markdownlint-disable MD013 MD060 -->

| Input               | Default      | Purpose                                              |
| ------------------- | ------------ | ---------------------------------------------------- |
| `version-source`    | `commit`     | `commit` (default) or `cargo`                        |
| `version-file`      | `Cargo.toml` | Manifest path for workspace/package version          |
| `skip-if-unchanged` | `false`      | Skip when version matches the latest `tag-prefix` tag |

<!-- markdownlint-enable MD013 MD060 -->

Flow when `version-source: cargo`:

1. `guard-release-commit` — common; proceed only on `chore(release):` commits
2. `read-cargo-version.sh` — cargo-specific; read semver from `version-file`
3. `detect-previous-tag-version.sh` — conditional (`skip-if-unchanged: true`);
   read latest `tag-prefix` version
4. `check-version-unchanged.sh` — conditional (`skip-if-unchanged: true`);
   skip tagging when versions match
5. `create-tag.sh` — common; create and push the annotated tag

Callers should filter `on.push.paths` to the manifest (for example `Cargo.toml`)
and set `create-release: false` when release assets are published separately.

### Multi-ecosystem release contract

`reusable-release-multi-ecosystem.yml` extends the release-version-pr family for
repos that bump **explicit file paths** across ecosystems in one version PR
(reference consumer: turbo-themes). It reuses `scripts/ci/release/*` (guard,
changelog, App-token PR creation, merge-queue skip, failure reporting) and
adds a file→kind manifests runner under `scripts/ci/release/ecosystems/`.

**Decision (extend vs new):** shipped as a **sibling** reusable rather than
overloading `reusable-release-version-pr.yml`. The existing workflow is
ecosystem-CSV + layout defaults (`node,ruby,python`); multi-ecosystem needs a
required `manifests` JSON map (`npm|raw|gemspec|pep621`), `bump`
(`auto-from-commits` \| `explicit`), and `prerelease-tag`. Sharing scripts keeps
one release family; a separate workflow keeps the consumer contracts clear.

<!-- markdownlint-disable MD013 MD060 -->

| Input             | Default              | Purpose                                                         |
| ----------------- | -------------------- | --------------------------------------------------------------- |
| `manifests`       | *(required)*         | JSON object: file path → kind (`npm`, `raw`, `gemspec`, `pep621`) |
| `bump`            | `auto-from-commits`  | Or `explicit` with `version`                                    |
| `version`         | *(empty)*            | Semver when `bump=explicit` (optional `v` prefix)               |
| `prerelease-tag`  | *(empty)*            | Appended as `-<tag>` (e.g. `rc.1` → `1.2.3-rc.1`)               |
| `changelog`       | `true`               | Generate/update `CHANGELOG.md` via existing release scripts     |
| `job-name`        | `Create Version PR`  | Visible check name                                              |
| `tooling-ref`     | *(workflow SHA)*     | Pin lgtm-ci scripts/actions                                     |

<!-- markdownlint-enable MD013 MD060 -->

**Runner policy:** same two-checkout harden path as `reusable-release-version-pr`
(GitHub-hosted Linux under `egress-policy: block` with `egress-preset:
release-version-pr` by default). Failure reporting uses workflow key
`release-multi-ecosystem` and the shared `report-release-failure` job (see
[Release failure reporting](#release-failure-reporting)).

Kinds update only the listed path: `npm` → `package.json` `.version`; `raw` →
plain-text `VERSION`; `gemspec` → literal `.version = "..."` in a `.gemspec`
(constant-backed gemspecs need `version-update-script` / `version.rb`);
`pep621` → `[project].version` only (no `__init__.py` / `uv.lock`).
`pep621` installs `tomlkit` from PyPI when the runner lacks it; the default
`release-version-pr` preset already allows `pypi.org:443` and
`files.pythonhosted.org:443`, so no caller allowlist is needed (#1093).
Callers that pass their own `allowed-endpoints` in `replace` mode must include
those two hosts themselves.

## Egress presets

Reusable workflows default to `egress-policy: block` and
`allowed-endpoints-mode: replace`. Presets are defined in
`scripts/ci/lib/egress/presets.sh` and reach harden-runner's pre hook as the
literal map described in [Egress allowlists](#egress-allowlists); since #913
`egress-preset` and `allowed-endpoints-mode` are **enforced**, not advisory.

### Pre-enforcement history (v0.50.0 → #913)

From [#467](https://github.com/lgtm-hq/lgtm-ci/issues/467) (v0.50.0) until
issue #913, reusables fed the caller's `allowed-endpoints` **verbatim** to the
job-start `step-security/harden-runner` step and resolved presets in a later,
non-enforcing step. A non-empty caller list therefore replaced the baseline
even under `append`, and `egress-preset` changed nothing (upgrade incidents
during org-wide v0.52.3 adoption,
[#510](https://github.com/lgtm-hq/lgtm-ci/issues/510):
[homebrew-tap#126](https://github.com/lgtm-hq/homebrew-tap/pull/126),
[podex#152](https://github.com/lgtm-hq/podex/pull/152),
[Rustume#385](https://github.com/lgtm-hq/Rustume/pull/385),
[turbo-themes#526](https://github.com/lgtm-hq/turbo-themes/pull/526),
[py-lintro#1281](https://github.com/lgtm-hq/py-lintro/pull/1281)). The
composition now happens inside the harden-runner step, so the table below is
what the agent enforces.

`step-security/harden-runner` splits `allowed-endpoints` on **spaces**. A
newline-separated `|` literal block (the common multiline YAML style) was
observed to be treated as one unrecognised token, blocking **all** egress
including the checkout (#510 incidents above). Use a folded scalar (`>-`) with
space-separated `host:port` tokens. The generated preset map is space-separated
for the same reason.

| Mode      | Enforced allowlist                                                                 |
| --------- | ---------------------------------------------------------------------------------- |
| `replace` | Non-empty `allowed-endpoints` is used alone; empty `allowed-endpoints` uses preset |
| `append`  | Preset + `allowed-endpoints`                                                       |

Use `append` to keep lgtm-ci defaults and add project-specific hosts. Empty
`allowed-endpoints` under either mode means preset-only. `audit` mode logs the
same list without blocking.

<!-- markdownlint-disable MD013 -->

| Preset               | Use case                                                                         |
| -------------------- | -------------------------------------------------------------------------------- |
| `github-minimal`     | PR summaries and reports (API, tooling checkout, workflow artifacts)             |
| `github-results`     | `github-minimal` + results blob storage (`reusable-auto-rerun-on-infra-failure`) |
| `github-tooling`     | Validate action pinning + GitHub raw/codeload/release-assets                     |
| `github-pages`       | GitHub Pages deploy/publish (OIDC)                                               |
| `docker`             | Docker build/pull/push (`reusable-docker.yml`)                                   |
| `playwright`         | Playwright E2E + browser CDN downloads (`reusable-test-e2e*.yml`)                |
| `pypi`               | PyPI/TestPyPI publish and availability checks                                    |
| `python-dist`        | `pypi` + Sigstore attestation (`reusable-build-python-dist.yml`)                 |
| `rubygems`           | RubyGems publish                                                                 |
| `npm-publish`        | npm OIDC trusted publish + Sigstore + artifact download                          |
| `quality`            | Docker `lintro chk` (default on quality lint, Node/Rust tests)                   |
| `build-artifact`     | Every vetted toolchain's registry (`reusable-build-artifact.yml`)                |
| `shell-test`         | `github-tooling` + Ubuntu apt mirrors (`reusable-test-shell.yml`)                |
| `sbom`               | SBOM, Grype scan, Sigstore attestation/cosign, release upload                    |
| `scorecard`          | OpenSSF Scorecard (`reusable-scorecards.yml`)                                    |
| `osv-scanner`        | GitHub tooling + release assets + OSV APIs                                       |
| `ai-review`          | GitHub tooling + PyPI/uv (`reusable-ai-review.yml`; provider hosts appended)     |
| `rust-release`       | Rust cross-compile releases (`reusable-build-rust-binaries.yml`)                 |
| `release-recover`    | Registry probes + npm resume (`reusable-release-recover.yml`)                    |
| `release-version-pr` | `github-tooling` + PyPI + rustup/crates.io (version-PR reusables, #1093)         |

<!-- markdownlint-enable MD013 -->

```yaml
egress-policy: block
egress-preset: quality
```

`reusable-quality-lint.yml` defaults `egress-preset: quality` and
`timeout-minutes: 45`.

## Egress block examples

### Allowlist formatting

**Wrong** — `|` block becomes one token; harden-runner blocks all egress:

```yaml
allowed-endpoints: |
  github.com:443
  api.github.com:443
```

**Right** — folded scalar (`>-`) yields space-separated hosts:

```yaml
allowed-endpoints: >-
  github.com:443
  api.github.com:443
```

**Right** — rely on the preset (recommended; every reusable ships a default):

```yaml
egress-preset: quality
```

**Careful** — a non-empty list in the default `replace` mode is the *whole*
allowlist; the preset is not applied, so the list must carry the GitHub hosts
the job needs (`github-minimal` is the floor):

```yaml
allowed-endpoints: >-
  github.com:443
  api.github.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  pipelines.actions.githubusercontent.com:443
  ghcr.io:443
```

Or add project-specific hosts without replacing the preset baseline:

```yaml
egress-preset: quality
allowed-endpoints-mode: append
allowed-endpoints: >-
  ghcr.io:443
```

### Node / Bun (web)

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  registry.npmjs.org:443
```

### Rust

For release builds, prefer the preset:

```yaml
egress-policy: block
egress-preset: rust-release
```

For workspace build/test only:

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  static.rust-lang.org:443
  sh.rustup.rs:443
  crates.io:443
  static.crates.io:443
  index.crates.io:443
```

### Quality / Lintro (Docker `lintro chk`)

Prefer the preset (canonical list in `scripts/ci/lib/egress/presets.sh`):

```yaml
egress-policy: block
egress-preset: quality
```

Expanded allowlist includes GitHub, GHCR, Docker Hub, PyPI, npm/crates, semgrep,
OSV, bun/rust/uv hosts, and `api.deps.dev` (py-lintro dogfooding lint).

### GitHub Pages publish (OIDC)

Prefer the preset (used by `reusable-deploy-pages.yml`,
`reusable-deploy-site-with-reports.yml` (`egress-deploy-preset`), and the
`publish` job of `reusable-publish-test-results-pages.yml` via `egress-preset`;
`reusable-test-e2e-matrix.yml`'s `publish-egress-preset` is deprecated and inert
since #770):

```yaml
egress-policy: block
egress-preset: github-pages
```

`reusable-deploy-site-with-reports.yml` uses `egress-build-preset` (default
`playwright`) on the build job and `egress-deploy-preset` (default `github-pages`)
on deploy. Use `allowed-endpoints-build` or `allowed-endpoints-deploy` for
per-job overrides; shared `allowed-endpoints` / `allowed-endpoints-mode` apply to both jobs
when the per-job inputs are empty.

### PyPI build

Used by `reusable-build-python-dist.yml` (`allowed-endpoints` on the reusable
`with:` block). Does not upload to PyPI.

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  release-assets.githubusercontent.com:443
  objects.githubusercontent.com:443
  github-releases.githubusercontent.com:443
  raw.githubusercontent.com:443
  astral.sh:443
  releases.astral.sh:443
```

### PyPI upload (OIDC + attestation)

Used on the **caller** upload job. Run `prepare-pypi-upload`, then
`pypa/gh-action-pypi-publish` and optional `attest-build-provenance` as
**top-level workflow steps** — do not nest pypa inside lgtm-ci composites.
Set `environment: pypi` on that job. `prepare-pypi-upload` downloads workflow
artifacts and checks out lgtm-ci tooling — include artifact and GitHub hosts
below. `pypa/gh-action-pypi-publish` pulls `ghcr.io/pypa/gh-action-pypi-publish`
— include `ghcr.io:443` and `pkg-containers.githubusercontent.com:443`.

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  codeload.github.com:443
  objects.githubusercontent.com:443
  actions.githubusercontent.com:443
  *.blob.core.windows.net:443
  ghcr.io:443
  pkg-containers.githubusercontent.com:443
  pypi.org:443
  upload.pypi.org:443
  files.pythonhosted.org:443
  test.pypi.org:443
  upload.test.pypi.org:443
  fulcio.sigstore.dev:443
  rekor.sigstore.dev:443
  tuf-repo-cdn.sigstore.dev:443
  oauth2.sigstore.dev:443
```

See [python-release-publish.md](python-release-publish.md) for trusted
publishing requirements.

### npm publish (OIDC trusted publishing)

Prefer the preset (canonical list in `scripts/ci/lib/egress/presets.sh`):

```yaml
egress-policy: block
egress-preset: npm-publish
```

Includes `registry.npmjs.org:443`, Sigstore hosts, and
`oauth2.sigstore.dev:443` for OIDC trusted publishing. Use Node 24 via
`setup-node`; never `npm install -g npm`. See
[workflows/publishing.md](workflows/publishing.md#reusable-publish-npm-setyml).

#### npm package set contract

`reusable-publish-npm-set.yml` publishes a set of packages with a fixed step
order that callers must not reorder around (asserted by
`tests/bats/integration/test_reusable_publish_npm_set.bats`):

1. `verify-artifacts` — required for live publishes, optional for dry-runs
   (`checksums-file` set): for every package, the files `npm pack --dry-run`
   reports (plus `files-to-verify`) get sha256 plus `gh attestation verify`
   against `signer-repo`/`signer-workflow`, before the real `npm pack`. A
   packed file the manifest does not list, and any tampered, missing, or
   unattested artifact, fails the job with nothing published.
2. `publish-set` — the only writer. Ordered (`order`, meta package last),
   idempotent on re-runs (`npm view` pre-check skip, `EPUBLISHCONFLICT`
   conflict-as-success, read-before-write dist-tag reconcile), bounded
   exponential backoff on transient Sigstore/5xx/429 errors only, auth
   failures never retried. Outputs `published` (JSON array of `{name,
   version, status: published|skipped|dry-run, integrity}`) and
   `dist-tag-drift`; dist-tag drift (an
   OIDC-scoped token cannot write `npm dist-tag`, npm/cli#8547) is deferred:
   remaining packages publish first, then the job fails.
3. `verify-published` — read-only and last. First a propagation wait
   over the whole set on one shared clock: every package is polled together
   with exponential backoff (`propagation-attempts` × up to
   `propagation-delay` seconds, default 30 × 30 s, about fifteen minutes) until
   it is visible, carries `dist.integrity` (and `dist.attestations` when
   `provenance` is on), and
   `dist-tags.<dist-tag>` points at the published version; the log records
   when each package appeared. Only then `npm audit signatures` on a scratch
   install of the meta package (its optional dependencies are the platform
   packages, which lag the registry by minutes) and the optional
   `smoke-command`. Callers can opt out with `post-publish-verify: false`
   (default `true`); not recommended for live releases.

The publish job is bound to the optional `environment` input (string,
default empty = no environment): a `uses:` caller cannot set the key on its
own job, so this is where an approval gate and the OIDC environment claim
live. `publish-set` restores `+x` on every regular file under each
package's `bin/` and on every package.json `bin` target before `npm pack`:
workflow artifacts (`artifact-name`) land every file as 0644, and npm records
on-disk modes into the tarball.

npm trusted publishing validates the entry workflow file, so consumers must
pass their top-level publish workflow via `entry-workflows` (a live publish
fails before publishing when it is empty; a dry-run only warns) and keep
their trusted-publisher registration pointed at that same file. The live
preconditions (hosted runner, `checksums-file`, `signer-repo`,
`signer-workflow`, and `access: public` while `provenance` or
`post-publish-verify` is on) are asserted by
`scripts/ci/actions/npm/assert-live-publish-inputs.sh` before any download
or pack. The access rule exists because npm issues automatic provenance only
for public packages from public repositories and the post-publish step reads
the registry unauthenticated (trusted publishing authenticates publish
commands only): a restricted package would publish irreversibly and then
always fail verification.

### Release recovery contract

`reusable-release-recover.yml` resumes a partially published release against
the original immutable tag and the original attested artifacts (#966). The
stages are fixed:

1. `resolve` — refuses prerelease tags; reads the source run from the API
   and refuses it unless it belongs to this repository, is a run of
   `source-workflow` (the publish workflow), and built the tag's commit;
   verifies the downloaded artifacts against their checksums manifest and
   provenance attestations; probes every configured channel (PyPI, npm,
   GitHub Release, Docker, Homebrew) and emits the missing set plus the
   unresumable set. The GitHub Release is complete only when every manifest
   asset is published with the same digest (a different digest is tier
   three); the Homebrew formula's `version` string must equal the release
   version exactly. `dry-run: true` (the default) stops here; nothing has
   been written.
   The release artifacts are also compared with any asset already published
   under the tag: a different digest is tier three, refused here.
2. `resume-*` — one job per channel, gated on membership in the missing set.
   npm resumes through the same scripts and guards as
   `reusable-publish-npm-set.yml` (#965): the entry-workflow guard
   (`npm-entry-workflows`, fail-closed), the live preconditions (hosted
   runner, manifest, signer inputs, `npm-access: public`), `verify-artifacts`
   over every file npm would pack, the idempotent `publish-set` loop, and
   `verify-published`. The GitHub Release resumes through
   `create-github-release.sh` with `IMMUTABLE_ASSETS: true` (already-published
   assets are skipped, never overwritten); the Homebrew dispatch is re-sent
   only when the tap lacks the version. Complete channels are skipped, not
   re-run; PyPI is never resumed (a version is burned on first upload — its
   missing state is tier three).
3. `record` — `if: always()`: posts the outcome table to the release-failure
   issue the notifier (#964) opened, closing it only when the run was live,
   the resolve stage succeeded, every detected-missing channel has a
   successful resume, and nothing unresumable (PyPI, Docker) is missing; a
   dry run leaves it open.

The recovery runs the default-branch workflow code: the consumer dispatches
its entry workflow from the default branch, and every tooling checkout in
the reusable pins the required `tooling-ref` (the caller's `uses:` SHA),
never `inputs.tag` and never `github.workflow_sha` (which names the caller's
commit inside a called workflow); the wiring test asserts it. Release tags
must be protected by a ruleset (runbook, "Prerequisites"). All jobs run on
`runner-image` (GitHub-hosted) under the runner contract; in block mode
`allowed-endpoints` must be complete on its own (harden-runner installs it
at job start; there is no preset fallback). The cross-repository Homebrew
re-dispatch uses the `homebrew-dispatch-token` secret.

Release-artifact retention defaults to the 90-day recovery window
(`reusable-build-python-dist.yml` `artifact-retention-days`,
`reusable-build-rust-binaries.yml` `retention-days`); consumers with local
build workflows must match it. Runbook:
[release-recovery.md](release-recovery.md).

### GitHub Release (artifact upload)

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443
  uploads.github.com:443
  codeload.github.com:443
  release-assets.githubusercontent.com:443
  objects.githubusercontent.com:443
```

### SBOM + attestation

```yaml
egress-policy: block
egress-preset: sbom
```

Covers GitHub, Anchore (Syft/Grype), Sigstore attestation/cosign hosts
(`fulcio.sigstore.dev`, `rekor.sigstore.dev`, `oauth2.sigstore.dev`), and
`uploads.github.com` for release-asset upload. Canonical list:
`scripts/ci/lib/egress/presets.sh` (preset name `sbom`). With
`allowed-endpoints-mode: replace`, a non-empty `allowed-endpoints` input
overrides the preset — callers that pass a custom allowlist must include the
full baseline (see #512).

#### Permissions by mode (`reusable-sbom.yml`)

<!-- markdownlint-disable MD013 -- SBOM mode permissions; columns exceed default line length -->

| Mode | Job permissions | Notes |
| ---- | --------------- | ----- |
| `report` (default) | `contents: read`, `security-events: write`, `id-token: write`, `attestations: write` | Scan/attest path. Since #770 the caller grants `contents: read`: the release-asset upload moved to `reusable-sbom-release-upload.yml`, so no job here declares write |
| `release-assets` | `contents: read`, `id-token: write`, `security-events: write`, `attestations: write` | Multi-format generate + cosign sign, then upload as the `artifact-name` **workflow artifact**; requires `release-tag`. Attaching it to the release is `reusable-sbom-release-upload.yml`'s job (#770). The last two belong to the scan job this mode skips, but reusable permission requests are validated statically — omitting them fails the run with `startup_failure` |

<!-- markdownlint-enable MD013 -->

`reusable-sbom.yml` defaults `fail-on-severity` to `critical` (breaking as of
issue #480). The Grype gate fails the job when findings meet or exceed that
threshold. Callers that need the previous advisory-only posture must pass
`fail-on-severity: ""` (or `none`):

*Fragment: permissions omitted for brevity, not copyable as-is. See
[Permissions by mode](#permissions-by-mode).*

```yaml
sbom:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  with:
    fail-on-severity: "" # advisory-only; default is critical
```

Release-asset mode (multi-format + optional cosign, no Grype gate):

```yaml
sbom-release:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  permissions:
    # Read since #770: the generated files leave as a workflow artifact and
    # reusable-sbom-release-upload.yml attaches them to the release.
    contents: read
    id-token: write
    # Declared by the scan job, which this mode does not run; reusable
    # permission requests are validated statically, before `if:`.
    security-events: write
    attestations: write
  with:
    mode: release-assets
    release-tag: ${{ github.ref_name }}
    formats: spdx-json,cyclonedx-json
    sign: true
```

`reusable-sbom-release-upload.yml` checks out lgtm-ci tooling only, never the
caller (#796), so its upload step passes the target repository explicitly as
`GH_REPO: ${{ github.repository }}` instead of letting `gh` read a git remote
that is not there (#935). Every `gh release` step in a publisher workflow or
composite is held to that rule by
`tests/bats/contract/test_gh_release_repo_context.bats`.

## Supplier tool pins and digests

Every tool that a script under `scripts/ci` installs (osv-scanner, syft,
cargo-nextest, cargo-llvm-cov, cross, cargo-xwin, cargo-binstall, bats-core and
its helper libraries, kcov, the Claude Code / Codex / Cursor review CLIs,
lintro) is
pinned in exactly one place, `scripts/ci/versions.env`, and every direct
download or clone is verified against a value committed next to that pin
(#1096). Block-mode egress constrains where bytes come from; the committed
digest decides what they are.

<!-- markdownlint-disable MD013 MD060 -- wide pin reference table -->

| Tool                             | Pin                                   | Content check at install time                                     |
| -------------------------------- | ------------------------------------- | ----------------------------------------------------------------- |
| osv-scanner, syft, cargo-nextest, cargo-llvm-cov, cross, cargo-xwin, cargo-binstall | `DEFAULT_<TOOL>_VERSION` | release asset sha256 equals `DEFAULT_<TOOL>_SHA256_<PLATFORM>`     |
| bats-core, bats-support, bats-assert, bats-file, kcov | `DEFAULT_<TOOL>_VERSION` | clone `HEAD` equals `DEFAULT_<TOOL>_COMMIT`                       |
| Claude Code, Codex               | `DEFAULT_<TOOL>_VERSION`              | `npm ci` from `scripts/ci/ai-review-cli/<cli>/package-lock.json` (integrity-pinned) |
| Cursor agent                     | `DEFAULT_CURSOR_AGENT_VERSION`        | tarball sha256 equals `DEFAULT_CURSOR_AGENT_SHA256_<ARCH>`        |
| lintro                           | `DEFAULT_LINTRO_VERSION`              | PyPI version pin; registry-side hashes (allowlisted, see below)    |

<!-- markdownlint-enable MD013 MD060 -->

Verification is implemented once, in `scripts/ci/lib/supply_chain.sh`, and
fails closed:

- A digest or commit **mismatch** always fails the job. It is never retried
  and never downgraded.
- A **missing** committed digest, a missing `sha256sum`/`shasum`, or a
  version override that was not paired with the matching
  `<TOOL>_SHA256_<PLATFORM>` / `<TOOL>_COMMIT` value is also an error, unless
  the caller sets `LGTM_CI_ALLOW_UNVERIFIED=1`. With that escape set the gap
  is reported as a `::warning` and the install continues unverified.
  lgtm-ci's own workflows never set it; it exists for callers that
  deliberately pin a version lgtm-ci has no digest for and accept the risk.
- Version overrides therefore need the matching digest: `bats-version` on
  `reusable-test-shell` takes it through the companion `bats-commit` input;
  `osv-version` on `reusable-vuln-suppression-check` through a caller
  `install-script` that exports `OSV_SCANNER_SHA256_<PLATFORM>`;
  `CARGO_NEXTEST_VERSION` / `CARGO_LLVM_COV_VERSION` through a caller
  `setup-script` that exports `CARGO_<TOOL>_SHA256_<TARGET>`. Caller `env:`
  does not cross the `workflow_call` boundary, so those are the only routes.
- Hosts with no committed archive digest (cargo-nextest, cargo-llvm-cov,
  cross and cargo-xwin outside the targets listed in `versions.env`) fall back to
  `cargo install --locked`, where crates.io is the trust root: registry-side
  checksums and the crate's own lockfile. Each such line carries an
  `# unverified-fallback: <reason>` marker so the contract test can see it;
  it is not an escape-hatch path.
- A binary already on `PATH` at the pinned version is reused without a digest
  check. The setup-rust action restores `~/.cargo/bin` from the Actions
  cache, which is scoped to the consumer repository and ref, so that shortcut
  trusts the consumer's own prior job rather than a fresh download. Accepted.

Upstream signatures are checked when a pin is created or refreshed, not on
every run: `scripts/ci/maintenance/refresh-tool-digests.sh --check` downloads
every pinned asset, verifies osv-scanner's SLSA provenance with
`slsa-verifier` and syft's checksum manifest with `cosign`, cross-checks the
nextest and cargo-xwin `.sha256` files, resolves every clone tag to its commit, and compares
all of it with `versions.env` (`--write` rewrites the values). Both verifiers
are hard prerequisites of that script; the same `LGTM_CI_ALLOW_UNVERIFIED=1`
escape downgrades a missing verifier, never a failed verification. The old
install-time `cosign` and `git verify-tag` paths that logged a warning and
continued are gone.

Renovate reads `versions.env` through one regex manager. A version line bumps
the version; each digest line is its own dependency on the
`github-release-attachments` (asset sha256) or `github-tags` (tag commit)
datasource, carrying the release tag as a trailing comment so Renovate can map
the asset into the next release. The version line and its digest lines share a
branch, so one PR carries both. A digest-only update means an upstream asset
or tag was replaced in place; `renovate.json` never automerges those.
`tests/bats/unit/renovate/test_tool_pins.bats` proves every line is
regex-visible, every digest-line tag matches its version, the npm lockfiles
equal `versions.env`, and every YAML copy that cannot read a file (`uv`, `bun`,
`grype`) equals its annotated source.

`tests/bats/unit/renovate/test_installer_verification.bats` enumerates every
installer-shaped command line under `scripts/ci` (`git clone`, `cargo
install`/`binstall`, `npm install`/`ci`, `bun add`, `pip install`, `uv tool
install`, `go install`, `pipx`/`gem install`, `download_with_retries`,
`curl -o`/`-O`, `wget`; image pulls are pinned by their `@sha256` reference
and `npx`/`bunx` only run consumer-installed packages). Each line must be followed
within a few lines by a `supply_chain_verify_sha256` /
`supply_chain_verify_commit` / `sha256sum -c` call that is not a comment, or
carry an explicit `# unverified-fallback: <reason>` or `# verified-by: <reason>`
marker, or live in a file listed in
`scripts/ci/maintenance/unverified-installers.allowlist` with a reason. The
test pins the exact set of paths the allowlist may contain, so the list can
only shrink; a new installer fails the test by default, and the test proves
that with planted fixtures.

Catalog note (#1079): until the catalog lands, treat every reusable listed in
the table above as "installs `<tool> <version>`, digest-verified". Rows for
tools delegated to a SHA-pinned action (`uv`, `bun`, `grype`) should read
"version-pinned, verified inside the action", and anything in the allowlist
should read "version-pinned, not digest-verified" rather than imply parity
with the SHA-pinned `uses:` lines.

## Action pinning policy

Org repos must pin GitHub Actions to **commit SHAs only** and add a trailing
Renovate version comment on the same line. Tag refs (for example `@v4`) fail
`reusable-validate-action-pinning.yml` unless the action is listed in the narrow
`allow-tag-exceptions` input.

| Pin                                                       | Result                     |
| --------------------------------------------------------- | -------------------------- |
| `uses: org/action@sha`                                    | Fail — missing `# vX.Y.Z`  |
| `uses: org/action@v1.2.3`                                 | Fail — tag pin             |
| `uses: org/action@sha # v1.2.3`                           | Pass                       |
| `tooling-ref: 'sha'`                                      | Fail — missing `# vX.Y.Z`  |
| `tooling-ref: 'sha' # v0.18.4`                            | Pass                       |
| `ref: 'sha'` under `repository: lgtm-hq/lgtm-ci` checkout | Same rule as `tooling-ref` |

Use the **release commit SHA** for `tooling-ref` and lgtm-ci checkout `ref` pins, not the
annotated tag object SHA. For example, `v0.18.4` resolves to release commit
`d3736367191ddaf56c41804d2dd5174732ed2d2b`, not tag object `95e202ae…`.

Canonical examples:

```yaml
uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
tooling-ref: "31750ecad528ca9312bfe169dd33325b18f6c637" # v0.75.3
```

Template expressions (for example `${{ inputs.tooling-ref }}`) are ignored.
Bare SHA pins without version comments are invisible to Renovate and are blocked
by design.

### Tag verification (`verify-tags`)

`verify-tags` defaults to **true**: each `sha # vX.Y.Z` pin is checked by
resolving the commented tag through the GitHub API and comparing it to the
pinned SHA. A comment that resolves to a different SHA (a lying pin) fails
validation; a tag that cannot be resolved is reported as a warning, not a hard
failure. This requires a `GH_TOKEN` for API access — the action falls back
through the explicit `gh-token` input, a caller-set `GH_TOKEN` env var, then the
workflow token.

Offline/air-gapped runners, or environments where the GitHub API is
unreachable, opt out with `verify-tags: false`.

### Composite actions calling sibling lgtm-ci actions

Composite `action.yml` files must not call sibling lgtm-ci actions with a remote
template ref:

```yaml
uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@${{ inputs.tooling-ref }}
```

GitHub validates nested composite `uses:` values before composite inputs are
available, so this pattern fails during workflow template validation. Workflows
and reusable workflows may still pass `${{ inputs.tooling-ref }}` to checkout
`ref:` values or reusable workflow inputs; this restriction is only for
composite action `uses:` fields.

A workspace-relative path is equally wrong:

```yaml
uses: ./.github/actions/setup-python
```

GitHub resolves `./` against `github.workspace`, which is the **caller's**
checkout. The reference only works when the caller happens to have lgtm-ci
checked out at the workspace root (lgtm-ci's own CI); from any other
repository it fails with `Can't find 'action.yml' … under
<workspace>/.github/actions/setup-python` (#1075).

Composite actions reach sibling lgtm-ci actions with the GitHub.com
**self-repository reference** `$/<path>`, which resolves to the repository and
SHA of the file that contains it — the SHA the consumer pinned the composite
to — with no checkout at all:

```yaml
- name: Setup Python
  uses: $/.github/actions/setup-python
  with:
    python-version: ${{ inputs.python-version }}
```

`run-pytest` uses this form, so
`uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@<sha>` works from a consumer
workflow that checks out only its own source. The Node runners `run-vitest`,
`run-playwright`, and `run-lighthouse` no longer nest the Bun-only
`setup-node` sibling: they pin `actions/setup-node`, `oven-sh/setup-bun`, and
`pnpm/action-setup` directly and gate the last two on `package-manager`
(#1077), so they carry no `$/` ref at all. `$/` is generally
available on GitHub.com and ghe.com since 2026-07-30 (see the
[self-repository references announcement](https://github.com/orgs/community/discussions/26245));
self-hosted runners need `>= 2.336.0`. GitHub Enterprise Server is **not**
covered by that announcement. On a GHES release without `$/`, `run-pytest` is
**unavailable**: the nested `$/` ref lives inside the action itself, so no
caller-side checkout (workspace root or `.lgtm-ci-tooling`) can make it
resolve. GHES consumers should call the per-language reusable workflows
instead (`reusable-test-python`, `reusable-test-node`,
`reusable-test-e2e-playwright`, `reusable-site-quality`), which run the same
`scripts/ci/actions/run-*.sh` directly and never load these composites.
Since `$/` is pinned by construction,
`validate-action-pinning` exempts `$/` refs the same way it exempts `./` and
`docker://` — but only the plain `$/<path>` form; a value carrying `@ref` or a
`..` segment is checked like any other ref.

Composite actions that need the lgtm-ci *scripts* tree alongside the caller's
source (for example `prepare-pypi-upload`) may still check lgtm-ci tooling out
into `.lgtm-ci-tooling` and call sibling actions by that local path:

```yaml
- name: Checkout lgtm-ci tooling
  uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    repository: lgtm-hq/lgtm-ci
    path: .lgtm-ci-tooling
    ref: ${{ inputs.tooling-ref != '' && inputs.tooling-ref || github.action_ref }}
    sparse-checkout: |
      .github/actions/
      scripts/ci/
    sparse-checkout-cone-mode: true
    persist-credentials: false

- name: Resolve scripts directory
  shell: bash
  run: echo "SCRIPTS_DIR=${GITHUB_WORKSPACE}/.lgtm-ci-tooling/scripts" >> "$GITHUB_ENV"

- name: Setup Python
  uses: ./.lgtm-ci-tooling/.github/actions/setup-python
```

`tests/bats/integration/test_composite_action_refs.bats` guards this contract
and fails if any `.github/actions/**/action.yml` uses
`lgtm-hq/lgtm-ci/...@${{ ... }}`;
`tests/bats/contract/test_composite_references.bats` additionally forbids
`uses: ./.github/actions/...` and requires every nested `uses:` in a composite
to be a SHA-pinned remote, `docker://`, `$/`, or `./.lgtm-ci-tooling/` ref.
The external fixture `TurboCoder13/lgtm-ci-consumer-fixture`
(`actions-direct.yml`) exercises the direct path at a pinned lgtm-ci SHA with
no lgtm-ci checkout. Hardened caller jobs that run composites with
tooling checkout need egress for `codeload.github.com`, `astral.sh`, and
`releases.astral.sh`; see the PyPI egress examples above.

## Dependency review

`reusable-dependency-review.yml` runs on `pull_request` and `merge_group`
events. Do not invoke it from plain `push` workflows unless you accept the job
being skipped.

### Licensing: "Unknown License" on lgtm-ci composite actions

Consumers pinning `lgtm-hq/lgtm-ci/.github/actions/*@<sha>` may see
**License: Null / Unknown** for those rows in GitHub Dependency Review and
OpenSSF Scorecard's license check, even though this repository is **MIT**
(`LICENSE` at the repo root). This is a known GitHub platform limitation, not
a missing license:

- The `action.yml` metadata schema (`name`, `author`, `description`, `inputs`,
  `outputs`, `runs`, `branding`) has **no license/SPDX field**. There is
  nothing for a composite action to declare that GitHub's dependency graph
  will read.
- GitHub's `actions` ecosystem in the dependency graph does not currently
  inherit the referencing repository's `LICENSE` for cross-repo composite
  action paths (`owner/repo/path@ref`), so `dependency-review-action` and
  Scorecard report the license as unknown regardless of the upstream repo's
  actual license.

Every `action.yml` under `.github/actions/` carries an
`SPDX-License-Identifier: MIT` header comment for humans and license-scanning
tools that read files directly; it does not change what GitHub's dependency
graph reports, since the field isn't part of the schema GitHub parses.

**Consumer workaround:** pass `allow-dependencies-licenses` through
`reusable-dependency-review.yml` with the PURLs of the lgtm-ci composites you
consume, pinned to the tag/SHA you use. The dependency-review-action matches
`allow-dependencies-licenses` entries on namespace/name only (version is
ignored), so a single PURL per action covers every ref you pin to it. Slashes
in the composite subpath are percent-encoded (`%2F`):

<!-- markdownlint-disable MD013 -- long PURL examples -->

```yaml
jobs:
  dependency-review:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-dependency-review.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      pull-requests: read
    with:
      allow-dependencies-licenses: >-
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fharden-runner,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcheckout-and-harden,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsecure-checkout,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-rust,
        pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcreate-github-release
```

<!-- markdownlint-enable MD013 -->

Canonical PURLs for common composites (swap the trailing action name for any
other directory under `.github/actions/`):

<!-- markdownlint-disable MD013 -- wide PURL reference table -->

| Composite               | PURL (namespace/name)                                            |
| ------------------------ | ----------------------------------------------------------------- |
| `harden-runner`          | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fharden-runner` |
| `checkout-and-harden`    | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcheckout-and-harden` |
| `secure-checkout`        | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsecure-checkout` |
| `setup-rust`             | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-rust` |
| `setup-python`           | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-python` |
| `setup-node`             | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fsetup-node` |
| `create-github-release`  | `pkg:githubactions/lgtm-hq/lgtm-ci%2F.github%2Factions%2Fcreate-github-release` |

<!-- markdownlint-enable MD013 -->

For OpenSSF Scorecard, there is no equivalent per-dependency allowlist for the
license check today; document the expected "Unknown" result for lgtm-ci
composite rows rather than treating it as a regression. Re-check this section
if GitHub ships license enrichment for the `actions` ecosystem or adds a
`license` field to the action metadata schema — at that point the
`allow-dependencies-licenses` workaround and this note can be retired.

## Security audit (osv-scanner)

`reusable-security-audit.yml` centralizes the lintro Docker + osv-scanner audit
pattern used by Rust monorepos. The audit job runs
`scripts/ci/security/run-lintro-audit.sh` (override with `audit-script`), uploads
a PR comment artifact on `pull_request`, and uses `continue-on-error` plus an
explicit fail step so comment generation still runs when vulnerabilities are
found.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                 | Default                                              | Notes                                           |
| --------------------- | ---------------------------------------------------- | ----------------------------------------------- |
| `lintro-image`        | pinned `ghcr.io/lgtm-hq/py-lintro` digest            | Same contract as `reusable-quality-lint`        |
| `audit-script`        | `.lgtm-ci-tooling/scripts/ci/security/run-lintro-audit.sh` | Repo-local override supported             |
| `upload-comment-artifact` | `true`                                           | Set `false` for push/schedule check-only          |
| `comment-marker`      | `security-audit-report`                              | Input on publish reusable                         |
| `egress-preset`       | `quality`                                            | Includes `api.osv.dev` and `api.deps.dev`       |

<!-- markdownlint-enable MD013 MD060 -->

Caller `on:` triggers are consumer-owned. Add `merge_group:` alongside
`pull_request:` when using merge queue — the audit job runs on both; PR comments
upload/post only on `pull_request`. Scheduled or push callers should set
`upload-comment-artifact: false` and omit the publish reusable caller job.

Grant `packages: read` on the audit job (Docker pull from ghcr.io). Call
`reusable-publish-security-audit-comment.yml` from the caller when PR comments
are required; that publish reusable declares `pull-requests: write`. The audit
reusable itself requires only `contents: read` and `packages: read`.

Outputs: `exit-code`, `has-vulns`, `audit-failed`, `status`.

Suppression status in the comment comes from the per-tool `metadata.suppressions`
list lintro attaches after its probe scan (py-lintro >= 0.94; the pre-0.95.0
`ai_metadata` alias is still read with a deprecation warning and will be removed,
see #825). lintro omits the key when the probe did not run. If the key is missing
while `.osv-scanner.toml` declares entries with a plain-date `ignoreUntil` (not a
datetime) and the scan itself succeeded, the formatter exits non-zero instead of
listing static TOML entries as status: `run-lintro-audit.sh` then replaces the
whole comment body with its formatter-failure placeholder (no vulnerability
table), reports "FORMAT FAILED" / `status=failed`, and the audit job exits 1 until
probe metadata appears (there is no opt-out input; the stderr diagnostic in the
job log names the entries and next steps). When the scan failed, the
scanner-error section is kept and the status line is marked unavailable.
Entries without a plain-date `ignoreUntil` are listed and labelled as
unclassified. Malformed probe entries also fail the formatter.

## Vulnerability suppression check (osv-scanner)

`reusable-vuln-suppression-check.yml` centralizes the weekly stale/expired OSV
suppression cleanup pattern used by Rustume, py-lintro, and turbo-themes. The job
installs `osv-scanner` directly (no Docker), runs
`scripts/ci/security/check-vuln-suppressions.sh`, and may open a cleanup PR
removing stale entries (vulnerability resolved). Expired entries (past
`ignoreUntil`) are left untouched and flagged for manual review with a
non-zero exit.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                    | Default                                              | Notes                                           |
| ------------------------ | ---------------------------------------------------- | ----------------------------------------------- |
| `osv-version`            | empty                                                | Empty uses install-osv-scanner.sh pin           |
| `config-path`            | `.osv-scanner.toml`                                  | Suppression TOML relative to repo root          |
| `check-script`           | `.lgtm-ci-tooling/scripts/ci/security/check-vuln-suppressions.sh` | Repo-local override supported |
| `cleanup-pr-labels`      | `security,dependencies,automation`                   | Labels on auto-created cleanup PR               |
| `egress-preset`          | `osv-scanner`                                        | `github-tooling` + release assets + OSV APIs    |
| `allowed-endpoints-mode` | `append`                                             | Merge preset with caller-specific endpoints     |
| `workflow-file`          | empty                                                | Caller workflow filename for auto-PR footer     |
| `runner-image`           | `ubuntu-24.04`                                       | Linux runners only (`install-osv-scanner.sh`)   |

<!-- markdownlint-enable MD013 MD060 -->

The cleanup commit is created through the GitHub API
(`scripts/ci/git/create-signed-commit.sh`, reset mode on the default branch
head), so GitHub signs it and the PR can merge where `required_signatures` is
enforced; nothing is committed or pushed with the git CLI. The run stops before
any write if the suppression file on the default branch differs from the
checked-out copy. The PR is opened without labels and `cleanup-pr-labels` are
added afterwards one at a time; a label missing in the repository only logs a
warning. An empty `cleanup-pr-labels` opts out of labelling. If the PR cannot
be created, the new
`chore/remove-stale-vulns-<timestamp>-<run_id>-<attempt>-<random>` branch is deleted
(or, when deletion fails or it cannot be verified that no PR exists, left in
place with its compare URL in the job summary) and the job fails.

Caller `on:` triggers are consumer-owned (`schedule`, `workflow_dispatch`).
Grant `contents: write` and `pull-requests: write` on the caller job. Forward
`secrets.GH_TOKEN` (typically `secrets.GITHUB_TOKEN`). Use a Linux
`runner-image`; the install script downloads `linux_*` release binaries only.

Required secrets: `GH_TOKEN`.

## GHCR cleanup

`reusable-ghcr-cleanup.yml` prunes aged untagged container versions and ephemeral
build-cache tags. Referenced-digest protection walks tagged manifest indexes and
OCI Referrers before untagged deletion; the job skips pruning when registry auth
or manifest collection is incomplete. Opt in to `prune-tagged` to also age out
`main`/`sha-*` and pre-release tagged versions — a version is deleted only when
every tag on it is deletable, so release manifests (`latest` + semver + `sha-*`)
are kept forever. See
[reusable-workflows.md](reusable-workflows.md#tagged-retention-prune-tagged).

| Input | Default | Notes |
| --- | --- | --- |
| `package-name` | required | GHCR package name |
| `min-age-days` | `7` | Min age before deletion |
| `keep-latest` | `0` | Keep N most recent |
| `build-cache-pr-age-days` | `14` | Min cache age |
| `protect-referenced` | `true` | Skip when incomplete |
| `prune-buildcache` | `true` | Delete ephemeral tags |
| `prune-tagged` | `false` | Opt in to tagged retention |
| `main-retention-days` | `30` | `main` / `sha-*` retention |
| `prerelease-retention-days` | `90` | Pre-release retention |
| `dry-run` | `false` | Log only |
| `egress-policy` | `block` | `audit` or `block` |
| `egress-preset` | `github-tooling` | Preset host list |
| `allowed-endpoints` | `""` | Custom endpoints |
| `allowed-endpoints-mode` | `replace` | `replace` / `append` |
| `tooling-ref` | `""` | lgtm-ci git ref |
| `runner-image` | `ubuntu-24.04` | Runner image label |

Grant `contents: read` and `packages: write` on the caller job. Forward
`secrets.token` with `packages:write` scope (or `secrets: inherit`).

## Documentation site quality

`reusable-site-quality.yml` centralizes the docs-site pattern used by Rust
monorepos: Astro (or similar) build, lychee link check on built HTML, and
caller-provided check/test commands. Repo scripts such as `scripts/ci/site/build.sh`
remain consumer-owned and are passed as `build-command`, `check-command`, and
`test-command` inputs.

The reusable runs two parallel jobs (`site-build-link`, `site-test`). Lychee uses
`build-lychee-args.sh` plus `prepare-lychee-action-args.sh` to strip duplicate
`--format`/`--output` flags and add `--root-dir` for built dist output. Set
`lychee-root-dir` when the default (first `lychee-paths` value) is insufficient.

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                    | Default                         | Notes                                           |
| ------------------------ | ------------------------------- | ----------------------------------------------- |
| `build-command`          | required                        | e.g. `./scripts/ci/site/build.sh`               |
| `test-command`           | required                        | e.g. `./scripts/ci/site/test-all.sh`            |
| `check-command`          | empty                           | Optional type-check before tests                |
| `build-env`              | empty                           | Multiline `KEY=VALUE` (`apply-build-env.sh`)    |
| `site-working-directory` | `.`                             | Node/Bun install path (e.g. `apps/site`)        |
| `lychee-paths`           | `.`                             | Built dist path for link check                  |
| `lychee-root-dir`        | first `lychee-paths` entry      | `--root-dir` for built HTML link resolution     |
| `upload-site-artifact`   | `false`                         | Set `true` with explicit artifact path          |
| `python-version`         | empty                           | When set, enables optional Python setup         |
| `python-test-command`    | empty                           | Hook before `test-command` when Python enabled  |
| `vitest-json-path`       | empty                           | Optional non-default Vitest JSON for summaries  |
| `test-egress-preset`     | falls back to `egress-preset`   | Override egress for Python+Node test job        |

<!-- markdownlint-enable MD013 MD060 -->

Work jobs require only `contents: read`. Optional `publish-test-summary` delegates
to `reusable-publish-test-summary.yml` (requires `pull-requests: write` on the
caller publish job path). Outputs: `passed`, `build-passed`, `test-passed`.

## Playwright E2E (`reusable-test-e2e-playwright`)

`reusable-test-e2e-playwright.yml` is the consumer-facing Playwright E2E reusable
for smoke / a11y / full suites as thin callers with distinct `job-name` values
(turbo-themes 🎭/🔥/♿, holy-grail 🎭 E2E). Prefer this over hand-rolled
Playwright jobs; do not migrate consumers until org rulesets are updated in
lockstep (#514).

Single always-run job uses `name: ${{ inputs.job-name }}`. Browser binaries are
cached under `~/.cache/ms-playwright` keyed on the resolved `@playwright/test`
version plus `browsers`. Install uses `npx playwright install --with-deps
<browsers>`. Reporters are passed as **exactly one** `--reporter=` flag
(`reporters`, default `list,json,junit,html`); Playwright keeps only the last
flag, so repeating it used to drop the HTML report while the job stayed green
(#804). The flag replaces the consumer's `playwright.config` reporters, so add
custom ones to `reporters` rather than to the config. Output locations are
pinned: `playwright-results.json` (parsed for the summary),
`playwright-results.xml`, `playwright-report/`. A missing `playwright-report/`
after the run **fails the job**, even when every test passed. HTML/JUnit/blob
reports upload when `upload-report: true`, on failure by default
(`upload-report-when: failure`) or on every run (`always`). Default
`egress-preset: playwright` (CDN + apt mirrors); the workflow default
`allowed-endpoints` mirrors that full baseline under replace semantics (#512).

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                | Default                | Notes                                                        |
| -------------------- | ---------------------- | ------------------------------------------------------------ |
| `job-name`           | required               | Check name / summary suite title                             |
| `test-command`       | `npx playwright test`  | Base CLI; `project` / `grep` append                          |
| `project`            | empty                  | `--project=` filter                                          |
| `grep`               | empty                  | `--grep=` filter (e.g. `@smoke`)                             |
| `node-version`       | `22`                   | setup-node                                                   |
| `browsers`           | `chromium`             | install `--with-deps` list or `all`                          |
| `reporters`          | `list,json,junit,html` | One `--reporter=` flag; must include `json` and `html`       |
| `upload-report`      | `true`                 | HTML/JUnit/blob artifact                                     |
| `upload-report-when` | `failure`              | `failure` (non-zero exit only) or `always`                   |
| `base-url`           | empty                  | `BASE_URL` + `PLAYWRIGHT_BASE_URL`                           |
| `web-server`         | empty                  | `PLAYWRIGHT_WEB_SERVER` for consumer config                  |
| `package-manager`    | `npm`                  | `npm` / `bun` / `pnpm`                                       |

<!-- markdownlint-enable MD013 MD060 -->

Plus standard contract inputs (`tooling-ref`, egress, `runner-image`,
`timeout-minutes`, `draft-pr-skip`, `publish-test-summary`, `comment-marker`).
Caller permissions: `contents: read` (add `pull-requests: write` when publishing
summaries). merge_group-safe: tests run; PR summary gated to `pull_request`.

## Build artifact

`reusable-build-artifact.yml` runs a caller-provided `build-command`, optionally a
`post-build-test-command`, then uploads `artifact-path` for cross-job handoff
(turbo-themes Build & Quality → Validate Examples; holy-grail Build & Test).

`toolchain` (`node` | `rust` | `python` | `none`, default `node`) selects the
setup action installed before the build. It is an enum, not a free-form action
ref, so every toolchain stays digest-pinned inside lgtm-ci and covered by
`validate-action-pinning`; new ecosystems arrive by PR here. `toolchain-version`
sets the version (`stable` for rust, `3.12` for python; alias of `node-version`
for node). Neither the Rust nor the Python setup installs project dependencies.

`matrix` takes an arbitrary JSON matrix (array of objects, or an object with an
`include` array) and generalises `node-version-matrix`, which is **deprecated**
and warns when set. `runner-map` maps a matrix value to a runner label, the same
pair `reusable-docker` uses for `platforms`; values with no mapping fall back to
`runner-image` with a `::notice::`. Set `runner-map-key` when entries have more
than one field — an entry missing that field is rejected. The resolved runner is
injected as a `runner` matrix field (and only when `runner-map` is non-empty), so
legacy Node callers keep their existing job names and check contexts.

Each matrix field is exported to `build-command` and `post-build-test-command`
as `MATRIX_<FIELD>` (`target` → `$MATRIX_TARGET`), so a cross-compile leg can
read its own target without a per-repo wrapper.

Legacy Node callers pass **exactly one** of `node-version` (single) or
`node-version-matrix` (JSON array such as `'["20","22"]'`); both are rejected
alongside `matrix`, which is the general form every non-Node caller uses. Matrix
legs keep a static inner `name: ${{ inputs.job-name }}`, so every leg reports
under the **same** check-run name, `{caller_job_id} / {job-name}` (for example
`build / 🏗️ Build & Quality Checks`, one check run per leg). There is no
`({node-version})` or `(x86_64-apple-darwin, stable)` suffix: GitHub appends
matrix values only when a matrix job's `name:` carries no expression (#623).
What a ruleset sees and how to require it is in
[Matrix legs and check-run names](#matrix-legs-and-check-run-names). Plan org
ruleset updates in lockstep with consumer migration.

Single-version uploads use `artifact-name` verbatim. Matrix mode appends the
leg's matrix values so parallel legs do not collide (`js-dist-20`,
`js-dist-22`; `rustume-x86_64-apple-darwin-stable`). The injected `runner` field
is excluded from the suffix, so adding `runner-map` never renames an artifact.
Workflow outputs expose `artifact-name`, `artifact-id`, and `artifact-url` from
the build job (matrix runs surface one completed leg — prefer the naming
convention when downloading from multi-leg matrices).

<!-- markdownlint-disable MD013 MD060 -- wide input reference table -->

| Input                     | Default   | Notes                                              |
| ------------------------- | --------- | -------------------------------------------------- |
| `build-command`           | required  | e.g. `./scripts/build.sh --quick`, `bun run build` |
| `artifact-name`           | required  | Base upload name; matrix appends `-<version>`      |
| `artifact-path`           | required  | Relative to `working-directory`                     |
| `toolchain`               | `node`    | `node` \| `rust` \| `python` \| `none`             |
| `toolchain-version`       | empty     | Toolchain version; alias of `node-version` (node)  |
| `matrix`                  | empty     | Arbitrary JSON matrix; XOR with the node inputs    |
| `runner-map`              | `{}`      | Matrix value → runner; unmapped uses `runner-image`|
| `runner-map-key`          | empty     | Lookup field; auto for single-field entries        |
| `node-version`            | empty     | XOR with `node-version-matrix`                     |
| `node-version-matrix`     | empty     | Deprecated (use `matrix`); XOR with `node-version` |
| `post-build-test-command` | empty     | Optional post-build test gate                      |
| `retention-days`          | `7`       | Artifact retention                                 |
| `working-directory`       | `.`       | Build / post-test cwd                              |
| `job-name`                | `Build`   | Static inner check label                           |

<!-- markdownlint-enable MD013 MD060 -->

Plus standard contract inputs (`tooling-ref`, egress, `runner-image`,
`timeout-minutes`). Caller permissions: `contents: read` only. merge_group-safe
(no PR-context requirements; no draft-PR job skip).

## Merge queue (`merge_group`)

Callers using GitHub merge queue must add `merge_group:` triggers to every
caller workflow that produces a required check, alongside `pull_request:` —
otherwise queued PRs time out waiting for checks that never report. The
starter examples (`examples/ci-*.yml`) include `merge_group:` by default.

### App-level code-scanning checks

Never require the github-advanced-security app's code-scanning **summary** context
(`CodeQL` alone, without a caller-job prefix) in a ruleset when the repo uses a
merge queue. The app produces that check only on `pull_request` commits, never on
`merge_group` commits, so every queue entry times out and is silently ejected
([holy-grail#143](https://github.com/lgtm-hq/holy-grail/pull/143), twice during
v0.52.3 adoption). Require the workflow-job contexts instead — for example
`codeql / 🔬 CodeQL Analysis` (the `{caller_job_id} / {job-name}` path your caller
passes to `reusable-codeql.yml`). See [org-rulesets.md](org-rulesets.md)
(Check-name contract).

| Workflow                               | `merge_group` behavior                         |
| -------------------------------------- | ---------------------------------------------- |
| `reusable-quality-lint.yml`            | Safe to run — no PR context required           |
| `reusable-codeql.yml`                  | Safe to run — no PR context required           |
| `reusable-validate-action-pinning.yml` | Safe to run — no PR context required           |
| `reusable-dependency-review.yml`       | Runs on `merge_group` (same as PR)             |
| `reusable-security-audit.yml`          | Audit on `merge_group`; PR comment on PR only  |
| `reusable-site-quality.yml`            | Safe to run — no PR context required           |
| `reusable-build-artifact.yml`          | Safe to run — no PR context required           |
| `reusable-docker.yml`                  | Safe to run — no PR context required           |
| `reusable-test-shell.yml`              | Tests run; PR summary comment on PR only       |
| `reusable-test-python.yml`             | Tests run; PR summary comment on PR only       |
| `reusable-test-node.yml`               | Tests run; PR summary comment on PR only       |
| `reusable-test-node-custom.yml`        | Tests run; PR summary comment on PR only       |
| `reusable-test-e2e-playwright.yml`     | Tests run; PR summary comment on PR only       |
| `reusable-test-rust-build.yml`         | Safe to run — no PR context required           |
| `reusable-coverage.yml`                | Coverage runs; PR comment on PR only           |
| `reusable-semantic-pr-title.yml`       | No-op on `merge_group` — title validated on PR |

Test reusables gate their draft-PR skip on `github.event_name ==
'pull_request'`, so work jobs always run in the merge queue; PR summary
comments are gated on `pull_request` events in workflow conditions and in
`post-pr-comment.sh`, so they skip cleanly. Caller-side summary jobs (e.g.
the split `publish-quality-summary` pattern) already carry a
`github.event_name == 'pull_request'` guard and skip in the queue.

Semantic title validation is intentionally a no-op in the merge queue because
`amannn/action-semantic-pull-request` requires pull request context. The job
itself still runs (finishing in seconds with every step skipped): a job with a
dynamic `name:` that is skipped at job level reports its check under the raw
expression text (`semantic-title / inputs.job-name`), so the required context
would never arrive and queue entries would time out. Required checks produced
by reusables with configurable job names must therefore never carry job-level
event skips — skip at step level instead.

## Required-check-safe conditional workflows

`on.<event>.paths` filters must not be used on workflows that produce
**required checks**: when the paths don't match, the workflow never runs,
the check never reports, and the PR deadlocks (docs-only PRs block forever;
merge-queue entries time out). Paired no-op shim workflows are also
discouraged — duplicated job names and path filters drift apart silently.

Instead, drop the `paths:` filter, always run the workflow (including on
`merge_group`), and early-exit green via the `detect-changes` action:

1. A `changes` job runs `lgtm-hq/lgtm-ci/.github/actions/detect-changes`
   (checkout with `fetch-depth: 0` first) and exposes its `changes` output.
   The job must grant `contents: read` **and** `pull-requests: read`:
   `dorny/paths-filter` reads the PR files API on `pull_request` events even
   with full history, and fails with `Resource not accessible by integration`
   on a job that has only `contents: read` (#669).
2. Downstream jobs keep their **static job name** (the required check's
   identity) and gate their steps on
   `fromJSON(needs.changes.outputs.changes).<filter>`, running a cheap
   "skipped" step (~seconds) when the filter didn't match.

Minimal `changes` job:

```yaml
changes:
  runs-on: ubuntu-24.04
  permissions:
    contents: read
    pull-requests: read # dorny/paths-filter reads the PR files API (#669)
  outputs:
    changes: ${{ steps.detect.outputs.changes }}
  steps:
    - uses: actions/checkout@<sha> # vX.Y.Z
      with:
        fetch-depth: 0
    - uses: lgtm-hq/lgtm-ci/.github/actions/detect-changes@<sha> # vX.Y.Z
      id: detect
      with:
        filters: |
          docs:
            - 'docs/**'
```

`detect-changes` is a thin SHA-pinned wrapper around `dorny/paths-filter`
(v4.0.2+), which supports `merge_group` natively. The wrapper resolves the
diff base from `pull_request` (`event.pull_request.base.sha`), `merge_group`
(`event.merge_group.base_sha`), and `push` (`event.before`); when no base is
resolvable it **fails open** and reports every filter as changed, so a
required check runs its full job rather than silently early-exiting. Filters
are dorny YAML (see [detect-changes](actions/testing.md#detect-changes)).
Prior art for the caller pattern: homebrew-tap's
`validate-homebrew-formula.yml`.

Callers need `pull-requests: write` when `post-failure-comment` is enabled
(default). With `post-failure-comment: false`, `pull-requests: read` suffices.
Tooling is loaded from `lgtm-ci` via `prepare-semantic-pr-lists.sh` (supports
`tooling-ref` for unreleased fixes). The workflow passes newline-delimited
`types`/`scopes` to amannn (empty `types` uses the built-in default;
comma-separated overrides are normalized). On failure, `error_message` from
amannn (or the optional `max-length` check) is posted via `post-pr-comment`;
stale failure comments are cleared on success.

## Results contract (`schemas/results.v1.json`, #1080)

Every test, coverage and audit runner emits one normalized document per leg,
and every publisher reads only those documents. Nothing about test counts
travels through `needs.*.outputs` any more; the public workflow outputs are
derived from the same documents, so existing callers see identical values.

### The document

`schemas/results.v1.json` (JSON Schema 2020-12) describes `results.json`:

```json
{
  "tool": "pytest",
  "status": "passed",
  "counts": { "passed": 10, "failed": 0, "skipped": 1, "total": 11 },
  "duration_ms": 5250,
  "coverage": { "lines": 85.5, "branches": 70.25 },
  "artifacts": [{ "kind": "report", "path": "python/pytest-results.json" }],
  "source": { "runner": "run-pytest", "version": "<lgtm-ci sha>" },
  "matrix": { "key": "python-version", "value": "3.12" },
  "exit_code": 0
}
```

- `tool`, `status`, `counts`, `duration_ms`, `artifacts`, `source` are required;
  `coverage`, `matrix`, `exit_code` are optional. Unknown properties are rejected.
- `status` is one of `passed`, `failed`, `no-tests`, `error`. `error` means the
  native report was missing or unparseable; `failed` means a failed count or a
  non-zero runner exit; `no-tests` means a clean run with nothing counted. An
  audit leg reports its findings under `counts.failed` and a clean scan as
  `passed`.
- `coverage` is present only when coverage was collected. A metric the format
  does not measure (branches in line-only LCOV, functions in Cobertura) is
  omitted, never written as `0`.
- **Versioning:** v1 may gain optional properties; it never removes or
  retypes one. A breaking change is a new `results.v2.json` next to v1.

### Layout and artifact names

Each runner writes `results/<runner>/<matrix-key>/results.json` in its job
workspace and uploads that file under the artifact names the typed-name
convention already assigned (#752 / #1091). No existing name changed; the
file replaces the untyped `summary.json` that `<prefix>-results-<version>`
used to carry.

<!-- markdownlint-disable MD013 MD060 -- wide reference table -->

| Reusable                         | Runner / `tool`               | Document on disk                                     | Artifact                                          |
| -------------------------------- | ----------------------------- | ---------------------------------------------------- | ------------------------------------------------- |
| `reusable-test-python.yml`       | `run-pytest` / `pytest`       | `results/pytest/<python-version>/results.json`       | `<prefix>-results-<python-version>`               |
| `reusable-test-node.yml`         | `run-vitest` / `vitest`       | `results/vitest/<node-version>/results.json`         | `<prefix>-results-<node-version>`                 |
| `reusable-rust-test.yml`         | `run-rust-nextest` / `cargo-nextest` | `<wd>/results/nextest/<rust-toolchain>/results.json` | `<prefix>-results-<rust-toolchain>`        |
| `reusable-test-shell.yml`        | `run-bats-tests` / `bats`     | `<wd>/results/bats/default/results.json`             | `<prefix>-results` (new; single and sharded path) |
| `reusable-test-e2e-playwright.yml` | `run-playwright-tests` / `playwright` | `results/playwright/default/results.json`    | `results-artifact-name` (new; default `playwright-results-<run_id>`) |
| `reusable-security-audit.yml`    | `run-lintro-audit` / `osv-scanner` | `<wd>/results/security-audit/default/results.json` | `results-artifact-name` (new; default `security-audit-results`) |
| `reusable-coverage.yml`          | `collect-coverage` / `coverage` | `results/coverage/default/results.json`            | `<coverage-artifact-name>-results` (new)          |

<!-- markdownlint-enable MD013 MD060 -->

Inside the artifact the file is `results.json` at the root (upload-artifact
strips the common parent). Downloading `<prefix>-results-*` with
`merge-multiple: false` therefore yields `<name>/results.json` per leg, which is
what the aggregate and the publishers glob with `**/results.json`.

### Parsers and renderers

- `scripts/ci/lib/testing/parse/*.sh` stay the native parsers; each gains a
  pure `*_results_v1` wrapper (native file → document on stdout):
  `pytest_results_v1`, `vitest_results_v1`, `playwright_results_v1`,
  `junit_results_v1` (nextest), `tap_results_v1` (bats), `osv_results_v1`.
  `scripts/ci/lib/testing/results.sh` holds the builder (`results_v1_build`),
  the validator (`results_v1_validate`), `results_v1_github_outputs` (the
  `tests-*` / `coverage-percent` / `status` step outputs, read back from the
  document) and `results_v1_set_status` / `results_v1_set_coverage` for gates
  that run after the parser (`scripts/ci/actions/results-update.sh`).
- `scripts/ci/actions/render-test-summary.sh` (document(s) → PR comment),
  `render-step-summary.sh` (document → job step summary) and
  `render-pages-results.sh` (document(s) → `index.html` + `results.json` for a
  Pages site) read nothing but documents. The comment body still comes from
  `generate-test-summary.sh`, so a comment rendered from `results.json` is
  byte-identical to one rendered from the old job outputs for the same counts
  (`tests/bats/unit/actions/test_results_renderers.bats` asserts this). The
  one visible difference is the **Skipped** row: it now reports the real
  count where the old output chain hard-coded `0`.
- `aggregate-results.sh` validates every leg before summing, fails on a leg
  count that disagrees with the matrix, reports `status` (`error` > `failed`
  > `no-tests` > `passed`; one empty leg is not a passing matrix) and
  `passed` (every leg `passed`), and can write the merged document
  (`AGGREGATE_OUTPUT`) for the publishers. A single leg's coverage literal is
  passed through verbatim; several legs are averaged to two decimals, as
  before.
- A gate that fails after the parser ran (coverage threshold, Node's
  `post-test-command`) is recorded into the document by
  `results-update.sh` before the upload, so the artifact never carries a
  `passed` the job did not earn.
- `passed` (aggregate output, `reusable-required-check` document gate) keeps
  its pre-contract meaning: no leg failed. A `no-tests` leg (vitest
  `passWithNoTests`, nextest `--no-tests=pass`) is not a failure, while the
  aggregate `status` still reports `no-tests`.
- The shell reusable's `tests-passed` no longer counts `# skip` directives
  (bats prints them as `ok`); they are reported under `tests-skipped`.
- Rust's public `tests-total` output and comment total have always been
  `passed + failed` (skipped tests excluded from the pass rate). That stays:
  the rust aggregate runs with `TESTS_TOTAL_EXCLUDES_SKIPPED=true` and its
  publisher call sets `tests-total-excludes-skipped: true`, while
  `counts.total` in the document is the inclusive count.

### Who reads what

- **Aggregate jobs** (`python` / `rust` / `node`): always download this call's
  documents, by exact name for a single version
  (`<prefix>-results-<version>`, so two single-version siblings on different
  versions stay invisible to each other) or by `<prefix>-results-*` with the
  by-name matrix check for a multi-version call (#803). The workflow-level
  `tests-passed` / `tests-failed` / `tests-total` / `coverage-percent` /
  `passed` outputs are the aggregate's, for a single version and a matrix
  alike. The shell reusable's two paths (single job, sharded aggregate) each
  write and upload the document themselves.
- **`reusable-publish-test-summary.yml`**: new inputs
  `results-artifact-pattern` and `results-expected-count`. When the pattern
  is set the job downloads the documents and renders the totals comment from
  them; a missing, miscounted or malformed document fails the job rather than
  posting an empty comment. Without the pattern the `tests-*` /
  `coverage-percent` inputs render as before (direct callers are unaffected).
  The rich coverage path (`rich-coverage-comment`) is unchanged.
- **`reusable-required-check.yml`**: optional `results-artifact-pattern` /
  `results-expected-count`. When set, the gate downloads the documents and
  fails unless every one validates and reports `status: passed`, on top of
  the `upstream-result` / `passed-output` checks.
- **`reusable-coverage.yml`**: `coverage-percent` output and the fallback
  totals comment come from the document the coverage job writes.

### Conformance

`tests/bats/unit/lib/testing/test_results_contract.bats` runs every parser
fixture under `tests/fixtures/{pytest,vitest,playwright,junit,rust,security}`
through its wrapper and the schema, plus negative fixtures under
`tests/fixtures/results/`. The validator is a small jq interpreter of the
schema file itself (`type`, `properties`, `required`, `additionalProperties`,
`enum`, `minimum` / `maximum`, `minLength`, `pattern`, `items`, local `$ref`
without siblings); the whole schema file is preflighted before every
validation, so any other keyword anywhere in it is a hard error and the
schema cannot grow a construct that silently validates nothing. This was chosen over pinning a
JSON Schema CLI under the `versions.env` digest pattern (#1113): the contract
is one flat object, jq is already on every runner and in every tooling
checkout, and a pinned validator would have added a download plus two digests
to every test job for a check that takes ten lines of jq. Should v2 need
`oneOf` or formats, pin a validator then.

A consumer can validate its own run with the same library:

```bash
source .lgtm-ci-tooling/scripts/ci/lib/testing/results.sh
results_v1_validate results-download/python-results-3.12/results.json
```

## Fork PR summaries and reports

PR summaries and reports are skipped automatically on fork PRs (`head.repo.fork == true`).
This is enforced in `scripts/ci/actions/post-pr-comment.sh` and workflow `if`
conditions.

## Rustume example

Tag/release pipelines should call lint-only reusables (no `pull-requests: write`):

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🛠️ Lintro Code Quality & Analysis"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        ghcr.io:443
        api.osv.dev:443
        semgrep.dev:443
        metrics.semgrep.dev:443
```

Pull-request pipelines with comments call both reusables directly:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🛠️ Lintro Code Quality & Analysis"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        ghcr.io:443
        api.osv.dev:443
        semgrep.dev:443
        metrics.semgrep.dev:443

  publish-quality-summary:
    needs: quality
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-quality-summary.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      exit-code: ${{ needs.quality.outputs.exit-code }}
      tooling-ref: "<sha>"

  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>"
      job-name: "🔨 Build Check"
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        static.rust-lang.org:443
        crates.io:443

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🦀 Rust Coverage"
      coverage: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        static.rust-lang.org:443
        crates.io:443

  web-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node-custom.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🌐 Web Coverage"
      working-directory: apps/web
      package-manager: bun
      test-command: bun run test:coverage
      coverage: true
      publish-test-summary: true
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        registry.npmjs.org:443
```

## External verification

Every structural defect in lgtm-ci's history was found by a consumer after
release, never by the repository's own tests (#279, #294, #412/#420, #935, #995):
BATS asserts YAML shape and shell behaviour, but cannot observe
GitHub's action-path resolution, the harden-runner pre/post hooks,
cross-repository context or permission validation. Internal lgtm-hq callers
mask these because they share the owner and pass `tooling-ref`.

### The fixture

[`TurboCoder13/lgtm-ci-consumer-fixture`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture)
is a public repository outside the `lgtm-hq` org that consumes lgtm-ci only
through `uses: lgtm-hq/lgtm-ci/.github/workflows/<file>.yml@<sha>` and the
direct `lgtm-hq/lgtm-ci/.github/actions/<name>@<sha>` form, pinned to one
exact SHA in every workflow file, with **no `tooling-ref`** and **no copied
lgtm-ci files** (its `scripts/check-no-vendoring.sh` enforces that). Its
`scripts/pin.sh <sha>` rewrites every pin; the README records every
before/after run. What each workflow proves:

<!-- markdownlint-disable MD013 -- evidence table -->

| Fixture workflow | Proves | Role |
| --- | --- | --- |
| `python.yml`, `retry.yml`, `perms.yml` | Python reusable at an exact SHA with no `tooling-ref` (#995); documented-minimum caller permissions parse (#735/#736); two-leg matrix drives the artifact-availability wait (#803); frozen `uv sync` (#1021) | gate |
| `node-bun.yml`, `node-npm.yml`, `node-pnpm.yml` | Each package manager installs only its own toolchain and leaves every lockfile untouched (#1077) | gate |
| `rust.yml`, `verify-fresh-install.yml`, `vuln-suppression.yml` | cargo-nextest, cargo-llvm-cov and osv-scanner install from digest-verified archives under block-mode egress (#1096) | gate |
| `siblings.yml`, `rust-build-siblings.yml` | Sibling calls in one run get namespaced artifacts (`artifact-prefix`, #752/#1091) and namespaced concurrency groups (#1076) | gate |
| `egress.yml` | `egress-preset` reaches harden-runner's pre hook; a host present only in the selected preset is allowed, the control preset and the replace list deny it (#913) | gate |
| `actions-direct.yml`, `build-python-direct.yml` | Direct composite path with no lgtm-ci checkout: nested `uses:` resolve (#1075), default-branch preflight on a shallow tag checkout (#1087) | gate |
| `coverage-lcov.yml`, `playwright.yml` | Line-only LCOV through `reusable-coverage` (#1078); Playwright report artifact holds HTML + JSON + JUnit (#804) | gate |
| `python-private-dep.yml` | Private git dependency in an uninstalled group does not break a frozen install (#1021) | gate |
| `rust-release-build.yml` | Default `reusable-build-rust-binaries` matrix builds and runs a Windows binary (#1076) | gate |
| `app-token-probe.yml`, `sbom-release-upload.yml` | Scoped App-token reach (#849); SBOM assets attached to a disposable prerelease that the run deletes again (#935) | informational, expected `success` |
| `verify-negative.yml`, `playwright-negative.yml` | Negative-by-design: a wrong tool digest refuses to install (#1096); the failure-path Playwright artifact still carries the report (#804) | informational, expected `failure`; dispatched by its probe |
| `perms-negative.yml` | An under-permissioned caller is rejected at parse time | informational, expected `startup_failure`; dispatched by its probe |
| `perms-negative-node.yml`, `perms-negative-shell.yml`, `perms-negative-rust.yml` | The Node, shell and Rust facades, called with only the read scopes their read-only variants need, are rejected at parse time, before any job starts (#1081). The Rust negative lands on the fixture's main after its PR merges | informational, expected `startup_failure`; no probe yet, so the canary dispatches each directly |
| `readonly-node.yml` (and one `readonly-<family>.yml` per further variant) | The generated read-only variant (`reusable-*-run.yml`, #1081) runs green with read scopes only, and its check job asserts the tests ran. One workflow per variant, so a candidate that predates a variant loses only that gate (`not_applicable`). `readonly-shell.yml` is an expected gate; `readonly-rust.yml` lands after its PR merges and becomes one in the next family's PR | gate |
| `verify-negative-probe.yml`, `playwright-negative-probe.yml`, `perms-negative-probe.yml` | Each dispatches its negative on the same ref and asserts the designed failure: run conclusion plus job evidence (the `digest mismatch` annotation in both digest jobs; the failing e2e job next to a green report-verdict job; zero jobs for the parse-time rejection). Green exactly when the negative failed as designed; after a pass it deletes the red negative run, keeping its jobs and annotations in the probe's summary and `negative-evidence` artifact | informational, expected `success` |
| `release-version-pr.yml`, `release-benign-hook.yml`, `release-tamper-hook.yml` | `reusable-release-version-pr` from outside the org with the fixture's single-repo App: version PR, well-behaved hook, tampering hook stopped (#849). The three share one fixture concurrency group (concurrent dispatch cancels one) and every success opens a version PR a human closes, so the canary lists them as `not_dispatched` and runs them only with `CANARY_INCLUDE_MANUAL=true` | manual |

<!-- markdownlint-enable MD013 -->

`starter-python.yml` (the verbatim `examples/ci-python.yml`) runs on the
fixture's own pushes and has no `workflow_dispatch`, so the canary does not
dispatch it. `build-python-direct.yml` enforces the on-default-branch
preflight only on the fixture's `main` and tags: a canary branch commit is
by construction not on `main`, so on `canary/<sha>` the probe proves the
direct build path and the shallow-checkout handling, and the on-main check
is proven by the fixture's own pushes.

### The canary

`.github/workflows/external-consumer-canary.yml` runs the whole fixture
against one lgtm-ci candidate from inside lgtm-ci. Because GitHub forbids
expressions in `uses:`, the fixture cannot take the candidate as an input;
`scripts/ci/actions/external-canary.sh` instead:

1. resolves the candidate ref to a full SHA;
2. reads every fixture workflow from the fixture's `main`, rewrites each
   lgtm-ci pin to the candidate (the same pattern as the fixture's
   `scripts/pin.sh`), refuses any lgtm-ci reference that is not then pinned
   to the candidate, and commits the result through the git data API as the
   branch `canary/<sha>`. The fixture's `main` is never written;
3. looks up every lgtm-ci path each dispatchable fixture workflow
   references (`.github/workflows/<file>.yml`, `.github/actions/<name>`;
   push-only `starter-python.yml` is not checked) at the candidate through
   the contents API, deciding presence from the HTTP status (#1128), and
   every `with:` input it passes to an lgtm-ci reusable against that
   reusable's `workflow_call` inputs at the same refs (#1134): GitHub refuses
   a run that passes an undeclared input, so a new input the fixture adopts
   (such as `concurrency-scope`) would otherwise fail every older candidate,
   and a removed input is a consumer-breaking change. A path or input missing at the
   candidate is looked up at the candidate's merge base with `main`
   (compare API): present there means the candidate deletes or renames a
   public interface, reported `removed_by_candidate`, which fails the canary
   whatever the workflow's role; missing there too but present on `main`
   means it landed after the candidate branched, reported `not_applicable`
   (not dispatched, not a failure, the summary suggests a rebase). A path
   missing everywhere is dispatched as usual and the run reports it. A
   failed lookup fails the canary before any dispatch;
4. dispatches every gate and informational fixture workflow that declares
   `workflow_dispatch` on that branch (the fixture's `push` triggers are
   limited to `main`, so creating the branch starts nothing by itself);
   manual workflows are listed as `not_dispatched`. A negative-by-design
   workflow with a `<name>-probe.yml` is not dispatched directly: its row
   reads `via_probe` and the probe carries the verdict. A run that fails by
   design is red on the fixture's Actions page, a job calling a reusable
   cannot take `continue-on-error`, and a parse-time rejection cannot be
   caught inside its own run, so the assertion has to live in a second
   workflow. A probe inherits a `not_applicable` or `removed_by_candidate`
   verdict from its negative, and a negative whose probe is not dispatched
   is dispatched directly. A run that dispatches nothing at all (every
   workflow `not_applicable`) warns that nothing was exercised;
5. polls the fixture's run list until each dispatched workflow has a
   completed run, bounded at 25 minutes; a workflow whose dispatch was
   rejected is reported `dispatch_failed` at once instead of waiting;
6. writes a table (workflow, role, expected, conclusion, verdict, run URL) to
   the job summary, deletes the branch it created on every exit path, and
   fails when any **gate** workflow did not succeed (a `not_applicable` gate
   is not a failure) or any workflow is `removed_by_candidate`. Informational rows are
   compared with their expected conclusion and flagged `unexpected`, but
   never fail the run. The gate set is a fixed list in the script: a gate the
   fixture no longer exposes for dispatch is reported `not_dispatchable` and
   fails the canary, and a fixture workflow the script has never seen is a
   gate (fail closed).

When it runs:

- **Every pull request** starts the single canary job (`opened`,
  `synchronize`, `reopened`, `ready_for_review`, `labeled`) so the check
  always reports. The job lists the PR's changed files through the API (not
  an `on.pull_request.paths` filter, which would leave the check unreported
  and deadlock a required check) and runs the fixture set only when the PR
  touches `.github/workflows/**`, `.github/actions/**`, `scripts/ci/**`,
  `schemas/**` or `examples/**`. Otherwise it exits green with the summary
  line `Skipped: no adoption-relevant changes`.
- **Label `needs-external-canary`** forces the full set on any PR, whatever
  it touches; every later push to the labelled PR re-runs it at the new head.
  A `labeled` event for any other label is skipped, so adding an unrelated
  label does not re-run the fixture set.
- **Fork PRs skip**: they cannot read the secret. Re-run from a same-repo
  branch with the force label when a fork PR needs the evidence.
- **Dispatch it** from the Actions tab with `ref` set to any commit, branch or
  tag (empty means the commit the workflow was dispatched on, e.g. `main`).
  Dispatch always runs the full set.

**Override (owner only, by convention).** The label `canary-informational`
makes a run whose gate failed report success: each failed gate becomes a
`::warning` annotation and the summary says why the run is green. It exists
for the observation period, when a fixture defect or a GitHub incident must
not block unrelated work. GitHub lets anyone with triage access apply a
label, so "owner only" is a convention, not an enforced rule; the table
still shows the red rows so the failure stays visible. Remove the label once
the cause is fixed.

**Status.** The canary is **not** a required check yet and the ruleset is
untouched. It is promoted to required after an observation period on real
PRs and after `EXTERNAL_FIXTURE_TOKEN` is replaced by a GitHub App installed
on the fixture only (follow-up issue); the App removes the personal-token
expiry and ties the credential to the fixture instead of a person. Until
then a red canary is a signal to read, not a merge block. One full run
dispatches roughly 25 fixture workflows (one on a Windows runner), and the
release-path workflows open and leave a version PR in the fixture that is
closed by hand.

### Token scope and rotation

The only secret is `EXTERNAL_FIXTURE_TOKEN`, a fine-grained personal access
token owned by the fixture owner and stored as a repository secret on
`lgtm-hq/lgtm-ci`. It is scoped to the single repository
`TurboCoder13/lgtm-ci-consumer-fixture` with **Actions: read and write**
(dispatch and poll), **Contents: read and write** (create and delete the
`canary/<sha>` branch) and **Workflows: read and write** (GitHub refuses to
write anything under `.github/workflows/` without it, through the git data
API too; a token without it fails at "create tree" with HTTP 403). It has no
access to any lgtm-hq repository; the candidate ref and the PR file list are
read with the job's own `github.token`. The workflow passes it as one named
env value to one step, there is no `secrets: inherit`, and the hardened job
can reach only `github.com:443` and `api.github.com:443` (preset
`external-canary`).

What that does **not** protect against: on `pull_request` the job runs the
workflow and the script from the PR head, so a same-repository author with
push access can read the token or point it at the fixture's `main`. The
token's reach is the fixture only, which exists to be written by candidates,
and fork PRs never see the secret. Treat the PAT as a fixture credential, not
an lgtm-ci one; the GitHub App that replaces it (follow-up) issues
short-lived installation tokens, and a fixture ruleset on `main` is the
owner's lever against a hostile candidate.

Rotation: fine-grained tokens expire; generate a new one with the same three
permissions on the same single repository, update the secret, and run the
canary once by dispatch. A read-only API listing of the fixture's workflows
from a job is enough to confirm the new token before relying on it. If the
token is lost, revoke it in the owner's token settings; nothing else is
affected because it grants nothing outside the fixture.

## Related docs

- [release-security-policy.md](release-security-policy.md) — mandatory evidence,
  build-then-publish ordering, blocking failures and recovery for every publish
- [python-release-publish.md](python-release-publish.md) — Python tag-push layout
- [reusable-workflows.md](reusable-workflows.md) — per-workflow inputs and outputs
