# Cross-repository duplication scan

`.github/workflows/duplication-scan.yml` reads non-archived lgtm-hq repositories
each Monday at 03:37 UTC, with lgtm-ci's catalog as the reference implementation.
It also supports manual dispatch. Repository code is read as immutable Git
blobs, held in memory, and never executed. Only the public-safe Markdown report
is written to the step summary.

The scanner covers workflow jobs (`.yml` and `.yaml`), composite actions, and
scripts under `scripts/` and `.github/scripts/`. It removes comments, normalizes
spacing, action refs, repository/image names, paths and versions. Known version
inputs to setup-python, setup-node and setup-uv are parameters. Unknown action
inputs, executable programs, environment values and execution metadata
(including dependencies, permissions and runner selection) remain significant.
Step ordering, conditions, Python indentation and shell command boundaries also
remain significant. Explicit local script paths resolve exactly, including
extensionless scripts and nested calls; cycles and unresolved calls retain their
identity. Bare names do not use a basename fallback without a known working
directory. Dynamic paths, imports and changes of working directory can prevent a
match, so absence of findings does not establish absence of duplication.

Two consumer repositories qualify a cluster; one consumer qualifies when it
matches a catalog implementation. Automatic issues require identical normalized
structure to establish parameter-only differences. Public near matches use
Jaccard similarity of ordered shingles and appear separately for manual review,
without creating issues. `--threshold` controls these suggestions; its default
is **0.8**. At most 20 public near matches are shown. Private source never appears
in these suggestions. Reusable-workflow calls and jobs composed entirely of
lgtm-ci actions plus hardening/checkout are already adoption and are skipped.
Catalog entry points and directly referenced scripts form the reference set.

`catalog/local-exceptions.yml`, defined by
[#1236 / PR #1240](https://github.com/lgtm-hq/lgtm-ci/pull/1240), requires
`schema-version: 1` and an `exceptions` list. Each row has exactly `repo`, `path`,
optional `job`, `reason`, and `link`: an exact repository and file path, optional
job ID, a one-line technical reason, and a GitHub issue or PR decision link.
Omitting `job` exempts the whole file. Unknown fields, traversal, globs and invalid
values are rejected before reporting. Missing setup skips the scheduled scan;
an invalid allowlist fails before any issue writes.

Each logic fingerprint gets one issue with `ci` and `needs-triage` labels. The
fingerprint excludes the current member list, so adding a repository updates the
existing issue. The fingerprint payload carries a normalizer version; changing
that version requires an explicit migration of existing issue markers and
rejections. Every page of open and closed issues is read before writing; an API
error aborts reporting. Open issues change only when membership changes, and
only the marked member section is replaced. Human notes and the original
snippet remain intact. Updates and reopens refresh the title's repository count.
Not-planned closures stay silent; completed closures reopen with a comment when
the copy is found again. At most five new issues are created per run; deferred
candidates remain in the summary. Snippets cannot inject scanner markers.

Private members contribute only repository and path to findings, never job
names, input names/values, snippets or suggested names derived from their code.
The inventory lists public repository names and only a count for private repos.
Malformed, oversized and binary files are skipped with aggregate counts and a
partial-scan notice; no private names or parser source are logged. Empty repos
are skipped only when a tree request returns 409 and repository metadata reports
zero size. Authentication errors, inaccessible repositories, GraphQL errors and
truncated trees abort the scan rather than presenting an incomplete inventory.

## Setup and rollout

Install a GitHub App on **all lgtm-hq repositories**, with repository
**Contents: read** (and implicit Metadata: read) only. Store its credentials as
lgtm-ci repository secrets `DUPLICATION_SCAN_APP_ID` and
`DUPLICATION_SCAN_APP_PRIVATE_KEY`. App setup is tracked under
[#1233](https://github.com/lgtm-hq/lgtm-ci/issues/1233).

A prerequisite job checks for both secrets and `catalog/local-exceptions.yml`.
If any are absent, it succeeds with a skip notice and the scan job is skipped.
When present, it uses an App JWT to verify the installation has
`repository_selection: all` and Contents: read before minting the source token.
A partially installed App fails this check. The temporary signing key is deleted
immediately after signing; credentials and installation responses are not logged.

`GH_READ_TOKEN` reads source. Issue reads and writes use the job's separate
repository-scoped `GH_TOKEN` with Contents: read and Issues: write. Both jobs use
the literal `ubuntu-26.04` runner, pinned actions and block-mode harden-runner.
The dedicated `duplication-scan` egress preset is registered in
`scripts/ci/lib/egress/presets.sh`; generated workflow maps are maintained by
`scripts/ci/egress/sync-workflow-presets.sh`. It permits only `github.com:443` and
`api.github.com:443`. No package installation or consumer source checkout is
needed.

Live reporting requires repository variable `DUPLICATION_SCAN_LIVE_ENABLED` to
be `true`. Otherwise schedules and dispatches are dry-runs. Once enabled,
schedules report live and manual dispatches honor `dry-run` (default true).
Before enabling it:

1. Merge #1236 and apply its local exceptions.
2. Configure the read-only App and verify its installation covers the org.
3. Rerun the audit, tune the public near-match threshold if useful, and triage
   candidates against existing adoption trackers. The historical
   [audit](duplication-scan-audit.md) records the first provisional findings.
   Post the reviewed summary on
   [#1237](https://github.com/lgtm-hq/lgtm-ci/issues/1237).
4. Link existing adoption trackers or resolve their copies before the first live
   run. Confirm `ci` and `needs-triage` labels exist on lgtm-ci.

## Local commands

Source reads use `GH_READ_TOKEN` or the local `gh` login, discarding `GH_TOKEN`
and `GITHUB_TOKEN` so a repository-only Actions token cannot narrow the source
inventory. Local login visibility must be checked separately; the App
installation check runs in the workflow. Issue reads use `GH_TOKEN` or the local
login. The system Python needs PyYAML, as do the catalog scripts. No scanned
source is cached.

```sh
/usr/bin/python3 scripts/ci/maintenance/duplication_scan.py --dry-run=true \
  --report /tmp/duplication-scan.md
```

A provisional read-only audit may explicitly use `--allow-missing-exceptions`
when the prerequisite file is absent. This option is rejected with
`--dry-run=false`. `--threshold` accepts `(0, 1]`; `--max-new-issues` accepts 0
through 5. Writes require an explicit `--dry-run=false` and a repository-scoped
`GH_TOKEN`.
