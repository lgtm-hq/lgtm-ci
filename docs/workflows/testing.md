# Testing workflows

Per-language test reusables plus coverage collection and summary
publishing. Full inputs/outputs/examples: [reusable-workflows.md](../reusable-workflows.md#tests).
Contract details (compat vs coverage mode, job display names, Pages
coverage HTML inputs): [workflow-contract.md](../workflow-contract.md).

## Caller concurrency

To replace superseded PR CI, set concurrency on the caller, as this
repository's [CI workflow](../../.github/workflows/ci.yml) does:

```yaml
concurrency:
  group: >-
    ci-caller-${{ github.workflow_ref }}-${{ github.event_name }}-${{
    github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id }}-${{
    github.event_name == 'pull_request' && 'pr' || github.run_attempt }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

`github.workflow_ref` identifies the workflow file and ref, isolating even
workflow files with the same display name. For PRs, that ref and the PR number
stay stable across commits and reruns. Every non-PR execution uses its run ID
and attempt, so main pushes, tags, releases and merge queue runs each keep an
independent group. Setting only `cancel-in-progress: false` on a shared group
still replaces pending work.

Keep this group in the caller. A reusable inherits the caller's `github`
context; copying the group into a callee can make it wait on or cancel its
caller (#108). CI's reachable reusables currently define no concurrency groups;
this example does not change their defaults or publication guards. Review
callee groups before applying the example to another workflow.

The expression tests establish identity and policy only. Hosted supersession,
cancellation latency, isolation and before/after overlap measurements remain
acceptance work for [#1298](https://github.com/lgtm-hq/lgtm-ci/issues/1298).
They do not establish saved minutes.

## Python, Node, shell, E2E

`reusable-test-python.yml`, `reusable-test-node.yml` (Vitest),
`reusable-test-node-custom.yml` (caller-provided command),
`reusable-test-shell.yml` (BATS), `reusable-test-e2e.yml`,
`reusable-test-e2e-playwright.yml`, and `reusable-test-e2e-matrix.yml` share a
standard shape: they check out lgtm-ci tooling, run the language runner,
optionally collect coverage, and post/update a PR summary comment via
`reusable-publish-test-summary.yml` when `pull-requests: write` is granted.

With `coverage: false` (the default), the PR summary is totals-only — no
Coverage / Code Coverage sections and no “Unable to retrieve coverage…”
warning. With `coverage: true`, rich or totals-with-percent comments stay as
today; a missing report still warns. See workflow-contract.md
[Comment body selection](../workflow-contract.md#comment-body-selection).

### reusable-test-python.yml

```yaml
jobs:
  test:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha> # vX.Y.Z
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      python-version: "3.12"
      test-path: "tests"
      coverage: true
      coverage-threshold: 80
      upload-coverage: true
```

**Inputs:** `python-version` (default '3.12'), `test-path` (default
'tests'), `coverage` (default false), `coverage-format` (xml/json/lcov,
default 'json'), `coverage-threshold` (default 0), `upload-coverage`
(default false), `artifact-prefix` (default 'python'; artifacts upload as
`<artifact-prefix>-coverage` and `<artifact-prefix>-results-<version>`, so a
caller running this workflow twice in one run gives each call its own prefix —
see [Calling a language test reusable twice in one run](../reusable-workflows.md#calling-a-language-test-reusable-twice-in-one-run-1091)),
`extras`, `git-deps-host` (default 'github.com'), `git-deps-username`
(default 'x-access-token').

This repo's `ci.yml` measures `scripts/ci` (its `[tool.coverage]` config in
`pyproject.toml`, including scripts the tests run as subprocesses) and gates
it at `coverage-threshold: 80`, the minimum set for the Python lane. With
`branch = true` the gated figure is coverage.py's combined line and branch
total. Raise the floor as coverage grows; do not lower it.

What the 80% covers: every Python file under `scripts/ci` except the files
listed under `omit` in `pyproject.toml` (8 today). No pytest test loads those
yet, so they are not measured; all are tested through bats and leave the list
as #1435 ports their suites. The list may only shrink, and
`tests/python/test_coverage_config.py` fails if it grows. A new script that no
test loads still counts, at 0%. Counting the omitted files at 0% too would put
the whole tree at about 65%.

To reproduce the number locally, from the repository root:

```bash
uv sync --extra test
uv run pytest tests/python --cov --cov-report=term
```

A macOS run reads about two points lower than CI, because the Linux-only tests
are skipped there. The Python lane posts no PR comment yet; showing the floor
there is tracked in #1202.

**Secrets:** `GIT_DEPS_TOKEN` (optional) — only for private git dependencies
in the groups being installed. Dependencies install with `uv sync --frozen`,
so commit a current `uv.lock`; see
[Frozen installs and private git dependencies](../workflow-contract.md#frozen-installs-and-private-git-dependencies-1021).

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`,
`coverage-percent`, `passed`.

`pipeline-skip` defaults to `false`. On a non-draft pull request, opting in
keeps matrix preparation and the normally named test jobs running, with runner
hardening, while omitting dependency installation, tests, result artifacts and
summary publishing. Empty or comma-only version lists retain the default
Python leg. The aggregate still blocks failed preparation or test jobs;
successful lightweight calls return zero counts and `passed: true`. Draft
skipping follows `draft-pr-skip`. All other events, including `main` pushes and
`merge_group`, run full tests even when the input is true.

Callers must fail open to full tests for unknown paths and keep the reusable
caller running. Before enabling filtering in a consumer, use a separately
authorized hosted canary to verify its exact single/matrix/empty-list required
contexts and failure controls. Local planning tests do not prove GitHub's
hosted check-name interpolation. Measure eligible workload and lightweight
runner overhead before claiming savings (Part of #1297).

### reusable-test-node.yml

Vitest testing with optional coverage and PR summaries. Custom package
scripts (for example `bun run test:coverage`) use
`reusable-test-node-custom.yml` instead.

**Inputs:** `job-name` (check name, default `Node.js Tests`),
`node-version` (default '22'), `package-manager` (npm/bun/pnpm, default
'npm'; drives setup, the frozen-lockfile install, and how `vitest` is
executed — never inferred from lockfiles, see the
[Node package-manager contract](../workflow-contract.md#node-package-manager-contract-1077)),
`test-path` (default '.'), `coverage` (default false; needs
`@vitest/coverage-v8` or `-istanbul` as a devDependency), `coverage-format`
(json/lcov/html, default 'json'), `coverage-threshold` (default 0),
`upload-coverage` (default false), `pre-test-command` (after install, before
tests), `post-test-command` (right after vitest, before parsing; non-zero
fails the job — the fixture uses it for a clean-tree assertion),
`artifact-prefix` (default 'node'; every artifact this call uploads is
`<artifact-prefix>-…`, and `coverage-artifact-name` defaults to
`<artifact-prefix>-coverage` — see
[Calling a language test reusable twice in one run](../reusable-workflows.md#calling-a-language-test-reusable-twice-in-one-run-1091)),
plus the Pages coverage HTML inputs (see
[reusable-workflows.md](../reusable-workflows.md#pages-coverage-html-inputs-reusable-test-node)).
`vitest` itself must be a devDependency; the workflow never installs it.

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`,
`coverage-percent`, `passed`.

**Read-only variant:** `reusable-test-node-run.yml` runs the same jobs
without the PR comment job. Its caller grants `actions: read` and
`contents: read` only (#1081, see
[Read-only variants](../reusable-workflows.md#read-only-variants)).

### reusable-test-node-custom.yml

Node testing via a caller-provided shell command (after dependency
install). Use when Vitest is not the runner or a package script owns
coverage.

**Inputs:** `test-command` (**required**, runs in `working-directory`),
`job-name` (default `Node.js Tests`), `node-version`, `node-versions`,
`package-manager`, `pre-test-command`, `artifact-prefix` (default
'node_custom', so its `<artifact-prefix>-coverage` payload never collides with
the Vitest workflow's `node-coverage`), and the same Pages coverage HTML
inputs as the Vitest workflow.

**Outputs:** `passed`, `pages-coverage-artifact-name`,
`pages-coverage-uploaded`.

Generated from `reusable-test-node.yml` and
`.github/workflow-overlays/reusable-test-node-custom.overlay` (#1356, see
[Overlay variants](../reusable-workflows.md#overlay-variants)); edit those,
not the generated file.

### reusable-test-shell.yml

BATS tests with optional kcov coverage. `coverage-shards` (default `1`)
keeps today's single job named `job-name`. When `coverage: true` and
`coverage-shards > 1`, each shard runs a subset of `.bats` files
(`cksum(path) % N`) and a fan-in job named `job-name` merges TAP totals
plus Cobertura XML (max per-line hits) and enforces `coverage-threshold`.
kcov v43 cannot merge bash coverage itself, so do not pass `kcov --merge`.
Shard TAP/coverage artifacts are named
`<artifact-prefix>-test-results-<comment-marker>-shard-*` and
`<artifact-prefix>-coverage-<comment-marker>-shard-*`, and the single-job
path uploads `<artifact-prefix>-test-results` and `<artifact-prefix>-coverage`,
so two invocations in one run do not mix results: give each call its own
`artifact-prefix` (default `shell`; the `comment-marker` keeps isolating the
PR comments). This repo's `ci.yml` opts in with `coverage-shards: 8` and
sets `coverage-include-path` to `scripts/ci/lib`, `scripts/ci/bootstrap` and
`.github/actions/checkout-and-harden`, so the scripts extracted from workflow
and action YAML (#1450) count toward its 84% floor.

```yaml
jobs:
  shell:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-shell.yml@<sha> # vX.Y.Z
    permissions:
      # actions: read — the aggregate job's artifact-availability wait (#803)
      actions: read
      contents: read
      pull-requests: write
    with:
      job-name: "🐚 Shell Tests"
      test-path: tests/bats
      coverage: true
      coverage-threshold: 84
      coverage-shards: 4
      upload-coverage: true
```

**Inputs:** `bats-version` (default empty; script pin in
`run-bats-tests.sh`), `test-path` (default
`tests/bats`), `coverage` (default false), `coverage-threshold` (default
0), `coverage-shards` (default 1), `upload-coverage` (default false),
`parallel` (default 1; ignored under kcov), `comment-marker` (default
`shell-test-results`; unique per invocation in the same run so the PR
comments do not mix), `artifact-prefix` (default `shell`; unique per
invocation in the same run so artifacts do not mix), plus standard
`tooling-ref` / egress / `job-name` / `draft-pr-skip` inputs.

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`,
`coverage-percent`, `passed`.

**Read-only variant:** `reusable-test-shell-run.yml` runs the same jobs
without the PR comment job (and its `publish-test-summary` input). Its
caller grants `actions: read` and `contents: read` only (#1081, see
[Read-only variants](../reusable-workflows.md#read-only-variants)).

#### kcov build cache

Both coverage paths (the single `test` job and every `test-sharded` leg)
cache the kcov build (#886). "Resolve kcov cache key" (`STEP=kcov-cache-key`)
prints one exact key,
`lgtm-kcov-<version>-<commit>-<patch sha256>-r<recipe sha256>-<ImageOS>-<distro><release>-<arch>`.
It covers the kcov version, the tag commit the source build checks, the
digest of the patch the build applies (`nopatch` for none), the digest of the
build recipe (`scripts/ci/lib/testing/kcov_cache.sh` plus the
`kcov-recipe:begin` to `kcov-recipe:end` block of `run-bats-tests.sh`), the
runner image, the `/etc/os-release` release and the architecture. A change to
any of them, the recipe included, misses the cache. An unknown part (a
`KCOV_VERSION` override without `KCOV_COMMIT`, an unreadable os-release)
leaves the key empty and skips the cache.

"Restore kcov build cache" (`actions/cache/restore`, SHA-pinned) restores
`~/.cache/lgtm-kcov/<version>` under that key, with no `restore-keys`, on
every event. "Save kcov build cache" (`actions/cache/save`, same pin) runs
only when "Check for a default-branch push"
(`scripts/ci/actions/default-branch-push.sh`, #1659) reports a `push` to the
repository's default branch, when the restore missed and the install staged
a build. The script compares the event and `refs/heads/<default branch>`
exactly and case-sensitively (expression `==` ignores case, so a push to a
branch `Main` would otherwise pass for `main`); the default branch reaches it
through `env:` only, and an empty value gives `false`. Pull requests,
`pull_request_target`, merge queue runs, schedules and dispatches restore
only and never write the cache through these steps. Both cache steps carry
`timeout-minutes: 5` and `continue-on-error: true`.

"Install kcov for coverage" installs from the stage only when it was staged
for the same key, its `tree/` holds exactly kcov v43's install set (`bin/kcov`,
optionally `bin/kcov-system-daemon`, the three files under
`share/doc/kcov/` and `share/man/man1/kcov.1`) with no symlink, special file
or other file, `ldd` (bounded by `timeout`) confirms every shared library of
`bin/kcov` resolves, and `bin/kcov --version` prints exactly `kcov <version>`
and nothing else. It then copies only those files into the prefix with
`sudo install -m 0755` or `-m 0644`. That path runs no `apt-get`,
`git clone` or build. A missing `ldd`, an `ldd` error or timeout, an
unresolved library or any other failed check is a `::warning::`, and the
source build runs (apt packages, clone, commit check, patch, cmake, make).
The build installs once, unprivileged, with `make install DESTDIR=`, stages
that tree when it passes the same checks (step output `stage-ready=true`),
and installs into the prefix through the same allowlisted copy. A build
that fails the checks is installed but not staged, so nothing is saved.
Cache state never fails the step.

The checks catch a stale or broken stage, not tampering: whoever can write
the cache entry can also write a stamp and a binary that pass them. These
steps save only on a push to the default branch, which stops pull requests
and other events in workflows that use them from writing the key through
them; GitHub lets pull requests read the default branch's cache entries but
not write them. It does not stop other code that runs in a default-branch
job holding the Actions runtime token, such as a compromised dependency,
from writing a cache entry under the same key: that threat is residual and
unresolved here. A stage restored under the right key that fails the checks
is rebuilt on every run until the key changes, since a cache key is never
overwritten.

"Install BATS and helpers" and "Install kcov for coverage" carry
`timeout-minutes: 10` in both paths. The BATS install clones bats-core and its
three helpers from GitHub and installs no apt package, so a warm kcov cache
leaves the job with no apt call. The cache adds no egress host: harden-runner
allows the Actions cache storage host itself (its pre step logs
`Adding cacheHost: ...` under the `shell-test` preset), as it does for the
Playwright browser cache (#1433).

#### Per-file BATS durations

On the sharded coverage path (`coverage: true`, `coverage-shards` above 1),
a push to the repository's default branch also records how long each
`.bats` file took (#1422). Later work uses it to assign shards by duration
instead of by path hash. Pull requests, merge queue runs, forks, the
single-job path and runs with a `test-filter` record nothing.

- **Artifact:** `<artifact-prefix>-bats-durations` (`shell-bats-durations`
  by default), holding one file, `bats-durations.json`. The aggregate job
  (named `job-name`) uploads it.
- **Retention:** 90 days. A reader takes it from the latest default-branch
  run, so it has to outlive a quiet period with no merges. The file is a
  few kilobytes.
- **Best effort:** none of these steps can fail a job. Missing, empty,
  truncated or malformed data produces a `::warning::` and, at worst, no
  artifact. A reader must handle the artifact being absent or a file
  missing from it.
- **Refused shards are listed:** when the merge cannot use a shard, the
  aggregate job's summary gets a "BATS durations" section with one line
  per shard and the reason, next to the warnings.

What `--timing` changes on every run. Under coverage `run-bats-tests.sh`
passes `--timing` to bats (when bats supports it) on every event, pull
requests included. With bats' report file (`bats-report.tap`, written
whenever bats supports `--report-formatter`) both the report and the
console TAP (the job log and `bats-output.tap`) end a timed result line in
`# in N ms` after a space, for example `ok 3 slow pass # in 208 ms`. A
skipped test keeps its `# skip [reason]` ending and gets no time. One
exception: when a test's name itself contains `# skip` as a word after a
space, bats reads the line as a skip and keeps its internal form (a space
and `in Nms`) at the end, so a passing test prints
`ok 1 parser handles # skip directive in 221ms`. A bats without
`--report-formatter` writes no report file, and its console TAP appends a
space and `in Nms` to the test name instead, with no `#`
(`ok 3 slow pass in 211ms`, `ok 1 plain skip in 2ms # skip`). Test counts
are unchanged in every case.

How it is measured. `run-coverage` also writes, next to the TAP,
`bats-files.txt` (the files in run order), `bats-version.txt` and, when
`test-filter` is set, a `bats-filter-used.txt` marker. On a default-branch
push each shard then runs `scripts/ci/actions/bats-durations.py shard`. Bats
numbers tests across the run in file order, so the script ties each result
to its file by position. It reads each file's tests statically, with the
line patterns bats' own preprocessor uses to find `@test` lines, and
executes nothing. It then checks the count and the names against the
report: the tests must add up to the TAP plan, and the description on each
result line must match the name of the test expected at that position. The
names are compared as lower-cased ASCII letters and digits only, so quoting
and punctuation cannot cause a mismatch. If anything differs, or the report
holds a second plan line or a test number twice, the shard records nothing
and says why in a warning. Otherwise it writes `bats-durations-shard.json`
into the shard's `<artifact-prefix>-test-results-<comment-marker>-shard-N`
artifact.

Limits of the static reading. Attribution compares the names and the count
of the statically read tests with the report, shard by shard. A shard with
a file whose tests cannot be read that way records nothing: tests
registered by a loaded helper or library (`load`, `bats_load_library`),
generated tests (`bats_test_function`). A file with a test definition
inside heredoc text also makes its shard record nothing: whether bats ever
registers such a test cannot be known by reading the file. An `@test` line
in code that never runs (inside `if false; then ... fi`, say) is still read
as a test, because the reading does not run bash. The name check then
refuses the shard. The one exception is a dead test whose name happens to
match the test bats runs at that position.

A test name that bash would expand (one with `$`, a backtick or an
unescaped double quote) is not compared, and its position matches any
result. A few such names in a shard are fine: the names around them still
fix every position. A shard in which no name can be compared records
nothing, because its count alone could hide two errors that cancel out. A
test whose name contains `# skip` that way (above) gives its file no value:
the file is listed as missing.

Symlinks. When `test-path` is a directory, `run-coverage` lists its test
files with `find -type f`, which skips a symlinked `.bats` file and does not
enter a symlinked directory, so bats never runs them. The merge lists the
expected files the same way, so such a file is neither run nor listed under
`missing`. A `test-path` that names one file is used as given.

Merging. The aggregate job runs `bats-durations.py merge` over the
downloaded shard artifacts and uploads the merged file. The shard documents
come from other jobs, so each is checked in full before it is used. The
merge refuses, with a warning, any shard document that is not a regular
file, too large to read (over 16 MiB), not valid JSON, or not in the shard
schema, or that comes
from another commit or run, from a later run attempt than its own, with
another shard count, an index out of range, a path that is not one of the
run's test files, or a file that a second document also claims. That
shard's files are then listed under `missing`. The run's test files are
listed from the aggregate job's own checkout of `test-path`; when that path
is not there, or leads outside the repository, nothing is published.

Each refused shard also gets a line in the job summary, for example:

<!-- markdownlint-disable MD013 -- summary lines, quoted in full -->

```markdown
### BATS durations

- Shard 3/8 was refused: it appears twice in attempt 2.
- A durations file in shard-4 (it claims shard 4/8) was refused: sha is 'def456', expected 'abc123'.
- Shard 5/8 sent no durations: its step "Record shard BATS durations" refused the data or did not run, and that step's warning says why.
```

<!-- markdownlint-enable MD013 -->

A file that fails its checks is named by its artifact folder, with the
shard it claims to be: that number is the file's own word. At most 50
refused files are listed. The last form means the shard job itself
recorded nothing; the reason
is in that job's warning, for example a name that differs from the report.
Documents from earlier attempts of the same run are kept: after "Re-run
failed jobs", the shards that were not re-run still hold real measurements
of the same commit. When two attempts reported the same shard, the later
one is kept and the earlier dropped with a notice; two documents for one
shard in the same attempt are both dropped. Each entry of `shards` records
the attempt it came from.

A file's duration is the sum of its tests' times, in seconds with three
decimals; a skipped test adds nothing, so a file whose tests were all
skipped is recorded as `0.0`, not as missing. All times are measured under
kcov coverage and are larger than those of a plain bats run. Bats has no file-level timing: its
JUnit report's per-file time is the same sum. So the sum leaves out
`setup_file` and `teardown_file` and a fixed cost of about a second per
file (bats starting the file, and kcov). That is why each shard's wall time
and the test counts are recorded too: a consumer can fit the per-file and
per-test cost from them. A file gets no value when any of its tests has no
result line: its `setup_file` failed, or the shard was cut short before the
file finished. Such a file is listed under `missing`, as is any `.bats` file
under `test-path` that no kept shard reported. No value is made up.

Schema of `bats-durations.json` (`schema_version` 1; keys sorted, output
deterministic):

| Field            | Type           | Meaning                                                                                     |
| ---------------- | -------------- | ------------------------------------------------------------------------------------------- |
| `schema_version` | integer        | `1`. A change of meaning bumps it; fields may be added without one.                         |
| `sha`            | string         | The commit the run tested (`GITHUB_SHA`).                                                   |
| `run_id`         | integer        | The workflow run (`GITHUB_RUN_ID`).                                                         |
| `run_attempt`    | integer        | The attempt that merged (`GITHUB_RUN_ATTEMPT`).                                             |
| `shard_total`    | integer        | The `coverage-shards` input.                                                                |
| `bats_version`   | string or null | The bats version the shards ran; null when unknown or when shards disagree.                 |
| `shards`         | array          | Per kept shard, by index: `index`, `run_attempt`, `wall_seconds`, `files`, `tests` (below). |
| `test_counts`    | object         | Repo-relative `.bats` path to its test count.                                               |
| `durations`      | object         | Repo-relative `.bats` path to seconds (number).                                             |
| `missing`        | array          | Sorted repo-relative paths with no duration.                                                |

In `shards`, `run_attempt` is the attempt that shard ran in, `wall_seconds`
the shard's whole bats run (under kcov in CI) in whole seconds (null when
unknown), `files` the sorted paths it ran and `tests` its test count. A
shard document has `schema_version`, `sha`, `run_id`, `run_attempt`,
`bats_version`, `test_counts`, `durations` and `missing` with the same
meaning, plus `shard_index`, `shard_total` and its own `wall_seconds`. Both
examples below are real output of the two commands, from two shards over
`tests/bats/unit/lib/release` run locally with bats 1.14.0 and without
kcov (the run id is made up). The wall times show the fixed cost: shard 1
ran 113 tests for 4.713 s in total and took 17 s.

```json
{
  "bats_version": "1.14.0",
  "durations": {
    "tests/bats/unit/lib/release/test_changelog_merge.bats": 2.488,
    "tests/bats/unit/lib/release/test_release_assets.bats": 0.072,
    "tests/bats/unit/lib/release/test_version.bats": 2.153
  },
  "missing": [],
  "run_attempt": 1,
  "run_id": 19876543210,
  "schema_version": 1,
  "sha": "0d91acbbd79be69819ccdd60029d5a398c7bd7fb",
  "shard_index": 1,
  "shard_total": 2,
  "test_counts": {
    "tests/bats/unit/lib/release/test_changelog_merge.bats": 44,
    "tests/bats/unit/lib/release/test_release_assets.bats": 2,
    "tests/bats/unit/lib/release/test_version.bats": 67
  },
  "wall_seconds": 17.0
}
```

```json
{
  "bats_version": "1.14.0",
  "durations": {
    "tests/bats/unit/lib/release/test_analyze.bats": 7.983,
    "tests/bats/unit/lib/release/test_changelog.bats": 8.23,
    "tests/bats/unit/lib/release/test_changelog_merge.bats": 2.488,
    "tests/bats/unit/lib/release/test_conventional.bats": 1.024,
    "tests/bats/unit/lib/release/test_extract.bats": 1.676,
    "tests/bats/unit/lib/release/test_fileops.bats": 0.568,
    "tests/bats/unit/lib/release/test_release_assets.bats": 0.072,
    "tests/bats/unit/lib/release/test_version.bats": 2.153
  },
  "missing": [],
  "run_attempt": 1,
  "run_id": 19876543210,
  "schema_version": 1,
  "sha": "0d91acbbd79be69819ccdd60029d5a398c7bd7fb",
  "shard_total": 2,
  "shards": [
    {
      "files": [
        "tests/bats/unit/lib/release/test_analyze.bats",
        "tests/bats/unit/lib/release/test_changelog.bats",
        "tests/bats/unit/lib/release/test_conventional.bats",
        "tests/bats/unit/lib/release/test_extract.bats",
        "tests/bats/unit/lib/release/test_fileops.bats"
      ],
      "index": 0,
      "run_attempt": 1,
      "tests": 124,
      "wall_seconds": 34.0
    },
    {
      "files": [
        "tests/bats/unit/lib/release/test_changelog_merge.bats",
        "tests/bats/unit/lib/release/test_release_assets.bats",
        "tests/bats/unit/lib/release/test_version.bats"
      ],
      "index": 1,
      "run_attempt": 1,
      "tests": 113,
      "wall_seconds": 17.0
    }
  ],
  "test_counts": {
    "tests/bats/unit/lib/release/test_analyze.bats": 26,
    "tests/bats/unit/lib/release/test_changelog.bats": 33,
    "tests/bats/unit/lib/release/test_changelog_merge.bats": 44,
    "tests/bats/unit/lib/release/test_conventional.bats": 31,
    "tests/bats/unit/lib/release/test_extract.bats": 21,
    "tests/bats/unit/lib/release/test_fileops.bats": 13,
    "tests/bats/unit/lib/release/test_release_assets.bats": 2,
    "tests/bats/unit/lib/release/test_version.bats": 67
  }
}
```

Paths are relative to the repository root: with a `working-directory`
other than `.`, it is the prefix of every key.

Fetching and trusting the file. A job that reads it needs `actions: read`
(the GitHub CLI uses `GH_TOKEN`). Take the latest push run of the calling
workflow on the default branch, then download the artifact:

```bash
run_id="$(gh run list --workflow ci.yml --branch main --event push \
  --status completed --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run download "$run_id" --name shell-bats-durations --dir durations
# or, with the REST API:
gh api "repos/{owner}/{repo}/actions/runs/$run_id/artifacts" \
  --jq '.artifacts[] | select(.name == "shell-bats-durations" and (.expired | not))'
```

When the latest default-branch run has no artifact, or lists the files you
need under `missing`, walk back a few runs (raise `--limit` and try each
run id in turn) before falling back to having no data.

Then check what you read:

- Reject any `schema_version` other than `1`, and treat a missing
  artifact or a download error as "no data", not as a failure.
- A non-empty `missing`, or fewer `shards` entries than `shard_total`,
  means the data is partial: fall back for those files.
- Compare `sha` with the commit being tested to judge how stale the data
  is; files added since then have no entry.
- The repository or organization setting for artifact retention can cap
  the 90 days at a lower value, after which the artifact is gone.

### reusable-test-e2e.yml

```yaml
jobs:
  e2e:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
    with:
      browsers: "chromium"
      shard: "1/3" # optional, for parallel execution
      reporter: "html"
      upload-report: true
```

**Inputs:** `node-version` (default '22'), `package-manager` (npm/bun/pnpm,
default 'npm'), `bun-version` (exact Renovate-managed pin, used only with
`bun`), `project` (Playwright project), `browsers` (chromium/firefox/webkit/all,
default 'chromium'), `shard` (for example "1/3"), `reporter` (json/html/junit,
default 'html'), `upload-report` (default true), `system-deps` (`always`
default, or `if-missing`: Linux system packages install only when `ldd`
reports a missing shared library of the installed browsers, or cannot tell,
which WebKit always is; `ldd` does not see fonts or `xvfb`),
`browser-install-mode` (`full`
default, or `headless-shell` for `playwright install --only-shell`, Playwright
1.49+). `@playwright/test` must be a devDependency. Browsers are cached under an
exact key by the `run-playwright` action (#1433); its steps save that cache
only on a push to the default branch, every other event only restores it
(#1659; trust model and residual threat in
[workflow-contract.md](../workflow-contract.md#playwright-e2e-reusable-test-e2e-playwright)).

**Outputs:** `tests-passed`, `tests-failed`, `passed`.

### reusable-test-e2e-playwright.yml

Preferred Playwright E2E reusable for thin smoke / a11y / full callers with
distinct required `job-name` values. Caches the browsers under one exact
key (OS release, architecture, installed Playwright version, install mode,
browsers; no `restore-keys`) and skips the download on an exact hit (#1433).
Every event restores the cache; these steps save it only on a push to the
default branch (compared case-sensitively), right after an install whose
browsers pass the completeness check (#1659). That stops pull requests and
other events in workflows that call this reusable from writing the key
through it; it does not stop other code that runs in a default-branch job
holding the Actions runtime token, such as a compromised dependency, from
writing a cache entry, a residual threat this does not resolve. The
completeness check catches staleness and breakage, not tampering. A failed
restore does not fail the job, and leftovers from it, or any browser
directory that was not empty before the install, keep the save off; nothing
is removed. Known limit: a partial restore can still make that one run fail
(Playwright skips a browser whose marker exists), but such a run never
saves. Pull request runs restore the default branch's
cache, so one before any default-branch push runs cold. It
passes reporters as one `--reporter` flag and
fails the job when `playwright-report/` is missing afterwards (#804); uploads
HTML/JUnit/blob reports on failure by default (`upload-report-when: always`
to keep them on every run).

```yaml
jobs:
  e2e-smoke:
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-e2e-playwright.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      pull-requests: write
    with:
      job-name: "🔥 Smoke E2E"
      grep: "@smoke"
      browsers: "chromium"
```

**Inputs:** `job-name` (**required**), `test-command` (default `npx playwright
test`), `project`, `grep`, `node-version`, `browsers` (default `chromium`),
`reporters` (default `list,json,junit,html`; must keep `json` and `html`),
`upload-report` (default true), `upload-report-when` (`failure` default, or
`always`), `base-url`, `web-server`, `system-deps` (`always` default, or `if-missing`: Linux
system packages install only when `ldd` reports a missing shared library of the
installed browsers, or cannot tell; `always` installs them every run; `ldd` does
not see fonts or `xvfb`), `browser-install-mode` (`full` default, or
`headless-shell` for `playwright install --only-shell`, Playwright 1.49+), plus
standard egress / tooling inputs.

**Outputs:** `tests-passed`, `tests-failed`, `tests-total`, `passed`.

### reusable-test-e2e-matrix.yml

Matrix E2E with parallel legs per suite/browser/shard, tag-based filtering
(`@smoke`, `@visual`, `@a11y`), browser caching, and automatic report
merging.

**Inputs:** `node-version` (default '22'), `package-manager` (npm/bun/pnpm,
default 'npm'), `bun-version` (exact Renovate-managed pin, used only with
`bun`), `test-suites` (comma-separated, default 'smoke'), `browsers`
(comma-separated, default 'chromium'), `tag-prefix` (default '@'), `shards` (per
suite, default 1), `reporter` (json/html/blob, default 'html'), `upload-report`
(default true), `timeout-minutes` (default 30), `artifact-prefix` (default
'playwright'), `system-deps` (`always` default, or `if-missing`: Linux system packages
install only when `ldd` reports a missing shared library of the installed
browsers, or cannot tell; `always` installs them every run; `ldd` does not see
fonts or `xvfb`), `browser-install-mode` (`full` default, or `headless-shell`
for `playwright install --only-shell`, Playwright 1.49+). Browsers are cached
per leg by the `run-playwright` action under an exact key (#1433); its steps
save that cache only on a push to the default branch, every other event only
restores it (#1659; trust model and residual threat in
[workflow-contract.md](../workflow-contract.md#playwright-e2e-reusable-test-e2e-playwright)).

`publish-results`, `pages-target-dir`, `publish-egress-preset` and
`publish-allowed-endpoints` are **deprecated and inert** since #770 — see
below.

Shards upload as `<artifact-prefix>-<suite>-<browser>-<shard>` and the merge
job collects them with `<artifact-prefix>-*`, so a caller running this workflow
twice in one run must give the second call its own `artifact-prefix` — otherwise
each merge picks up the other call's shards. The prefix must match
`[A-Za-z0-9_.]+`: `-` is reserved as the separator, and allowing it inside the
prefix would let `e2e-*` match an `e2e-nightly` call's shards.

#### Publishing moved out (#770)

This workflow no longer deploys to Pages. Its `publish` job declared
`pages: write`, `id-token: write` and `actions: write`, and because a reusable
workflow's permission request is validated **statically**, every caller had to
grant all three — including callers running with `publish-results: false`. The
job moved to `reusable-publish-test-results-pages.yml`, which the caller invokes
in its own job:

```yaml
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
    pages-target-dir: playwright # the value this call used to pass
    results-path: "."
```

`publish-results`, `pages-target-dir`, `publish-egress-preset` and
`publish-allowed-endpoints` are still accepted so pinned callers keep parsing —
an unknown input to a reusable workflow is a hard `startup_failure` — but they
do nothing and warn when set to a non-default value. `report-url` is always
empty; read `pages-url` off the publisher job instead.

`pages-target-dir` kept its name and its validator: it is the separate,
Pages-side half of the artifact isolation (#754). The publisher deploys to
`<pages-site>/<pages-target-dir>/`, so two publishing calls in one run overwrite
each other unless each is given its own value. It is **not** derived from
`artifact-prefix`: this value is URL-visible, has no glob-disjointness
requirement (so `-` is allowed), and deriving it would silently move the
published URL of any caller that sets `artifact-prefix` for artifact reasons
alone.

Neither workflow can detect the collision for you — a reusable workflow cannot
see its sibling calls, so the publisher only validates the value in isolation:
it must be a relative path matching `[A-Za-z0-9._/-]+` with no leading `/` and
no `..` segment, because it is interpolated into a deploy destination. Keeping
two publishing calls apart is the caller's contract.

Distinct `pages-target-dir` values are necessary but not sufficient for two
publishing calls on one site: every deploy uploads a **full site artifact** that
replaces the whole published site, and both jobs share the
`pages-<repo>-<ref>` concurrency group. Callers publishing more than one report
tree should use Model B (`reusable-deploy-site-with-reports`) or
`merge-existing-site` — see [pages-publishing.md](../pages-publishing.md).

**Outputs:** `total-passed`, `total-failed`, `shard-counts` (JSON array, one
`{report, passed, failed, skipped}` entry per shard report; empty with
`reporter: junit`, whose legs write no JSON results), `report-url` (deprecated,
always empty).

The `Merge Reports` job fails unless every matrix leg's artifact
(`<artifact-prefix>-<suite>-<browser>-<shard>`) holds exactly one Playwright
JSON report whose `suites` hold as many tests as its `stats` count, so a leg
that uploaded nothing, or an empty or inconsistent report, cannot shrink the
totals. A consistent zero-test report passes. `reporter: junit` writes no JSON
and skips this check. When the test job did not succeed, a missing shard
report is a `::warning::` and the merge fails without an `::error::` of its
own, so the failure points at the leg; a malformed or inconsistent report
stays an `::error::`.

The setup job normalises the `reporter` input once, and the legs and the merge
both use that value. Case and surrounding whitespace are ignored; `json`,
`html` and `junit` are kept; any other value, `blob` and comma lists such as
`html,junit` included, becomes `json`, which is the reporter the legs run.

### Isolated Pages publish variants

`reusable-test-node.yml` does not include a Pages publish job — use
`reusable-test-node-publish.yml` in a separate caller job when you need
coverage-badge / Pages publishing (same for Python:
`reusable-test-python-publish.yml`). Both publish variants run in a
**fresh workspace**; checkout order must be repo → lgtm-ci tooling → egress
→ harden, or `actions/checkout` wipes `.lgtm-ci-tooling/`. See
[pages-publishing.md](../pages-publishing.md) (Isolated publish jobs).

Multi-runtime matrices (`node-versions`, `python-versions`,
`rust-toolchains`) are **compat mode only**: `coverage: false` and
`publish-test-summary: false`. See workflow-contract.md
[Compat vs coverage contract](../workflow-contract.md#compat-vs-coverage-contract-340).

## Rust

`reusable-rust-build.yml` for compile checks, `reusable-rust-test.yml` for
tests (`coverage: false` for fast nextest-only, `coverage: true` for a
single instrumented `llvm-cov nextest` run). `reusable-test-rust-build.yml`
is a low-noise build-only alternative safe to run without PR context. See
[rust-testing.md](../rust-testing.md) and
[reusable-workflows.md](../reusable-workflows.md#rust). `reusable-rust-test.yml`
takes `artifact-prefix` (default `rust`; `<artifact-prefix>-coverage-lcov`,
`<artifact-prefix>-results-<toolchain>`) like the other language test
reusables — see
[Calling a language test reusable twice in one run](../reusable-workflows.md#calling-a-language-test-reusable-twice-in-one-run-1091).

`reusable-rust-test-run.yml` is its read-only variant: the same jobs without
the PR comment job, granting `actions: read` and `contents: read` only (#1081,
see [Read-only variants](../reusable-workflows.md#read-only-variants)).

## Coverage

`reusable-coverage.yml` unifies coverage collection (auto-detects format),
threshold checking and badge generation in one workflow — the workflow-level
equivalent of chaining `collect-coverage` + `check-coverage-threshold` +
`generate-coverage-badge` (see [actions/coverage.md](../actions/coverage.md)).
It does **not** publish to Pages; since #770 that is a separate call to
`reusable-publish-test-results-pages.yml`, described below.

**Inputs:** `coverage-files` (glob or list, default auto-detect), `format`
(input format: auto/istanbul/coverage-py/lcov, default 'auto'),
`output-format` (json/lcov/cobertura; empty by default, meaning the merged
report keeps the input format), `threshold` (default 0), `generate-badge`
(default true).

Since #1078 the merged report is never converted unless `output-format`
asks for it, so an LCOV producer stays LCOV through merge, threshold and the
PR comment. Asking for a format no converter implements (for example LCOV to
JSON) fails the job with `unsupported coverage conversion: <src> -> <dst>`
(exit 2) instead of producing an empty report. Line-only LCOV (no `BRF`/`FNF`
records) is a first-class input: branch and function coverage render as `n/a`
rather than `0%`, and their thresholds in the PR comment are skipped. The
merged file is `merged-coverage.json`, `.lcov` or `.xml` by format; the
`coverage-report` artifact name is unchanged.

`publish-pages` is **deprecated and inert** since #770: the Pages publish job
moved to `reusable-publish-test-results-pages.yml` so that callers which never
publish stop granting `pages`, `id-token` and `actions: write`. Call that
workflow with `artifact-name` set to this call's `coverage-artifact-name`,
`pages-target-dir: coverage`, `coverage-path` set to the `working-directory`
(`.` for the repo root) and `badge-path` set to `<working-directory>/coverage`.

**Outputs:** `coverage-percent`, `badge-url`, `passed`, plus `pages-url`
(deprecated, always empty). The workflow itself requires only
`contents: read` and `pull-requests: write`.

## Quality and gating

`reusable-quality-lint.yml` runs lintro in the pinned py-lintro Docker
image; pair with `reusable-publish-quality-summary.yml` for a PR comment.
`reusable-validate.yml` runs a caller-provided validation script.
`reusable-validate-lintro-version.yml` resolves or validates the pinned
py-lintro digest used by the quality/testing reusables.

### reusable-required-check.yml

Org ruleset gate: asserts an upstream reusable job succeeded (and optional
outputs) under a caller-controlled `job-name`, replacing consumer-local
shim `runs-on` jobs. The gate reports its check as
`{caller_job_id} / {job-name}` and org rulesets must require that exact
prefixed context — see [org-rulesets.md](../org-rulesets.md) for the
registry and [workflow-contract.md](../workflow-contract.md#org-ruleset-check-names).

```yaml
lintro-code-quality:
  needs: dogfooding-lint
  if: always()
  uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-required-check.yml@<sha> # vX.Y.Z
  permissions:
    contents: read
  with:
    job-name: "🛠️ Lintro Code Quality"
    upstream-result: ${{ needs.dogfooding-lint.result }}
    status-output: ${{ needs.dogfooding-lint.outputs.status }}
```

**Inputs:** `job-name` (**required**), `upstream-result` (**required**,
`needs.*.result`), `passed-output` (when set, must be the string `true`),
`status-output` / `status-expected` (optional status gate, default
expected `passed`), `draft-pr-skip` (default false), plus `tooling-ref`,
`egress-policy`, `allowed-endpoints`, `runner-image`, `timeout-minutes`.

**Outputs:** `exit-code` (`0`/`1`), `status` (`passed`/`failed`).
