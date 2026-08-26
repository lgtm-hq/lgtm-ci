# Reusable Workflows

Use reusable workflows from consumer repositories with a thin caller job.

**Tag/release and non-PR pipelines** should call lint/test/coverage reusables
directly (for example `reusable-quality-lint.yml`) with `contents: read` only.

**Grant what the workflow declares, not what your inputs use.** GitHub validates
a reusable workflow's permission requests **statically**, before any job `if:` is
evaluated, so the caller job must grant at least the union of every scope
declared across the called workflow's jobs — including jobs your inputs disable.
A caller that grants less does not get a step failure: the run dies at
`startup_failure` with nothing executed. Copy the permission block from the
example for the workflow you call instead of trimming it to the scopes the
feature you enabled appears to need. Where a scope looks broader than a
snippet's inputs warrant, that is the static check talking, and the fix belongs
in the workflow (see #730 for that pattern), not in the caller.

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
```

Pull-request pipelines with PR summaries and reports call both reusables directly:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read

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
```

Pass `tooling-ref` when testing an unreleased lgtm-ci branch on **script-backed**
reusables (quality, test-*, validate-*, release-*, etc.). Production callers
should pin the workflow ref to a commit SHA and pass the same ref as
`tooling-ref` on script-backed workflows.

## Scopes a caller cannot avoid granting

Sometimes a snippet asks for a scope that the inputs it shows plainly do not use.
That is either a bug in the workflow (a scope declared but never exercised —
the #730 case, fixed by deleting the declaration) or a scope a conditional job
really does need, in which case the static check forces it on everyone.

The audit in #737 classified the broad grants on `reusable-sbom.yml`,
`reusable-coverage.yml` and `reusable-test-e2e-matrix.yml`. **All of them were
real**, so none could be deleted. #770 removed them from those callers the only
way a genuinely-needed scope can be removed: by moving the job that needs it
into its own reusable workflow, which a caller invokes only when it publishes.

<!-- markdownlint-disable MD013 -- citation column exceeds default line length -->

| Scope | Now declared by | Why it is real |
| --- | --- | --- |
| `contents: write` | `reusable-sbom-release-upload.yml` | `gh release upload --clobber` with `GITHUB_TOKEN` (`scripts/ci/actions/upload-sbom-release-assets.sh:29`) |
| `pages: write` | `reusable-publish-test-results-pages.yml` | `actions/deploy-pages` posts `/repos/{owner}/{repo}/pages/deployments` with `GITHUB_TOKEN` |
| `id-token: write` | `reusable-publish-test-results-pages.yml` | `actions/deploy-pages` calls `core.getIDToken()` and sends it as the deployment's `oidc_token` |
| `actions: write` | `reusable-publish-test-results-pages.yml` | `gh api --method DELETE /repos/{}/actions/artifacts/{id}` clears stale same-run Pages artifacts on rerun (`scripts/ci/actions/delete-run-pages-artifacts.sh:45-46`, #415) |

<!-- markdownlint-enable MD013 -->

The `actions: write` row is worth contrasting with #730. There the scope was
requested for an `actions/upload-artifact/merge` step in
`reusable-test-python.yml`, which authenticates with the per-run
`ACTIONS_RUNTIME_TOKEN` rather than `GITHUB_TOKEN`, so `permissions:` never
gated it and the declaration was pure over-grant. (That step has since been
deleted outright — it was unreachable under every valid input combination, #756.)
Here the same scope name covers a genuine `GITHUB_TOKEN` REST call that
hard-fails without it. The scope string alone proves nothing — the credential
the code path uses decides it.

Scopes still forced on every caller of a producer workflow are the ones its
*unconditional* jobs need: `reusable-sbom.yml` requires `security-events: write`,
`id-token: write` and `attestations: write` (all declared by its `sbom` job), and
`reusable-coverage.yml` requires `pull-requests: write` (declared by
`publish-test-summary`). For the complete union a given workflow requires, use
its caller snippet below — those are the authoritative contract and are pinned by
`tests/bats/integration/test_reusable_permission_unions.bats`.

## Publishing split (#770)

Three workflows used to carry a conditional publishing job. Because a reusable
workflow's `permissions:` request is validated **statically**, before any job
`if:` is evaluated, that job's scopes were part of the union every caller had to
grant — including callers that had switched the job off. #770 moved the jobs out.

<!-- markdownlint-disable MD013 -- migration table; columns exceed default line length -->

| Was | Now |
| --- | --- |
| `reusable-coverage.yml` with `publish-pages: true` | `reusable-coverage.yml` + a caller job on `reusable-publish-test-results-pages.yml` |
| `reusable-test-e2e-matrix.yml` with `publish-results: true` | `reusable-test-e2e-matrix.yml` + a caller job on `reusable-publish-test-results-pages.yml` |
| `reusable-sbom.yml` with `upload-release-assets: true` | `reusable-sbom.yml` + a caller job on `reusable-sbom-release-upload.yml` |
| `reusable-sbom.yml` with `mode: release-assets` | same call (it now uploads a workflow artifact) + a caller job on `reusable-sbom-release-upload.yml` |

<!-- markdownlint-enable MD013 -->

### Deprecation window

`publish-pages`, `publish-results`, `pages-target-dir`, `publish-egress-preset`,
`publish-allowed-endpoints` and `upload-release-assets` are still **accepted**
and are **inert**. They are not deleted yet on purpose: a reusable workflow
rejects an unknown input with a hard `startup_failure`, so removing them outright
would break every pinned caller at parse time instead of letting it migrate.
Setting any of them to a non-default value emits a `::warning::` and a job-summary
block naming the replacement. They will be removed a release or two out.

The `pages-url` output of `reusable-coverage.yml` and the `report-url` output of
`reusable-test-e2e-matrix.yml` are kept for the same reason and are always empty.
Read `pages-url` off the `reusable-publish-test-results-pages.yml` job instead.

### Shared Pages publisher (`reusable-publish-test-results-pages.yml`)

One publisher, not one per producer. Both former `publish` jobs wrapped the same
`publish-test-results` composite action with the same three write scopes, the
same `pages-<repo>-<ref>` concurrency group and the same `github-pages`
environment; only the action's path inputs differed. The concurrency group and
the environment moved with the job.

`artifact-name` and `pages-target-dir` are **required**: the Pages directory is
URL-visible, and defaulting it would publish a half-migrated caller's report over
the site root. `results-path`, `coverage-path` and `badge-path` are relative to
the **downloaded artifact's root**, where `.` means the root itself and the empty
string means "this artifact has no content of that kind".

```yaml
jobs:
  coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  publish-coverage:
    needs: coverage
    if: github.ref == 'refs/heads/main'
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-results-pages.yml@<sha>
    permissions:
      contents: read
      pages: write
      id-token: write
      actions: write
    with:
      artifact-name: coverage-report # the call's coverage-artifact-name
      pages-target-dir: coverage # reproduces the pre-#770 URL
      coverage-path: "." # working-directory '.'; otherwise pass it here
      badge-path: coverage # otherwise '<working-directory>/coverage'

  e2e-matrix:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-matrix.yml@<sha>
    permissions:
      contents: read

  publish-e2e:
    needs: e2e-matrix
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-results-pages.yml@<sha>
    permissions:
      contents: read
      pages: write
      id-token: write
      actions: write
    with:
      artifact-name: playwright-merged-report # '<artifact-prefix>-merged-report'
      pages-target-dir: playwright # reproduces the pre-#770 URL
      results-path: "."
```

### SBOM release upload (`reusable-sbom-release-upload.yml`)

`reusable-sbom.yml` no longer contains a `gh release upload`. In both modes it
leaves the SBOM files behind as a workflow artifact named `artifact-name`, and
this workflow attaches them to the release.

```yaml
jobs:
  sbom:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
      attestations: write
    with:
      mode: release-assets
      release-tag: ${{ github.ref_name }}

  sbom-release-upload:
    needs: sbom
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom-release-upload.yml@<sha>
    permissions:
      contents: write
    with:
      artifact-name: sbom
      release-tag: ${{ github.ref_name }}
```

**Changing a reusable workflow's permissions or inputs does not automatically
mean `examples/**` and `docs/onboarding.md` need the same change.** Those
snippets pin `uses:` and `tooling-ref` to a released commit SHA, not the
workflow tip (#765) — deliberately: pinning by SHA is the right security
posture for consumers copying a snippet, so examples keep pinning rather than
tracking a floating major. A fix landing on `main` only reaches the examples
once their pin is next bumped to a release that carries it. #730 is the
cautionary case: reflexively syncing the caller snippet to a permissions fix
that hadn't shipped yet made `examples/ci-python.yml` `startup_failure` for
anyone copying it, and it took a corrective restore (`d6190c1`) to fix. Check
which release the example is pinned to before assuming a workflow change
needs a matching example edit.

## Runner pinning

Script-backed reusables accept `runner-image` on every job. Pin explicitly in
production so runner OS does not drift with GitHub's `ubuntu-latest` alias:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    with:
      runner-image: ubuntu-24.04
      tooling-ref: <sha>
```

Multi-arch Docker builds use `runner-map` instead — see
[Docker workflow inputs](#docker-workflow-inputs) below. Action-only reusables and
npm/gem publish workflows do not expose `runner-image`; see
[workflow-contract.md](workflow-contract.md#runner-pinning).

**Action-only reusables** (labeler, dependency review, semantic PR title,
CodeQL, Scorecard) do not run the full `scripts/ci/` suite in their analysis
jobs; `tooling-ref` is optional and primarily pins egress composites.
**`reusable-codeql.yml`** is an exception when callers pass `languages` or
`language-build-modes`: its setup job sparse-checkouts
`scripts/ci/actions/generate-codeql-matrix.sh` to build per-language matrix
legs. Each leg still uses `github/codeql-action/*` with the resolved
`build-mode` — not caller repo scripts. Pass `tooling-ref` when testing
unreleased matrix-generator changes. See
[workflow-contract.md](workflow-contract.md#action-only-reusables).

Consumers do **not** need to vendor `.github/actions/harden-runner` or
`resolve-egress-allowlist` — reusables sparse-checkout lgtm-ci into
`.lgtm-ci-tooling/` and invoke `./.lgtm-ci-tooling/.github/actions/...` (same
`tooling-ref` / `github.workflow_sha` as other tooling steps).

See [workflow-contract.md](workflow-contract.md) for the standard input contract,
permissions by mode, egress allowlists, and Rust examples.

Caller examples live under [examples/](../examples/) (see [examples/README.md](../examples/README.md)).

For GitHub Pages (coverage, test reports, and static sites), see
[pages-publishing.md](pages-publishing.md).

## Artifact names

`actions/upload-artifact` v4+ rejects a second upload of an existing name with
`409 Conflict`. Every artifact upload in a reusable workflow therefore sets
`overwrite: true`, so a caller that invokes the same reusable twice in one run
(a bounded retry, or two legs of a fan-out) publishes the latest attempt rather
than failing — the latest attempt is authoritative.

Report-style convenience artifacts (link reports, validation reports, audit
comment payloads, test-summary coverage payloads, debug Playwright/TAP output)
additionally upload with `continue-on-error: true` and warn, so a storage hiccup
never reddens a job whose actual verdict is green. Artifacts that are a job's
verdict or a downstream job's required input (build outputs, dists, per-matrix
result summaries, Pages coverage bundles, merged reports) keep hard failure.

Sibling reusables that a caller can run in the same run use **distinct default
artifact names**, and expose an input so a caller running one workflow twice can
disambiguate further:

<!-- markdownlint-disable MD013 -->

| Workflow                           | Input                       | Default                      |
| ---------------------------------- | --------------------------- | ---------------------------- |
| `reusable-link-check.yml`          | `link-report-artifact-name` | `lychee-report`              |
| `reusable-site-quality.yml`        | `link-report-artifact-name` | `site-lychee-report`         |
| `reusable-test-node.yml`           | `coverage-artifact-name`    | `node-coverage`              |
| `reusable-test-node-custom.yml`    | `coverage-artifact-name`    | `node-custom-coverage`       |
| `reusable-test-e2e-playwright.yml` | `report-artifact-name`      | `playwright-report-<run_id>` |
| `reusable-test-e2e.yml`            | `report-artifact-name`      | `e2e-report-<run_id>`        |
| `reusable-coverage.yml`            | `coverage-artifact-name`    | `coverage-report`            |

<!-- markdownlint-enable MD013 -->

`pages-coverage-artifact-name` still defaults to `coverage-html` on **both**
`reusable-test-node.yml` and `reusable-test-node-custom.yml`, because that name
is baked into consumers' Pages bundles. A caller that enables
`upload-pages-coverage-html` on both in one run must override one of them.

## Quality And Validation

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      job-name: "Lintro Quality Checks"
      egress-preset: quality

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

  # The `linting-report` artifact is best-effort. `reusable-quality-lint`
  # uploads it with `continue-on-error`, and this workflow downloads it the
  # same way — a storage hiccup emits a warning and skips the summary, and
  # never turns a passing lint run red. `status` and `exit-code` always
  # reflect the lint result alone. The upload also sets `overwrite: true`, so
  # a caller that runs the lint twice in one run (a bounded retry) publishes
  # the latest attempt's report rather than keeping the first one.

  validate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      script: scripts/ci/validate.sh
```

### Structured lint report and timeout verdict (`reusable-quality-lint.yml`)

A tool that exceeds its execution timeout makes lintro exit `1` with
`status=failed` — indistinguishable from a genuine finding through `exit-code`
and `status` alone. The lint job therefore also publishes the structured JSON
report from **its own** run and derives a verdict from it.

lintro writes the report to `.lintro/artifacts/json/results.json` (auto-emitted
under GitHub Actions, so `--output-format grid` and the `chk-output.txt` every
consumer parses are untouched). `scripts/ci/actions/classify-lint-timeout.py`
reads it and sets the outputs below.

<!-- markdownlint-disable MD013 -->

| Input                | Type    | Required | Default | Purpose                                                      |
| -------------------- | ------- | -------- | ------- | ------------------------------------------------------------ |
| `upload-json-report` | boolean | no       | `true`  | Upload the JSON report as the `linting-json-report` artifact |

| Output            | Value                                                                     |
| ----------------- | ------------------------------------------------------------------------- |
| `timeout-flake`   | `'true'` only when ≥1 tool timed out **and** the run reported zero issues |
| `timed-out-tools` | Comma-separated names of the tools that timed out, `''` when none         |

<!-- markdownlint-enable MD013 -->

`upload-json-report` is separate from `upload-report` so a caller can consume
the verdict without paying for the artifact — the outputs are derived either
way. Both uploads are best-effort (`continue-on-error`), so a storage hiccup
warns rather than failing a job whose code passed.

**The classifier fails closed.** `timeout-flake` is `'true'` only when the
report positively proves a timeout with no findings anywhere. A missing or
malformed report, a non-timeout tool failure, an internally inconsistent
report, or any issue at all yields `'false'`. Absence of evidence is never
evidence of a flake.

**The verdict describes only the run that produced it.** A tool that times out
contributes zero findings precisely because it did not finish, so a clean
verdict here cannot clear a failure reported by a different lint job — a
different file scope or ordinary timing variance is enough for the two to
disagree. Consuming it across jobs can turn a required check green over a
genuine finding; only the job that produced the report may act on it.

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read

  # !cancelled() is required: a timeout makes the quality job fail, and a
  # dependent job is skipped by default when what it needs failed — so
  # without it this job never runs in exactly the case it exists for. It is
  # preferred over always(), which would also run on a cancelled run.
  retry-on-timeout:
    needs: quality
    if: >-
      !cancelled()
      && needs.quality.outputs.timeout-flake == 'true'
    runs-on: ubuntu-24.04
    steps:
      - run: |
          echo "::warning::lintro timed out: ${{ needs.quality.outputs.timed-out-tools }}"
```

A caller that sets none of the new inputs and reads none of the new outputs
behaves exactly as before: `exit-code` and `status` keep their existing
meanings and still reflect the lint result alone.

### Org ruleset gate (`reusable-required-check.yml`)

Thin aggregate-status gate for org rulesets. Like every `uses:` job, it
reports its check as `{caller_job_id} / {job-name}` — the ruleset must
require that prefixed path (below:
`test-suite-coverage / 🧪 Test Suite & Coverage`), never the unprefixed
`job-name`. Only inline `runs-on` jobs match on `name:` alone. See
[workflow-contract.md](workflow-contract.md) (Org ruleset check names) and
the ruleset registry in [org-rulesets.md](org-rulesets.md).

```yaml
test-suite-coverage:
  needs: test
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@<sha>
  permissions:
    contents: read
  with:
    tooling-ref: <sha>
    job-name: "🧪 Test Suite & Coverage"
    upstream-result: ${{ needs.test.result }}
    passed-output: ${{ needs.test.outputs.passed }}
```

## Tests

```yaml
jobs:
  node:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      node-versions: "20,22"
      pre-test-command: bun run build
      upload-build-artifact: true

  python:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      coverage: true
      upload-coverage: true

  shell:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-shell.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-path: tests/bats

  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      browsers: chromium

  e2e-playwright:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-playwright.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      job-name: "🎭 E2E Tests"
      browsers: chromium
      grep: "@smoke"

  e2e-matrix:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-matrix.yml@<sha>
    permissions:
      # Just read since #770: the Pages deploy moved to
      # reusable-publish-test-results-pages.yml, which the caller invokes in its
      # own job when it publishes.
      contents: read
    with:
      test-suites: smoke,visual
      browsers: chromium,firefox
```

`reusable-publish-test-summary.yml` is the shared internal workflow used by
language test reusables to publish test summaries (rich coverage table when
coverage was collected, otherwise test pass/fail totals). Artifact-based comments
use `reusable-publish-artifact-report.yml`.
Quality lint-only checks use `reusable-quality-lint.yml`; PR lint summaries use
`reusable-publish-quality-summary.yml` (called directly by the caller workflow).

### Playwright E2E (`reusable-test-e2e-playwright.yml`)

Thin callers express full / smoke / a11y as separate jobs with distinct
`job-name` values. `project` and `grep` append to `test-command` (default
`npx playwright test`). Browser cache key uses the resolved Playwright version.
Reports upload on failure only when `upload-report` is true. Default egress
preset is `playwright`.

<!-- markdownlint-disable MD013 -->

| Input             | Type    | Required | Default               | Purpose                          |
| ----------------- | ------- | -------- | --------------------- | -------------------------------- |
| `job-name`        | string  | yes      | —                     | Check / summary title            |
| `test-command`    | string  | no       | `npx playwright test` | Base CLI                         |
| `project`         | string  | no       | empty                 | `--project` filter               |
| `grep`            | string  | no       | empty                 | `--grep` filter                  |
| `browsers`        | string  | no       | `chromium`            | install `--with-deps` targets    |
| `upload-report`   | boolean | no       | `true`                | HTML/blob artifact on failure    |
| `base-url`        | string  | no       | empty                 | `BASE_URL` passthrough           |
| `web-server`      | string  | no       | empty                 | `PLAYWRIGHT_WEB_SERVER`          |

<!-- markdownlint-enable MD013 -->

Outputs: `tests-passed`, `tests-failed`, `tests-total`, `passed`.

### Pages coverage HTML inputs (`reusable-test-node`)

<!-- markdownlint-disable MD013 -- prettier table column alignment -->

| Input                           | Type    | Required | Default         | Purpose                               |
| ------------------------------- | ------- | -------- | --------------- | ------------------------------------- |
| `upload-pages-coverage-html`    | boolean | no       | `false`         | Upload flat HTML for Model B bundling |
| `pages-coverage-artifact-name`  | string  | no       | `coverage-html` | Flat HTML artifact name               |
| `pages-coverage-upload-on`      | string  | no       | `push-main`     | Upload gate selector (v1)             |
| `pages-coverage-source-subpath` | string  | no       | `coverage`      | HTML dir under `working-directory`    |

<!-- markdownlint-enable MD013 -->

Outputs: `pages-coverage-artifact-name`, `pages-coverage-uploaded` (`true`/`false`).

**`pages-coverage-upload-on` (v1):** The `(v1)` suffix marks the first supported
upload-gating behavior. Additional values may be added in later releases without
breaking existing callers. Use the literal string values below — they are not
Git ref aliases.

| Value       | Meaning                                                                          |
| ----------- | -------------------------------------------------------------------------------- |
| `push-main` | Upload only when `github.event_name == push` and `github.ref == refs/heads/main` |

When `node-versions` is a matrix, only the **first** listed version uploads the
flat artifact (avoids `upload-artifact` name collisions). Matrix debug artifacts
(`node-coverage-<version>/…`) are unchanged when `upload-coverage: true`.

**Job display names:** Vitest and custom Node tests are **split workflows**
(`reusable-test-node.yml` and `reusable-test-node-custom.yml`). Each test job uses
`${{ inputs.job-name }}` for the GitHub check label — there are no mutually
skipped Vitest/custom siblings. For Python, Docker per-platform, and E2E matrix
jobs, inner names are static; see [workflow-contract.md](workflow-contract.md)
(§ Job display names).

**test summaries:** Set `publish-test-summary: true` (default) to post or update one
comment per workflow run. All publish paths delegate to
`reusable-publish-test-summary.yml` — rich coverage when `coverage: true`
(single runtime only), pass/fail totals otherwise. Multi-runtime matrices
(`node-versions`, `python-versions`, `rust-toolchains`) are **compat mode**
only: `coverage: false` and `publish-test-summary: false`. See
[workflow-contract.md](workflow-contract.md) (§ Compat vs coverage contract).

### Rust

Use `reusable-rust-build.yml` for compile checks and `reusable-rust-test.yml` for
tests. Set `coverage: false` for fast nextest-only runs or `coverage: true` for a
single instrumented `llvm-cov nextest` run (tests + LCOV). See
[rust-testing.md](rust-testing.md).

```yaml
jobs:
  rust-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-build.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Build"
      egress-policy: block

  rust-compat:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      # Declared by the `publish-test-summary` job; still required with
      # publish-test-summary: false, since the request is validated statically.
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Compat"
      rust-toolchains: "stable,beta"
      coverage: false
      publish-test-summary: false
      egress-policy: block

  rust-test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Tests"
      rust-toolchain: stable
      coverage: false
      egress-policy: block

  rust-coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-rust-test.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Rust Coverage"
      coverage: true
      egress-policy: block
      upload-pages-coverage-html: true
      pages-coverage-artifact-name: rust-coverage-html
```

### Pages coverage HTML inputs (`reusable-rust-test` with `coverage: true`)

<!-- markdownlint-disable MD013 -- prettier table column alignment -->

| Input                          | Type    | Required | Default              | Purpose                            |
| ------------------------------ | ------- | -------- | -------------------- | ---------------------------------- |
| `upload-pages-coverage-html`   | boolean | no       | `false`              | Upload flat HTML for Model B sites |
| `pages-coverage-artifact-name` | string  | no       | `rust-coverage-html` | Rust HTML artifact name            |
| `pages-coverage-upload-on`     | string  | no       | `push-main`          | Upload gate selector (v1)          |

<!-- markdownlint-enable MD013 -->

Outputs: `pages-coverage-artifact-name`, `pages-coverage-uploaded` (`true`/`false`).

### Rust release (cross-compile from Linux)

Use `reusable-publish-rust-release.yml` on tag pushes for block-only binary
builds and GitHub release creation. The orchestrator verifies the tag against
`Cargo.toml`, calls `reusable-build-rust-binaries.yml` (strict tier,
`rust-release` egress preset), and uploads all matrix artifacts to a release.

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  release:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-rust-release.yml@<sha>
    permissions:
      contents: write
      id-token: write
      attestations: write
    with:
      tooling-ref: "<sha>"
      packages: "my-cli,my-server"
```

See [workflow-contract.md](workflow-contract.md#rust-release-contract) for artifact
naming, default target matrix, and runner policy tiers.

**`pages-coverage-upload-on` (v1):** Same gating semantics as the Node reusable
(see table above). `push-main` is a literal selector meaning push events to
`refs/heads/main`; it is not a Git ref alias. The `(v1)` suffix denotes the
current upload-gating API; new non-breaking values may appear in later releases.

HTML is generated in the same job as the LCOV run via `cargo llvm-cov report --html`
(no second test run). The script flattens cargo-llvm-cov's `<output-dir>/html/`
layout so the artifact root is browsable HTML.

## Release

`reusable-release-version-pr.yml` generates Keep a Changelog section headings
(`Added` / `Changed` / `Fixed`) as of v0.43.1. If your pin predates that, see
[release-changelog.md](release-changelog.md) for the consumer migration guide
(minimum pin, heading mapping, MD024 lint note).

When release automation fails on the default branch, the follow-up
`report-release-failure` job runs two steps in order: it first writes release
trigger context to the job step summary, then creates or updates a deduplicated
GitHub issue with failed step details. Set `report-failures: false` to disable
both actions. See [workflow-contract.md](workflow-contract.md) for inputs.

### Main failure notifier

`reusable-main-failure-notifier.yml` generalizes the same dedup'd-issue
mechanism for **any** main-branch workflow (docker publish, Pages deploy,
dogfood lint, …) — with auto-merge and merge queue landing PRs unattended,
nobody is watching main between merges. Call it from a failure-gated job:

```yaml
notify-failure:
  needs: [build]
  if: failure() && github.ref == 'refs/heads/main'
  # yamllint disable-line rule:line-length
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-main-failure-notifier.yml@<sha> # vX.Y.Z
  with:
    workflow-key: docker-publish # stable key: one open issue per key+branch
  permissions:
    actions: read
    contents: read
    issues: write
```

Repeat failures comment on the existing open issue instead of filing new
ones (tracking key `main-workflow-failure:<key>:<branch>`). Companion
convention: while such an issue is open, treat main as red — disarm pending
auto-merges (`gh pr merge --disable-auto`) until a fix-forward PR lands.

`report-failures` defaults to `true`. GitHub rejects a reusable-workflow call at
startup when the caller job does not grant every permission the reusable
workflow declares. Grant at least `actions: read` and `issues: write` on the
caller job, or pass `report-failures: false` when upgrading from a release that
did not include failure reporting.

### Auto re-run on infra failure

`reusable-auto-rerun-on-infra-failure.yml` re-runs the failed jobs of a
completed workflow run when — and only when — the failed-job logs match a
known transient-infrastructure signature. Built-in signatures:

- `Failed to resolve action download info`
- `The runner has received a shutdown signal`
- `Error resolving allowed domain`
- `lost communication with the server`
- `fetching ambient OIDC credentials`
- `retrieving ID token`
- `reading ID token`

The last three are cosign's transient ambient-OIDC markers, single-sourced from
`scripts/ci/lib/cosign.sh` so the in-step signing retry and this after-the-fact
safety net cannot drift apart. The in-step retry is the fast path; this matcher
covers the case where that retry is exhausted and the publish fails outright.

Signatures are matched as fixed strings, case-sensitively: every default is
stored in the exact case its source emits, so case-insensitive matching would
only widen what auto-rerun fires on.

Extend the list via the multiline `signatures` input (newline-separated,
appended to the defaults). When no signature matches, the job writes a step
summary and exits successfully without re-running — a real failure stays
failed. `max-reruns` (default `1`) caps automation per run: attempts beyond
the cap exit without re-running, so a persistent outage can never loop.
This repository's own caller and the consumer example set `max-reruns: "3"`
because a single retry does not converge runner-shutdown kill streaks
(#833). The reusable default stays `1` so existing callers keep their
current bound.

`workflow_run: completed` can fire before GitHub finishes ingesting the log
tail, so the matcher refetches the failed-job logs while they come back empty
(or the fetch errors) — up to `LOG_FETCH_ATTEMPTS` times (default `5`, must be at
least `1`) with `LOG_FETCH_DELAY` seconds between attempts (default `5`), both
script-level env knobs rather than workflow inputs. The first non-empty payload is matched
immediately, so the happy path never sleeps. When the logs never arrive the job
reports *inconclusive: logs unavailable* and exits successfully — deliberately
distinct from "no signature matched … the failure looks real", which is only
claimed when logs were actually read. If the final fetch attempt errors outright
(rather than returning an empty payload) the job fails instead, so a broken
`gh run view` is surfaced rather than reported as a quiet inconclusive.

Every `gh` call runs under `timeout`, bounded by `GH_CMD_TIMEOUT` seconds
(default `60`, must be at least `1`), and the refetch loop as a whole is bounded
by `LOG_FETCH_DEADLINE` seconds (default `180`, checked before each attempt).
Without those bounds a stalled `gh run view --log-failed` consumed the entire
job budget and the safety net never fired at all. A killed fetch is retryable
like an empty one, so a single slow attempt followed by a fast one still
re-runs. When the bounds are exhausted the job reports *timed out reading logs*
— a fourth outcome, deliberately distinct from *inconclusive: logs unavailable*
(GitHub answered with nothing) and from "no signature matched" (logs were read)
— and exits successfully without re-running. A `gh run rerun` that is killed or
errors fails the job loudly instead, because a matched signature the script
could not act on needs a human. A coreutils `timeout` is required: the script
picks whichever of `timeout` or `gtimeout` is on `PATH` — `runner-image` is a
caller input, and macOS runners ship the binary under the second name — and
fails up front when neither is present rather than silently reverting to
unbounded calls. Set `TIMEOUT_BIN` explicitly to name a different binary.

Those bounds cover `gh`; they cannot cover the shell itself. A quadratic
parameter expansion over a multi-megabyte failed-job log once burned the whole
10-minute job timeout inside a single bash command, with every `gh` bound
untouched and no output at all. So the script also announces itself before any
work, logs the phase and payload size it is working on, reads nothing from
stdin, and runs under its own watchdog: `WATCHDOG_DEADLINE` seconds (default
`420`, must be at least `1`) for the whole script, after which it prints the
phase it was stuck in and exits **successfully**. A safety net declining to act
must never add a second red job to a run that already failed, and a hang that
names itself is triageable where ten minutes of silence is not. Keep
`WATCHDOG_DEADLINE` below the job's `timeout-minutes`, or the job timeout wins
and you are back to the silent version.

Call it from a thin `workflow_run` consumer gated on a failed conclusion
(see [examples/auto-rerun-on-infra-failure.yml](../examples/auto-rerun-on-infra-failure.yml)):

```yaml
"on":
  workflow_run:
    workflows: ["CI", "Deploy Pages", "Coverage"]
    types: [completed]

jobs:
  rerun:
    if: github.event.workflow_run.conclusion == 'failure'
    # yamllint disable-line rule:line-length
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-auto-rerun-on-infra-failure.yml@<sha> # vX.Y.Z
    permissions:
      actions: write
      contents: read
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      run-id: ${{ format('{0}', github.event.workflow_run.id) }}
      run-attempt: ${{ format('{0}', github.event.workflow_run.run_attempt) }}
      max-reruns: "3"
```

Caveats: `workflow_run` triggers only execute from the workflow definition on
the **default branch**, so the caller file must land on main before it fires.
`workflow_run.workflows` matches workflow `name:` values, not file names. The
run id and attempt are numbers in the event payload; wrap them in `format()`
so they arrive as the strings the inputs expect.

Recommended caller `run-name` (reusable workflows cannot set this for you):

```yaml
name: Release Version PR
run-name: >-
  Release version PR via ${{ github.event_name }} on ${{ github.ref_name }}
  @ ${{ github.sha }}
```

Including `${{ github.event_name }}`, `${{ github.ref_name }}`, and
`${{ github.sha }}` in the `run-name` makes it easier to triage failures: the
workflow run list shows the triggering event, branch, and commit so you can
quickly correlate a failed run with the code and event that started it.

```yaml
jobs:
  version-pr:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
      actions: read
      issues: write
    with:
      ecosystems: node,ruby,python
      skip-patterns: "^chore(release):"
      auto-merge-patch-only: false
    secrets: inherit

  auto-tag:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-auto-tag.yml@<sha>
    permissions:
      contents: write
      actions: read
      issues: write
    with:
      create-release: false
    secrets: inherit
```

> **Release App prerequisite.** `reusable-release-auto-tag` requests
> `Workflows: Read and write` on the App token — the `Update floating tag`
> step force-pushes the major tag onto the release commit, which GitHub treats
> as a workflow update whenever the range touches `.github/workflows/**`. An
> App without that permission fails at
> `Create GitHub App installation token`, before any tag or release is
> created. See
> [onboarding.md](onboarding.md#upgrading-an-existing-release-app) for the
> upgrade path, including the installation approval step.

**Multi-ecosystem version PR** (explicit file→kind map; sibling of version-pr):

```yaml
jobs:
  version-pr:
    # yamllint disable-line rule:line-length
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-multi-ecosystem.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
      actions: read
      issues: write
    with:
      job-name: "Create Version PR"
      tooling-ref: "<sha>"
      manifests: >
        {"package.json":"npm","VERSION":"raw",
        "python/pyproject.toml":"pep621","my.gemspec":"gemspec"}
      bump: auto-from-commits
      changelog: true
      # prerelease-tag: rc.1   # optional → 1.2.3-rc.1
    secrets: inherit
```

**Cargo workspace auto-tag** (Rust monorepos that bump `Cargo.toml` on `main`):

```yaml
name: Release - Auto Tag

on:
  push:
    branches: [main]
    paths:
      - Cargo.toml

jobs:
  auto-tag:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-auto-tag.yml@<sha>
    permissions:
      contents: write
      actions: read
      issues: write
    with:
      version-source: cargo
      version-file: Cargo.toml
      skip-if-unchanged: true
      create-release: false
    secrets: inherit
```

`guard-release-commit` skips non-`chore(release):` commits — version bumps must
use a `chore(release):` subject or the job writes a skip summary without tagging.
`skip-if-unchanged` compares the Cargo version to the latest `tag-prefix` tag
before creating a new tag.

## Publishing And Deployment

```yaml
jobs:
  npm:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm.yml@<sha>
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      node-version: "24"
      # Prefer OIDC trusted publishing (no secrets). Optional legacy:
      # secrets: { npm-token: ${{ secrets.NPM_TOKEN }} }
```

Configure an npm trusted publisher for the **caller** workflow filename and
allow the `npm publish` action. Use Node 24 (default); never
`npm install -g npm`. Full recipe:
[workflows/publishing.md](workflows/publishing.md#reusable-publish-npmyml).

```yaml
jobs:
  pypi-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-python-dist.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      artifact-name: python-dist

  pypi-upload:
    needs: pypi-build
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      contents: read
      id-token: write
      attestations: write
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@<pin> # v2.19.4
        with:
          egress-policy: block
          # workflow-contract.md § PyPI upload (OIDC)
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
            fulcio.sigstore.dev:443
            rekor.sigstore.dev:443
            tuf-repo-cdn.sigstore.dev:443
            oauth2.sigstore.dev:443
      - name: Prepare PyPI upload
        id: prepare
        uses: lgtm-hq/lgtm-ci/.github/actions/prepare-pypi-upload@<sha> # vX.Y.Z
        with:
          artifact-name: python-dist
          tooling-ref: "<sha>"
      - name: Upload to PyPI
        uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
        with:
          repository-url: https://upload.pypi.org/legacy/
          packages-dir: ${{ steps.prepare.outputs.dist-path }}
      - name: Attest build provenance
        continue-on-error: true
        uses: actions/attest-build-provenance@a2bbfa25375fe432b6a289bc6b6cd05ecd0c4c32 # v4.1.0
        with:
          subject-path: ${{ steps.prepare.outputs.dist-path }}/*

  github-release:
    needs: pypi-upload
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-github-release.yml@<sha>
    permissions:
      contents: write
    with:
      artifact-name: python-dist
      tooling-ref: "<sha>" # vX.Y.Z

  gem:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-gem.yml@<sha>
    permissions:
      contents: read
      id-token: write

  # reusable-deploy-pages.yml is deploy-only: the caller builds the site and
  # uploads the Pages artifact, then this workflow deploys it.
  build-site:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # v6.x
        with:
          persist-credentials: false
      # ... build the site into ./dist however the repo builds ...
      - uses: actions/upload-pages-artifact@<sha> # v4.x
        with:
          name: github-pages
          path: dist

  pages:
    needs: build-site
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-pages.yml@<sha>
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      artifact-name: github-pages
```

### Site + bundled CI reports (Model B)

```yaml
deploy-site:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-deploy-site-with-reports.yml@<sha>
  permissions:
    contents: read
    pages: write
    id-token: write
    # write, not read: the build job resolves and downloads report artifacts and
    # prunes stale Pages artifacts on rerun (#415).
    actions: write
  with:
    site-root: apps/site/dist
    build-command: bun run build
    package-manager: bun
    bundle-manifest: examples/bundle-manifest-turbo-themes.json
    commit-sha: ${{ github.event.workflow_run.head_sha }}
    fallback-ref: main
    tooling-ref: "<sha>"
```

See [pages-publishing.md](pages-publishing.md) for manifest schema, egress
allowlist, and `workflow_run` caller patterns.

See [python-release-publish.md](python-release-publish.md) for a full production
tag-push layout (quality, SBOM, split publish, release assets).

### Artifact download preview comment (`reusable-publish-artifact-preview.yml`)

Posts (or updates) one **sticky PR comment** with a direct **download link** to a
named build artifact, optionally prefixed with a short build summary. Use it when
a PR uploads an artifact (a generated static site, a rendered report, a built
bundle) and reviewers want to grab it in one click instead of hunting through the
run page.

The link is the `artifact-url` output of `actions/upload-artifact` v4+
(`https://github.com/<owner>/<repo>/actions/runs/<run_id>/artifacts/<artifact_id>`).

> **Constraint (honest):** the link downloads a **`.zip`** and requires the viewer
> to be **signed in to GitHub with access to the repository**. It is a reviewer
> convenience, not a public preview URL.

Re-running on the same PR **updates** the existing comment (marker upsert — no
duplicates). A missing/empty `artifact-url` degrades gracefully: a warning is
emitted and any stale comment is removed (delete-on-empty) rather than posting a
broken link. Fork PRs are skipped (they cannot receive workflow comments).

```yaml
jobs:
  build-site:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    outputs:
      artifact-url: ${{ steps.upload.outputs.artifact-url }}
    steps:
      # ... build the site into ./dist ...
      - id: upload
        uses: actions/upload-artifact@<sha> # v4+
        with:
          name: site-preview
          path: dist

  preview-comment:
    needs: build-site
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-artifact-preview.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      artifact-name: site-preview
      artifact-url: ${{ needs.build-site.outputs.artifact-url }}
      marker: site-preview
      summary: "Rendered landing site from this PR's formulae."
      tooling-ref: "<sha>" # vX.Y.Z
```

<!-- markdownlint-disable MD013 -- input reference table -->

| Input           | Type   | Required | Default                     | Purpose                                                      |
| --------------- | ------ | -------- | --------------------------- | ----------------------------------------------------------- |
| `artifact-name` | string | yes      | —                           | Name shown in the "⬇ Download …" link text                  |
| `artifact-url`  | string | yes      | —                           | `upload-artifact` v4 `artifact-url` output (empty degrades) |
| `marker`        | string | yes      | —                           | Sticky-comment upsert identity                              |
| `summary`       | string | no       | `""`                        | Inline markdown prepended to the comment                    |
| `summary-file`  | string | no       | `""`                        | Markdown file (wins over `summary` when non-empty)          |
| `job-name`      | string | no       | `Publish artifact preview`  | Job display name                                            |

<!-- markdownlint-enable MD013 -->

Plus the standard contract inputs (`tooling-ref`, `egress-policy`,
`egress-preset`, `allowed-endpoints`, `allowed-endpoints-mode`, `runner-image`,
`timeout-minutes`). Unlike `reusable-publish-artifact-report.yml` (which posts
the **contents** of a markdown file from inside a downloaded artifact), this
workflow does not download the artifact — it only links to it.

## Build, Coverage, And Supply Chain

### Build artifact (`reusable-build-artifact.yml`)

Generic build + artifact upload for cross-job handoff, for any of the vetted
toolchains. Callers supply the build command; dependency install belongs in that
command or a wrapper script.

`toolchain` is an enum (`node` | `rust` | `python` | `none`), not a free-form
action ref: every value maps to a setup action pinned by digest inside lgtm-ci,
so `validate-action-pinning` keeps covering the toolchain and consumers never
carry that burden. Adding an ecosystem is a PR here.

<!-- markdownlint-disable MD013 -->

| `toolchain` | Setup                                                 | Version input                          | Matrix field     |
| ----------- | ----------------------------------------------------- | -------------------------------------- | ---------------- |
| `node`      | `actions/setup-node`                                  | `node-version`                         | `node-version`   |
| `rust`      | `.github/actions/setup-rust` (dtolnay/rust-toolchain) | `toolchain-version` (default `stable`) | `rust-toolchain` |
| `python`    | `.github/actions/setup-python` (astral-sh/setup-uv)   | `toolchain-version` (default `3.12`)   | `python-version` |
| `none`      | nothing installed                                     | —                                      | —                |

<!-- markdownlint-enable MD013 -->

With `toolchain: rust`, a `target` field on a matrix entry is installed as a
rustup target, so cross-compilation matrices need no extra input. Neither the
Python nor the Rust setup installs project dependencies — that stays in
`build-command`.

```yaml
jobs:
  build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-artifact.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: <sha>
      job-name: "🏗️ Build & Quality Checks"
      build-command: ./scripts/build.sh --quick
      # node-version-matrix: '["20","22"]' still works but is deprecated
      matrix: '[{"node-version":"20"},{"node-version":"22"}]'
      artifact-name: js-dist
      artifact-path: dist
      runner-image: ubuntu-24.04

  validate-examples:
    needs: build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@<sha>
        with:
          # Matrix legs upload js-dist-20 / js-dist-22
          name: js-dist-20
          path: dist
```

Single-version (holy-grail style build + test):

```yaml
jobs:
  build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-artifact.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: <sha>
      job-name: "🏗️ Build & Test"
      build-command: bun run build
      post-build-test-command: bun test
      node-version: "22"
      artifact-name: app-dist
      artifact-path: dist
```

Non-Node example — a Rust cross-compile matrix with per-target runners. `matrix`
is the general form of `node-version-matrix`, and `runner-map` routes each entry
to a runner exactly like `reusable-docker`'s `platforms` + `runner-map` pair:

```yaml
jobs:
  build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-artifact.yml@<sha>
    permissions:
      contents: read
    with:
      tooling-ref: <sha>
      job-name: "🦀 Build binaries"
      toolchain: rust
      toolchain-version: stable
      matrix: >-
        [{"target":"x86_64-unknown-linux-musl"},
         {"target":"aarch64-apple-darwin"},
         {"target":"x86_64-pc-windows-msvc"}]
      runner-map: >-
        {"aarch64-apple-darwin":"macos-15",
         "x86_64-pc-windows-msvc":"windows-2025"}
      build-command: cargo build --release --target "$MATRIX_TARGET"
      artifact-name: rustume
      artifact-path: target/release
      # Optional: the default allowlist already covers rustup and crates.io, so
      # a preset is only needed for hosts a build reaches beyond its toolchain.
      # allowed-endpoints-mode must be append or the non-empty default
      # allowed-endpoints replaces the preset outright.
      egress-preset: rust-release
      allowed-endpoints-mode: append
```

Every matrix field reaches `build-command` and `post-build-test-command` as
`MATRIX_<FIELD>` (`target` → `$MATRIX_TARGET`, `rust-toolchain` →
`$MATRIX_RUST_TOOLCHAIN`), which is how a cross-compile leg knows its target.

Legs upload `rustume-x86_64-unknown-linux-musl-stable`, … — the suffix is the
leg's matrix values (the injected `runner` is excluded). The unmapped
`x86_64-unknown-linux-musl` entry falls back to `runner-image` with a `::notice::`,
mirroring `reusable-docker`'s runner-map. When entries carry more than one field,
set `runner-map-key` to name the lookup field; an entry missing that field is a
hard error rather than a silent default.

<!-- markdownlint-disable MD013 -->

| Input                     | Type   | Required | Default  | Notes                                                        |
| ------------------------- | ------ | -------- | -------- | ------------------------------------------------------------ |
| `build-command`           | string | yes      | —        | Shell build command                                          |
| `artifact-name`           | string | yes      | —        | Upload name; matrix appends the leg's values                 |
| `artifact-path`           | string | yes      | —        | Relative to `working-directory`                              |
| `toolchain`               | string | no       | `node`   | `node` \| `rust` \| `python` \| `none`                       |
| `toolchain-version`       | string | no       | `""`     | Toolchain version; alias of `node-version` for `node`        |
| `matrix`                  | string | no       | `""`     | JSON array of objects (or `{"include": [...]}`)              |
| `runner-map`              | string | no       | `{}`     | Matrix value → runner label; unmapped falls back             |
| `runner-map-key`          | string | no       | `""`     | Lookup field; auto when entries have one field               |
| `node-version`            | string | xor      | `""`     | Single version; not with `matrix`                            |
| `node-version-matrix`     | string | xor      | `""`     | **Deprecated** — use `matrix`; warns when set                |
| `post-build-test-command` | string | no       | `""`     | Optional post-build test                                     |
| `retention-days`          | number | no       | `7`      | Artifact retention                                           |
| `working-directory`       | string | no       | `.`      | Build cwd                                                    |
| `job-name`                | string | no       | `Build`  | Static inner name; GitHub adds matrix leg                    |

<!-- markdownlint-enable MD013 -->

Outputs: `artifact-name`, `artifact-id`, `artifact-url`. GitHub appends a matrix
leg's fields to the check context, so a legacy Node caller still gets
`{caller_job_id} / {job-name} ({node-version})` while an arbitrary `matrix` gets
the fields it declares (`(x86_64-apple-darwin, stable)`), plus the injected
`runner` when `runner-map` is non-empty. A caller that sets none of the toolchain
inputs keeps exactly the Node behaviour it had before #760, including job names
and required-check contexts — `runner` is only added to matrix legs when
`runner-map` is non-empty. See
[workflow-contract.md](workflow-contract.md#build-artifact).

### Push (publish to registry)

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: true
      scan: true
      scan-exit-code: "1"
      cosign-sign: true
      cache-registry-ref: ghcr.io/org/repo:cache
      no-cache: ${{ startsWith(github.ref, 'refs/tags/v') }}
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'
```

### PR validation (build-only, no push)

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      file: docker/Dockerfile
      push: false
      validate-on-pr: true
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'
      scan: true
      scan-exit-code: "1"
      smoke-test: --version
```

### Push with runtime health check

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: true
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'
      health-check-cmd: curl -f http://127.0.0.1:8080/health
      health-check-port: "8080"
      health-check-timeout: "30s"
```

When `health-check-cmd` is set, the workflow loads or pulls the built image,
starts a detached container, waits for `health-check-port` on `127.0.0.1`, runs
the command on the runner, and only then publishes the final manifest/tags.

### Combined push and PR validation

```yaml
jobs:
  docker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker.yml@<sha>
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    with:
      push: ${{ github.event_name != 'pull_request' }}
      validate-on-pr: ${{ github.event_name == 'pull_request' }}
      scan: true
      scan-exit-code: "1"
      cosign-sign: true
      cache-registry-ref: ghcr.io/org/repo:cache
      no-cache: ${{ startsWith(github.ref, 'refs/tags/v') }}
      runner-map: '{"linux/arm64":"ubuntu-24.04-arm"}'

  sbom:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
    permissions:
      # Read since #770: the release-asset upload moved to
      # reusable-sbom-release-upload.yml. The other three are declared by the
      # unconditional `sbom` job.
      contents: read
      security-events: write
      id-token: write
      attestations: write

  coverage:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@<sha>
    permissions:
      contents: read
      # Declared by the `publish-test-summary` job. The Pages scopes moved out
      # with the publish job in #770.
      pull-requests: write

  ghcr-cleanup:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ghcr-cleanup.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      package-name: my-image
    secrets: inherit
```

### Docker workflow inputs

| Input                | Default | Description                                                   |
| -------------------- | ------- | ------------------------------------------------------------- |
| `validate-on-pr`     | `false` | Use native split builds on PRs without pushing staging images |
| `scan-exit-code`     | `"0"`   | Trivy exit code; set `"1"` to block PRs on CRITICAL/HIGH CVEs |
| `cache-registry-ref` | `""`    | Registry cache fallback (e.g. `ghcr.io/org/repo:cache`)       |
| `cosign-sign`        | `false` | Keyless Cosign signature on pushed manifests                  |
| `no-cache`           | `false` | Disable GHA/registry cache for clean release builds           |
| `free-disk-space`    | `false` | Reclaim unused ubuntu-24.04 amd64 toolchains before the build |
| `resource-monitor`   | `false` | Sample memory/disk every 30s; tee into the live job log       |
| `provenance`         | `true`  | Generate provenance attestation (only when `push: true`)      |
| `sbom`               | `true`  | Generate SBOM attestation (only when `push: true`)            |

`sbom` and `provenance` only apply when `push: true`. PR validation
(`validate-on-pr` with `scan`) loads images locally via `--load`; buildx cannot
export manifest lists from SBOM attestations, so attestations are intentionally
skipped on that path. The publish path (main/tags with `push: true`) still
receives full SBOM and provenance attestations.

The `type=gha` cache export is best-effort and never release-blocking.
`type=gha` is always read from (`cache-from`), but it is only written to on
PR/non-push builds or when no `cache-registry-ref` is configured — on push
builds the registry cache is the durable, cross-run source of truth and the
extra GitHub Actions Cache write is redundant. Where the `type=gha` export does
run it carries `ignore-error=true`, so a transient Actions Cache fault degrades
the next build's cache hit rate instead of failing an image that has already
been built and pushed.

The `type=registry` export is deliberately **not** tolerated the same way: it
writes to the same GHCR repository the release itself publishes to, so a
failure there is a credential or registry problem worth failing on rather than
a transient cache fault to shrug off. `no-cache: true` still suppresses every
cache import and export.

`cosign-sign` signing retries a bounded number of times with exponential backoff
when — and only when — cosign fails while fetching its ambient OIDC credentials,
the transient flake class that otherwise fails a whole tag publish. Every other
signing failure (registry error, rejected signature, policy failure) stays fatal
on the first attempt. Tune with `COSIGN_SIGN_MAX_ATTEMPTS` (default `3`) and
`COSIGN_SIGN_MAX_DELAY` (default `30` seconds) in the job environment. The same
retry (from `scripts/ci/lib/cosign.sh`) covers the `cosign sign-blob` paths in
the `sign-artifact` action and `reusable-sbom.yml`'s `release-assets` signing,
applied per blob so an already-signed artifact is never re-signed. The same
marker list is also a built-in signature of
[`reusable-auto-rerun-on-infra-failure.yml`](#auto-re-run-on-infra-failure), so a
flake that outlives the in-step retry still gets the failed jobs re-run.

`free-disk-space: true` runs only on `github-hosted` runners. It removes
unused hosted-image toolchains (`/usr/share/dotnet`,
`/usr/local/lib/android`, `/opt/ghc`, `/usr/local/share/powershell`, and
unused `$AGENT_TOOLSDIRECTORY` entries: CodeQL, go,
Java_Temurin-Hotspot_jdk, PyPy, Python, Ruby, node) and prints `df -h /`
before and after. Missing paths are skipped, so ARM/lean runners are a
no-op. `resource-monitor: true` backgrounds a 30s `date` / `free -m` /
`df -h /` sampler. Each line is prefixed `[resource-monitor]` and teed
to stdout (live job log, retained up to a VM kill) and
`$RUNNER_TEMP/resource-monitor.log` (flushed each iteration). Start is
best-effort (`continue-on-error`) so a sampler fault does not skip the
image build. The last ~100 lines still dump with `if: always()` when
the runner survives; do not treat that dump as the kill-case signal.

```yaml
with:
  free-disk-space: true
  resource-monitor: true
```

All inputs are opt-in; existing callers keep current behavior without changes.

### SBOM (`reusable-sbom.yml`)

Generates an SBOM with Syft, optionally scans it with Grype, and can create a
Sigstore attestation. `mode: release-assets` generates multi-format SBOMs,
optionally cosign-signs them (keyless OIDC), and uploads them as a workflow
artifact for `reusable-sbom-release-upload.yml` to attach to a GitHub Release
(#770). Used by release layouts such as
[python-release-publish.md](python-release-publish.md).

<!-- markdownlint-disable MD013 -- SBOM input table; columns exceed default line length -->

| Input                  | Default                      | Description                                      |
| ---------------------- | ---------------------------- | ------------------------------------------------ |
| `mode`                 | `report`                     | `report` or `release-assets`                     |
| `formats`              | `spdx-json,cyclonedx-json`   | Syft formats for `release-assets` mode           |
| `sign`                 | `true`                       | Cosign keyless sign in `release-assets` mode     |
| `release-tag`          | `""`                         | Required when `mode: release-assets`             |
| `scan-vulnerabilities` | `true`                       | Run Grype against the generated SBOM (report)    |
| `fail-on-severity`     | `"critical"`                 | Fail when findings meet this severity or higher  |
| `upload-sarif`         | `false`                      | Upload Grype SARIF to GitHub Security            |
| `create-attestation`   | `false`                      | Create a Sigstore attestation for the SBOM       |
| `upload-release-assets`| `false`                      | DEPRECATED and inert (#770); use `reusable-sbom-release-upload.yml` |
| `egress-preset`        | `sbom`                       | Harden-runner allowlist preset (workflow-contract) |

<!-- markdownlint-enable MD013 -->

**Breaking (#480):** `fail-on-severity` previously defaulted to `""` (advisory
only). Callers that must keep advisory-only behavior should pass
`fail-on-severity: ""` or `none`.

```yaml
sbom:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  permissions:
    # Read since #770: the release-asset upload moved to
    # reusable-sbom-release-upload.yml.
    contents: read
    security-events: write
    id-token: write
    attestations: write
  with:
    # default fail-on-severity is critical; opt out for advisory-only:
    # fail-on-severity: ""
```

```yaml
sbom-release:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  permissions:
    # Read since #770: this mode now leaves the signed SBOMs as a workflow
    # artifact for reusable-sbom-release-upload.yml to attach to the release.
    contents: read
    id-token: write
    # Declared by the scan job, which this mode does not run.
    security-events: write
    attestations: write
  with:
    mode: release-assets
    release-tag: ${{ github.ref_name }}
    formats: spdx-json,cyclonedx-json
    sign: true
```

## PR Automation And Security

### Semantic PR title

`amannn/action-semantic-pull-request` expects **newline-delimited** `types` and
`scopes`. The reusable workflow normalizes legacy comma-separated overrides and
ships a correct default when `types` is omitted.

By default the workflow posts a marker-based PR comment on validation failure
and clears it when the title is fixed. Set `post-failure-comment: false` for
check-only adopters.

| Input                  | Default              | Notes                                      |
| ---------------------- | -------------------- | ------------------------------------------ |
| `post-failure-comment` | `true`               | Opt out for check-only workflows           |
| `comment-marker`       | `semantic-pr-title`  | Upsert marker for failure comments         |
| `max-length`           | `0` (no limit)       | Optional title length cap                  |
| `require-scope`        | `false`              | Passed through to amannn                   |
| `types` / `scopes`     | built-in defaults    | Override only when needed                  |

Callers must grant `pull-requests: write` when `post-failure-comment` is enabled
(the default). With `post-failure-comment: false`, `pull-requests: read` is
sufficient. Workflow root `permissions: {}` otherwise strips PR access from the
reusable job.

### Security audit (lintro + osv-scanner)

`reusable-security-audit.yml` runs osv-scanner via the pinned py-lintro Docker
image and uploads a comment artifact on pull requests. The audit step uses
`continue-on-error` with an explicit fail step so comment generation still runs
when vulnerabilities are found.

Post the marker-based PR comment from a separate caller job using
`reusable-publish-security-audit-comment.yml` (same split pattern as quality
lint + publish-quality-summary). The audit reusable requires only
`contents: read` and `packages: read`.

Add `merge_group:` to the caller workflow when using merge queue (audit runs;
artifact upload and PR comment publish remain `pull_request`-only).

| Input                    | Default                 | Notes                                      |
| ------------------------ | ----------------------- | ------------------------------------------ |
| `lintro-image`           | pinned py-lintro        | Override when adopting a newer lintro pin  |
| `audit-script`           | tooling default         | Rarely needed — override for custom scans  |
| `upload-comment-artifact`| `true`                  | Set `false` for push/schedule check-only   |
| `comment-marker`         | `security-audit-report` | Used by publish reusable                   |

```yaml
'on':
  pull_request:
  merge_group:
    types: [checks_requested]
  push:
    branches: [main]
  schedule:
    - cron: '30 5 * * 1'

jobs:
  security-audit:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-security-audit.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      tooling-ref: "<sha>"
      job-name: "🔐 Security Audit"
      lintro-image: ghcr.io/lgtm-hq/py-lintro@sha256:...
      upload-comment-artifact: ${{ github.event_name == 'pull_request' }}

  publish-security-audit-comment:
    needs: security-audit
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-security-audit-comment.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
```

For push/schedule workflows, omit the publish job and pass
`upload-comment-artifact: false`.

### PR file breakdown comment

`reusable-publish-file-breakdown.yml` fetches the PR changed-files payload via
`gh api --paginate`, renders a grouped breakdown (files/additions/deletions per
top-level directory) with a capped collapsible per-file table, and upserts it as
a marker-based PR comment. All steps skip when no PR number can be detected;
fork PRs skip the comment post.

| Input            | Default                  | Notes                                     |
| ---------------- | ------------------------ | ----------------------------------------- |
| `comment-marker` | `file-breakdown`         | Upsert marker for the PR comment          |
| `max-rows`       | `50`                     | Per-file rows shown (capped at 500)       |
| `job-name`       | `Publish file breakdown` | Display name                              |
| `egress-preset`  | `github-minimal`         | GitHub API + tooling checkout             |

```yaml
jobs:
  file-breakdown:
    if: >-
      github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-file-breakdown.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      tooling-ref: "<sha>"
```

### AI code review (`reusable-ai-review.yml`)

Org-wide AI code review. Installs a **pinned `lintro[ai]` from PyPI** (never
from the reviewed repo), runs `lintro review --pr --post`, and publishes one
sticky PR comment as **`lintro-review[bot]`**. Posting, round state, and the
verdict legend live in the published CLI — this reusable does not re-implement
comment markup.

**Trust model.** The reviewer binary comes from a release, so the consuming PR
cannot control it. Use a plain `pull_request` trigger (same-repo gate
recommended). `pull_request_target` / base-ref trusted-install reasoning from
py-lintro's dogfood does **not** transfer here.

**Provider-agnostic.** The workflow never hardcodes a provider. Resolution is
`provider` / `transport` input → `LINTRO_AI_PROVIDER` / `LINTRO_AI_TRANSPORT`
Actions variable → the consuming repo's lintro config → lintro's own validation
error. Inputs map onto that env overlay surface; there is no workflow fallback.

**Caller snippet** (same shape for every provider; listed alphabetically, none
recommended). Enumerate the secrets explicitly — least privilege: `secrets:
inherit` would hand the reusable the caller's entire secret set, while it
only ever declares the seven below — the two App secrets reach only the
credential-guard and token-minting steps, and of the five provider
credentials the run step receives only the one for the resolved
`(provider, transport)` pair:

```yaml
# any lgtm-hq repo: .github/workflows/ai-review.yml
'on':
  pull_request:

jobs:
  ai-review:
    if: github.event.pull_request.head.repo.full_name == github.repository
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@<sha>
    permissions:
      contents: read
      pull-requests: read
      actions: read
    secrets:
      LINTRO_REVIEW_APP_ID: ${{ secrets.LINTRO_REVIEW_APP_ID }}
      LINTRO_REVIEW_APP_PRIVATE_KEY: ${{ secrets.LINTRO_REVIEW_APP_PRIVATE_KEY }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      CODEX_API_KEY: ${{ secrets.CODEX_API_KEY }}
      CURSOR_API_KEY: ${{ secrets.CURSOR_API_KEY }}
    with:
      tooling-ref: "<sha>"
      # provider/transport empty = Actions var, then repo lintro config
```

`secrets: inherit` also works (all seven are org-wide, so it is the
zero-maintenance shape) but is discouraged: it grants the called workflow
access to every secret the caller can see, not just these seven.

| provider | transport | binary | credential (env) |
| -------- | --------- | ------ | ---------------- |
| anthropic | cli | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` |
| anthropic | api | — | `ANTHROPIC_API_KEY` |
| cursor | cli | `agent` | `CURSOR_API_KEY` |
| openai | cli | `codex` | `CODEX_API_KEY` |
| openai | api | — | `OPENAI_API_KEY` |

`LINTRO_REVIEW_APP_ID` / `LINTRO_REVIEW_APP_PRIVATE_KEY` are org-wide (all-repo)
and mint the posting token. That token is in scope **only** for the review
step (`GITHUB_TOKEN`); `GH_TOKEN` stays the workflow token for fetching the
diff. The GitHub App **installation** must grant `issues: write` and
`pull-requests: write` — those are App permissions, not the caller's
`pull-requests: read` job grant. Token minting fails if the installation
lacks them.

`provider` / `transport` inputs and `LINTRO_AI_PROVIDER` /
`LINTRO_AI_TRANSPORT` variables must be lowercase. Harden-runner compares
the raw values and cannot fold case.

<!-- markdownlint-disable MD013 -- wide input reference table -->

| Input             | Default | Notes |
| ----------------- | ------- | ----- |
| `provider`        | `""`    | Overlay → `LINTRO_AI_PROVIDER`. No default. |
| `transport`       | `""`    | Overlay → `LINTRO_AI_TRANSPORT`. No default. |
| `lintro-version`  | `0.131.5` | Renovate-managed. Floor = 0.130.0 (py-lintro#2159). Default includes resume / INCOMPLETE work and persist-on-timeout support. |
| `python-version`  | `3.12`  | Scratch venv for the pinned lintro install. |
| `model`           | `""`    | Overlay → `LINTRO_AI_MODEL`. |
| `max-cost-usd`    | `""`    | Overlay → `LINTRO_AI_MAX_COST_USD`. |
| `blocking`        | `false` | When true, exit 2 (no review) or a changes-requested verdict fails the job. INCOMPLETE coverage-at-HEAD always reddens. |
| `egress-preset`   | `ai-review` | GitHub + PyPI/uv only. Provider hosts are appended from the visible pair. |
| `timeout-minutes` | `30`    | Raise for long CLI reviews. |
| `job-name`        | `AI Review` | Check name. |

<!-- markdownlint-enable MD013 -->

**Hardening guarantees:**

- **Trusted install.** Pinned lintro from PyPI only. The job never installs or
  executes the PR's own code, so inference credentials and the App token are
  scoped to the single "Run AI review" step.
- **Same-repo / fork skip.** Fork PRs skip (exit 0) because they cannot read
  org secrets. Put the same-repo `if:` on the caller as well.
- **Exit-code contract.** lintro exit `2` is "no review produced" (error
  envelope on stdout), not a crash. Exit `1` is a produced review with P1 /
  changes-requested. Default `blocking: false` keeps those outcomes
  non-blocking. **INCOMPLETE** coverage-at-HEAD always reddens the check.
- **Per-PR concurrency.** The reusable cancels in-progress runs for the same
  consuming-repo PR so overlapping pushes do not race on state artifacts.
- **Review resume.** `actions: read` on the caller job lets the reusable
  locate the newest completed trusted run that uploaded
  `lintro-review-state-pr-<N>-*` (conclusion irrelevant) and download it
  onto the consuming repo's next run. The final upload sets `overwrite: true`
  so a same-attempt retry does not 409. The App token is minted immediately
  before the review step. No `*.blob.core.windows.net` wildcard.
- **Egress.** The `ai-review` preset has no provider hosts. Extra hosts come
  from the `(provider, transport)` pair visible at harden time (input or
  `LINTRO_AI_*` variable). Repo-config-only resolution cannot expand that list
  before harden-runner, so under the default `egress-policy: block` the
  resolve step **fails the job with guidance** when the provider comes only
  from the repo config — set the input or the variable so the matching hosts
  are allowlisted (`egress-policy: audit` lifts the guard). A rotated Cursor
  shard appears in the failed run's harden-runner summary; add it to
  `egress_ai_review_provider_endpoints` and
  `AI_REVIEW_CURSOR_EGRESS` together. No wildcards.

**The sticky comment.** `lintro review --post` owns the `<!-- lintro-ai-review -->`
marker, in-place updates, and telemetry. Author is `lintro-review[bot]`.

**Rollout.** First consumer is a follow-up PR (one repo). py-lintro keeps its
own dogfood workflow (different trust model).

### Vulnerability suppression check (osv-scanner)

`reusable-vuln-suppression-check.yml` installs `osv-scanner` directly (no Docker),
probes the repository without suppressions, and opens a cleanup PR removing
suppressions that are stale (vulnerability resolved upstream). Expired entries
(past `ignoreUntil`) are left untouched and flagged for manual review, failing
the job so a human re-evaluates each one.

| Input                    | Default                 | Notes                                      |
| ------------------------ | ----------------------- | ------------------------------------------ |
| `osv-version`            | `2.3.5`                 | osv-scanner release version                |
| `config-path`            | `.osv-scanner.toml`     | Suppression TOML path                      |
| `check-script`           | tooling default         | Repo-local override supported              |
| `cleanup-pr-labels`      | see below | Labels on cleanup PR |
| `egress-preset`          | `osv-scanner`           | Includes GitHub tooling + OSV API hosts    |
| `allowed-endpoints-mode` | `append`                | Merge preset with caller endpoints         |
| `workflow-file`          | empty                   | Caller workflow filename for PR footer     |
| `runner-image`           | `ubuntu-24.04`          | Linux runners only (install script)        |

Use a Linux `runner-image`; the install script downloads `linux_*` release
binaries only.

```yaml
'on':
  schedule:
    - cron: '0 4 * * 1'
  workflow_dispatch: {}

permissions: {}

jobs:
  check-suppressions:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
    with:
      tooling-ref: '<sha>'
      job-name: '🔍 Check Vulnerability Suppressions'
      workflow-file: vuln-suppression-check.yml
    secrets:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GHCR cleanup

`reusable-ghcr-cleanup.yml` prunes aged untagged container versions and ephemeral
build-cache tags (`pr-*`, `mq-*`, `dispatch-*`). Before deleting untagged
versions it collects digests referenced by tagged manifest indexes (multi-arch
children, cosign/SLSA attestations) and skips the entire prune when that
collection is incomplete.

| Input | Default | Notes |
| --- | --- | --- |
| `package-name` | — | Required GHCR package name |
| `min-age-days` | `7` | Min age before untagged deletion |
| `keep-latest` | `0` | Keep N most recent untagged |
| `build-cache-pr-age-days` | `14` | Min age before cache deletion |
| `protect-referenced` | `true` | Skip when refs incomplete |
| `prune-buildcache` | `true` | Delete aged ephemeral tags |
| `prune-tagged` | `false` | Opt in to tagged retention (below) |
| `main-retention-days` | `30` | `main` / `sha-*` retention (`prune-tagged` only) |
| `prerelease-retention-days` | `90` | Pre-release retention (`prune-tagged` only) |
| `dry-run` | `false` | Log only, no deletions |
| `egress-policy` | `block` | `audit` or `block` |
| `egress-preset` | `github-tooling` | API + GHCR hosts |
| `allowed-endpoints` | `""` | Custom endpoints |
| `allowed-endpoints-mode` | `replace` | `replace` or `append` |
| `tooling-ref` | `""` | lgtm-ci tooling git ref |
| `runner-image` | `ubuntu-24.04` | Runner image label |

Grant `contents: read` and `packages: write` on the caller job. Forward a token with
`packages:write` via `secrets.token` (or `secrets: inherit`).

#### Tagged retention (`prune-tagged`)

Untagged pruning alone leaves tagged versions to accumulate forever: any repo
using `reusable-docker` with the default tag matrix publishes a `sha-<commit>`
tag on every default-branch push. Set `prune-tagged: true` to also age out
tagged versions. It is **off by default**, so existing callers are unaffected.

| Tag shape | Policy |
| --- | --- |
| `latest` | never deleted |
| semver (`1`, `1.2`, `1.2.3`, optional leading `v`) | never deleted |
| `main`, `sha-*` | deleted past `main-retention-days` |
| pre-release channel (below) | deleted past `prerelease-retention-days` |
| anything else | never deleted (fail safe) |

A tag is in the pre-release channel when it is exactly `alpha`, `beta`, `rc`,
`pre`, `dev` or `snapshot`, optionally preceded by anything ending in `-` and
optionally followed by digits, `.`, `_` or `-`: `dev`, `1.2.3-alpha.1`,
`2.0.0-beta`, `1.2.3-rc1`, `1.0.0-pre.2`, `3.1.0-snapshot`. The match is
anchored, not a substring — `predeploy` is *not* the `pre` channel and lands in
"anything else", which is never deleted. The exact patterns live in
`scripts/ci/lib/ghcr/retention.sh`.

A GHCR version can carry several tags on one manifest. **A version is deleted
only when *every* tag on it is deletable** — never when any single tag says
delete. That is what makes the policy safe:

- A release build publishes `:latest`, `:<semver>` and `:sha-<commit>` onto one
  manifest. `latest` and semver never expire, so the whole version is retained
  and the release's immutable `sha-` pin survives forever.
- A main-push build publishes only `:main` + `:sha-<commit>`. Once `:main` moves
  on, the version is a lone `sha-*` and ages out at `main-retention-days`.

Inverting that rule ("delete if *any* tag is deletable") would delete every
release image the moment its `sha-` tag ages out while `:latest` still pointed
at it. The library enforcing it is `scripts/ci/lib/ghcr/retention.sh`
(`ghcr_all_tags_deletable`), and it is covered by named regression tests.

Age uses `updated_at` when GitHub reports it, falling back to `created_at`, so a
recently re-pushed manifest is never treated as old. `dry-run` covers tagged
pruning too — there is no second dry-run input.

##### GitOps consumers that pin `sha-<commit>`

Some deployment repos pin a concrete `ghcr.io/<owner>/<pkg>:sha-<commit>` as
their production reference (lgtm-hq/rustume-ops does, in `deploy/image.txt`). A
running container survives its image being pruned, but redeploy, restart and
rollback all fail to pull.

The all-must-agree rule makes this safe **only when the pinned image came from a
release build** — that manifest also carries `latest`/semver, so it is retained
indefinitely. An image pinned from a plain main build carries only `main` +
`sha-*` and *will* be pruned at `main-retention-days`. Pin release-channel
images, or raise `main-retention-days` beyond your longest expected deploy gap.

This policy was proven in production in lgtm-hq/Rustume's inline `prune-tagged`
job before being generalised here; that repo can now drop its local copy.

```yaml
'on':
  schedule:
    - cron: '0 3 * * 0'
  workflow_dispatch:
    inputs:
      min_age_days:
        description: Minimum age in days
        type: number
        default: 7

permissions: {}

jobs:
  ghcr-cleanup:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ghcr-cleanup.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      package-name: my-image
      min-age-days: ${{ github.event_name != 'workflow_dispatch' && 7 || inputs.min_age_days }}
      keep-latest: 0
    secrets: inherit
```

### Prune build staging tags

`reusable-prune-build-staging-tags.yml` prunes the per-platform
`build-<run_id>-<slug>` staging tags that the multi-arch publish retains (the
release index's own children — see #433/#434). It deletes a staging tag only
when **both** hold: the tag is older than `threshold-days` (and not among the
`keep-recent` newest), **and** its manifest digest is **not** referenced by any
current tagged, non-build image index. That referenced-digest set is collected
from every live release index (children, subjects, cosign/SLSA referrers); when
collection is incomplete the entire prune is skipped (fail-closed), so a
transient registry error can never orphan a live index. Dry-run is the default.

| Input | Default | Notes |
| --- | --- | --- |
| `package-name` | — | Required GHCR package name |
| `threshold-days` | `30` | Min staging-tag age before deletion |
| `keep-recent` | `0` | Keep N most recent staging tags |
| `protect-referenced` | `true` | Skip when refs incomplete (#433 gate) |
| `dry-run` | `true` | Log only, no deletions |
| `egress-policy` | `block` | `audit` or `block` |
| `egress-preset` | `docker` | API + GHCR registry hosts |
| `allowed-endpoints` | `""` | Custom endpoints |
| `allowed-endpoints-mode` | `replace` | `replace` or `append` |
| `tooling-ref` | `""` | lgtm-ci tooling git ref |
| `runner-image` | `ubuntu-24.04` | Runner image label |

Grant `contents: read` and `packages: write` on the caller job. Forward a token
with `packages:write` via `secrets.token`. Scheduled callers should stay in
dry-run and delete only on an explicit `workflow_dispatch`.

```yaml
'on':
  schedule:
    - cron: '0 3 * * 1'
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: true

permissions: {}

jobs:
  prune-staging:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-prune-build-staging-tags.yml@<sha>
    permissions:
      contents: read
      packages: write
    with:
      package-name: my-image
      # Never delete on the scheduled path.
      dry-run: ${{ github.event_name != 'workflow_dispatch' || inputs.dry-run }}
    secrets:
      token: ${{ secrets.GITHUB_TOKEN }}
```

### Documentation site quality

`reusable-site-quality.yml` runs Astro (or similar) docs build, lychee link
check on built HTML, and caller-provided check/test commands in two parallel
jobs. Consumer repo scripts (e.g. `scripts/ci/site/build.sh`) stay in the
consumer and are passed as command inputs.

<!-- markdownlint-disable MD013 -->

| Input                    | Default                    | Notes                                      |
| ------------------------ | -------------------------- | ------------------------------------------ |
| `build-command`          | required                   | Site build script or inline command        |
| `test-command`           | required                   | Site test orchestrator                     |
| `check-command`          | empty                      | Optional type-check step before tests      |
| `build-env`              | empty                      | Multiline `KEY=VALUE` for build (ASTRO_BASE) |
| `site-working-directory` | `.`                        | Node/Bun install path                      |
| `lychee-paths`           | `.`                        | Built dist path for link check             |
| `lychee-root-dir`        | first `lychee-paths` entry | `--root-dir` for relative href resolution  |
| `upload-site-artifact`   | `false`                    | Set `true` with explicit artifact path     |
| `python-version`         | empty                      | Enables Python setup when set              |
| `python-test-command`    | empty                      | Hook before `test-command` when Python set |
| `vitest-json-path`       | empty                      | Non-default Vitest JSON for PR summaries   |
| `test-egress-preset`     | falls back to `egress-preset` | Override egress for site-test job       |

<!-- markdownlint-enable MD013 -->

`link-report-artifact-name` names the uploaded lychee report and defaults to
`site-lychee-report` — deliberately different from `reusable-link-check.yml`'s
`lychee-report`, so a caller running both in one run does not collide. See
[Artifact names](#artifact-names).

```yaml
jobs:
  site-quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-site-quality.yml@<sha>
    permissions:
      contents: read
      # Declared by the `publish-test-summary` job.
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "Build and check documentation site"
      test-job-name: "Test documentation site"
      node-version: "22"
      package-manager: bun
      site-working-directory: apps/site
      cache-dependency-path: apps/site/bun.lock
      build-command: ./scripts/ci/site/build.sh
      build-env: |
        ASTRO_BASE=/
      lychee-paths: apps/site/dist
      lychee-file-extensions: html
      check-external: false
      lychee-root-dir: apps/site/dist
      upload-site-artifact: true
      site-artifact-path: apps/site/dist
      check-command: ./scripts/ci/site/check.sh
      test-command: ./scripts/ci/site/test-all.sh
      python-version: "3.12"
      install-python-dependencies: false
      egress-policy: block
      allowed-endpoints: >
        github.com:443
        api.github.com:443
        codeload.github.com:443
        objects.githubusercontent.com:443
        release-assets.githubusercontent.com:443
        registry.npmjs.org:443
        bun.sh:443
      test-allowed-endpoints: >
        github.com:443
        api.github.com:443
        codeload.github.com:443
        objects.githubusercontent.com:443
        release-assets.githubusercontent.com:443
        raw.githubusercontent.com:443
        registry.npmjs.org:443
        bun.sh:443
        pypi.org:443
        files.pythonhosted.org:443
```

Path filters and concurrency remain on the caller workflow. Set
`publish-test-summary: true` and `vitest-json-path` when adopting lgtm-ci
Vitest JSON output for PR summaries.

```yaml
jobs:
  semantic-title:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-semantic-pr-title.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      egress-preset: github-minimal
      # Optional: override types (newline-delimited; CSV is normalized)
      # types: |
      #   feat
      #   fix
      #   ci
      # Optional: enforce a title length cap
      # max-length: "72"
      # Optional: check-only (no PR comments)
      # post-failure-comment: false
```

```yaml
jobs:
  label:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-labeler.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  assign:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-pr-auto-assign.yml@<sha>
    permissions:
      contents: read
      pull-requests: write

  action-pinning:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-validate-action-pinning.yml@<sha>
    permissions:
      contents: read

  links:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-link-check.yml@<sha>
    permissions:
      contents: read
      # Declared by the `publish-link-check-report` job.
      pull-requests: write

  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write

  dependency-review:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-dependency-review.yml@<sha>
    permissions:
      contents: read
      pull-requests: read

  scorecards:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-scorecards.yml@<sha>
    permissions:
      contents: read
      security-events: write
      id-token: write
```

### CodeQL build-mode

`reusable-codeql.yml` defaults `build-mode` to `none`. Choose the mode from the
language class — do **not** pass `build-mode: autobuild` for interpreted
languages (legacy inline workflows often had a separate `codeql-action/autobuild`
step; that maps to `autobuild` only for compiled languages).

<!-- markdownlint-disable MD013 -->

| Language class                          | `build-mode`              | Notes                                      |
| --------------------------------------- | ------------------------- | ------------------------------------------ |
| Python, JavaScript/TypeScript, Ruby, Go | `none` (default)          | Database built directly from source        |
| C/C++, C#, Java, Kotlin, Swift, …       | `autobuild` or `manual`   | Requires build observation or custom steps |

<!-- markdownlint-enable MD013 -->

**Python-only caller** — omit `build-mode` or set `none` explicitly:

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: python
      # build-mode defaults to none — do not use autobuild for Python
```

**Compiled-language caller** — use `autobuild` (or `manual` with your own build
steps before `Analyze`):

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: java
      build-mode: autobuild
```

**Multi-language caller** — when languages need different build modes (for example
Rust plus GitHub Actions), pass `language-build-modes` as a JSON object. The
reusable runs one matrix leg per language so `init` receives the correct
`build-mode` for each extractor (do **not** rely on a single global
`build-mode` across mixed language classes):

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      contents: read
      security-events: write
    with:
      languages: rust,actions
      language-build-modes: '{"rust":"autobuild","actions":"none"}'
      egress-policy: block
      allowed-endpoints-mode: append
      allowed-endpoints: |
        static.rust-lang.org:443
        sh.rustup.rs:443
        crates.io:443
        static.crates.io:443
        index.crates.io:443
```

When `category` is omitted, each matrix leg uploads SARIF under
`/language:<language>`. Pass `category` explicitly to override all legs (for
example `/language:all` on a single-language scan).

Pin the workflow `uses:` ref to a commit SHA in production. `tooling-ref` is
optional for egress composites only on single-language scans; for multi-language
callers, pass a matching `tooling-ref` when testing unreleased
`generate-codeql-matrix.sh` changes so the setup job and analysis legs stay
aligned.

See [CodeQL workflow configuration — build modes](https://docs.github.com/en/code-security/reference/code-scanning/workflow-configuration-options)
and [workflow-contract.md](workflow-contract.md#action-only-reusables).
