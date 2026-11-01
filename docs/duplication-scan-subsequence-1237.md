# Catalog subsequence tuning for #1237

Audit date: 2026-11-01. Catalog base: `f63b85534ce3a561f177c4ee3417b17c04f14a8b`.
The org inventory contained 22 repositories: lgtm-ci supplied the catalog and all
21 other repositories were scanned at their default-branch tree SHAs. No forks
or archived repositories were excluded from this particular inventory.

## Method

The production CLI requires an independent read-only App coverage proof even for
dry runs. The App secrets were unavailable locally, so a temporary read-only
harness used the local authenticated user instead. Every network request was
`env -u GITHUB_TOKEN gh api --method GET ...`, with `GH_TOKEN` and `GH_READ_TOKEN`
also removed from the subprocess environment. No scanned source was executed.

The harness fetched the org inventory, each default-branch recursive tree, selected
workflow/action/script blobs, and referenced dependencies using immutable blob
SHAs. All workflow and action definitions were available. A referenced oversized
test file was omitted under the production 256 KiB source bound; it is not a
workflow or action. The data lived only in a task-specific directory under
`$TMPDIR`, removed after the audit. The harness invoked the production model;
the four similarity measurements used its existing exact shapes and shingles.

The [rule and normalization](duplication-scan.md#catalog-subsequence-candidates)
use one core operation per top-level step, with no composite expansion. Reusables
without a deterministically identifiable primary input are conservatively omitted.
Both flagged jobs and the other jobs sharing an inferred main operation were read
for classification; this is not a claim to know every hand copy in the org.

## Every new result

<!-- markdownlint-disable MD013 -->

| Repository | File | Job | Matched reusable | Shared core steps | Review |
| --- | --- | --- | --- | ---: | --- |
| lgtm-hq/holy-grail | `.github/workflows/security-dependency-review.yml` | `security-audit` | `reusable-security-audit` | 3 | REAL COPY: container preparation, main security audit, and failure gate preserve the reusable's ordered roles. |
| lgtm-hq/holy-grail | `.github/workflows/security-dependency-review.yml` | `post-pr-comment` | `reusable-publish-security-audit-comment` | 1 | REAL COPY: the main comment action publishes the same security-audit marker; all other steps are excluded infrastructure. |

<!-- markdownlint-enable MD013 -->

There were no private-repository candidates and no observed false positives.
The six private repositories are represented publicly only as private repo (1)
through private repo (6), without paths or source-derived details.

## Threshold comparison

| N | Results | REAL COPY | FALSE POSITIVE | Known copies missed |
| ---: | ---: | ---: | ---: | --- |
| 1 | 2 | 2 | 0 | None |
| 2 | 1 | 1 | 0 | holy-grail comment job |
| 3 | 1 | 1 | 0 | holy-grail comment job |
| 4 | 0 | 0 | 0 | Both holy-grail jobs |

Choose **N=1**, retaining the independent exclusion for every one-core-step run job.
The comment job has exactly one core step after the mandated exclusions. Any
higher N necessarily loses that known copy. Single-script jobs still cannot
qualify, the reusable's main operation must be shared, and every consumer core
operation must fit in order. Comment markers distinguish security publishing from
other uses of the generic comment action. These semantic rules apply across the
inventory; no repository-specific allowlist or data pruning was used to remove
false positives. No false positives remained at the chosen N.

## Missed-copy review

- The old exact catalog matcher missed both holy-grail jobs above. N=1 catches
  both; N=2 and N=3 miss the comment job, and N=4 misses both.
- No additional confirmed whole-job hand copies were found while reading the
  other main-sharing candidates. In public `lgtm-hq/py-lintro`,
  `.github/workflows/docker-ci.yml` job `docker-build` shares Docker build actions
  but has fork handling, multiple image builds and tarball export absent from the
  compared Docker reusables. Its complete core sequence is not a subsequence.
- That same public workflow's `security-audit` job already calls the shared
  `post-pr-comment` action and also pulls/loads images and runs a different audit
  script. Sharing the comment action does not make its entire job a copy of the
  publish-comment reusable. It is correctly excluded by the full-sequence rule.
- Reusables with no primary script/file-input anchor and jobs with additional
  consumer-only operations remain outside this conservative category. Script
  basename/role normalization is a review hint, not proof of equal script bodies.

## Similarity-clause decision

Actual Jaccard scores from the unchanged `Unit.features` ordered shingles:

| holy-grail job | `reusable-security-audit` | `reusable-publish-security-audit-comment` |
| --- | ---: | ---: |
| `security-audit` | 0.000 | 0.000 |
| `post-pr-comment` | 0.000 | 0.000 |

**Drop the similarity clause from the new rule.** A positive similarity floor
loses both motivating copies. There is no demonstrated additional recall without
false positives from a Jaccard alternative on this audit, so no such alternative
is included. The pre-existing public near-match report remains separate.

## Publication guarantee

Subsequence candidates are computed after issue reconciliation and rendered only
in their own manual-review heading. They never enter the issue findings list and
carry no issue identity marker. The live-mode offline test sets
`DUPLICATION_SCAN_LIVE_ENABLED=true`, runs with `--dry-run=false`, requires both
candidates in the report and asserts zero issue mutations. Synthetic fixtures
also cover minimum counts, ordering, missing main, single-script rejection,
already-adopted workflows, comment-marker mismatches and private rendering.

Part of #1237.
