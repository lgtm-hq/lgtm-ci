# Catalog subsequence tuning for #1237

Audit date: 2026-11-04. Integrated catalog main: `9caf40e256d91803b9fffd6a816f07ff2a1314c2`.
The measurements below describe the **pre-R1 matcher at `72df763`**. R1 repairs
input validation, main derivation and infrastructure exclusion. The completed
local R1 audit at `96730ee` was partial: one invalid source in Rustume was a valid
bare `workflow_call` event. It does not establish zero-omission tuning acceptance.
R2 restores empty optional mappings; fresh tuning against all 21 repositories
remains required after R2. The original measurements and raw evidence below
remain historical.
Fresh default-branch snapshots cover all 21 consumer repositories: 698 model units,
133 workflow jobs, and 651 catalog units. All skipped counters are zero.

## Method

The local read-only harness calls the integrated production `GitHub.files`,
`read_blobs`, dependency discovery and model without executing scanned source.
It translates only the blob-query transport into immutable REST blob GETs.
Every network operation uses
`env -u GITHUB_TOKEN -u GH_TOKEN -u GH_READ_TOKEN gh api --method GET --paginate ...`
with the local authenticated user. The unchanged 256 KiB bound and
binary/invalid-source counters remain enforced. It fetched 1951 files through
1,973 GETs; recursive trees were not truncated. The model audit completed in
355.1 seconds.

This is a local snapshot/model audit, not a hosted workflow execution or an
independent App installation coverage proof. The previously completed hosted
zero-omission run 41785928729 satisfied that separate prerequisite. No workflow
was dispatched here. Local raw org/tree metadata, request hashes, per-repository
coverage and classifications are retained for verification; temporary source
snapshots were deleted after review.

The [rule and normalization](duplication-scan.md#catalog-subsequence-candidates)
use one core operation per top-level step, without composite expansion. Production
adoption and local-exception exclusions apply unchanged. Both main-sharing
consumer/reference pairs in this fresh audit are the two results below; both
public workflows were read for classification. Unsupported primary anchors and
additional consumer operations remain conservative recall limits.

The 2026-11-01 audit is historical: it omitted one genuine oversized dependency
and does not establish current coverage or tuning. The fresh audit above replaces
that evidence; no source limit, privacy rule or reconciliation guard was weakened.

## Every new result

<!-- markdownlint-disable MD013 -->

| Repository         | File                                               | Job               | Matched reusable                          | Shared core steps | Review                                                                                                                    |
| ------------------ | -------------------------------------------------- | ----------------- | ----------------------------------------- | ----------------: | ------------------------------------------------------------------------------------------------------------------------- |
| lgtm-hq/holy-grail | `.github/workflows/security-dependency-review.yml` | `security-audit`  | `reusable-security-audit`                 |                 3 | REAL COPY: container preparation, main security audit, and failure gate preserve the reusable's ordered roles.            |
| lgtm-hq/holy-grail | `.github/workflows/security-dependency-review.yml` | `post-pr-comment` | `reusable-publish-security-audit-comment` |                 1 | REAL COPY: the main comment action publishes the same security-audit marker; all other steps are excluded infrastructure. |

<!-- markdownlint-enable MD013 -->

There were no private-repository candidates and no observed false positives.
The six private repositories are represented publicly only as private repo (1)
through private repo (6), without paths or source-derived details.

## Threshold comparison

|   N | Results | REAL COPY | FALSE POSITIVE | Known copies missed    |
| --: | ------: | --------: | -------------: | ---------------------- |
|   1 |       2 |         2 |              0 | None                   |
|   2 |       1 |         1 |              0 | holy-grail comment job |
|   3 |       1 |         1 |              0 | holy-grail comment job |
|   4 |       0 |         0 |              0 | Both holy-grail jobs   |

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
- No additional confirmed whole-job hand copies were identified in this fresh
  main-sharing review. This does not claim exhaustive knowledge of every hand copy
  or validate arbitrary script bodies that happen to share a basename.
- Reusables with no primary script/file-input anchor and jobs with additional
  consumer-only operations remain outside this conservative category. Script
  basename/role normalization is a review hint, not proof of equal script bodies.

## Similarity-clause decision

Actual Jaccard scores from the unchanged `Unit.features` ordered shingles:

| holy-grail job    | `reusable-security-audit` | `reusable-publish-security-audit-comment` |
| ----------------- | ------------------------: | ----------------------------------------: |
| `security-audit`  |                     0.000 |                                     0.000 |
| `post-pr-comment` |                     0.000 |                                     0.000 |

**Drop the similarity clause from the new rule.** A positive similarity floor
loses both motivating copies. There is no demonstrated additional recall without
false positives from a Jaccard alternative on this audit, so no such alternative
is included. The pre-existing public near-match report remains separate.

## Publication guarantee

Subsequence candidates are computed after issue reconciliation and rendered only
in their own manual-review heading. They never enter the issue findings list and
carry no issue identity marker. The live-mode offline test runs with
`--dry-run=false`, requires both
candidates in the report and asserts zero issue mutations. Synthetic fixtures
also set `DUPLICATION_SCAN_LIVE_ENABLED=true` to reflect workflow configuration;
that variable guards the workflow and is not read by the CLI. Fixtures
also cover minimum counts, ordering, missing main, single-script rejection,
already-adopted workflows, comment-marker mismatches and private rendering.

Part of #1237.
