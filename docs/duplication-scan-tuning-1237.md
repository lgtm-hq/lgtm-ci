# Duplication scan tuning and recall check for #1237 (2026-11-05)

Requested by the owner when approving the whole-workflow holy-grail triage:

1. add a minimum unit size so tiny generic scripts cannot create issues;
2. report the top near-miss scores below the threshold, then retune;
3. check recall against the known cases and classify every miss.

## Snapshot

Read-only local snapshot of the default branches of all **21** non-archived,
non-fork consumer repositories (six private), taken on 2026-11-05 with REST
`GET` requests only: 1,984 requests, zero skipped or oversized sources, no
truncated trees. The production `GitHub.files`, parser and model ran unchanged;
local exceptions were applied. Result: **701 consumer units** and **651 catalog
units**. Snapshot source was deleted after analysis. No workflow was dispatched
and no issue was written.

## 1. Minimum unit size

New gate: a script needs **3 operative commands** before it can be a cluster
member or match the catalog. Commands are split at newlines and at `;`, `&&`,
`||` and `|`. Reporting, exit and shell-option commands (`echo`, `printf`,
`exit`, `return`, `set`, `true`, `:`, `shift`; Python `print`, `return`, `raise`,
`sys.exit`) do not count. Neither do imports, docstrings, function headers,
condition heads (`if`, `while`, `[`, `test` and the Python equivalents) or block
delimiters (`then`, `else`, `fi`, `done`, `}` and so on). Wrapping a failure
message in `if`/`else` or a function therefore cannot inflate the count; a
semicolon-joined line is counted command by command. A script with any opaque
(uninspected) region is never undersized: the gate must not be what hides it.
Such scripts stay keyed to their repository and cannot match across repositories
anyway. Jobs and composite actions keep their existing rules.

<!-- markdownlint-disable MD013 -->
| Minimum | Qualifying clusters | Members |
| ---: | ---: | --- |
| 0 (off) | 1 | holy-grail `scripts/ci/fail-audit.sh` (0 operative commands) |
| 1 | 0 | none |
| 2 | 0 | none |
| 3 (chosen) | 0 | none |
| 4 | 0 | none |
| 5 | 0 | none |
<!-- markdownlint-enable MD013 -->

The 13 consumer scripts that normalize fully (no opaque region) measure 0, 0,
0, 0, 0, 0, 1, 1, 2, 2, 6, 6 and 8 operative commands. The six zeros only test
conditions, report or exit: `fail-audit.sh`, `publish-swift.sh`,
`fail-release-push.sh`, `determine-target-sha.sh` (selects a SHA with `if` and
`echo` to the step output), `frontend-presence.sh` and an empty `__init__.py`.
The 1–2 group is single-tool setup: `generate-sbom.sh`, `install_plane_gate.py`,
`configure-git.sh` and `install-ruby-deps.sh`. 3 is the smallest value that
excludes both groups; the next scripts (6–8) are real programs. Every value from
1 to 5 removes the only current issue (`fail-audit.sh`) with no change to job or
action clusters.

## 2. Near misses and threshold retune

Scored pairs: every public, cross-repository pair of the same kind, against
consumers and the catalog, excluding exact matches.

| Pairs | Count |
| --- | ---: |
| Public pairs scored (after the size gate) | 213,621 |
| Score above 0.000 | 78 |
| Score at or above 0.100 | 3 |
| Score at or above 0.150 | 1 |
| Score at or above 0.200 | 0 |
| Highest score | 0.157 |

The pair count includes scripts with opaque regions, which the gate never
excludes. They score 0 against everything, because each marker is keyed by
repository.

Top ten near misses (all below 0.800):

