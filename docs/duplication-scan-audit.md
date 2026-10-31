# Initial duplication audit: 2026-10-31

Read-only audit for [#1237](https://github.com/lgtm-hq/lgtm-ci/issues/1237).
**Historical and provisional:** the allowlist was absent during this audit, so
local exceptions were not applied. No GitHub issues, comments or other remote
state were changed. Later review fixes changed normalization and fingerprints;
these counts and identifiers describe only the original audit. Rerun and triage
a fresh report before enabling live reporting or posting results on #1237.

The final scan read **21 non-archived consumer repositories**, including the
six private repositories visible to the local login. It considered **699 units**
and found **3 qualifying clusters**, all with normalized Jaccard similarity
**1.000**. The threshold remains **0.800**, the initial value; no broader
similarity tuning is claimed. Dedupe found no existing cluster markers and would
create three issues, below the cap of five. The initial four-cluster report also
included jobs already calling shared lgtm-ci actions; those are now skipped.

## Candidate triage

<!-- markdownlint-disable MD013 -- audit reference table -->

| Fingerprint | Members | Proposed adoption and inputs | Tracker decision |
| --- | --- | --- | --- |
| `2a01acce15d589486113dcb2` | `lgtm-hq/holy-grail`: `scripts/ci/fail-audit.sh` | Already matches the helper shipped through `reusable-security-audit`; adopt that implementation rather than introduce another reusable. No additional input is evident from the exact copy. | None of the five named trackers directly tracks this holy-grail copy. A new adoption candidate after #1236 exceptions are applied. |
| `be07b2bf712a9bd5738d7046` | `lgtm-hq/podex-ops`: `scripts/install-tflint.sh`; `lgtm-hq/rustume-ops`: `scripts/ci/terraform/install-tflint.sh` | Owner triage required. | Owner triage required. |
| `c85aac82335c4e01cc8d1ebd` | `lgtm-hq/holy-grail`: `.github/workflows/pr-labeler.yml` (job `label`); `lgtm-hq/turbo-themes`: `.github/workflows/pr-labeler.yml` (job `label`) | Adopt the existing `reusable-pr-labeler` workflow. Candidate parameters: token source and `sync-labels`, retaining the shared egress policy. This catalog association was identified during manual triage. | Existing turbo-themes trackers #1051, #1021 and #1066 address different paths/behavior, so link them as context without duplicating their tasks. |

<!-- markdownlint-enable MD013 -->

Only repository names and paths are recorded for private members. No private
job names, source, parameters or snippets are included.

## Existing tracker review

All five required trackers were read and were open at the time of this audit:

- [lgtm-ci#1083](https://github.com/lgtm-hq/lgtm-ci/issues/1083): repair and
  external-proof adoption epic. Keep its repair tasks there; these findings
  do not refile its completed infrastructure fixes.
- [lgtm-ci#1051](https://github.com/lgtm-hq/lgtm-ci/issues/1051): turbo-themes'
  removed PR-comment actions and scripts. No matching scanner candidate for
  those paths; absence from a conservative scan does not resolve the tracker.
- [py-lintro#976](https://github.com/lgtm-hq/py-lintro/issues/976): broad adoption,
  including GHCR cleanup, security audit, publishing and Homebrew. None of the
  three candidates belongs to py-lintro. Keep its existing tasks there.
- [turbo-themes#1021](https://github.com/lgtm-hq/turbo-themes/issues/1021): npm
  package-set publishing and release failure reporting. The labeler candidate
  does not duplicate this publishing migration.
- [turbo-themes#1066](https://github.com/lgtm-hq/turbo-themes/issues/1066): remove
  the dead internal-ref updater and its scripts. No candidate for those paths;
  retain the existing removal issue.

These are initial triage recommendations. Merge/apply #1236, configure the
org-wide read App, rerun the scan, review the candidates and post a fresh summary
before setting `DUPLICATION_SCAN_LIVE_ENABLED=true`. The scan does not establish
that repositories without findings are free of duplication: extra steps,
renamed variables and indirect dependencies can prevent a conservative match.

## Command and result

<!-- markdownlint-disable MD013 -- preserve the exact executed command -->

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/ci/maintenance/duplication_scan.py --dry-run=true --allow-missing-exceptions --report /tmp/lgtm-ci-1237-audit.md > /tmp/lgtm-ci-1237-scan.log 2>&1
```

<!-- markdownlint-enable MD013 -->

Exit status **0**: one completed final audit, zero API writes, three candidates.
The generated public-safe report was inspected and summarized above. Earlier
dry-runs informed the false-positive fixes; only the final inventory is quoted
here. No scanned source was persisted.
