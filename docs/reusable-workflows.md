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

Production callers should pin the workflow ref to a commit SHA and omit
`tooling-ref`: the tooling checkout follows the workflow pin on its own (#995).

A `tooling-ref` that checks out a commit other than the workflow's own
(`job.workflow_sha`) now fails the job before any tooling script runs (#1368),
because the new workflow YAML would run against old scripts (an external
consumer hit exit 127 from a stale `tooling-ref` this way). The error names both
SHAs; the fix is to remove `tooling-ref`. On GHES `job.workflow_sha` is empty,
so the guard has nothing to compare against and does not run. Mirror callers on
GitHub.com that must diverge can set `tooling-ref-allow-divergence: true`
(default `false`) to downgrade the failure to a warning. It is an escape hatch,
not a way to test unreleased branches: use a `uses:` ref for that.

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

| Scope             | Now declared by                           | Why it is real                                                                                                                                                                                                  |
| ----------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `contents: write` | `reusable-sbom-release-upload.yml`        | `gh release upload --clobber` with `GITHUB_TOKEN` (`scripts/ci/actions/upload-sbom-release-assets.sh:33`); the step sets `GH_REPO` because the job has no caller checkout for `gh` to read a remote from (#935) |
| `pages: write`    | `reusable-publish-test-results-pages.yml` | `actions/deploy-pages` posts `/repos/{owner}/{repo}/pages/deployments` with `GITHUB_TOKEN`                                                                                                                      |
| `id-token: write` | `reusable-publish-test-results-pages.yml` | `actions/deploy-pages` calls `core.getIDToken()` and sends it as the deployment's `oidc_token`                                                                                                                  |
| `actions: write`  | `reusable-publish-test-results-pages.yml` | `gh api --method DELETE /repos/{}/actions/artifacts/{id}` clears stale same-run Pages artifacts on rerun (`scripts/ci/actions/delete-run-pages-artifacts.sh:45-46`, #415)                                       |

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
_unconditional_ jobs need: `reusable-sbom.yml` requires `security-events: write`,
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

| Was                                                         | Now                                                                                                 |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `reusable-coverage.yml` with `publish-pages: true`          | `reusable-coverage.yml` + a caller job on `reusable-publish-test-results-pages.yml`                 |
| `reusable-test-e2e-matrix.yml` with `publish-results: true` | `reusable-test-e2e-matrix.yml` + a caller job on `reusable-publish-test-results-pages.yml`          |
| `reusable-sbom.yml` with `upload-release-assets: true`      | `reusable-sbom.yml` + a caller job on `reusable-sbom-release-upload.yml`                            |
| `reusable-sbom.yml` with `mode: release-assets`             | same call (it now uploads a workflow artifact) + a caller job on `reusable-sbom-release-upload.yml` |

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
      actions: read
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

## Read-only variants

A facade such as `reusable-test-node.yml` runs its tests and then publishes a
PR comment. GitHub checks the permission union of the whole file before any
`if:` runs, so every caller grants `pull-requests: write`, including callers
that set `publish-test-summary: false`. Issue #1081 adds a generated
read-only variant next to each facade:

<!-- markdownlint-disable MD013 -- wide table -->

| Facade                    | Read-only variant             | Variant union                     | Dropped                                                                                          |
| ------------------------- | ----------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------ |
| `reusable-test-node.yml`  | `reusable-test-node-run.yml`  | `actions: read`, `contents: read` | `publish-test-summary` job, `comment-marker` input                                               |
| `reusable-test-shell.yml` | `reusable-test-shell-run.yml` | `actions: read`, `contents: read` | `publish-test-summary` job and input (`comment-marker` stays: it also names the shard artifacts) |
| `reusable-rust-test.yml`  | `reusable-rust-test-run.yml`  | `actions: read`, `contents: read` | `publish-test-summary` job, `comment-marker` input                                               |

<!-- markdownlint-enable MD013 -->

The variant is the facade minus the regions it marks
`# lgtm-ci-readonly:omit`, generated by
`scripts/ci/workflows/sync-readonly-variants.sh` and checked for drift by
`tests/bats/integration/test_readonly_variants.bats`. Everything else is
copied: job ids, job names (so the checks under your job id keep their
names), the other inputs and their defaults, outputs and artifact names.
The facade itself is unchanged and stays supported. Its jobs are not nested
under the variant, because that would add a segment to every check name and
break the org rulesets that require them
([org-rulesets.md](org-rulesets.md)).

To move a call to the variant, change the `uses:` file name, remove
`pull-requests: write`, and remove every input in the table's Dropped column:
`comment-marker` for Node and Rust, `publish-test-summary` for shell, where
`comment-marker` stays because it names the shard artifacts. In the Node and
Rust variants, `publish-test-summary` only stages the coverage payload the
comment would use, and a version matrix no longer requires it to be `false`.
To keep the comment, call `reusable-publish-test-summary.yml` from a separate
job. That job reads the same results.v1 artifacts (#1080), so the write scope
stays in a job that runs no project code. For Node:

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node-run.yml@<sha>
    permissions:
      actions: read
      contents: read
    with:
      package-manager: bun
      artifact-prefix: node

  test-summary:
    needs: test
    # tests-total is empty when the variant skipped its jobs (a draft PR
    # under the default draft-pr-skip): there are no results to render.
    if: >-
      !cancelled()
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.fork == false
      && needs.test.outputs.tests-total != ''
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-summary.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      test-suite-name: Node.js Tests
      comment-marker: node-test-results
      results-artifact-pattern: node-results-*
      # A job can go red after it set passed (e.g. the harden-runner
      # recheck, #1203): require its result as well.
      job-result: >-
        ${{ needs.test.result == 'success'
        && needs.test.outputs.passed == 'true'
        && 'success' || 'failure' }}
```

This posts the plain results table. For the facade's rich coverage comment
(`coverage: true`, single Node version), also pass what the facade's own
comment job passes: `coverage-enabled: true`, `rich-coverage-comment: true`,
`coverage-threshold`, `coverage-artifact-name: node-coverage`
(`<artifact-prefix>-coverage`), `coverage-file` (`coverage-summary-file`
under `working-directory`) and `coverage-format: istanbul`. Set
`results-expected-count` to the number of Node versions so a missing leg
fails the comment job. A variant caller with no comment job can set
`publish-test-summary: false` to skip uploading the staged coverage payload.

For Rust, use `results-artifact-pattern: <artifact-prefix>-results-*` and
`tests-total-excludes-skipped: true`, which the Rust facade always sets so
the Total Tests row excludes skipped tests. Set `results-expected-count`
to the number of toolchains. For the rich coverage comment (`coverage: true`,
single toolchain) add `coverage-enabled: true`, `rich-coverage-comment: true`,
`coverage-threshold`, `coverage-artifact-name: <artifact-prefix>-coverage-lcov`,
`coverage-file: rust-coverage.lcov` and `coverage-format: lcov`. For shell,
use `results-artifact-pattern: <artifact-prefix>-results` and
`results-expected-count: "1"`.

Docker multi-platform takes the other route (no required check depends on
its nested names): `reusable-docker-multiplatform.yml` became a facade that
calls `reusable-docker-multiplatform-validate.yml` for `push: false` and the
internal `reusable-docker-multiplatform-publish.yml` for `push: true`. The
validate file is the read-only entry point (`contents: read`): it builds
each platform without pushing and keeps the Trivy SARIF as the artifact
`<artifact-prefix>-trivy-sarif-<slug>` (default prefix `docker`; give sibling
calls in one run distinct prefixes); the facade uploads that SARIF to code
scanning from its own job. Calling the facade adds one segment to the
per-platform check names
(`… / Validate / Docker build per platform (linux/amd64, linux-amd64, ubuntu-24.04, false)`:
every matrix value is appended).

```yaml
jobs:
  docker-validate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-docker-multiplatform-validate.yml@<sha>
    permissions:
      contents: read
    with:
      matrix: >-
        [{"platform":"linux/amd64","slug":"linux-amd64","runner":"ubuntu-24.04","qemu":false},
        {"platform":"linux/arm64","slug":"linux-arm64","runner":"ubuntu-24.04-arm","qemu":false}]
      validate-on-pr: true
      scan: true
```

Release recovery is composed the same way:
`reusable-release-recover.yml` calls the read-only
`reusable-release-recover-plan.yml` (`actions: read`, `contents: read`),
then the internal `reusable-release-recover-resume.yml`. A dry run without
write scopes calls the plan stage directly; see
[release-recovery.md](release-recovery.md#stages-and-permissions-1081).

The measured permission, secret and job inventory of the five reusables
that issue #1081 covers, and the split chosen for each, is in
[reusable-splits.md](reusable-splits.md).

## Overlay variants

`reusable-test-node-custom.yml` runs a caller's `test-command` where
`reusable-test-node.yml` runs Vitest. The two share the prepare, Pages
coverage and aggregate jobs, the harden-runner and tooling steps, and the
comment job. Until #1356 they were hand-kept copies. The custom file is now
generated from the facade by `scripts/ci/workflows/sync-readonly-variants.sh`:
the same script, a second variant kind.

The facade wraps every line the custom variant does not share in a named
region:

```yaml
jobs:
  # lgtm-ci-overlay:test-job-id:begin
  test-vitest:
    # lgtm-ci-overlay:test-job-id:end
```

and `.github/workflow-overlays/reusable-test-node-custom.overlay` holds the
variant's lines for each region, after a column-0 `@@ <slot>` line (an empty
slot drops the region):

```text
@@ test-job-id
  test:
```

The variant is the facade with each region replaced by its slot. A shared
line has one source, the facade; a custom-only line has one, the overlay.
Edit the right file, then run the script and commit the generated
`reusable-test-node-custom.yml`. `--check` (run by
`tests/bats/integration/test_readonly_variants.bats`) fails on drift, on a
region with no slot, on a slot no region uses, on a slot or region used
twice, on a facade comment that looks like an overlay marker but is not a
valid one (wrong case, an underscore, a missing `:begin` or `:end`), on a
missing or orphaned overlay and on a variant that would overwrite a
hand-maintained workflow. A slot may only use a local `./` action, whatever
the key quoting or flow style: Renovate reads `.github/workflows`, not the
overlay, so a remote pin belongs in the facade.

The custom variant keeps its own API: the required `test-command` input,
`artifact-prefix` default `node_custom`, `comment-marker` default
`node-coverage-report`, the `passed`, `pages-coverage-artifact-name` and
`pages-coverage-uploaded` outputs, the `contents: read` +
`pull-requests: write` union (no `actions: read`: its aggregate reads the
matrix result, not results.v1 artifacts) and the check names listed in the
catalog. Its jobs stay inline rather than calling the facade, which would
add a check-name segment and the `actions: read` scope its callers do not
grant.

Every other `reusable-*.yml` is either a facade, generated, or listed in
`scripts/ci/workflows/standalone-reusables.txt`;
`tests/python/test_reusable_variant_sources.py` fails on any other file. A
new reusable that copies most of an existing one belongs in an overlay, not
on that list.

## Runner pinning

Runner-pinnable reusables default `runner-image` to `""`: an explicit input
wins, then the caller's `vars.LGTM_CI_RUNNER`, then `ubuntu-26.04`. Leave it
empty so the org switch applies. Pin only when a job needs a specific runner;
see [Runner selection](workflow-contract.md#runner-selection). This example
follows the org switch:

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
```

Multi-arch Docker builds use `runner-map` instead — see
[Docker workflow inputs](#docker-workflow-inputs) below. The generic
control-plane workflows (semantic PR title, labeler and dependency review)
accept the same empty `runner-image` override and org switch. CodeQL,
Scorecard and the gem publish workflow do not expose `runner-image`;
`reusable-publish-npm-set.yml` does, GitHub-hosted labels only, since npm
provenance needs a hosted runner; see
[workflow-contract.md](workflow-contract.md#runner-pinning).

### macOS runner images

`runner-image` moves every job that follows it, coordinator jobs included,
so a macOS label runs the aggregate job on macOS too. The hosted macOS
images run `bash` 3.2 and ship no coreutils `timeout`. What is known on them
(#1729):

#### Known to work on macOS

- `reusable-test-python.yml` test legs and aggregate job: passed on a hosted
  `macos-26` image, two Python versions, at the commit that added the bound
  described in
  [Matrix aggregation waits for the artifact listing](#matrix-aggregation-waits-for-the-artifact-listing-803)
  (#1729). The aggregate job needed coreutils `timeout` before that and failed
  there. Not covered by that run: the test-summary publisher, which is listed
  under the known failures below.

#### Fixed, not yet proven on a macOS runner

- The aggregate jobs of `reusable-test-node.yml` and `reusable-rust-test.yml`
  (and their `-run` variants) run the same two scripts and no longer need
  coreutils `timeout`.

A hosted image that ships a `timeout` binary (newer macOS releases have a BSD
one in `/usr/bin`) uses it instead of the perl watchdog; it takes the same
arguments and gives the same exit statuses.

#### Known to fail on macOS

These reach bash 4 features or coreutils `timeout` on their path:

- `reusable-auto-rerun-on-infra-failure.yml`: its script needs coreutils
  `timeout` and bash 4.1 or newer.
- `reusable-test-shell.yml` (and `-run`) with coverage, including the
  aggregate job, which only runs with coverage and more than one shard: the
  kcov run needs coreutils `timeout` and Linux.
- `reusable-test-python.yml` with private git dependencies
  (`configure-git-deps-auth.sh` lowercases with `${var,,}`).
- `reusable-build-python-dist.yml` checksum generation (`mapfile`).
- `reusable-pr-auto-assign.yml`, and the reviewer assignment step of
  `reusable-release-version-pr.yml` (`mapfile`).
- `reusable-publish-file-breakdown.yml` (`mapfile`),
  `reusable-publish-quality-summary.yml` (`${var,,}`),
  `reusable-publish-test-summary.yml` (`mapfile`, `${var,,}`), and the
  comment-history path of the comment publishers (`mapfile`, associative
  arrays).
- `reusable-sbom.yml` release assets and `reusable-sbom-release-upload.yml`
  (`mapfile`).
- `reusable-link-check.yml` report (`mapfile`).
- `reusable-vuln-suppression-check.yml` (associative arrays).
- `reusable-semantic-pr-title.yml` failure comment when allowed types are
  configured (`mapfile`).
- The release failure notifiers (`reusable-main-failure-notifier.yml`,
  `reusable-release-failure-notifier.yml` and the failure jobs of
  `reusable-release-auto-tag.yml` and `reusable-release-version-pr.yml`) when
  they file an issue (`local -n`); without `timeout` they also skip the log
  fetch and treat the logs as unavailable.

Every other reusable is untested on macOS (#1074). Harden-runner and egress
enforcement on hosted macOS are covered in
[Runner policy tiers](workflow-contract.md#runner-policy-tiers).

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

Consumers do **not** need to vendor anything for egress — reusables carry
their allowlist presets as a workflow literal and invoke
`step-security/harden-runner` directly (#913). Tooling composites are
sparse-checked-out into `.lgtm-ci-tooling/` and invoked as
`./.lgtm-ci-tooling/.github/actions/...` (resolved from `job.workflow_sha`, or
the `tooling-ref` override, like every tooling step).

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
| `reusable-test-node.yml`           | `coverage-artifact-name`    | `<artifact-prefix>-coverage` |
| `reusable-test-node-custom.yml`    | `coverage-artifact-name`    | `<artifact-prefix>-coverage` |
| `reusable-test-e2e-playwright.yml` | `report-artifact-name`      | `playwright-report-<run_id>` |
| `reusable-test-e2e.yml`            | `report-artifact-name`      | `e2e-report-<run_id>`        |
| `reusable-coverage.yml`            | `coverage-artifact-name`    | `coverage-report`            |

<!-- markdownlint-enable MD013 -->

`pages-coverage-artifact-name` still defaults to `coverage-html` on **both**
`reusable-test-node.yml` and `reusable-test-node-custom.yml`, because that name
is baked into consumers' Pages bundles. A caller that enables
`upload-pages-coverage-html` on both in one run must override one of them.

### Calling a language test reusable twice in one run (#1091)

`overwrite: true` is a rerun safeguard for one logical producer, never a
substitute for namespace isolation (#728, #752). Before #1091 the language
test reusables uploaded flat names, so a caller invoking one of them twice in
a run (two packages, two coverage formats, two Python versions as separate
calls) silently kept only the second call's coverage: the run stayed green and
the summary comment reported whichever leg finished last. They now take the
same `artifact-prefix` input as `reusable-test-e2e-matrix.yml`
(`[A-Za-z0-9_.]+`, validated by `scripts/ci/actions/validate-artifact-prefix.sh`
before any upload uses it: in an upstream job, or as the first step of the
uploading job on `reusable-test-shell.yml`'s single-job path), and every
coverage and result upload name, every download glob, the availability wait
from #803 and the summary-comment handoff are built from it:

<!-- markdownlint-disable MD013 -->

| Workflow                        | Default prefix | Artifacts (`<p>` = prefix)                                                                          |
| ------------------------------- | -------------- | --------------------------------------------------------------------------------------------------- |
| `reusable-test-python.yml`      | `python`       | `<p>-coverage`, `<p>-results-<version>`                                                             |
| `reusable-test-node.yml`        | `node`         | `<p>-coverage`, `<p>-coverage-<version>`, `<p>-results-<version>`, `<p>-build-<version>`            |
| `reusable-test-node-custom.yml` | `node_custom`  | `<p>-coverage`                                                                                      |
| `reusable-rust-test.yml`        | `rust`         | `<p>-coverage-lcov`, `<p>-results-<toolchain>`                                                      |
| `reusable-test-shell.yml`       | `shell`        | `<p>-test-results`, `<p>-coverage`; sharded: `<p>-{test-results,coverage}-<comment-marker>-shard-N` |

<!-- markdownlint-enable MD013 -->

The defaults are the language words, so a caller that invokes a reusable once
keeps today's artifact names byte-for-byte. The one rename is
`reusable-test-node-custom.yml`: its default coverage payload is now
`node_custom-coverage` (was `node-custom-coverage`), because `-` is the
reserved separator between the prefix and the rest of the name. A caller that
invokes the same reusable twice in one run must give the second call its own
prefix:

```yaml
jobs:
  backend:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      working-directory: backend
      coverage: true
      upload-coverage: true
      artifact-prefix: backend # backend-coverage, backend-results-3.12
  worker:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      actions: read
      contents: read
      pull-requests: write
    with:
      working-directory: worker
      coverage: true
      upload-coverage: true
      artifact-prefix: worker # worker-coverage, worker-results-3.12
```

The Node variants keep `coverage-artifact-name` as an escape hatch for a name
outside the scheme; empty (the default) resolves to `<artifact-prefix>-coverage`
at both the upload and the summary publisher, so an explicitly empty value no
longer suppresses the rich coverage comment (use `coverage: false` for that).
Two calls that both keep the default prefix
still share names: isolation is only as good as the prefixes the caller
passes. `pages-coverage-artifact-name`
is not derived from the prefix (its default is a published Pages contract, see
above) and stays a per-call input of its own.

`reusable-test-python-publish.yml` and `reusable-test-node-publish.yml` are
consumers of these artifacts in a separate caller job
(`reusable-test-python-publish.yml` downloads `<artifact-prefix>-coverage`;
`reusable-test-node-publish.yml` downloads `<artifact-prefix>-coverage-*`). They
take
the same `artifact-prefix` input with the same defaults; a caller that sets it
on the test call must pass the same value to the matching publish call.

`tests/bats/integration/test_reusable_artifact_names.bats` asserts, per step
block, that every upload name and download glob in these workflows is built
from the input, that an upstream job validates it, that the default prefix
reproduces the pre-#1091 names, and that two distinct prefixes are mutually
invisible to each other's download globs.

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

### Semgrep version check (`reusable-quality-lint.yml`)

`semgrep --version` performs an update check against the Semgrep registry.
On a runner where that call stalls, the round trip can outlast lintro's
version-check timeout and the whole lint job hangs
(lgtm-hq/py-lintro#2521). Set the input below to `"0"` to switch the update
check off inside the lintro container.

<!-- markdownlint-disable MD013 -->

| Input                          | Type   | Required | Default | Purpose                                                    |
| ------------------------------ | ------ | -------- | ------- | ---------------------------------------------------------- |
| `semgrep-enable-version-check` | string | no       | `"1"`   | `SEMGREP_ENABLE_VERSION_CHECK` inside the lintro container |

<!-- markdownlint-enable MD013 -->

```yaml
jobs:
  quality:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@<sha>
    permissions:
      contents: read
      packages: read
    with:
      semgrep-enable-version-check: "0"
```

It only removes the update notice; the scan itself is unchanged. Do **not**
pair it with `SEMGREP_SEND_METRICS=off` — semgrep refuses `--config auto`
(lintro's default) when metrics are disabled, which turns a flaky version
check into a hard scan failure. The scan still reaches `semgrep.dev:443`
for rule packs, so keep those endpoints on the egress allowlist.

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

### All checks gate (`reusable-all-checks-gate.yml`)

Native auto-merge and the merge queue wait for **required** checks only, so a
PR (Renovate automerge included) can merge while non-required checks are
still running or after one failed. This gate turns "every check passed" into
one required context. It polls the commit's workflow runs, check runs and
commit statuses until nothing is queued or in progress and nothing has
changed for `settle-seconds`, then passes only if every other check
concluded `success`, `skipped` or `neutral`:

- **Workflow runs** for the commit: a run that is not completed keeps the
  gate waiting (this covers jobs still waiting on `needs:`, which have no
  check run yet). A run that concluded `failure`, `cancelled`, `timed_out`,
  `startup_failure` or `action_required` fails the gate. A cancelled run
  counts as superseded (concurrency) and is dropped with its check runs
  only when newer runs of the same workflow file did its work: they have at
  least one check run that is not skipped, and every job the cancelled run
  left unfinished has such a check run in a newer run. Any other older run
  still counts, so a later run (say on `labeled`) that skips the real jobs
  can hide neither an earlier failure nor an earlier cancellation. To clear
  a run that failed only on infrastructure, re-run that run
  (`gh run rerun <run-id> --failed`): the re-run keeps the run ID and its
  latest attempt is what counts, while a new run of the same workflow does
  not replace the failed one. The external consumer canary prints this
  command when its result is inconclusive
  ([workflow contract](workflow-contract.md#the-canary)).
- **Check runs** from every app: anything other than `success`, `skipped`
  or `neutral` (`failure`, `cancelled`, `timed_out`, `action_required`,
  `stale`, `startup_failure`, or no conclusion) fails the gate. Actions check runs are
  judged per workflow run and job name (the newest re-run attempt counts),
  so jobs that share a name in different workflows are judged separately.
  Retried Actions runs additionally use complete job-to-check attempt membership,
  preserving every current matrix job ID and retaining ambiguous historical
  failures. A cancelled, never-started `inputs.job-name` placeholder is retired
  only for the audited CodeQL source contract, after both attempts' runner
  headers attest the same immutable reusable revision and evaluated inputs and
  the later setup and analysis actually succeed. This currently supports one
  explicit language and the exact workflow/generator bytes recognized by
  `reconcile_check_retries.py`; auto-detect, multiple languages, other dynamic
  graphs and unavailable evidence keep the cancellation. The one
  successful-run rule: when an older attempt's same-name matrix legs
  concluded `cancelled`, they are retired only if the latest attempt of the
  same run has at least as many legs of that name and every one of them
  completed with `success` (a full re-run of the matrix). Older `failure`,
  `timed_out`, `action_required` or other non-passing legs, a failed-only
  re-run with fewer legs, and any non-success latest leg keep the gate red.
- **Commit statuses**: `pending` (CodeRabbit, `renovate/stability-days`)
  counts as not finished; `failure` and `error` fail the gate.

It gates the PR head SHA on `pull_request` and `merge_group.head_sha` on
`merge_group`, needs no secrets (read-only `GITHUB_TOKEN`, so fork PRs
work; a private mirror passes only the optional `LGTM_CI_TOOLING_TOKEN`)
and has a static job name. Put it in its **own** workflow file, one
per repository: runs of the calling workflow are excluded so a gate never
waits on itself or on an older gate run for the same commit; a gate that
shares its workflow run with other jobs fails and says so. Require the
context `gate / ✅ All Checks Passed` (caller job id `gate`), with GitHub
Actions as its expected source, in the ruleset.

```yaml
name: All Checks Gate

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  merge_group:

permissions: {}

concurrency:
  group: all-checks-gate-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  gate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-all-checks-gate.yml@<sha>
    permissions:
      actions: read
      checks: read
      contents: read
      statuses: read
```

| Input                   | Default | Purpose                                               |
| ----------------------- | ------- | ----------------------------------------------------- |
| `timeout-minutes`       | `60`    | Job timeout; the wait gives up 3 minutes earlier      |
| `settle-seconds`        | `60`    | Quiet period before the verdict                       |
| `poll-interval-seconds` | `60`    | Seconds between API polls                             |
| `ignore-checks`         | `""`    | Regex (jq) of check, status or workflow names to skip |
| `allow-empty`           | `false` | Pass when no other check exists                       |
| `fail-on-draft`         | `false` | Fail draft PRs at once instead of gating them         |
| `head-sha`              | `""`    | Override the gated commit                             |

Choose `timeout-minutes` above the longest dependency path plus setup, queue,
settle time and the three-minute reporting margin. A caller with a 120-minute
Docker job needs a larger gate budget, for example 130 minutes; the reducer
derives its wait budget from that input rather than imposing a one-hour cap.

The standard `egress-policy`, `egress-preset` (default `github-results`, for
Actions log downloads as well as the API),
`allowed-endpoints`, `allowed-endpoints-mode` and `runner-image` inputs
apply as in [workflow-contract.md](workflow-contract.md). Outputs: `status`
(`passed`/`failed`) and `exit-code`.

### Gate for consumers

A repository outside lgtm-ci adopts the gate with one dedicated workflow file
that pins the reusable to an exact SHA and needs no secrets (a caller on a
private mirror adds `LGTM_CI_TOOLING_TOKEN`; see
[Tooling token](workflow-contract.md#tooling-token-1451)):

```yaml
name: Gate

"on":
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  merge_group:

permissions: {}

jobs:
  gate:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-all-checks-gate.yml@<sha> # vX.Y.Z
    permissions:
      actions: read
      checks: read
      contents: read
      statuses: read
```

- **Permissions:** `actions: read`, `checks: read`, `contents: read` and
  `statuses: read` on the `gate` job, and `permissions: {}` for the workflow.
  Granting less fails the run at parse time.
- **Triggers:** `pull_request` and `merge_group`, and no `push`. The merge
  queue only starts the gate if the workflow listens for `merge_group`, and the
  required context must exist for the queued commit as well as the PR head.
  Leave out `workflow_dispatch`: the gate judges the checks of one commit, and
  a dispatched run has no pull request head to judge.
- **Ruleset:** require `gate / ✅ All Checks Passed` with GitHub Actions as its
  source. The `gate` prefix is the caller job id.

It differs from `reusable-required-check.yml` in what the one required context
stands for. `reusable-required-check.yml` turns the result of a single upstream
job (`needs.<job>.result`, optionally its `passed` output or a `results.v1`
document) into one named required context, and does not look at anything else.
`reusable-all-checks-gate.yml` ignores your job graph and waits on every other
workflow run, check run and commit status on the commit. Use the first to
require one job's verdict under a stable name, and the second so that native
auto-merge and the merge queue wait for everything.

### Ignored checks and retry refresh

`ignore-checks` changes the verdict, not visibility: the final step summary and
log list observed matching workflow runs, check runs and status contexts under
**Ignored (not judged)** with their current conclusion or status. Check runs
belonging to an ignored workflow are listed too, even when their own names do
not match. They do not count toward passing, failing, pending or settling; an
ignored-only head still needs `allow-empty: true` to pass. Own-workflow and
superseded exclusions are not treated as ignored checks. While judged workflows
are pending, only workflow runs are fetched, so timeout summaries can list only
the ignored workflow runs observed at that point.

This repository also installs `all-checks-gate-rerun.yml`: a `workflow_run`
completion handler with an explicit, contract-tested list of PR workflow names
(excluding the gate itself). A successful **later attempt** (`run_attempt > 1`)
refreshes failed `All Checks Gate` runs from `all-checks-gate.yml` on the same
head SHA. It re-reads each gate immediately before posting `rerun-failed-jobs`
and verifies that the attempt advanced or entered a running/queued state.
Successful, queued and in-progress gates are left alone. Per-SHA concurrency
serializes handlers, and gates completed at or after the triggering success
are skipped, preventing delivery replay from retrying a newly failed attempt.
The handler also rejects stale triggering attempts and deduplicates run IDs.
Ambiguous write failures are not automatically retried.

The privileged handler uses `actions: write` and `contents: read`, blocked egress
and immutable action pins. It checks out only the trusted default-branch SHA,
never the triggering PR SHA, and does not download PR artifacts. It becomes
active only once its workflow exists on the default branch. Consumers can copy
the caller and script, adjusting the explicit workflow-name list and gate file
identity for their repository. This first version is intentionally not a generic
reusable workflow: privileged trigger scope and trusted tooling checkout need
an explicit consumer adoption contract.

Limitations:

- **Request budget.** While a workflow run is in progress a poll costs one
  request, otherwise three plus one jobs listing per retried run (more when
  a list passes 100 entries). Placeholder reconciliation also fetches immutable
  source and completed job logs once, caching them for the remaining polls. While
  nothing changes the interval grows to 4x `poll-interval-seconds`.
  `GITHUB_TOKEN` allows 1,000 requests per hour per repository, shared by
  every workflow. At the default 60 s a gate waiting on workflows uses
  about 15–60 requests an hour, one waiting on a status or another app's
  check about 45–180 before retry lookups, so raise `poll-interval-seconds` where many PRs wait
  at once. A rate-limited poll waits instead of failing.
- **Jobs a cancelled run never started** (still waiting on `needs:`, so
  skipped or without a check run) are not compared against newer runs: if
  a newer run of the same file skips them too (say behind
  `if: github.event.action != 'labeled'`), they go unchecked. Check runs a
  workflow creates through the API are not tied to its run, so
  `ignore-checks` must match them by name.
- **`pull_request_target` workflows** run on the base commit, not the PR
  head, so the gate does not wait for their runs; only check runs that land
  on the PR head commit are gated.
- **Duplicate job names in one run** cannot be told apart from re-run
  attempts, so only the newest counts; the run's own conclusion still fails
  the gate.
- **The verdict is final until refreshed.** The optional retry handler above
  refreshes failed gates after successful later workflow attempts. Without it,
  or when a pending status resolves after the gate timed out, re-run the gate
  manually. First-attempt successes, third-party statuses and new workflow runs
  (as opposed to later attempts of an existing run) do not trigger refresh.
  A failed run stays failed even when a later run of the same workflow on
  the same commit is green (for example after close and reopen): re-run the
  failed run itself.
  Statuses that can stay pending for hours (`renovate/stability-days`) or
  jobs waiting on an environment approval will time the gate out; list them
  in `ignore-checks` if they are enforced elsewhere. For a job, match its
  workflow's name: a matched workflow is dropped together with its check
  runs (matching only the job still waits for its workflow run). When
  `reusable-auto-rerun-on-infra-failure` re-runs failed jobs, raise
  `settle-seconds` above its start-up delay (a few minutes) so the gate
  sees the re-run. Workflows that start after the gate finished (for
  example on `labeled` or `edited`) are not gated: add every
  `pull_request` activity type your other workflows use to the gate's
  trigger types.
- **Nothing to gate fails.** When no other check or status exists on the
  commit after the settle period the gate fails, so a merge queue whose
  workflows do not trigger on `merge_group` cannot merge unchecked. Set
  `allow-empty: true` for a repository with no other CI.
- **Same-SHA re-trigger window.** On `ready_for_review` or `reopened` the
  previous gate result for the same commit stays visible until the new run
  registers its check (seconds). Drafts are gated like any PR, and
  workflows that skip on drafts report `skipped`, so a draft's gate can be
  green on nothing real; `fail-on-draft: true` makes it red instead.
- **Trust model.** As with every `pull_request` check, a PR can edit the
  caller workflow (for example `ignore-checks: '.*'`). Protect
  `.github/workflows/` with CODEOWNERS review and pin the required check's
  source to GitHub Actions.

## Tests

```yaml
jobs:
  node:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-node.yml@<sha>
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      node-versions: "20,22"
      pre-test-command: bun run build
      upload-build-artifact: true

  python:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      coverage: true
      upload-coverage: true

  shell:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-shell.yml@<sha>
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
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

`reusable-test-shell.yml` and `reusable-test-shell-run.yml` take two inputs for
kcov coverage (#1373):

- `coverage-include-path` (default `scripts/ci/lib`): comma-separated
  repo-relative paths kcov instruments, one `--include-path` and one
  `--bash-parse-files-in-dir` per entry. The default is lgtm-ci's own library
  location; callers set it to their own shell library path (for example
  `scripts/lib,scripts/ci/lib`). The run fails with an `::error::` naming the
  paths when none of them exists in the checkout; missing entries next to an
  existing one only warn. Migration: before this input existed the run always
  pointed kcov at `scripts/ci/lib` and reported 0% when that directory was
  absent; a caller without `scripts/ci/lib` must now set
  `coverage-include-path` to its library path (or `coverage-on-empty:
not-applicable` when it has no library) instead of relying on a 0% result.
- `coverage-on-empty` (`fail` default, or `not-applicable`): what to do when
  kcov instruments zero lines. `fail` keeps the 0% result, so a
  `coverage-threshold` above 0 fails. `not-applicable` reports
  `coverage-percent` as `n/a`, skips the threshold check with a `::notice::`,
  and the PR summary shows `n/a` with no percent sign or threshold verdict.

`reusable-publish-test-summary.yml` is the shared internal workflow used by
language test reusables to publish test summaries (rich coverage table when
coverage was collected, otherwise test pass/fail totals). Artifact-based comments
use `reusable-publish-artifact-report.yml`.

The totals table comes from the `results.v1` documents named by
`results-artifact-pattern`, from the JUnit XML reports named by
`junit-artifact` (#1686: the workflow counts every test case itself, see
[junit-artifact.md](junit-artifact.md); setting both inputs fails the job),
or, for a direct caller without either, from the count inputs `tests-passed`, `tests-failed`, `tests-total`,
`tests-skipped`, `tests-xfailed` and `tests-xpassed` (the last three strings,
default empty, read as 0). Its rows (#1684, #1685):

- **Total Tests** is the caller's total: `tests-total`, or `counts.total`
  (`passed + failed` with `tests-total-excludes-skipped: true`).
- **Skipped** is `tests-skipped`, or `counts.skipped`.
- **Expected failures** appears after Skipped when `tests-xfailed` (or
  `counts.xfailed`) is above 0: tests marked to fail that failed.
- **Unexpected passes** follows when `tests-xpassed` (or `counts.xpassed`) is
  above 0, marked ⚠️, with one line under the table saying the marker should
  be removed from those tests. A strict unexpected pass is reported by pytest
  as failed and stays under Failed.
- **Other** appears next only when the total is larger than
  `passed + failed + skipped + xfailed + xpassed`, and shows the difference:
  tests the report counts in its total in none of those rows, for example
  skipped tests of a direct caller that passes no `tests-skipped`, or
  pytest's expected failures from a document written before #1685. There is
  no row when the difference is 0 or negative. pytest errors are not in it:
  the pytest parser counts them as failed, as the JUnit parser does for
  `<error>`.
- **Pass Rate** is `passed * 100 / (passed + failed)`, rounded down. When
  `passed + failed` differs from the Total Tests value, the rate names its
  denominator, for example `100% (of 229 run)`. There is no row when
  `passed + failed` is 0.

The status line and the pass rate do not change with expected failures or
unexpected passes: a run with `failed = 0` stays ✅ PASSED.

When the document has an `expected_failures` list (pytest fills it), a
collapsed **Expected failures and their reasons** block follows the table:
one line per test, the test id as code and the reason as text, both through
the comment sanitiser ([comment-sanitize.md](comment-sanitize.md)), so a
reason cannot mention anyone, link, or inject markup. The comment shows at
most 50 lines and at most 200 characters of each id and reason (the document
keeps 500). Sanitising expands text (`<` becomes `&lt;`), and the comment
must stay well within GitHub's limit (262,144 bytes; an oversized comment is
replaced by a notice and fails the step), so lines stop once the block would
pass 20,000 bytes, measured after
sanitising (#1702). A last line says `and N more` for every entry not shown.
The table, status and footer are never cut: with the largest list and a
2,000-character suite name the whole comment stays near 40,000 bytes. A
matrix aggregate lists the same test (same id and reason) from several legs
once; when that leaves fewer entries than the Expected failures count, a line
says so. The direct-caller inputs carry counts only, no list; a
`RESULTS_EXPECTED_FAILURES_FILE` in the environment is ignored on that path.

The run-history totals line follows the table, for example
`229 passed, 0 failed, 13 skipped, 13 expected failures`; unexpected passes
add `, N unexpected passes` and anything left `, N other`.

`tests-skipped`, `tests-xfailed` and `tests-xpassed` accept digits only. Any
other value (a sign, decimal point, space, exponent or hex prefix) is ignored
with a warning that names the input but not the value, and the tests it would
have covered show under Other. When `tests-xfailed` and `tests-xpassed` add up
to more than `tests-total` leaves after passed, failed and skipped, both are
ignored with one warning naming the two inputs (#1702): rows that cannot add
up to the total are not shown, and the rest of the total shows as Other.
Leading zeros in any count are dropped (`08` reads as 8). The other counts
must be plain whole numbers of at most nine digits; anything else is
unreadable (#1676): the comment names the field, shows no totals, and its
status is `NO COUNTS`, never a pass.

Quality lint-only checks use `reusable-quality-lint.yml`; PR lint summaries use
`reusable-publish-quality-summary.yml` (called directly by the caller workflow).

### PR comment run history (`comment-history`, #1346)

Every PR comment publisher overwrites its marker comment on each run unless
`comment-history: true` is set. With it, the latest result stays on top and
earlier runs fold into a collapsible **🕘 Previous runs** archive; see
[post-pr-comment run history](actions/pr-comments.md#run-history-history-1346)
for the format, ordering, size budget and race behaviour.

<!-- markdownlint-disable MD013 -- input reference table -->

| Input                   | Type    | Default | Purpose                                                                  |
| ----------------------- | ------- | ------- | ------------------------------------------------------------------------ |
| `comment-history`       | boolean | `false` | Keep earlier runs in the archive under the latest result                 |
| `comment-history-limit` | number  | `3`     | Earlier runs kept; `0` = unlimited within the 60,000-byte comment budget |

<!-- markdownlint-enable MD013 -->

Both inputs are accepted by:

- the test summary publisher `reusable-publish-test-summary.yml`, whose
  archived entries are labelled with the run's totals line
  (`42 passed, 1 failed · 91.2% cov`, or the line coverage for a rich coverage
  table), and the facades that call it: `reusable-coverage.yml`,
  `reusable-rust-test.yml`, `reusable-site-quality.yml`,
  `reusable-test-e2e-playwright.yml`, `reusable-test-node.yml`,
  `reusable-test-node-custom.yml`, `reusable-test-python.yml` and
  `reusable-test-shell.yml`. The read-only `*-run.yml` variants publish nothing
  and do not declare them;
- `reusable-publish-quality-summary.yml` (entries labelled with lintro's total
  issue count);
- `reusable-publish-security-audit-comment.yml`,
  `reusable-publish-file-breakdown.yml`, `reusable-publish-artifact-report.yml`
  and `reusable-publish-artifact-preview.yml`, plus the facades that call the
  artifact-report publisher: `reusable-link-check.yml` and
  `reusable-validate.yml`.

`reusable-semantic-pr-title.yml` (its failure comment is deleted on success)
does not take them. The default stays `false` for now. Enable history on test,
coverage, quality and security comments first; the file breakdown is already
cumulative over the PR, and artifact preview links expire with the artifact, so
their archives add little.

```yaml
jobs:
  python:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha>
    permissions:
      actions: read
      contents: read
      pull-requests: write
    with:
      coverage: true
      comment-history: true
      comment-history-limit: 5
```

### PR comment fields (`comment-fields`, #1677)

Every workflow that posts a pull request comment takes `comment-fields`
(string, default empty): labelled values shown under the comment's heading,
one `Label: value` per line, for example the environment a test run targeted.
A bad line becomes a note in the comment and a warning in the job log, never a
failure. Rules, limits and messages: [comment-fields.md](comment-fields.md).

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-playwright.yml@<sha>
    permissions:
      contents: read
      pull-requests: write
    with:
      comment-fields: |
        Environment: staging
        Environment URL: https://staging.example.com
        Region: eu-west-1
```

The input is accepted by every workflow that takes `comment-history` (listed
above) and by `reusable-semantic-pr-title.yml`. The read-only `*-run.yml`
variants publish nothing and do not declare it.
`scripts/ci/workflows/validate_comment_fields_forwarding.py` fails when a
workflow posts a comment, or calls one that does, without declaring and
forwarding the input.

### Matrix aggregation waits for the artifact listing (#803)

`reusable-test-python.yml`, `reusable-test-node.yml` and
`reusable-rust-test.yml` collect per-leg results into one aggregate job.
GitHub's artifact listing is eventually consistent: a leg whose upload
reported success can be absent from the run's artifact list for tens of
seconds, and a listed artifact can still 404 on download for a few more. A
one-shot download then fails the aggregate with
`Expected 2 matrix summaries, found 1` on a run whose legs all passed.

The aggregate job therefore runs `scripts/ci/actions/wait-for-artifacts.sh`
before aggregating. It polls
`GET /repos/{owner}/{repo}/actions/runs/{run_id}/artifacts` until the count of
artifacts matching the matrix pattern (`<artifact-prefix>-results-*`, see
[Calling a language test reusable twice in one run](#calling-a-language-test-reusable-twice-in-one-run-1091))
reaches the matrix size (from the `prepare` job's `matrix-count` output),
backing off 2/4/8/16/30 s within a 90 s
budget, then downloads each listed artifact over the REST zip endpoint and
checks it against the listing's sha256 `digest` before extracting. Every API
call runs under a 30 s bound, SIGKILL 10 s later, so a stalled request cannot
burn the job budget; when a leg already failed the budget drops to 10 s, since a
leg that never uploaded will not appear. The bound is a `timeout` binary (or
`gtimeout`) when one is on `PATH`: GNU coreutils, or the BSD `timeout` of newer
macOS releases, which takes the same arguments and gives the same statuses. On
a runner with neither, such as the hosted macOS images, it is a perl watchdog
with the same signals and exit statuses (#1729,
`scripts/ci/lib/bounded-run.sh`, which runs the program
`scripts/ci/lib/bounded_run_watchdog.pl` beside it; the aggregate jobs check
out all of `scripts/ci/`, so the program is on the runner, and a missing or
uncompilable one counts as no bound). The watchdog's perl runs with every `PERL*`
variable removed, so none of them can preload code into it; it refuses bounds below 0.001 s and
caps them at 100,000,000 s (the largest interval timer macOS accepts), and
when the command exits it also kills what is left of the command's process
group, which coreutils `timeout` does not. With no usable perl either the
step fails rather than run unbounded. The retry is narrow on purpose:

<!-- markdownlint-disable MD013 -- behaviour column exceeds default line length -->

| Condition                                                                                                     | Behaviour                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Listing shows fewer than expected                                                                             | retried until the budget expires; the failure names the missing legs                                                       |
| HTTP 404 downloading an id the listing returned                                                               | retried within the same budget                                                                                             |
| Listing or download answers HTTP 500, 502, 503 or 504 (#1606)                                                 | retried within the same budget; the failure names the answers seen and the number of attempts                              |
| Listing shows **more** than expected, or a matching name outside the matrix                                   | fails at once — a sibling call in the same run uploaded under the same names (see [Artifact names](#artifact-names), #752) |
| Any other listing/download error (401, 403, other 4xx), timeout, digest mismatch, corrupt or escaping archive | fails at once                                                                                                              |

<!-- markdownlint-enable MD013 -->

All retries share one budget and one backoff schedule: a 404 followed by a
503 on the same artifact counts as attempts of the same retry sequence. A
transient answer is read from the `gh` error line only: `gh: HTTP 503`, or
`gh: <message> (HTTP 503)`. The same digits elsewhere, in an artifact id, a
name or a URL, do not count, and any other `gh:` error line next to it (a
401 or 403, or an error the script does not know) makes the failure fatal at
once. Each failed attempt's file is deleted before the next one, and the
digest and archive checks run once, on the download that succeeded. In the
worst case a transient error adds the rest of the budget (90 s, or 10 s
after a failed leg) plus one bounded call (30 s, plus up to 10 s to stop it)
to the job, the same as the 404 lag. When the budget ends on a server error,
the job fails with `Download of artifact <name> (id <id>) still answered
HTTP <code> after <n> attempts over <s>s (answers seen: …); a transient
GitHub server error outlasted the wait budget (#1606)`; a listing that keeps
answering a server error fails with `Artifact listing still answered HTTP
<code> after <n> polls over <s>s …`.

Aggregation then runs once against the downloaded set with its existing
strictness (#1058). The happy path adds one API call and no sleep. A rerun
of failed jobs lists the earlier attempt's artifacts too; the wait keeps the
newest artifact per name, as `actions/download-artifact` does, so a rerun is
not mistaken for contamination.

The sharded path of `reusable-test-shell.yml` is affected by the same race
and runs the script in a lighter mode: listing only (no `DOWNLOAD_DIR`),
expecting `coverage-shards` TAP artifacts, as a `continue-on-error` pre-check
ahead of its existing best-effort downloads — once for the TAP artifacts and
once for the coverage artifacts, which upload later. The strict shard count in
`run-bats-tests.sh` stays the verdict there; the wait's log names the shard a
permanent under-count is missing. The artifact pattern is
`<artifact-prefix>-test-results-<comment-marker>-shard-*`, so keep the marker
free of glob characters (`*`, `?`, `[`); the prefix is validated.

This is why all four workflows request `actions: read` on the aggregate job:
`GITHUB_TOKEN` cannot read the artifact listing without it, and a reusable
workflow's request is validated statically, so every caller must grant
`actions: read` alongside `contents: read` and `pull-requests: write`. The
job previously used only `actions/download-artifact`, which authenticates with
the per-run runtime token, so the scope was deliberately absent (#730).

### Playwright E2E (`reusable-test-e2e-playwright.yml`)

Thin callers express full / smoke / a11y as separate jobs with distinct
`job-name` values. `project` and `grep` append to `test-command` (default
`npx playwright test`). Browser cache key uses the resolved Playwright version.
Reporters go out as one `--reporter=` flag (`reporters`, default
`list,json,junit,html`), replacing the config's reporters; a missing
`playwright-report/` after the run fails the job (#804). Reports upload when
`upload-report` is true, on failure by default or on every run with
`upload-report-when: always`. Default egress preset is `playwright`.

The default runner is `ubuntu-26.04`, which needs `@playwright/test` 1.61 or
newer (the first release with Ubuntu 26.04 browser builds, per the
[v1.61.0 release notes](https://github.com/microsoft/playwright/releases/tag/v1.61.0)).
The install step reads `/etc/os-release` and, on 26.04 with an older
`@playwright/test`, fails before `playwright install` with an `::error::`
naming the found version and the minimum. Bump `@playwright/test`; setting
`runner-image: ubuntu-24.04` (or `vars.LGTM_CI_RUNNER`) is a temporary escape
hatch, not a fix. The same check guards `reusable-test-e2e.yml` and
`reusable-test-e2e-matrix.yml` (#1313).

<!-- markdownlint-disable MD013 -->

| Input                | Type    | Required | Default                | Purpose                                      |
| -------------------- | ------- | -------- | ---------------------- | -------------------------------------------- |
| `job-name`           | string  | yes      | —                      | Check / summary title                        |
| `test-command`       | string  | no       | `npx playwright test`  | Base CLI                                     |
| `project`            | string  | no       | empty                  | `--project` filter                           |
| `grep`               | string  | no       | empty                  | `--grep` filter                              |
| `browsers`           | string  | no       | `chromium`             | install-deps and install targets             |
| `reporters`          | string  | no       | `list,json,junit,html` | One `--reporter` flag; needs `json` + `html` |
| `upload-report`      | boolean | no       | `true`                 | HTML/JUnit/blob artifact                     |
| `upload-report-when` | string  | no       | `failure`              | `failure` or `always`                        |
| `base-url`           | string  | no       | empty                  | `BASE_URL` passthrough                       |
| `web-server`         | string  | no       | empty                  | `PLAYWRIGHT_WEB_SERVER`                      |

<!-- markdownlint-enable MD013 -->

Outputs: `tests-passed`, `tests-failed`, `tests-total`, `tests-xfailed`,
`tests-xpassed`, `passed`.

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
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
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
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
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
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
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

Each `targets` entry names its builder (`native`, `cross`, or `xwin`); the
default Windows leg is `x86_64-pc-windows-msvc` built with a digest-verified
`cargo-xwin` on Linux, and `cross` with an MSVC target is rejected before the
build. A caller that wants a MinGW artifact instead overrides the matrix:

```yaml
jobs:
  release:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-rust-release.yml@<sha>
    permissions:
      attestations: write
      contents: write
      id-token: write
    with:
      packages: "my-cli"
      targets: >-
        [{"target":"x86_64-unknown-linux-musl","builder":"native","archive":"tar.gz"},
         {"target":"x86_64-pc-windows-gnu","builder":"cross","archive":"zip"}]
```

See
[Windows targets and runner tiers](workflow-contract.md#windows-targets-and-runner-tiers)
for the opt-in native Windows tier and the egress hosts the `xwin` leg needs.

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

A repository without a `CHANGELOG.md` does not need to create one first: the
`Update CHANGELOG.md` step seeds a Keep a Changelog header with an empty
`## [Unreleased]` section and writes the first release into it, so the file
appears in the same version PR as its first entry (#1092). Under
`egress-policy: block` the default `egress-preset: release-version-pr` already
covers the registries the ecosystem bumps reach (PyPI for `ecosystems: python`
/ kind `pep621`, rustup and crates.io for `ecosystems: rust`), so selecting an
ecosystem needs no `allowed-endpoints` (#1093).

`catalog-release-notes: true` (default `false`) merges the
`catalog/catalog.yml` diff since the previous stable tag into the generated
section: entries added or removed, tier changes, and inputs, outputs and entry
points newly deprecated or removed, each as a `**catalog**` bullet under
`Added`, `Changed`, `Deprecated` or `Removed` (#1082). It is meant for
repositories that keep an lgtm-ci support catalog; lgtm-ci's own version PR
sets it. Nothing is added when either release has no catalog.

`reusable-release-version-pr.yml` also covers what the removed
`reusable-release-multi-ecosystem.yml` did, through optional inputs whose
defaults keep version-pr's own behaviour (#1356). A caller that passes none
of them gets the same steps, PR and version as before:

| Input            | Default             | Effect when set                                                                 |
| ---------------- | ------------------- | ------------------------------------------------------------------------------- |
| `bump`           | `auto-from-commits` | `explicit` uses `version` instead of conventional commits                       |
| `version`        | `""`                | Semver for `bump: explicit` (optional `v` prefix)                               |
| `prerelease-tag` | `""`                | Appends `-<tag>` to the next version (`rc.1` → `1.2.3-rc.1`)                    |
| `changelog`      | `true`              | `false` skips `Generate changelog` and `Update CHANGELOG.md`                    |
| `manifests`      | `""`                | JSON `{path: kind}` (`npm`, `raw`, `gemspec`, `pep621`), run after `ecosystems` |

With the default `bump` and an empty `prerelease-tag`, the version still comes
from `calculate-version.sh` and `max-bump`. Otherwise the step runs
`resolve-multi-ecosystem-version.sh`, which wraps it. `manifests` uses the same
`_manifests_runner.sh` the removed multi-ecosystem workflow used, in the
token-free hook job and in `version-pr`, and can be combined with `ecosystems`. Before any
update, every manifest path must be relative, free of `..`, reached through no
symlink, and resolve inside the checkout but outside `.git` and
`.lgtm-ci-tooling`; otherwise the step fails with an `::error` naming the path.
An empty `manifests` skips the manifest update; with no `ecosystems` and no
`version-update-script` either, the version PR then carries only the changelog.
With `changelog: false` the PR body shows `_No changelog entries._` under
Changelog.

```yaml
jobs:
  version-pr:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
    permissions:
      actions: read
      contents: write
      issues: write
      pull-requests: write
    with:
      manifests: '{"package.json":"npm","VERSION":"raw"}'
      prerelease-tag: rc.1
    secrets: inherit
```

`request-workflows-permission` (boolean, default `true`, on
`reusable-release-version-pr.yml`) decides whether the version-PR App token
asks for `workflows: write` next to `contents: write` and
`pull-requests: write` (#1449). The default needs the
App to hold `Workflows: Read and write`; without it the job fails at
`Create GitHub App installation token`. Set `false` for an App that does not
hold it. The `Refuse workflow file changes` step then fails the job, before
the version PR is published, if an updater or the hook diff changed anything
under `.github/workflows/`, and the error names the path. One risk with
`false` is unproven: a leftover version-PR branch that is force-moved across
workflow changes on the default branch may be refused by GitHub. See
[workflow-contract.md](workflow-contract.md) and
[migration/v0.94.md](migration/v0.94.md).

When release automation fails on the default branch, the follow-up
`report-release-failure` job runs two steps in order: it first writes release
trigger context to the job step summary, then creates or updates a deduplicated
GitHub issue with failed step details. Set `report-failures: false` to disable
both actions. See [workflow-contract.md](workflow-contract.md) for inputs.

### Version update hook (`version-update-script`)

`reusable-release-version-pr.yml` runs the caller's `version-update-script`
in its own job, `version-update-hook`, with `permissions: contents: read`, no secrets and no
token of any kind (#849). The jobs that mint the App installation token
(`prepare`, `version-pr`) execute lgtm-ci code only; a hook can never edit
tooling that later runs with the token. Callers without a hook skip both
extra jobs.

The hook job does not check out the lgtm-ci tooling, since that may need
`LGTM_CI_TOOLING_TOKEN` (#1451). `prepare` packs `scripts/ci` from its own
tooling checkout, after the tooling-ref divergence guard, into a tarball,
uploads it as `release-<workflow>-tooling-<key>` and passes its SHA-256 as
the `tooling-digest` job output. The hook job downloads the tarball outside
the workspace, checks it against that digest and extracts it into
`.lgtm-ci-tooling` before any step that reads or runs the caller's code.

The hook receives:

- `NEXT_VERSION` — the version being prepared.
- `RELEASE_METADATA_PATH` — a read-only JSON file written by lgtm-ci code in
  the `prepare` job, so a hook needing API data does not need a token:

```json
{
  "schema": 1,
  "repository": "owner/name",
  "next_version": "1.3.0",
  "tag_prefix": "v",
  "latest_release": {
    "tag": "v1.2.2",
    "version": "1.2.2",
    "published_at": "...",
    "url": "..."
  },
  "container": {
    "package": "name",
    "version": "1.2.2",
    "digest": "sha256:..."
  }
}
```

`latest_release` is `null` when the repository has no release. `container`
is the highest bare `major.minor.patch`-tagged version (no `v` prefix;
`sha-*`, `latest` and the like are ignored) of the GitHub Packages container
named by `release-metadata-container-package`; it is `null` when that input
is empty, the package is unreadable, or no release tag exists. Setting the
input makes the `prepare` job request `Packages: read` on its token, so the
App must hold that permission or the token step fails. A hook that re-pins a
published image
reads this instead of calling the API.

The hook sees the prepared workspace (changelog and ecosystem/manifest
updates already applied) and its own edits — tracked changes and new files —
travel to the privileged job as a `git diff` artifact. That job rejects the
diff if it touches `.github/**` (workflows, composite actions, CODEOWNERS),
the tooling checkout, `.git/`, any path outside the repository (matched
case-insensitively), or adds a symlink or submodule pointer; it also refuses
a diff built for a different version than it resolved itself. It then
`git apply --check`s and applies the diff before PR creation. A hook that writes
into `.lgtm-ci-tooling/` or exits non-zero fails the run before any branch,
commit or PR exists.

The isolation assumes ephemeral runners (GitHub-hosted, or self-hosted with
a fresh machine per job): the hook job and the privileged job share nothing
but the artifact. On a persistent self-hosted runner, state the hook leaves
in `$HOME`, the tool cache or a lingering process would carry over, and the
guarantee does not hold. Artifacts are named per `tag-prefix` through a
filesystem-safe key (`release-version-pr-hook-changes-<key>`, where
`cli/v` becomes `cli_v-<digest>`), so two calls of one reusable in a single
run must use distinct prefixes, as the version PR title and concurrency
group already require.

**App token scope.** Every `create-github-app-token` step in the release
reusables passes `repositories: ${{ github.event.repository.name }}`, so an
App installed org-wide still yields a token for the calling repository only.
No lgtm-ci reusable writes to a second repository; a future one that must
(for example a Homebrew tap dispatch) takes that repository as an explicit
input rather than widening this default.

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

### Release failure notifier (tag publishes)

`reusable-release-failure-notifier.yml` is the tag-publish counterpart of the
two notifiers above. The branch-keyed mechanisms go quiet on tag runs
(`GITHUB_REF_NAME` is the tag, so a branch gate never matches), which is how a
half-published release used to stay invisible. This reusable deduplicates by
tag: one open issue per `<workflow-key>` + `<tag>` —
`release-failure:<key>:<tag>` — titled
`fix(release): tag publish failed: <tag> (<key>)`, labelled
`bug,ci,release,automation,infrastructure` (missing labels are skipped; create
`release` in the consumer if absent).

```yaml
release-failure-notifier:
  name: Report release failure
  needs: [pypi-build, pypi-upload, github-release]
  if: always()
  # yamllint disable-line rule:line-length
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-failure-notifier.yml@<sha> # vX.Y.Z
  with:
    workflow-key: publish-python-release # stable key: one open issue per key+tag
    tag: ${{ github.ref_name }}
    channels: ${{ toJson(needs) }}
    max-reruns: 3 # only with the auto-rerun reusable wired; default 0 files every failure
  permissions:
    actions: read
    contents: read
    issues: write
```

`channels` accepts `toJson(needs)` directly; per-job `url` (job link column)
and an optional `probe` (whether the channel already has the version) can be
added by building the JSON in a pre-step. Without a `url` the job column links
to the run, which lists every job. Verdicts:

- **every channel success/skipped** — comments on and closes the tag's issue.
- **a channel failed** — files or updates the issue at once, with a channel
  table (channel, result, job link, probe) and the recovery tier per
  [release-security-policy.md](release-security-policy.md). A transient
  failure now opens an issue that closes itself on a successful re-run
  (#1710): when the attempt is within `max-reruns` and its failed-job logs
  match an infra signature (the classifier the auto-rerun reusable acts on),
  the issue says an automatic re-run may follow (`rerun-may-follow`). The
  issue is keyed by workflow and tag, never by attempt, so the re-run's
  notifier (a `--failed` re-run re-runs the jobs that depend on the failed
  ones, and this job depends on every publish job) closes it when every
  channel publishes and updates it when the re-run fails too. Before #1710
  the job stayed quiet in this case, and a re-run the auto-rerun then
  declined left the failure unreported. A run of an event the auto-rerun
  never re-runs (`release`, for one) files with `ref-not-rerun`.

`max-reruns` (default `0`) only words the issue: set it to the caller's
`reusable-auto-rerun-on-infra-failure.yml` input when that reusable watches
this workflow, and pass the same `signatures` extension to both so they
classify alike. A wrong value never keeps a failure from being filed.
The failed-job log fetch is bounded like the auto-rerun script's
(`GH_CMD_TIMEOUT`, `LOG_FETCH_DEADLINE`); logs that stay unavailable file
rather than wait. The filed issue's summary states the classification reason
(re-run budget exhausted, no infra signature, logs unavailable). The contract
section is
[workflow-contract.md](workflow-contract.md#tag-publish-failure-reporting-release-mode).

### Auto re-run on infra failure

`reusable-auto-rerun-on-infra-failure.yml` re-runs the failed jobs of a
completed workflow run when — and only when — the failed-job logs match a
known transient-infrastructure signature. Built-in signatures, matched
anywhere in the failed-job logs:

- `Failed to resolve action download info`
- `The runner has received a shutdown signal`
- `lost communication with the server`

A cosign signing step whose in-step OIDC retry gave up is the fourth built-in
case, matched only in one line, not anywhere. cosign's transient ambient-OIDC
markers (`fetching ambient OIDC credentials`, `retrieving ID token`,
`reading ID token`) are single-sourced from `scripts/ci/lib/cosign.sh`, so the
in-step signing retry and this after-the-fact safety net cannot drift apart.
The in-step retry is the fast path; this matcher covers the case where that
retry is exhausted and the publish fails outright. Since #1706 a marker counts
only in the line that retry prints when it gives up (`[ERROR] <operation>
failed for <target> after <N> attempt(s): transient OIDC failure persisted
(matched '<marker>')`), and only when the job's next line is GitHub's
`##[error]Process completed with exit code <N>.`. Anywhere else, such as a
test that prints the marker, it is not a signature: run 44749053360 failed on
one ordinary test and was re-run because a passing cosign test had printed
`fetching ambient OIDC credentials`. A step that prints that pair on purpose
still gets its job re-run: this reads the log, it does not prove where a line
came from, and the cost is compute up to `max-reruns`, for the current head
only.

Egress refusals are deliberately not signatures: under harden-runner's block
policy a host missing from the allowlist fails identically on every attempt
(`Error resolving allowed domain`, `connect: connection refused`,
`ECONNREFUSED`), so a re-run never helps and, on a publish workflow, repeats
jobs that already published. `Error resolving allowed domain` was a built-in
signature until 0.74.2 and re-ran a publish run into the npm approval gate
(#967). A caller that knows a refusal is transient in its own environment can
still add it through `signatures`.

A job that GitHub could not place on a runner ("The job repeatedly failed to
be acquired (5 attempts)") never starts, so it leaves no log for the matcher.
The reusable reads the check-run annotations of failed jobs that ran zero
steps instead (`ACQUISITION_MAX_JOBS` of them, default `10`, `0` disables) and
treats `failed to be acquired`, `failed to acquire` and `was not acquired`
as a transient signature. That check runs both when the failed-job log is
empty and when it matched nothing: a matrix can lose one runner while another
leg fails for real. Reading annotations needs `checks: read`, which the
reusable declares and every caller must grant alongside `actions: write`.

A harden-runner agent that did not start (#1616), or harden-runner's eBPF
fallback agent refused at job start (#1668), is checked at the same two
points. The `Verify harden-runner agent` step still fails the job: a job
never continues without a verified standard agent. The reusable only decides
whether the failure was transient, and re-runs it on attempt 1 only, whatever
`max-reruns` allows: a failure that comes back on the re-run is not
transient. A job counts when three things agree:

- **Step shape.** The first failed step is `Verify harden-runner agent`, and
  every step before it is `Set up job`, `Pre Harden runner` or
  `Harden runner`.
- **Annotations.** The job's only own annotation is the message of one
  cause, with at most one `Process completed with exit code N.` line per step
  that ran from the verify step on:
  - `agent.service is not active; egress is not enforced` (the agent did
    not start);
  - `harden-runner installed its eBPF fallback agent; only the standard
agent is trusted` (#1668).

  When the reusable test workflows' `always()` step
  `Fail if any matrix leg failed` failed after the verify step, its own
  message is allowed once: with nothing aggregated, it fails whether or not
  a leg did.

- **Job log** (`GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs`),
  evidence of that same cause:
  - agent did not start: the agent's own `Error resolving allowed domain`
    line for an allowed host, ending in `status 2` (SERVFAIL) or `status 5`
    (REFUSED). The pinned agent resolves every allowed host at start and
    exits on one such answer. NXDOMAIN (`status 3`) and every other agent
    failure are not matched;
  - eBPF fallback: harden-runner's own line
    `[!] Unable to check TLS_STATUS. Defaulting to TLS enabled.` in its
    pre-step. When its TLS-status call
    fails, harden-runner v2.22.3 installs the eBPF agent v1.9.5 in place of
    the standard agent v0.18.0; the re-run usually gets the standard agent.

The runner prints caller-controlled text verbatim (a `run:` step's caption
is its script's first line; an action's inputs and environment are printed
raw), so the log line counts only where its provenance is structural:

- **harden-runner's own output**: after its `[harden-runner] pre-step` or
  `[harden-runner] main-step` marker, which must directly follow the details
  group of a `step-security/harden-runner@<sha>` action (one that opens with
  `with:`), and before the next group. The TLS-status line counts only in
  the pre-step.
- **the verify step's own output** (DNS line only, #1669). harden-runner
  waits only 9 seconds for the agent, so an agent that fails later is
  otherwise reported only in harden-runner's post step, after job steps ran.
  When the verify step finds the agent inactive, it prints the agent's own
  start-up errors from `agent.log`, each prefixed with
  `verify-harden-runner-agent: agent.log:` and a space. No job step has run at that
  point. The prefixed line counts only in the output of the first step after
  harden-runner, whose caption must be the verify step's
  (`Run # lgtm-ci-inline:begin verify-harden-runner-agent`), between its
  details group and the next group or the runner's `Post job cleanup.`
  line, and before that step's own `##[error]` line for the start-up
  message. The log must hold that caption and that `##[error]` line exactly
  once.

`Set up job`, the runner configuration dumps, `Initialize containers`, the
action's or step's inputs and environment, and any later step never count.
Any forged group end, marker, caption or `##[error]` line makes the whole
check fail closed: no re-run. Of the three late-failing occurrences on #1616
(fixture runs 43858549864, 43924199865 and 43983818529), the agent failed
while the verify step was polling, so each now matches.

A failed end-of-job `Recheck harden-runner agent` (the agent stopped
enforcing mid-job) is never re-run. Its known benign cause was the eBPF
fallback agent, which the verify step now refuses at job start.

A caller whose repository or organization variable
`LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT` is exactly `true` opts in to the eBPF
agent: the verify step accepts it only with its own proof of block mode
([workflow-contract.md](workflow-contract.md), "Opting in to the eBPF
agent"), so the refusal above does not happen. An eBPF agent that lacks part
of that proof fails with a different message and is never re-run.

At most `AGENT_CHECK_MAX_JOBS` failed jobs with an agent-failure shape
(default `3`, `0` disables) have their annotations and log read; a job ruled
out before any read (no numeric id) does not count. When the budget runs out
with shape-matching jobs left unread, the run says so with a warning and none
of them is re-run. The step summary names the job, the step and the rule.

#### A superseded commit is not re-run (#1706)

Immediately before re-running, the reusable compares the run's head commit
with the current commit of the branch or tag it ran on, in the run's head
repository. A re-run of an old commit's run would join the concurrency group
of the current commit's run and, with `cancel-in-progress`, cancel it. Every
event is handled explicitly:

| Event                                 | Re-run only when                                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `pull_request`, `pull_request_target` | the pull request's head branch is still at the run's commit                                             |
| `merge_group`                         | the queue branch (`gh-readonly-queue/...`) is still at it                                               |
| `schedule`                            | the branch the schedule ran on is still at it                                                           |
| `push`, `workflow_dispatch`           | a branch of that name, and no tag, is still at it; or a tag of that name, and no branch, still names it |
| any other, or none                    | never                                                                                                   |

Refs are read fully qualified,
`GET /repos/{owner}/{repo}/commits/refs%2Fheads%2F<name>` for a branch and
`.../commits/refs%2Ftags%2F<name>` for a tag, which resolves an annotated tag
to the commit it names. One namespace never stands in for the other, and a
name that looks like a commit SHA is never read as one. A `push` or
`workflow_dispatch` run can be on a branch or a tag, and the run payload does
not say which (`head_branch` holds either name, and the run has no `ref`), so
the reusable lists both
(`GET /repos/{owner}/{repo}/git/matching-refs/{heads,tags}/<name>`, exact
name): a branch alone is compared by its tip, a tag alone by its commit, and
both or neither is not re-run. A tag does not move in normal use, so a failed
tag publish is re-run while its tag still names the run's commit. A pushed
branch that has since been deleted, while a tag has its name, reads as a tag
run too, and is re-run only when that tag names the run's own commit: with
no branch there is no newer run in that branch's concurrency group to cancel,
and the commit re-run is the one the tag names. Pull request, merge-queue and
schedule runs are always on a branch, so for them a same-named tag is never
read. All reads need `contents: read`; each is bounded by `HEAD_CMD_TIMEOUT`
(15 s).

Since #1706 the failed jobs are **not** re-run, and the step summary says
why, when:

- the run is for a superseded commit: its branch has moved on. This includes
  a `push` run on a busy default branch where another commit landed during
  the run;
- the run's tag no longer names its commit (the tag was moved);
- the run's branch or tag is gone (a pull request merged with auto-delete, a
  finished merge-queue entry, a deleted branch with no tag of its name, a
  deleted tag);
- a `push` or `workflow_dispatch` run's name is both a branch and a tag;
- the head repository cannot be read, such as a private fork;
- any of the head check's reads (the run, the branches, the tags, the commit
  of the branch or tag) fails or times out, even transiently;
- the run payload has no valid head SHA, event, branch or head repository
  (for example a deleted fork);
- the run's event is not in the table above (for example `release`).

The [release failure notifier](#release-failure-notifier-tag-publishes)
does not depend on this check: it files every failed release at once, and
the issue closes itself when a re-run publishes every channel, so a re-run
the head check declines never leaves a failure unreported.

The check narrows the window, it does not close it. The tip read and the
re-run request are two requests, so a push that lands between them, or a
force-push back to the run's commit, can still let the re-run join the
current commit's group and cancel its run. It avoids re-running stale work;
it is not a guarantee. The guarantee that an automatic re-run never cancels
another run comes only from the caller's concurrency group: give every attempt
above the first a group of its own and no `cancel-in-progress`, as this
repository's CI does (#1706):

```yaml
concurrency:
  group: >-
    ci-caller-${{ github.workflow_ref }}-${{ github.event_name }}-${{
    github.event_name == 'pull_request' && github.run_attempt == '1'
    && github.event.pull_request.number || github.run_id }}-${{
    github.event_name == 'pull_request' && github.run_attempt == '1' && 'pr' || github.run_attempt }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' && github.run_attempt == '1' }}
```

A first attempt still cancels the previous commit's run. A re-run attempt
neither cancels nor shares a group, so it can replace no pending run either
(`cancel-in-progress: false` alone does not prevent that). The other
direction is not expressible: a later push cannot cancel a re-run attempt,
because cancelling needs a shared group, and in a shared group the re-run
could replace the newer run while that run is pending. Details:
[Caller concurrency](workflows/testing.md#caller-concurrency).

#### Irreversible steps are never re-run (#967)

`gh run rerun --failed` re-runs every failed job of the run, and a job that
published or promoted cannot be undone by a second attempt. Two guards run
before any log is read:

- `protected-workflows` (default empty): newline- or comma-separated workflow
  files (basename or `.github/workflows/...` path) or display names. A run of a
  listed workflow is never re-run, whatever its logs say.
- `protected-job-pattern` (default `publish|promote|release|upload`):
  case-insensitive extended regex over failed job names. One match protects the
  whole run, because a `--failed` re-run cannot exclude jobs; the summary names
  the eligible jobs left un-run. An empty pattern disables the guard.

Both guards fail closed: when the run's workflow or its failed jobs cannot be
read, the reusable reports _inconclusive_ and re-runs nothing. Consumers that
watch a publish workflow should list it in `protected-workflows`; the job
pattern is the backstop for workflows that were not listed.

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
reports _inconclusive: logs unavailable_ and exits successfully — deliberately
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
re-runs. When the bounds are exhausted the job reports _timed out reading logs_
— a fourth outcome, deliberately distinct from _inconclusive: logs unavailable_
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
      checks: read # check-run annotations, for the runner-acquisition signature
      contents: read
    with:
      tooling-ref: "<sha>" # vX.Y.Z
      run-id: ${{ format('{0}', github.event.workflow_run.id) }}
      run-attempt: ${{ format('{0}', github.event.workflow_run.run_attempt) }}
      max-reruns: "3"
      # Never re-run the publish pipeline: its jobs have irreversible steps.
      protected-workflows: publish-python-release.yml
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

**Explicit-manifest version PR** (version-pr with a file→kind map; see
[Release](#release)). The former `reusable-release-multi-ecosystem.yml` was
removed in v0.100.0 (#1356); its callers switch to this call, see
[migration/v0.100.md](migration/v0.100.md):

```yaml
jobs:
  version-pr:
    # yamllint disable-line rule:line-length
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
      actions: read
      issues: write
    with:
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

### npm package set (ordered, idempotent, verified)

`reusable-publish-npm-set.yml` publishes a **set** of npm packages under npm
trusted publishing (OIDC): platform packages first, meta package last, so
consumers never resolve a meta-package whose optional dependencies are
missing. It ports the audited py-lintro publish loop, including the
read-before-write dist-tag reconcile (#2631 semantics): a live re-run skips
already-published packages, reconciles their dist-tag without writing when
the registry already matches, and records (rather than aborts on) OIDC
dist-tag drift so the remaining packages still publish before the run goes
red.

The step order is the contract, asserted by the wiring test:

1. **Verify artifacts** (when `checksums-file` is set): every file
   `npm pack --dry-run` would ship, plus `files-to-verify`, gets sha256 against
   the manifest plus
   `gh attestation verify --repo <signer-repo> --signer-workflow <signer-workflow>`
   — before the real `npm pack`. A packed file the manifest does not list fails.
   The release security policy forbids publishing unverified artifacts.
2. **Publish package set**: the only step that writes to the registry.
   Bounded exponential backoff on transient Sigstore/5xx/429 errors only;
   `EPUBLISHCONFLICT` is an idempotent success; auth failures never retry.
3. **Verify published** (read-only, last): waits for the whole set to
   propagate on one shared clock, polling every package with exponential
   backoff (`propagation-attempts` × up to `propagation-delay` seconds,
   default 30 × 30 s, about fifteen minutes; platform packages routinely lag by
   one to six minutes) until each is visible, carries `dist.integrity` (and
   `dist.attestations` when `provenance` is on), and `dist-tags.<dist-tag>`
   points at the published version, logging when each appeared; only then
   `npm audit signatures` in a scratch install of the meta package and the
   optional `smoke-command` in that install. `post-publish-verify: false`
   skips this step; not recommended for live releases.

```yaml
jobs:
  npm-set:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-npm-set.yml@<sha>
    permissions:
      contents: read
      id-token: write
      attestations: write
    with:
      packages-dir: npm-dist
      artifact-name: npm-dist # upload-artifact name from the staging job
      order: '["darwin-arm64", "linux-x64", "meta"]' # meta last
      dry-run: false
      entry-workflows: .github/workflows/publish-npm-set.yml
      checksums-file: npm-dist/SHA256SUMS # workspace-relative; entries are packages-dir-relative
      files-to-verify: '["*/package.json", "*/bin/*"]'
      signer-repo: <owner>/<repo>
      signer-workflow: .github/workflows/build-binaries.yml
      environment: npm # optional: approval gate on the publish job
```

npm trusted publishing validates the **entry** workflow file of the run —
your top-level workflow, not this reusable — so the consumer's
trusted-publisher registration stays valid when it calls this reusable.
Name that entry file via `entry-workflows` so the built-in guard enforces
the binding before any publish. A live publish (`dry-run: false`) fails
closed before anything is downloaded or packed unless `entry-workflows`,
`checksums-file`, `signer-repo` and `signer-workflow` are set, the
runner is GitHub-hosted, and `access` is `public` while `provenance` or
`post-publish-verify` is on (npm provenance and unauthenticated post-publish
reads need a public package); dry-runs stay permissive. Dry-run packages are
reported with `status: dry-run`, never `published`. A `uses:` job cannot
declare `environment`, so pass the deployment environment through the
`environment` input: the reusable's publish job is bound to it (approval
gate, and the environment claim in the OIDC token, so a trusted publisher
registered with that environment name keeps matching). Empty (the default)
runs without an environment, in which case register the trusted publisher
without an environment name. No npm token: OIDC only. Workflow artifacts
drop file modes, so the publish step restores `+x` on `bin/*` and on
package.json `bin` targets before `npm pack` records the modes.
`setup-node` writes a placeholder `_authToken`; the publish script strips
it. Do not self-upgrade npm in-place. Full example:
[examples/publish-npm-set.yml](../examples/publish-npm-set.yml).

A single package is a set of one: pass the package directory as
`packages-dir` with `order: "."`. The single-package wrapper
`reusable-publish-npm.yml` was removed in v0.97.0 (#1526); see
[migration/v0.97.md](migration/v0.97.md) for the input and output mapping.

Configure an npm trusted publisher for the **caller** workflow filename and
allow the `npm publish` action. Use Node 24 (default); never
`npm install -g npm`. Full recipe:
[workflows/publishing.md](workflows/publishing.md#reusable-publish-npm-setyml).

The snippet below is abbreviated: it shows 2 of the 140 GitHub results
storage hosts. Copy the full list from
[`examples/publish-python-release.yml`](../examples/publish-python-release.yml)
or the list under [PyPI upload (OIDC + attestation)](workflow-contract.md#pypi-upload-oidc--attestation);
both are tested against `egress_github_results_storage_endpoints` in
`scripts/ci/lib/egress/presets.sh`.

```yaml
jobs:
  pypi-build:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-build-python-dist.yml@<sha>
    permissions:
      contents: read
      id-token: write # attestation of dist/*
      attestations: write
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
        uses: step-security/harden-runner@<pin> # v2.22.1
        with:
          egress-policy: block
          # workflow-contract.md § PyPI upload (OIDC)
          allowed-endpoints: >
            github.com:443
            api.github.com:443
            codeload.github.com:443
            objects.githubusercontent.com:443
            pipelines.actions.githubusercontent.com:443
            productionresultssa0.blob.core.windows.net:443
            productionresultssa1.blob.core.windows.net:443
            ghcr.io:443
            pkg-containers.githubusercontent.com:443
            pypi.org:443
            upload.pypi.org:443
            files.pythonhosted.org:443
            tmaproduction.blob.core.windows.net:443
            releases.astral.sh:443
            release-assets.githubusercontent.com:443
            raw.githubusercontent.com:443
            fulcio.sigstore.dev:443
            rekor.sigstore.dev:443
            tuf-repo-cdn.sigstore.dev:443
            oauth2.sigstore.dev:443
      - name: Prepare PyPI upload
        id: prepare
        uses: lgtm-hq/lgtm-ci/.github/actions/prepare-pypi-upload@<sha> # vX.Y.Z
        with:
          artifact-name: python-dist
          require-attestation: "true"
      - name: Upload to PyPI
        uses: pypa/gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b # v1.14.0
        with:
          repository-url: https://upload.pypi.org/legacy/
          packages-dir: ${{ steps.prepare.outputs.dist-path }}

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

| Input                   | Type    | Required | Default                    | Purpose                                                     |
| ----------------------- | ------- | -------- | -------------------------- | ----------------------------------------------------------- |
| `artifact-name`         | string  | yes      | —                          | Name shown in the "⬇ Download …" link text                  |
| `artifact-url`          | string  | yes      | —                          | `upload-artifact` v4 `artifact-url` output (empty degrades) |
| `marker`                | string  | yes      | —                          | Sticky-comment upsert identity                              |
| `summary`               | string  | no       | `""`                       | Inline markdown prepended to the comment                    |
| `summary-file`          | string  | no       | `""`                       | Markdown file (wins over `summary` when non-empty)          |
| `title`                 | string  | no       | `artifact-name`            | Comment heading                                             |
| `upstream-result`       | string  | no       | `""`                       | `success`/`failure`/`cancelled`/`skipped` status line       |
| `job-name`              | string  | no       | `Publish artifact preview` | Job display name                                            |
| `comment-history`       | boolean | no       | `false`                    | Keep earlier runs in a "Previous runs" archive (#1346)      |
| `comment-history-limit` | number  | no       | `3`                        | Earlier runs kept (`0` = unlimited within the size budget)  |

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
      # Optional: the default build-artifact preset already covers rustup and
      # crates.io. A leg that builds with `cross` also pulls the cross images
      # (ghcr.io and Docker Hub) and musl-tools (Ubuntu archive); append those
      # hosts. Without allowed-endpoints-mode: append, a non-empty list
      # replaces the preset instead of extending it.
      allowed-endpoints-mode: append
      allowed-endpoints: >-
        ghcr.io:443 pkg-containers.githubusercontent.com:443
        docker.io:443 registry-1.docker.io:443 auth.docker.io:443
        production.cloudflare.docker.com:443 production.cloudfront.docker.com:443
        docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443
        archive.ubuntu.com:80 archive.ubuntu.com:443 azure.archive.ubuntu.com:80
        security.ubuntu.com:80 security.ubuntu.com:443
```

`reusable-build-artifact.yml` accepts only its default `egress-preset`
(`build-artifact`); any other name, such as `rust-release`, fails the
unknown-preset guard (#1623). The list above is the part of the `rust-release`
preset that `cross` uses and `build-artifact` lacks, host for host, from
`egress_preset_own_endpoints` in `scripts/ci/lib/egress/presets.sh`. Every
host is exact: the Docker Hub blob redirect is named, not covered by an
`*.amazonaws.com` wildcard. `rust-release` also carries hosts this example does
not need: `aka.ms:443` and `download.visualstudio.microsoft.com:443`, where
`cargo-xwin` fetches the Windows SDK for an MSVC target built on Linux, and the
Sigstore hosts `fulcio.sigstore.dev:443`, `rekor.sigstore.dev:443`,
`timestamp.sigstore.dev:443` and `tuf-repo-cdn.sigstore.dev:443` for build
attestation. Append
those only when a build does the same.

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

| Input                     | Type   | Required | Default | Notes                                                 |
| ------------------------- | ------ | -------- | ------- | ----------------------------------------------------- |
| `build-command`           | string | yes      | —       | Shell build command                                   |
| `artifact-name`           | string | yes      | —       | Upload name; matrix appends the leg's values          |
| `artifact-path`           | string | yes      | —       | Relative to `working-directory`                       |
| `toolchain`               | string | no       | `node`  | `node` \| `rust` \| `python` \| `none`                |
| `toolchain-version`       | string | no       | `""`    | Toolchain version; alias of `node-version` for `node` |
| `matrix`                  | string | no       | `""`    | JSON array of objects (or `{"include": [...]}`)       |
| `runner-map`              | string | no       | `{}`    | Matrix value → runner label; unmapped falls back      |
| `runner-map-key`          | string | no       | `""`    | Lookup field; auto when entries have one field        |
| `node-version`            | string | xor      | `""`    | Single version; not with `matrix`                     |
| `node-version-matrix`     | string | xor      | `""`    | **Deprecated** — use `matrix`; warns when set         |
| `post-build-test-command` | string | no       | `""`    | Optional post-build test                              |
| `retention-days`          | number | no       | `7`     | Artifact retention                                    |
| `working-directory`       | string | no       | `.`     | Build cwd                                             |
| `job-name`                | string | no       | `Build` | Static inner name; GitHub adds matrix leg             |

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
      actions: read
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
      actions: read
      contents: read
      security-events: write
      # Declared by the push/sign/attest jobs this call never runs; reusable
      # permission requests are validated statically, before `if:`.
      packages: write
      id-token: write
      attestations: write
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
      actions: read
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
      actions: read
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
      actions: read
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

On GitHub-hosted Linux, Docker setup gives harden-runner's
`/home/agent/agent.status` 60 seconds to report exactly `Initialized`, then checks
Docker once with a 10-second deadline. Setup verifies GNU coreutils, preferring
`gnutimeout` over `timeout`, and fails before service or Docker checks if neither
is GNU. Both deadlines use that same verified binary: TERM at the deadline, then
KILL after a 2-second grace period. The service/status phase
can therefore take up to 62 seconds and the Docker check up to 12 seconds (74
seconds combined, plus scheduling overhead). Timeout exits 124 and 137 both
produce setup failure exit 1. Forced termination covers signal-ignoring
processes in the monitored group; Linux tasks stuck in uninterruptible kernel
sleep cannot be guaranteed to terminate within that bound.

On GitHub-hosted Linux, the readiness helper is checked out separately from the
workflow's own immutable
`job.workflow_repository` and `job.workflow_sha`, even when `tooling-ref` selects
older scripts. This checkout includes only the helper, disables credential
persistence, and uses `.lgtm-ci-readiness`; normal tooling and app-source overrides
remain independent. Hosted Linux fails closed if the workflow repository or full
commit SHA is unavailable. The identity guard, helper checkout and barrier all run
only on GitHub-hosted Linux. Other platforms and self-hosted runners skip these
three readiness steps and continue normal Docker setup without requiring the
helper or workflow identity. GHES callers can continue to supply an explicit
`tooling-ref` as described in the [workflow contract](workflow-contract.md).

The hardener can continue initialization after its own initial wait times out,
including a Docker restart. A responsive Docker
socket before that restart does not establish readiness. A stopped agent,
unexpected status, timeout or unavailable Docker fails setup before QEMU or
Buildx starts. Other platforms and host-managed self-hosted agents retain their
existing setup path.

Hosted Linux setup fails closed even when harden-runner deliberately skips agent
installation or cannot install it. This includes container jobs, `ubuntu-slim`,
the `skip-harden-runner` custom property, custom VM images, and StepSecurity API
unavailability, download or checksum failures. An already installed agent must
still satisfy the same service and status checks. This applies in both audit and
block mode; a StepSecurity outage can therefore fail Docker setup.

The completion signal is verified against the pinned OSS agent v0.18.0. Owners
with TLS enabled receive agent-ebpf v1.9.5; its status protocol has not been
verified here. A missing or inactive `agent.service`, an unexpected status or a
missing completion signal fails closed rather than bypassing the barrier.

This barrier addresses the startup overlap in #1269. A registry download timeout
or blocked endpoint remains a separate failure requiring its own evidence and
policy review; readiness does not change egress enforcement or allowlists.

`runner-map` defaults to `{}`. Unmapped split platforms use the fixed
`ubuntu-26.04` standard (QEMU for non-amd64), independently of `LGTM_CI_RUNNER`.
Explicit mappings and single-platform selection are unchanged. Upgrades
across #1241 rename fallback-derived matrix checks; see the
[rename notice](workflow-contract.md#docker-runner-fallback-rename-1241).

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
applied per blob so an already-signed artifact is never re-signed. When the
in-step retry gives up, the line it prints, ending the step, is a built-in
signature of
[`reusable-auto-rerun-on-infra-failure.yml`](#auto-re-run-on-infra-failure), so a
flake that outlives the in-step retry still gets the failed jobs re-run. The
markers on their own, anywhere else in a log, are not (#1706).

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

| Input                   | Default                    | Description                                                         |
| ----------------------- | -------------------------- | ------------------------------------------------------------------- |
| `mode`                  | `report`                   | `report` or `release-assets`                                        |
| `formats`               | `spdx-json,cyclonedx-json` | Syft formats for `release-assets` mode                              |
| `sign`                  | `true`                     | Cosign keyless sign in `release-assets` mode                        |
| `release-tag`           | `""`                       | Required when `mode: release-assets`                                |
| `scan-vulnerabilities`  | `true`                     | Run Grype against the generated SBOM (report)                       |
| `fail-on-severity`      | `"critical"`               | Fail when findings meet this severity or higher                     |
| `upload-sarif`          | `false`                    | Upload Grype SARIF to GitHub Security                               |
| `create-attestation`    | `false`                    | Create a Sigstore attestation for the SBOM                          |
| `upload-release-assets` | `false`                    | DEPRECATED and inert (#770); use `reusable-sbom-release-upload.yml` |
| `egress-preset`         | `sbom`                     | Harden-runner allowlist preset (workflow-contract)                  |

<!-- markdownlint-enable MD013 -->

**Breaking (#480):** `fail-on-severity` previously defaulted to `""` (advisory
only). Callers that must keep advisory-only behavior should pass
`fail-on-severity: ""` or `none`.

```yaml
sbom:
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-sbom.yml@<sha>
  permissions:
    actions: read
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
    actions: read
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

| Input                  | Default             | Notes                              |
| ---------------------- | ------------------- | ---------------------------------- |
| `post-failure-comment` | `true`              | Opt out for check-only workflows   |
| `comment-marker`       | `semantic-pr-title` | Upsert marker for failure comments |
| `max-length`           | `0` (no limit)      | Optional title length cap          |
| `require-scope`        | `false`             | Passed through to amannn           |
| `types` / `scopes`     | built-in defaults   | Override only when needed          |

Callers must grant `pull-requests: write` when `post-failure-comment` is enabled
(the default). With `post-failure-comment: false`, `pull-requests: read` is
sufficient. Workflow root `permissions: {}` otherwise strips PR access from the
reusable job.

Avoid a per-PR `concurrency` group on the caller. A bot that pushes and then
edits the PR body fires `synchronize` and `edited` back to back. With
`cancel-in-progress: true` the second run cancels the first, which leaves a
cancelled check on the head commit; `cancel-in-progress: false` still cancels a
superseded pending run. Without a group, runs can overlap. The semantic check
reads the current title from the API, so a run that starts after a title fix
passes. A run that already failed on the older title can still finish last.
Its failed check run stays on that head commit, because later runs add check
runs rather than replace them; only a new head commit starts a clean set. The
next successful run deletes the failure comments it finds, but it lists only
the first page of PR comments. The `max-length` check reads the title from the
event payload, so an overlapping run for an older title can also report a
stale length failure.

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

| Input                     | Default                 | Notes                                     |
| ------------------------- | ----------------------- | ----------------------------------------- |
| `lintro-image`            | pinned py-lintro        | Override when adopting a newer lintro pin |
| `audit-script`            | tooling default         | Rarely needed — override for custom scans |
| `upload-comment-artifact` | `true`                  | Set `false` for push/schedule check-only  |
| `comment-marker`          | `security-audit-report` | Used by publish reusable                  |

```yaml
"on":
  pull_request:
  merge_group:
    types: [checks_requested]
  push:
    branches: [main]
  schedule:
    - cron: "30 5 * * 1"

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

`reusable-publish-security-audit-comment.yml` also accepts `comment-history`
and `comment-history-limit` (see
[PR comment run history](#pr-comment-run-history-comment-history-1346)).

### PR file breakdown comment

`reusable-publish-file-breakdown.yml` fetches the PR changed-files payload via
`gh api --paginate`, renders a grouped breakdown (files/additions/deletions per
top-level directory) with a capped collapsible per-file table, and upserts it as
a marker-based PR comment. All steps skip when no PR number can be detected;
fork PRs skip the comment post.

| Input                   | Default                  | Notes                                   |
| ----------------------- | ------------------------ | --------------------------------------- |
| `comment-marker`        | `file-breakdown`         | Upsert marker for the PR comment        |
| `max-rows`              | `50`                     | Per-file rows shown (capped at 500)     |
| `job-name`              | `Publish file breakdown` | Display name                            |
| `egress-preset`         | `github-minimal`         | GitHub API + tooling checkout           |
| `comment-history`       | `false`                  | Keep earlier runs in an archive (#1346) |
| `comment-history-limit` | `3`                      | Earlier runs kept (`0` = unlimited)     |

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

**Trust model.** Use `pull_request` with the same-repo guard below. Forks skip.
The pinned published reviewer and tooling are trusted; the PR checkout is data.
Installation runs without provider credentials. The invocation runs from a clean
working directory and owner-only home: PR lintro settings, dotenv, CLI settings,
hooks, helpers, PATH entries and ambient runner sessions cannot execute or redirect
requests in credential scope. Only resolved provider/transport, model and cost-cap
scalars cross from the reviewed config; custom agents and other repo settings do
not. This is distinct from py-lintro's `pull_request_target` trusted-base workflow.

**Selection.** Provider and transport keep input → Actions variable → repo config
precedence, with no default. `auth` resolves input → `LINTRO_AI_AUTH` Actions
variable → the static tuple default below. There is no product `ai.auth` key and
secret presence never chooses authentication. Both Anthropic and OpenAI CLI
**default to OAuth subscription sessions**. In particular, OpenAI CLI does not
fall back to metered `CODEX_API_KEY` billing when a session is missing or expired.
API transports and Cursor CLI default to `api_key`. Unsupported/empty tuples fail
before provider invocation, listing supported choices. Selection outputs and the
job summary name requested/resolved tuples, auth/model sources and credential
purpose (`review`); these are selected policy, not observed billing or model facts.
Lintro 0.173.1+ supplies its existing credential/endpoint/model/cost provenance.

**Caller contract.** Keep the compatible generic reusable **slot** names. Map
metered slots from dedicated **review source secrets**, never the generic
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` GitHub secrets used by smoke tests. The
SDK/CLI's generic **environment variable** name is a separate layer. Provisioning
review sources in the consumer or a scoped org secret is an operator gate: a
py-lintro repository secret is not inherited by lgtm-ci or Podex. Missing sources
are hard failures, with no smoke-key fallback.

```yaml
"on":
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
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_REVIEW_API_KEY }}
      OPENAI_API_KEY: ${{ secrets.OPENAI_REVIEW_API_KEY }}
      CODEX_API_KEY: ${{ secrets.OPENAI_REVIEW_API_KEY }}
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      CODEX_AUTH_JSON: ${{ secrets.CODEX_AUTH_JSON }}
      LINTRO_REVIEW_APP_ID: ${{ secrets.LINTRO_REVIEW_APP_ID }}
      LINTRO_REVIEW_APP_PRIVATE_KEY: ${{ secrets.LINTRO_REVIEW_APP_PRIVATE_KEY }}
      CURSOR_API_KEY: ${{ secrets.CURSOR_API_KEY }}
    with:
      # Match the workflow release pin when a tooling override is needed.
      tooling-ref: "<sha>"
      # provider/transport/model/max-cost-usd: input → Actions var → repo config
      # auth: input → LINTRO_AI_AUTH → static default (no repo ai.auth key)
```

Exactly one selected provider credential reaches the invocation, gated by literal
expressions on the full `(provider, transport, auth)` tuple. OAuth has a separate
invocation step with no API-key env slots, so `CODEX_API_KEY` is absent entirely.
Even its presence with an empty value under OAuth is refused. Competing effective
credentials and whitespace/missing credentials fail before invocation.

`secrets: inherit` remains compatible **only for OAuth-only callers** that pin or
verify an OAuth tuple. Only that tuple's OAuth slot is injected; inherited API keys
remain outside the invocation. API-key callers must use explicit source remapping;
inherit cannot express this contract. A called workflow cannot inspect an encrypted
value's original secret name: caller review and the known-consumer scan enforce
source policy, not a runtime provenance claim.

The known-consumer scan resolves each selector component (`provider`, `transport`,
`auth`) to either `KNOWN(value, source)` or `UNKNOWN`. Only a nonempty literal
workflow input or a readable Actions variable that is set establishes `KNOWN`.
Empty literals, dynamic expressions, readable-but-unset variables, unreadable
variables, and lookup errors leave the component `UNKNOWN`; repository lintro
config and matrix defaults do not establish a known selection. The scan filters
possible tuples using only known components. If any component is unknown, it
accepts a forwarded credential slot for any compatible tuple and emits an
informational "auth selection unverified" note listing those tuples. Forwarding
no compatible credential still fails. An exact missing-slot finding requires all
three components known; a fully known unsupported tuple also fails. API-key source
mappings are checked independently; dynamic source expressions remain unverified.

<!-- markdownlint-disable MD013 -- generated capability table -->

<!-- prettier-ignore-start -->
<!-- ai-review-capabilities:begin -->
| Provider | Transport | Auth | Default | Secret slot / child binding | CLI |
| --- | --- | --- | --- | --- | --- |
| anthropic | api | api_key | yes | `ANTHROPIC_API_KEY` | — |
| anthropic | cli | oauth | yes | `CLAUDE_CODE_OAUTH_TOKEN` + `LINTRO_CLI_BARE=never` | claude |
| anthropic | cli | api_key | — | `ANTHROPIC_API_KEY` + `LINTRO_CLI_BARE=always` | claude |
| cursor | cli | api_key | yes | `CURSOR_API_KEY` | agent |
| openai | api | api_key | yes | `OPENAI_API_KEY` | — |
| openai | cli | oauth | yes | `CODEX_AUTH_JSON` → isolated `CODEX_HOME/auth.json` | codex |
| openai | cli | api_key | — | `CODEX_API_KEY` | codex |
<!-- ai-review-capabilities:end -->
<!-- prettier-ignore-end -->

<!-- markdownlint-enable MD013 -->

The auth selector pins Anthropic CLI `LINTRO_CLI_BARE=never` for OAuth and `always`
for API-key auth. This overrides conflicting repo `cli_bare` settings; a conflicting
final environment policy refuses execution. Config files and cached credentials
are isolated for every tuple, including API-key CLI.

**Codex session operations.** On a trusted workstation, use `codex login` with
file-based credential storage and provision the base64 of its complete `auth.json`
as `CODEX_AUTH_JSON` through your normal secret manager. Never paste session data
into logs or issues. The workflow validates base64, size, JSON and nonempty OAuth
tokens, and rejects an API-key login object. It exclusively creates
`$HOME/.lgtm-ci-review-<run>-<attempt>-<job>/codex/auth.json` with directory mode
0700/file mode 0600. This avoids temporary CODEX_HOME bootstrap limitations of the
pinned Codex version and never overwrites `$HOME/.codex`. It sets file-only auth
storage and the selected login method. No container is used; container consumers
must mount this same isolated directory as `CODEX_HOME`, not an ambient home.

The review is bounded by GNU timeout. Cancellation forwards signals to the child
process group and reaps it before deleting the session; `finally` cleanup and a
separate `always()` step remove owned material on success, failure, timeout and
ordinary cancellation. Pre-existing paths/symlinks refuse creation or cleanup.
Abrupt runner loss/SIGKILL can prevent cleanup: discard hosted runners; on a
self-hosted runner, an operator removes the abandoned owned directory before reuse.
Session material is never cached, uploaded or written back to secrets.

Choose and record one authoritative consumer/org `CODEX_AUTH_JSON` source before
adoption. A base64 snapshot does not update when the disposable CLI refreshes its
copy. Concurrent jobs may race to refresh the same snapshot; serialize affected
reviews or provision separately managed sessions if refresh rotation invalidates
siblings. Missing/expired/revoked sessions require operator renewal of the
authoritative secret and a new completed review. A restored file, login-status
check or API health smoke does not prove the subscription review succeeded.

`LINTRO_REVIEW_APP_ID` / `LINTRO_REVIEW_APP_PRIVATE_KEY` are org-wide (all-repo)
and mint the posting token. That token is in scope **only** for the review
invocation or credential-free size-notice step (`GITHUB_TOKEN`); `GH_TOKEN`
stays the workflow token for fetching the
diff. The GitHub App **installation** must grant `issues: write` and
`pull-requests: write` — those are App permissions, not the caller's
`pull-requests: read` job grant. Token minting fails if the installation
lacks them.

`provider` / `transport` inputs and `LINTRO_AI_PROVIDER` /
`LINTRO_AI_TRANSPORT` and `LINTRO_AI_AUTH` variables must be lowercase. Harden-runner compares
the raw values and cannot fold case.

<!-- markdownlint-disable MD013 -- wide input reference table -->

| Input             | Default     | Notes                                                                                                                                                                                                            |
| ----------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `provider`        | `""`        | Overlay → `LINTRO_AI_PROVIDER`. No default.                                                                                                                                                                      |
| `transport`       | `""`        | Overlay → `LINTRO_AI_TRANSPORT`. No default.                                                                                                                                                                     |
| `auth`            | `""`        | Input → `LINTRO_AI_AUTH` → tuple default; `oauth` or `api_key`.                                                                                                                                                  |
| `lintro-version`  | `""`        | Empty resolves `DEFAULT_LINTRO_VERSION` from `scripts/ci/versions.env` (Renovate-managed, #1096). Floor = 0.173.1 for isolated auth and provenance.                                                              |
| `python-version`  | `3.12`      | Scratch venv for the pinned lintro install.                                                                                                                                                                      |
| `model`           | `""`        | Overlay → `LINTRO_AI_MODEL` (input → `vars.LINTRO_AI_MODEL`).                                                                                                                                                    |
| `max-cost-usd`    | `""`        | Overlay → `LINTRO_AI_MAX_COST_USD` (input → `vars.LINTRO_AI_MAX_COST_USD`).                                                                                                                                      |
| `blocking`        | `false`     | When true, exit 2 (no review), a timed-out review, a size-skipped review (see `max-diff-lines`), or a changes-requested verdict fails the job. INCOMPLETE coverage-at-HEAD always reddens.                       |
| `max-diff-lines`  | `0`         | Skip the review (PR comment; neutral unless `blocking`) when additions+deletions exceed this; `0` disables. `2000` is a sensible start: ~1,900-line diffs did not finish in 30 min on `anthropic`/`cli` (#1097). |
| `egress-preset`   | `ai-review` | GitHub + PyPI/uv only. Provider hosts are appended from the visible pair.                                                                                                                                        |
| `timeout-minutes` | `30`        | Job cap; the review call is bounded to what remains of it (from preflight) minus 4 min. Raise for long CLI reviews.                                                                                              |
| `job-name`        | `AI Review` | Check name.                                                                                                                                                                                                      |

<!-- markdownlint-enable MD013 -->

**Hardening guarantees:**

- **Trusted install.** Pinned lintro from PyPI only. The job never installs or
  executes the PR's own code, so inference credentials and the App token are
  scoped to one mutually exclusive review invocation step.
- **Same-repo / fork skip.** Fork PRs skip (exit 0) because they cannot read
  org secrets. Put the same-repo `if:` on the caller as well.
- **Exit-code contract.** lintro exit `2` is "no review produced" (error
  envelope on stdout), not a crash. Exit `1` is a produced review with P1 /
  changes-requested. Default `blocking: false` keeps those outcomes
  non-blocking. **INCOMPLETE** coverage-at-HEAD and reported authentication failures always
  redden the check. Expired/revoked sessions require renewal; no billing fallback
  is attempted.
- **Timed-out is neutral.** The review call runs under GNU `timeout` with
  a budget of whatever remains of `timeout-minutes` — measured from the
  preflight step, so the CLI and lintro installs are already counted —
  minus a 4-minute margin. The margin absorbs the harden-runner and
  checkout steps that run before preflight (~15 s on the evidence run)
  plus everything after the bound fires: kill escalation, the notices,
  and the artifact upload (~110 s worst case). When the bound ends the
  review (GNU `timeout -v`'s "sending signal" diagnostic is the evidence;
  a 124/137 that lintro produced on its own stays `broken`) the step logs
  a `::warning`, adds a step-summary line, posts a "did not complete" PR
  comment as the bot (best effort: it updates its own earlier comment when
  the bounded lookup finds one, and the comment stays once a later round
  completes), and exits `0`
  (`outcome=timed-out`; fails only with `blocking: true`). If under 60 s
  remain the same outcome is recorded without running the model. The job
  cap is never what ends the review — a job cancelled at its cap records a
  failed check and flips the PR to `UNSTABLE`, which blocks
  `lgtm-ai gh pr merge` (#1098). Real errors (missing App secrets, resolve
  failures, unexpected exit codes including a 124/137 that lintro produced
  on its own, INCOMPLETE) still fail. A review killed by the bound may not
  persist resume state for the next round.
- **Per-PR concurrency.** The reusable cancels in-progress runs for the same
  consuming-repo PR so overlapping pushes do not race on state artifacts.
- **Review resume.** `actions: read` on the caller job lets the reusable
  locate the newest completed trusted run that uploaded
  `lintro-review-state-pr-<N>-*` (conclusion irrelevant) and download it
  onto the consuming repo's next run. The final upload sets `overwrite: true`
  so a same-attempt retry does not 409. The App token is minted immediately
  before the review step. No wildcard over `blob.core.windows.net`.
- **Egress.** The `ai-review` preset has no provider hosts. Extra hosts come
  from the full `(provider, transport, auth)` tuple visible at harden time (input or
  `LINTRO_AI_*` variable). Repo-config-only resolution cannot expand that list
  before harden-runner, so under the default `egress-policy: block` the
  resolve step **fails the job with guidance** when the provider comes only
  from the repo config — set the input or the variable so the matching hosts
  are allowlisted (audit mode is not accepted, #1203). A rotated Cursor
  shard appears in the failed run's harden-runner summary; add it to
  `ai_review_matrix.sh`, then regenerate workflow blocks with
  `scripts/ci/workflows/sync_ai_review_matrix.py`. No wildcards.

**The sticky comment.** `lintro review --post` owns the `<!-- lintro-ai-review -->`
marker, in-place updates, and telemetry. Author is `lintro-review[bot]`.

**Rollout.** The local pilot uses explicit review-source mappings. Review and release
this workflow through the normal process, then adopt it through separate consumer
PRs. Podex is the named adoption proof: update both workflow/tooling SHA pins,
verify actual selected-secret availability and obtain a completed posted review.
This implementation changes no variables, secrets, external pins or release gates.
Live canaries require provisioned credentials and operator approval; offline tests
alone do not prove live OAuth refresh, billing, endpoint or posted-review behavior.
See [the migration guide](migration/v0.79.md).

### Vulnerability suppression check (osv-scanner)

`reusable-vuln-suppression-check.yml` installs `osv-scanner` directly (no Docker),
probes the repository without suppressions, and opens a cleanup PR removing
suppressions that are stale (vulnerability resolved upstream). Expired entries
(past `ignoreUntil`) are left untouched and flagged for manual review, failing
the job so a human re-evaluates each one. The probe sets
`ScanGoModVersion = true` so osv-scanner 2.4.0 and later still find Go
toolchain advisories from `go.mod`. Older releases reject that key as unknown,
so on that error the probe runs again with an empty config.

**Which suppressions count as stale.** A suppression is removed only when the
check reads every part of it exactly as the pinned osv-scanner (2.7.1) does,
it is not expired, and the probe scan reported no problem the check recognises
as incompleteness. Anything else is left alone and reported. What that does
and does not guarantee is spelled out under _What the job guarantees_ below.

- _Understood entries._ An `[[IgnoredVulns]]` entry is understood when its keys
  are only `id` and `reason` (strings) and `ignoreUntil` and `effectiveUntil`
  (a TOML date or date-time), spelled exactly so, and its `id` is a non-empty
  string without surrounding whitespace or characters that are not printable.
  osv-scanner matches key names regardless of case (Unicode case folding, so
  `ſ` counts as `s`) and refuses unknown keys, so
  an entry with any other key, a key spelled with other case (`ID`,
  `IgnoreUntil`), a value of another type, or a bare time is "not understood".
  Such an entry is never stale, and neither is any ID it might carry or that ID
  without whitespace and invisible characters. A top-level table spelled
  `IgnoredVulns` in other case holds back every ID. Entries left alone are
  listed in the job log and under their own heading in the job summary; they do
  not fail the job, because osv-scanner may read them fine.
- _Timebox._ `effectiveUntil` is used when set, otherwise `ignoreUntil`, as in
  osv-scanner. The entry stops at that instant: a date means midnight at its
  start and a date-time without an offset means that time, both read the way
  osv-scanner does (the runner's UTC offset at the moment of the check) and
  also in the runner's time zone, and the earliest of these readings is used,
  so a local time the zone repeats or skips around a daylight-saving change can
  only make an entry expire sooner; a date-time with an offset is exact. The
  job reads the clock once, and every step decides expiry at that one instant.
  An entry past its timebox is expired: flagged in the job summary, never
  removed, and the job fails. An ID that either step found expired, or could
  not fully read, is never removed; if one step found it expired and the other
  stale, the job fails and nothing is removed. An ID listed more than once is
  reported once, as expired if any copy has expired. **Behaviour change:**
  an entry with a date-only timebox is now
  reported expired on its listed date; it used to count as active that day.
  That date is when osv-scanner stops honouring it (`time.After` against
  midnight at the start of the date). A timebox in year `0000` cannot be read
  by Python's TOML parser, so no entry of that file can be read: the job fails
  with one `ERROR:` line and nothing is removed.
- _Scan checks._ The probe runs as
  `osv-scanner scan --recursive --format json --no-call-analysis=all --config
<file> .`. Call analysis is off because classification only needs the
  vulnerabilities: every listed one counts as present, and without analysis
  osv-scanner counts each as called, so the result does not change. Nothing is
  removed, and the job fails, when any of these holds:
  - a path at or under the repository root (the root as an absolute path
    included) holds a control character or is not valid UTF-8; this is
    checked before the scan, because osv-scanner prints paths raw;
  - osv-scanner fails (an exit status above 1);
  - the exit status is not the one the output implies (1 when a vulnerability
    is called and not unimportant, otherwise 0);
  - osv-scanner printed a stderr line that is not one of these, each judged on
    its own line: `Scanning dir .`,
    `Scanned <file> file and found <N> package(s)`,
    `Filtered <N> local/unscannable package/s from the scan.`,
    `Starting filesystem walk for root: <path>`, the walk's `End status: ...`
    and `Status: ...` progress lines, the transitive Maven resolver's "may be
    risky" notice, and its "default Maven registry is being overwritten" note.
    Any other line fails the run, for example an extraction error, a file the
    scanner could not read, a failed dependency resolution, or
    `Skipping <package>: short commit hash ...` (a package with a known
    identity that was not looked up). The error quotes the line; if the line
    is harmless, report it so the list of known osv-scanner messages can be
    extended;
  - the probe JSON is not in the shape this command prints: a `results` array
    (a clean scan prints `"results": []`), each result with a non-empty
    `packages` array, each package with a `package` object and non-empty
    `vulnerabilities` and `groups` whose IDs match, every ID and alias a
    non-empty string, and no duplicate keys or `NaN`.

  The filtered line is expected and harmless. osv-scanner prints it for a
  package it has no version or identity to look up: an unpinned or ranged
  requirement, a Maven dependency whose version comes from a parent or BOM, a
  Go `replace` to a local directory, an npm `file:` dependency. Such a package
  is not looked up in the main audit either, so no suppression can be in
  effect for it.

  Expired and not-understood entries are read from the file alone, before the
  scan, so they are flagged (job log, job summary, and a failing job for an
  expired entry) even when the scan is refused.

  _What the job guarantees._ It removes nothing when the scan reported a
  problem it recognises as incompleteness (the conditions above), when an
  entry is not fully understood, or when an entry is expired.

  _What it cannot guarantee._ osv-scanner reads some things silently or not at
  all, and the job only sees what the scanner reports: a secondary file it
  cannot read or parse (for example `go.sum`, logged only at debug level), a
  manifest over the extractor's size limit (20 MiB), requirement lines given
  as a direct URL, as an editable or VCS reference, or through an environment
  variable, a local-file dependency that is extracted but not queried, files
  excluded by `.gitignore`, and symbolic links to files or directories. The
  main audit uses the same scanner and walk and has the same blind spots, so a
  suppression for a vulnerability in one of those places has no effect in the
  audit either, and the cleanup may propose removing it. The cleanup is a pull
  request, and its body asks the reviewer to check that the package behind
  each removed entry is really gone or fixed.

  _When the job turns red with nothing wrong in the file._ A transitive
  dependency that cannot be resolved (a private package, or one missing from
  the public index); a Maven project whose parent or BOM must be fetched from
  a host the `osv-scanner` egress preset does not allow (it allows the GitHub
  tooling hosts `github.com`, `api.github.com`, `codeload.github.com`,
  `objects.githubusercontent.com`, `raw.githubusercontent.com`,
  `release-assets.githubusercontent.com`, `uploads.github.com` and
  `pipelines.actions.githubusercontent.com`, plus `api.osv.dev` and
  `api.deps.dev`); a package pinned to a short commit hash; a path with a
  control character; and a new scanner message after an osv-scanner upgrade.
  The job stays red until the cause is gone or the message is added to the
  list. Expired entries are still flagged in all of these cases.

- _Present._ A suppression is active when its ID matches any vulnerability ID
  or alias the scan reports, as osv-scanner matches suppressions against every
  alias.

The stale IDs reach the remover as the classifier's own JSON array, in a file,
with no text conversion in between, and every listed ID must be in the file.
Text from the caller (such as `config-path`), the suppression file or the
scanner is printed so that the runner cannot read it as a command: IDs appear
as they are when they hold only letters, digits, `.`, `_`, `:`, `+` and `-`
(without `::`), and JSON-quoted otherwise with backticks, pipes, percent signs,
number signs and colons escaped; other values have control characters shown as
`?` and `##[` and `::` broken up; output replayed from the scanner and the
scripts is printed between `::stop-commands::` and a random resume token. Lists
in the job summary and the pull request stop after 50 items; the job log lists
every one.

**How the cleanup edits the file.** Only `[[IgnoredVulns]]` blocks whose `id`
is stale are removed; other tables such as `[[PackageOverrides]]` are never
removed or moved. Kept lines keep their exact bytes (comments, spacing, CRLF
line endings), with two exceptions: blank lines left at the end of the file are
trimmed to the number the original ended with, and when the original had no
final newline, the new last line loses its line ending too. A block runs from
its header to the next table header and is removed with these lines:

- Comment lines directly above its header, with no blank line in between,
  except a comment run that starts on the first line of the file: that is the
  file header, and it is never removed.
- Its key lines, comments between them or directly after the last one, and the
  blank lines that follow.

Inside a removed block, a comment paragraph with a blank line directly before
and directly after it (a section comment such as `# ---- Go toolchain ----`) is
kept, together with the blank lines after it. The rule cannot tell what a
comment is about: a note about a kept entry written directly above the header of
a removed entry goes with it, and a note about a removed entry that is set off
by blank lines on both sides stays. Every comment the edit deletes, whole-line
or after a key or header on a removed line (found outside strings), is printed
in the job log and listed, with its line number, under "Comment lines removed
with these entries" in the cleanup pull request so a reviewer sees what went.
The file is deleted only when nothing but whitespace is left, so a kept file
header or section comment is never lost. Headers are recognised with
indentation, spaces inside the brackets, a quoted name and a trailing comment; a
header-like line inside a multi-line string is not one. After editing, the
script reads the result with Python's TOML parser and checks that it equals the
original with exactly the stale entries taken out, comparing tables, arrays,
value types and array order exactly. The file is then replaced through a
temporary file in the same directory, keeping its mode; a symbolic link is
refused. If the check or the write fails, or the input is unusable, the file is
left unchanged, one `ERROR:` line is printed and the job fails. Expired entries
are flagged in the job summary before the cleanup starts, so they are reported
even when it fails.

| Input                    | Default                 | Notes                                         |
| ------------------------ | ----------------------- | --------------------------------------------- |
| `osv-version`            | empty                   | Empty uses install-osv-scanner.sh pin         |
| `config-path`            | `.osv-scanner.toml`     | Suppression TOML path                         |
| `check-script`           | tooling default         | Repo-local override supported                 |
| `cleanup-pr-labels`      | security labels (below) | Added after PR creation; empty opts out       |
| `egress-preset`          | `osv-scanner`           | Includes GitHub tooling + OSV API hosts       |
| `allowed-endpoints-mode` | `append`                | Merge preset with caller endpoints            |
| `workflow-file`          | empty                   | Caller workflow filename for PR footer        |
| `runner-image`           | `""`                    | Runner override; Linux only                   |
| `concurrency-scope`      | empty                   | Suffix for the cleanup group (see below)      |
| `cleanup-app-token`      | `false`                 | `true`: App token for the cleanup (see below) |

The cleanup commit is created through the GitHub API
(`scripts/ci/git/create-signed-commit.sh`, reset mode on the default branch
head), so GitHub signs it and the PR can merge where `required_signatures` is
enforced; nothing is committed or pushed with the git CLI. The run stops before
any write if the suppression file on the default branch differs from the
checked-out copy. The PR is opened without labels and `cleanup-pr-labels`
(default `security,dependencies,automation`) are added afterwards one at a
time; a label missing in the repository only logs a warning. An empty
`cleanup-pr-labels` opts out of labelling. If the PR cannot be created, the new
`chore/remove-stale-vulns-<timestamp>-<run_id>-<attempt>-<random>` branch is
deleted (or, when deletion fails or it cannot be verified that no PR exists,
left in place with its compare URL in the job summary) and the job fails.
Cleanup runs are serialized per repository by a job-level `concurrency` group,
so a later run sees an earlier run's open cleanup PR instead of opening a
duplicate. This group never cancels a running cleanup (a caller's own
`cancel-in-progress: true` group still can); if several runs queue, GitHub
keeps only the newest pending one, which scans the latest suppressions.
`concurrency-scope` suffixes the group (`vuln-suppression-cleanup-<repo>-<scope>`)
for a caller that dispatches from many throwaway refs at once and needs every
run to conclude rather than be superseded, such as the external fixture
(`concurrency-scope: ${{ github.ref }}`, #1134). The fixture carries no
`.osv-scanner.toml`, so its runs never reach the cleanup-PR path and cannot race
each other into duplicate PRs. Leave it empty in a real repository so cleanup
PRs stay serialized.

**Which token opens the cleanup PR (#1687, #1691).** The checkout, the signed
cleanup commit, the branch and the PR all use one token, chosen at job start
by the `cleanup-app-token` input (boolean, default `false`). App mode is never
chosen from the secrets alone:

| `cleanup-app-token` | Secrets passed                                                             | Result                                                                     |
| ------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `false` (default)   | `GH_TOKEN`, with or without any `RELEASE_APP_*`                            | `GH_TOKEN`, exactly as before; the App secrets are ignored (fallback mode) |
| `false`             | no `GH_TOKEN`                                                              | fails before any write, naming `GH_TOKEN`, the input and the App secrets   |
| `true`              | `RELEASE_APP_CLIENT_ID` or `RELEASE_APP_ID`, and `RELEASE_APP_PRIVATE_KEY` | an App installation token minted in the job (App mode); `GH_TOKEN` unused  |
| `true`              | anything less (an ID without the key, the key without an ID, nothing)      | fails before any write, whether or not `GH_TOKEN` is passed                |

With the input off, inherited `RELEASE_APP_*` secrets (for example through
`secrets: inherit`) change nothing. The App secrets follow the release
reusables' rules: the client ID is preferred when both IDs are set. The token
is minted inside the cleanup job, right before the checkout, for the calling
repository only, with `contents: write` and `pull-requests: write` and nothing
else; the App must hold both. The minting action revokes it when the job ends.
It is never written to a job output. If minting gives no token, the consumers
get a placeholder that cannot authenticate, never `GH_TOKEN`. The token
endpoint is `api.github.com`, which the `osv-scanner` egress preset already
allows.

Why App mode: GitHub starts no workflow for a push or a PR made with
`GITHUB_TOKEN`, so in fallback mode the cleanup PR's checks wait for someone
to approve and run them. A PR opened with an App token starts them like any
other PR. In App mode the cleanup commit is authored by the App's bot account
(`<app-slug>[bot]`) and signed by GitHub; in fallback mode it is
`github-actions[bot]`, as before. Only fallback mode with `GITHUB_TOKEN` as
`GH_TOKEN` needs the repository setting "Allow GitHub Actions to create and
approve pull requests".

**What App mode trusts.** The App token can do more than `GITHUB_TOKEN`:

- its pushes and pull requests start workflows, which run with the
  repository's secrets;
- it is not limited by the job's `permissions:` block, only by the two
  permissions requested at mint and by what the App's installation holds;
- if the App is a bypass actor on a ruleset, the token keeps that bypass and
  can write a protected branch or tag directly;
- with `pull-requests: write` it can approve pull requests if the App may,
  even when "Allow GitHub Actions to create and approve pull requests" is off.

Who receives it: the repository checkout (which persists no credential) and
the "Check suppression staleness" step, which runs the `check-script` input
(by default lgtm-ci's `check-vuln-suppressions.sh`, which runs osv-scanner and
lgtm-ci's Python helpers) with the token in `GH_TOKEN` for the whole step. The
`install-script` input runs earlier on the same runner, so it can change what
that step runs. `persist-credentials: false` and the job's `permissions:` do
not sandbox a script that is handed the token: the check script, the install
script and the checked-out ref must all be trusted with it. A later step in
the same job would not be a boundary either, so the write phase is not split
out of the check step.

Recommendations for App mode:

- use an App that is not a bypass actor on any ruleset of the repository, and
  that holds no permission beyond contents and pull requests write;
- enable `cleanup-app-token` only for events that run a trusted ref, such as
  `schedule` and `workflow_dispatch` on the default branch, never for events
  that run untrusted code;
- fork pull requests get no secrets, so App mode fails there with "incomplete
  App credential" rather than falling back.

In App mode the job's `GITHUB_TOKEN` still holds the `contents: write` and
`pull-requests: write` the caller grants, unused for the cleanup; a reusable
job cannot change its permissions by input, so the caller job must grant them
in both modes.

Use a Linux `runner-image`; the install script downloads `linux_*` release
binaries only.

```yaml
"on":
  schedule:
    - cron: "0 4 * * 1"
  workflow_dispatch: {}

permissions: {}

jobs:
  check-suppressions:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-vuln-suppression-check.yml@<sha>
    permissions:
      contents: write
      pull-requests: write
    with:
      tooling-ref: "<sha>"
      job-name: "🔍 Check Vulnerability Suppressions"
      workflow-file: vuln-suppression-check.yml
    secrets:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

For App mode, set the input and pass the App credential instead of
`GH_TOKEN` (the caller job's `permissions:` stay as above; permissions omitted
for brevity):

```yaml
with:
  cleanup-app-token: true
secrets:
  RELEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}
  RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

### GHCR cleanup

`reusable-ghcr-cleanup.yml` prunes aged untagged container versions and ephemeral
build-cache tags (`pr-*`, `mq-*`, `dispatch-*`). Before deleting untagged
versions it collects digests referenced by tagged manifest indexes (multi-arch
children, cosign/SLSA attestations) and skips the entire prune when that
collection is incomplete.

| Input                       | Default          | Notes                                                 |
| --------------------------- | ---------------- | ----------------------------------------------------- |
| `package-name`              | —                | Required GHCR package name                            |
| `min-age-days`              | `7`              | Min age before untagged deletion                      |
| `keep-latest`               | `0`              | Keep N most recent untagged                           |
| `build-cache-pr-age-days`   | `14`             | Min age before cache deletion                         |
| `protect-referenced`        | `true`           | Skip when refs incomplete                             |
| `prune-buildcache`          | `true`           | Delete aged ephemeral tags                            |
| `prune-tagged`              | `false`          | Opt in to tagged retention (below)                    |
| `main-retention-days`       | `30`             | `main` / `sha-*` retention (`prune-tagged` only)      |
| `prerelease-retention-days` | `90`             | Pre-release retention (`prune-tagged` only)           |
| `dry-run`                   | `false`          | Log only, no deletions                                |
| `egress-policy`             | `block`          | `audit` or `block`                                    |
| `egress-preset`             | `github-tooling` | API + GHCR hosts                                      |
| `allowed-endpoints`         | `""`             | Custom endpoints                                      |
| `allowed-endpoints-mode`    | `replace`        | `replace` or `append`                                 |
| `tooling-ref`               | `""`             | lgtm-ci tooling git ref                               |
| `runner-image`              | `""`             | Explicit override → `LGTM_CI_RUNNER` → `ubuntu-26.04` |

Grant `contents: read` and `packages: write` on the caller job. Forward a token with
`packages:write` via `secrets.token` (or `secrets: inherit`).

#### Tagged retention (`prune-tagged`)

Untagged pruning alone leaves tagged versions to accumulate forever: any repo
using `reusable-docker` with the default tag matrix publishes a `sha-<commit>`
tag on every default-branch push. Set `prune-tagged: true` to also age out
tagged versions. It is **off by default**, so existing callers are unaffected.

| Tag shape                                          | Policy                                   |
| -------------------------------------------------- | ---------------------------------------- |
| `latest`                                           | never deleted                            |
| semver (`1`, `1.2`, `1.2.3`, optional leading `v`) | never deleted                            |
| `main`, `sha-*`                                    | deleted past `main-retention-days`       |
| pre-release channel (below)                        | deleted past `prerelease-retention-days` |
| anything else                                      | never deleted (fail safe)                |

A tag is in the pre-release channel when it is exactly `alpha`, `beta`, `rc`,
`pre`, `dev` or `snapshot`, optionally preceded by anything ending in `-` and
optionally followed by digits, `.`, `_` or `-`: `dev`, `1.2.3-alpha.1`,
`2.0.0-beta`, `1.2.3-rc1`, `1.0.0-pre.2`, `3.1.0-snapshot`. The match is
anchored, not a substring — `predeploy` is _not_ the `pre` channel and lands in
"anything else", which is never deleted. The exact patterns live in
`scripts/ci/lib/ghcr/retention.sh`.

A GHCR version can carry several tags on one manifest. **A version is deleted
only when _every_ tag on it is deletable** — never when any single tag says
delete. That is what makes the policy safe:

- A release build publishes `:latest`, `:<semver>` and `:sha-<commit>` onto one
  manifest. `latest` and semver never expire, so the whole version is retained
  and the release's immutable `sha-` pin survives forever.
- A main-push build publishes only `:main` + `:sha-<commit>`. Once `:main` moves
  on, the version is a lone `sha-*` and ages out at `main-retention-days`.

Inverting that rule ("delete if _any_ tag is deletable") would delete every
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
`sha-*` and _will_ be pruned at `main-retention-days`. Pin release-channel
images, or raise `main-retention-days` beyond your longest expected deploy gap.

This policy was proven in production in lgtm-hq/Rustume's inline `prune-tagged`
job before being generalised here; that repo can now drop its local copy.

```yaml
"on":
  schedule:
    - cron: "0 3 * * 0"
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

| Input                    | Default   | Notes                                                 |
| ------------------------ | --------- | ----------------------------------------------------- |
| `package-name`           | —         | Required GHCR package name                            |
| `threshold-days`         | `30`      | Min staging-tag age before deletion                   |
| `keep-recent`            | `0`       | Keep N most recent staging tags                       |
| `protect-referenced`     | `true`    | Skip when refs incomplete (#433 gate)                 |
| `dry-run`                | `true`    | Log only, no deletions                                |
| `egress-policy`          | `block`   | `audit` or `block`                                    |
| `egress-preset`          | `docker`  | API + GHCR registry hosts                             |
| `allowed-endpoints`      | `""`      | Custom endpoints                                      |
| `allowed-endpoints-mode` | `replace` | `replace` or `append`                                 |
| `tooling-ref`            | `""`      | lgtm-ci tooling git ref                               |
| `runner-image`           | `""`      | Explicit override → `LGTM_CI_RUNNER` → `ubuntu-26.04` |

Grant `contents: read` and `packages: write` on the caller job. Forward a token
with `packages:write` via `secrets.token`. Scheduled callers should stay in
dry-run and delete only on an explicit `workflow_dispatch`.

```yaml
"on":
  schedule:
    - cron: "0 3 * * 1"
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

| Input                    | Default                       | Notes                                        |
| ------------------------ | ----------------------------- | -------------------------------------------- |
| `build-command`          | required                      | Site build script or inline command          |
| `test-command`           | required                      | Site test orchestrator                       |
| `check-command`          | empty                         | Optional type-check step before tests        |
| `build-env`              | empty                         | Multiline `KEY=VALUE` for build (ASTRO_BASE) |
| `site-working-directory` | `.`                           | Node/Bun install path                        |
| `lychee-paths`           | `.`                           | Built dist path for link check               |
| `lychee-root-dir`        | first `lychee-paths` entry    | `--root-dir` for relative href resolution    |
| `upload-site-artifact`   | `false`                       | Set `true` with explicit artifact path       |
| `python-version`         | empty                         | Enables Python setup when set                |
| `python-test-command`    | empty                         | Hook before `test-command` when Python set   |
| `vitest-json-path`       | empty                         | Non-default Vitest JSON for PR summaries     |
| `test-egress-preset`     | falls back to `egress-preset` | Override egress for site-test job            |

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
      actions: read
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
      actions: read
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

| Language class                          | `build-mode`            | Notes                                      |
| --------------------------------------- | ----------------------- | ------------------------------------------ |
| Python, JavaScript/TypeScript, Ruby, Go | `none` (default)        | Database built directly from source        |
| C/C++, C#, Java, Kotlin, Swift, …       | `autobuild` or `manual` | Requires build observation or custom steps |

<!-- markdownlint-enable MD013 -->

**Python-only caller** — omit `build-mode` or set `none` explicitly:

```yaml
jobs:
  codeql:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml@<sha>
    permissions:
      actions: read
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
      actions: read
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
      actions: read
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