<!-- markdownlint-disable MD013 -->
| Score | Left | Right | Review |
| ---: | --- | --- | --- |
| 0.157 | homebrew-tap `scripts/ci/read_pypi_sdist.py` | py-lintro `scripts/utils/extract_comment_body.py` | unrelated; shared Python JSON boilerplate |
| 0.134 | homebrew-tap `scripts/ci/read_pypi_sdist.py` | py-lintro `scripts/utils/find_comment_with_marker.py` | unrelated |
| 0.108 | homebrew-tap `scripts/ci/probe_dist_version.py` | py-lintro `scripts/utils/extract_comment_body.py` | unrelated |
| 0.093 | homebrew-tap `scripts/ci/probe_dist_version.py` | py-lintro `scripts/utils/find_comment_with_marker.py` | unrelated |
| 0.091 | homebrew-tap `scripts/ci/probe_dist_version.py` | py-lintro `scripts/ci/generate-tool-versions.py` | unrelated |
| 0.087 | homebrew-tap `scripts/ci/read_pypi_sdist.py` | py-lintro `scripts/ci/generate-builtin-tool-index.py` | unrelated |
| 0.086 | ai-skills `scripts/ci/npm/manifest_yaml_boundary_tests.py` | py-lintro `scripts/ci/github_api.py` | unrelated |
| 0.082 | homebrew-tap `scripts/ci/read_pypi_sdist.py` | py-lintro `scripts/ci/generate-tool-versions.py` | unrelated |
| 0.077 | homebrew-tap `scripts/ci/probe_dist_version.py` | py-lintro `scripts/ci/generate-builtin-tool-index.py` | unrelated |
| 0.072 | ai-skills `scripts/ci/npm/renovate_helpers.py` | py-lintro `scripts/ci/github_api.py` | unrelated |

<!-- markdownlint-enable MD013 -->

Without the size gate the top of the list was boilerplate (0.500
`publish-swift.sh` vs a catalog one-liner, 0.444 `fail-audit.sh` vs
`publish-swift.sh`); the gate now also filters near misses.

**Decision: keep 0.800.** No real copy scores anywhere in 0.16–0.80, so the
threshold has no evidence to move on. Lowering it to reach the top pair (0.157)
would only surface unrelated scripts. The known copies in section 3 score
0.000, not just under the line, because of normalization, so the threshold is
not the limiting factor. Every report now prints the top ten near misses, so
the next real-data run shows whether a lower value becomes useful.

## 3. Recall check against known cases

Model score is the scanner's ordered-shingle Jaccard. Lexical score is a
diagnostic only (3-token shingles of comment-stripped source, with 40-character
SHAs and the repo name masked); it is not part of the scanner and shows how
similar the raw text actually is.

### GHCR tag sweep: py-lintro and Rustume (named in #1237/#1238)

<!-- markdownlint-disable MD013 -->
| Pair | Model | Lexical | Verdict |
| --- | ---: | ---: | --- |
| py-lintro `ghcr-cleanup.yml` job `sweep-ci-tags` vs Rustume `ghcr-cleanup.yml` job `prune-tagged` | not scored | 0.213 | **Deliberate exclusion** + drift |
| py-lintro job `sweep-sha-tags` vs Rustume `prune-tagged` | not scored | 0.210 | as above |
| py-lintro `sweep-ci-ghcr-tags.sh` vs Rustume `ghcr-prune-tags.sh` | 0.000 | 0.089 | **Drifted** |
| py-lintro `delete-ci-ghcr-tags.sh` vs Rustume `ghcr-prune-tags.sh` | 0.000 | 0.131 | **Drifted** |

<!-- markdownlint-enable MD013 -->

