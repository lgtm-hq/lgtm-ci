# Cross-repository duplication scan

`.github/workflows/duplication-scan.yml` reads non-archived lgtm-hq repositories
each Monday at 03:37 UTC, with lgtm-ci's catalog as the reference implementation.
It also supports manual dispatch. Repository code is read as immutable Git
blobs, held in memory, and never executed. Only the public-safe Markdown report
is written to the step summary.

The scanner covers workflow jobs (`.yml` and `.yaml`), composite actions, and
scripts under `scripts/` and `.github/scripts/`. It removes comments, normalizes
spacing, action refs, repository/image names, paths and versions, and treats
action input values as parameters. Ordered operation shingles and script token
shingles use a configurable Jaccard threshold, initially **0.8**. A candidate
also needs identical normalized control structure: similarity alone is not
evidence that differences can be inputs. Step ordering, conditions, Python
indentation and shell command boundaries remain significant. Called scripts
are compared by normalized body when their local filename is unambiguous;
unresolved script names retain their identity. This conservative first version
can miss copies with renamed variables, extra setup steps, or indirect script
dependencies. All admitted candidates currently score 1.0 after normalization.

Two consumer repositories qualify a cluster; one consumer qualifies when it
matches a catalog implementation. Reusable-workflow calls and jobs composed
entirely of lgtm-ci actions plus hardening/checkout are already adoption and
are skipped. Catalog entry points and directly referenced scripts form
the reference set. Exact `repo`, `path`, optional `job`, `reason`, and `link`
entries in `catalog/local-exceptions.yml` suppress local exceptions. Missing or
invalid allowlists fail before any reporting. That file and its final schema
belong to prerequisite [#1236](https://github.com/lgtm-hq/lgtm-ci/issues/1236);
reconcile the reader with its final schema when it merges.

Each logic fingerprint gets one issue with `ci` and `needs-triage` labels. The
fingerprint excludes the current member list, so adding a repository updates
the existing issue. Every page of open and closed issues is read before
writing; an API error aborts reporting. Not-planned closures stay silent;
completed closures reopen with a comment when the copy is found again. At most
five new issues are created per run; deferred candidates remain in the summary.
Private members contribute only repository and path to report text, never job
names, input names/values, snippets or suggested names derived from their code.

## Setup and rollout

The existing fixture App is scoped to an external fixture, and the runner
governor App has organization-variable permissions. Neither is an org-wide
read-only source reader. Setup still needed under
[#1233](https://github.com/lgtm-hq/lgtm-ci/issues/1233): install a GitHub App on
**all lgtm-hq repositories**, with repository **Contents: read** (and implicit
Metadata: read) only. Store its credentials as lgtm-ci repository secrets
`DUPLICATION_SCAN_APP_ID` and `DUPLICATION_SCAN_APP_PRIVATE_KEY`. The token action
requests only Contents: read and scopes the installation to owner `lgtm-hq`.
It needs access to private repos as well as public ones; a partially installed
App produces an incomplete inventory.

`GH_READ_TOKEN` reads source, while the job's separate `GH_TOKEN` is the
repository-scoped Actions token with Contents: read and Issues: write. The job
uses the literal `ubuntu-26.04` runner, a 30-minute timeout, pinned actions and
block-mode harden-runner. Its dedicated `duplication-scan` egress preset permits
only `github.com:443` and `api.github.com:443`, supplied as a job-start literal
map because this standalone workflow does not consume reusable presets. No
package installation or source checkout from scanned repositories is needed.

Live reporting is gated by repository variable
`DUPLICATION_SCAN_LIVE_ENABLED=true`. Until it is set, schedules and dispatches
are dry-runs regardless of the input. Once enabled, schedules report live and
manual dispatches honor `dry-run` (default true). Before enabling it:

1. Merge #1236, reconcile the final allowlist schema and apply its exceptions.
2. Configure the read-only App and confirm its installation covers the org.
3. Rerun the audit and triage candidates against existing adoption trackers.
   The initial [audit](duplication-scan-audit.md) records the first findings and
   tracker decisions. Post the reviewed summary on
   [#1237](https://github.com/lgtm-hq/lgtm-ci/issues/1237).
4. Resolve tracked copies or establish their dedupe linkage before the first live
   run, so an existing adoption issue is linked rather than duplicated. Local
   exceptions need a concrete technical reason under #1236. Confirm `ci` and
   `needs-triage` labels exist on lgtm-ci.

The initial implementation session was explicitly prohibited from making live
GitHub writes, so posting the summary and adding the owner setup checklist item
remain pending. The schedule is present but live issue creation stays gated.

## Local commands

Uses the current `gh` login for reads when `GH_READ_TOKEN` is absent; source
reads discard `GH_TOKEN` and `GITHUB_TOKEN` to avoid accidentally using the
repository-only Actions token. The system Python needs PyYAML, as do the catalog
scripts. No scanned source is cached.

```sh
/usr/bin/python3 scripts/ci/maintenance/duplication_scan.py --dry-run=true \
  --report /tmp/duplication-scan.md
```

While #1236 is unmerged, a provisional read-only audit may explicitly use
`--allow-missing-exceptions`. This option is rejected with `--dry-run=false`.
Adjust `--threshold` within `(0, 1]` and record the tuned value in the audit;
`--max-new-issues` accepts 0 through 5. Writes require an explicit
`--dry-run=false` and a repository-scoped `GH_TOKEN`.

Runner-default automation and the `STANDARD_RUNNER` constant belong to
[#1230 / PR #1239](https://github.com/lgtm-hq/lgtm-ci/pull/1239). This change adds
neither, and does not edit any of that PR's files. Its custom manager covers
reusable runner defaults; this standalone workflow keeps a literal `runs-on`
label for the existing GitHub Actions manager. Recheck the combined runner
contract and Renovate coverage after the PR merges.
