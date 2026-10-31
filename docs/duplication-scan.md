# Cross-repository duplication scan

`.github/workflows/duplication-scan.yml` reads non-archived, non-fork lgtm-hq repositories
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
Step ordering, conditions, shell command boundaries, and Python indentation and
numeric tokens also remain significant. Python operators retain their exact text,
including floor division `//` and augmented assignment `//=`. Python numeric tokens
retain their exact text, including floating-point and exponential constants; Python path/version
strings still normalize as parameters. Explicit local script paths resolve
exactly, including extensionless scripts and nested calls; cycles and unresolved
calls retain their repository-qualified identity, so unknown implementations
cannot match across repositories. Referenced programs outside the script directories and local
composite actions are read as additional immutable blobs. Suffix lookup expands
the blob inventory only; matching always resolves an exact execution path.
Step `working-directory` and workflow/job `defaults.run` remain significant;
relative script paths resolve against their effective directory. Quoted string
whitespace also remains significant. Script-looking arguments such as
`echo scripts/missing.sh` are data, not executable dependencies. The scanner
recognizes common keyword/group positions, simple `uv run`, `bun run`, `timeout`,
interpreter flags and option-free `sudo`, `nohup`, `command`, `env`, `exec` and
`time` wrappers. Unrecognized wrappers or options with possible executable paths
stay repository-specific; this bounded recognition does not parse arbitrary
shell syntax. For example, `xargs -n1 bash scripts/check.sh` stays unknown.
Shell blocks that change directories with `cd`, `pushd` or `popd` stay
repository-specific; their control flow is not modeled. Python process launchers,
including asyncio's subprocess helpers, also stay unknown until command
identities can be compared. Local, relative and third-party Python imports
keep the entrypoint repository-specific, even when helper source is available:
their implementations are not inspected. Standard-library imports remain
comparable unless an inventoried Python module or package could shadow them.
Local JavaScript/Docker actions, shell command substitutions, inline programs,
unresolved dynamic paths and cycles stay unknown. Bare names never use basename fallback.
Absence of findings does not establish absence of duplication.

Known follow-up: the shared text normalizer still masks bare dotted numbers in
non-Python scripts and workflow `run` blocks as versions. For example,
`sleep 0.5` and `sleep 30.0` have identical fingerprints and can qualify an
automatic issue. Distinguishing executable arguments from dependency/version
parameters needs command context, including quoted arguments; a numeric regex
alone cannot establish that distinction. Replace the blanket version mask in
those contexts with bounded recognition of known dependency/version parameters,
retaining executable decimal values and existing path/image normalization.
This remains deferred rather than adding a language parser in this revision.
Reproduce offline from the repository root (currently prints `True 1`):

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/ci/maintenance /usr/bin/python3 - <<'PY'
import duplication_model as model
units = [
    model.units(repo, False, {"scripts/check.sh": source})[0]
    for repo, source in (("org/left", "sleep 0.5"), ("org/right", "sleep 30.0"))
]
print(units[0].fingerprint == units[1].fingerprint,
      len(model.clusters(units, [], 0.8)))
PY
```

Two consumer repositories qualify a cluster; one consumer qualifies when it
matches a catalog implementation. Automatic issues require identical normalized
structure to establish parameter-only differences. Public near matches use
Jaccard similarity of ordered shingles and appear separately for manual review,
without creating issues. `--threshold` controls these suggestions; its default
is **0.8**. At most 20 public near matches are shown. Private source never appears
in these suggestions. Reusable-workflow calls and jobs composed entirely of
lgtm-ci actions plus hardening/checkout are already adoption and are skipped.
Catalog entry points and directly referenced scripts form the reference set.
For a catalog composite, equality compares the ordered operations and effective
step environment, shell and working directory. A consumer job still retains its
runner, dependencies and permissions when compared with other consumers; the
composite does not need job-only fields such as `runs-on`. Automatic matches
score 1.000; threshold tuning affects manual suggestions only. Forks are omitted
because upstream copies are not adoption candidates.

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
rejections. The current normalizer version is **2**; historical audit markers
are not current evidence. Every page of open and closed issues is read before writing; an API
error aborts reporting. Open issues refresh when membership changes or retained
generated source needs redaction. The marked member section is replaced, and
historical examples and input names are retained only while their source repository
remains the current public example; otherwise they are regenerated or removed.
Human notes remain intact. Web-edited CRLF bodies compare identically. Updates and
reopens refresh the count only on generated titles, preserving human titles.
Catalog matches use "adopt … from lgtm-ci" and singular "1 repo" wording.
Not-planned closures stay silent; completed closures reopen with a comment when
the copy is found again. At most five new issues are created per run; deferred
candidates remain in the summary. Untrusted identifiers and snippets cannot
inject scanner markers. Removing an issue's identity marker makes it unseen;
retain the marker when editing to avoid a duplicate candidate.

Private members contribute only repository and path to findings, never job
names, input names/values, snippets or suggested names derived from their code.
Markers are stable, unsalted logic digests, not a confidentiality boundary: a
person guessing a private implementation could confirm its normalized digest
offline. This is an accepted tradeoff for stable deduplication; private source
and job/input names remain excluded from public output.
The inventory lists public repository names and only a count for private repos.
Malformed, oversized and binary files are skipped with aggregate counts and a
partial-scan notice; no private names or parser source are logged. Partial
coverage blocks all issue reconciliation, including membership updates,
reopening and creation. Dry-runs still emit the partial report; live runs emit
it and fail. Existing membership is preserved until a complete scan. Empty repos
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
When present, it validates the allowlist and uses an App JWT to verify the
installation has
`repository_selection: all`, Contents: read and read-only values for every
installation permission before minting the source token. Additional write
permissions and malformed permission mappings fail this check, as does a
partially installed App. The temporary signing key is deleted
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