- Rustume's `prune-tagged` job is allowlisted in `catalog/local-exceptions.yml`
  (Rustume#266, the #1236 seed), so the scanner skips it by design.
- The scripts no longer share an implementation. py-lintro sweeps `ci-*`/`sha-*`
  tags by tag prefix with TOCTOU and digest-reachability guards (py-lintro#1652,
  #1666, #2669); Rustume prunes `main`/`sha-*`/pre-release tags by retention age.
  At 0.09–0.13 lexical overlap they are different programs that solve the same
  problem. A token threshold cannot and should not cluster them. The
  normalization also leaves both opaque (backslash continuations), which is a
  second gap, but even fully resolved they would not be parameter-only copies.
- Both repositories already call `reusable-ghcr-cleanup` for untagged pruning.
  The remaining shared need is a tagged-retention input on that reusable, which
  is a design gap to raise under #1238 or py-lintro#976, not a scanner miss.

### 31 Oct 2026 audit (docs/duplication-scan-audit.md)

<!-- markdownlint-disable MD013 -->
| Audit cluster | Model | Lexical | Verdict |
| --- | ---: | ---: | --- |
| holy-grail `scripts/ci/fail-audit.sh` → `reusable-security-audit` | 1.000 (exact) | — | Found; now **gated by size**, owned by the approved whole-workflow migration |
| holy-grail `pr-labeler.yml` `label` vs turbo-themes `pr-labeler.yml` `label` | 0.000 | 0.706 | **Normalization gap** (plus runner drift) |
| podex-ops `scripts/install-tflint.sh` vs rustume-ops `scripts/ci/terraform/install-tflint.sh` | 0.000 | 1.000 | **Normalization gap** |

<!-- markdownlint-enable MD013 -->

- **tflint installer.** The two private copies differ only in comments and the
  `mktemp` prefix (`podex-ops-tflint` / `rustume-ops-tflint`), a parameter-only
  difference. The script uses `${1:-${TFLINT_VERSION:-0.64.0}}`-style default
  expansions, so `shell_opacity` returns `shell-expansion` and the whole script
  becomes an opaque marker hashed with the repository name. Opaque units can
  never match across repositories. It still matched in the 31 Oct audit, so a
  later fail-closed normalization change made it opaque.
- **PR labeler.** Both jobs run the same `actions/labeler` step. Two
  differences: holy-grail now resolves its runner through
  `vars.LGTM_CI_RUNNER || 'ubuntu-26.04'` while turbo-themes pins
  `ubuntu-24.04` (real drift), and the harden-runner `allowed-endpoints` value
  (one line vs two lines) falls into an opaque region keyed by repository. The
  runner expression is the kind of input a reusable absorbs, so this is still
  a parameter-only copy that the normalizer misses. turbo-themes' job also
  matches `reusable-pr-labeler`, and py-lintro already calls that reusable.

### October manual audit (py-lintro 5, turbo-themes 13 jobs with an existing reusable)

That audit's job list was not recorded in #1237, #1238 or the wiki, so the
original 18 jobs cannot be scored individually. Best available reconstruction:

- **Adoption since October.** py-lintro now calls lgtm-ci reusables from 48
  jobs and turbo-themes from 22. Of the reusable families named in
  py-lintro#976, py-lintro now calls vulnerability suppression, GHCR untagged
  cleanup, scorecards and the Homebrew trigger. It does not call
  `reusable-security-audit`: its `dependency-vuln-gate.yml` job builds an SBOM
  and runs the shared `scan-vulnerabilities` action instead, a different
  contract (SBOM scan rather than the Lintro audit container). turbo-themes now calls
  `reusable-security-audit`, `reusable-publish-security-audit-comment`,
  `reusable-test-e2e-playwright` and the build/deploy reusables.
- **Remaining local jobs.** Every one of py-lintro's 44 and turbo-themes' 24
  remaining local workflow jobs was scored against all 651 catalog units. All
  68 have model similarity 0.000 and no catalog subsequence candidate. The
  highest lexical overlap with any reusable is 0.138. They are product-specific
  (dogfood, AI review, publishing gates, theme generation) or allowlisted
  (#1236).

Verdict: the October jobs have **mostly been adopted since (drift through
migration)**. Exact job-to-reusable recall is unmeasurable without the original
list. If the owner has it, it can be scored with the retained harness.

## Normalization gaps found

The recall check exposes one systemic limit. Of the 560 consumer scripts, only
**13** normalize without an opaque region; the other 547 are a single
repository-keyed marker (115 backslash continuations, 83 unproven forwarding,
81 Python f-strings, 57 shell expansions, 50 heredocs, and others). These
markers are fail-closed by design: they stop unrelated logic from matching. But
they also make every non-trivial script copy invisible to clustering. Opaque
regions inside jobs (242 `script-write`, 38 `shell-command`) have the same
effect on job clusters.

Proposed follow-up, as a separate change: hash an opaque region by its
normalized source instead of by repository and path. Literal copies (tflint)
would then match. Behavior-affecting variation would still differ, and the
match would stay manual-review only until reviewed. Not implemented here; this
PR is limited to the three requested changes.

## Reproduction

The harness and results are retained outside the repository under
`ci-runner/research/1237-tuning-r2/` (`fetch.py`, `load.py`, `retune.py`,
`recall.py`, `best.py`).

Part of #1237.
