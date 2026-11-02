# Control-plane runner repair: consumer inventory

Snapshot: 2026-10-31, for
[#1252](https://github.com/lgtm-hq/lgtm-ci/issues/1252) and
[#1231](https://github.com/lgtm-hq/lgtm-ci/issues/1231). This is historical
adoption evidence; its immutable pins are not Renovate update targets.

The read-only scan resolved every default branch in the 22 repositories returned
by `gh repo list lgtm-hq --limit 100` and the registered external fixture to a
commit SHA. It checked every `.github/workflows/*.yml` and `*.yaml` file at
those commits, plus the three blocked rollout PR heads. All repositories in
`catalog/consumers.yml` were included. Git tree listings were checked for
truncation. Each matching reusable definition was then read at the exact
40-character `uses:` pin, rather than inferred from a release tag or the default
branch. The scan covered 422 workflow files across 26 snapshots: 29 affected
default-branch calls and five rollout-head calls. Unknown external consumers and
other non-default branches are outside this inventory; no execution or
Actions-variable visibility is inferred from it.

## Affected definitions

These generic jobs used literal `ubuntu-latest` at every pin listed below. The
repair adds an optional string `runner-image` defaulting to `""`, with
precedence: explicit input, caller-visible `vars.LGTM_CI_RUNNER`, then
`ubuntu-26.04`. Existing job IDs, check-name inputs/defaults, permissions,
timeouts, event guards, harden-runner configuration and steps are preserved.

<!-- markdownlint-disable MD013 -->

| Reusable                         | Job ID              | Default check name  | Job permissions                          |
| -------------------------------- | ------------------- | ------------------- | ---------------------------------------- |
| `reusable-semantic-pr-title.yml` | `semantic-title`    | `Semantic PR Title` | `contents: read`, `pull-requests: write` |
| `reusable-pr-labeler.yml`        | `label`             | `PR Labeler`        | `contents: read`, `pull-requests: write` |
| `reusable-dependency-review.yml` | `dependency-review` | `Dependency Review` | `contents: read`, `pull-requests: read`  |

<!-- markdownlint-enable MD013 -->

Caller-supplied `job-name` values keep taking effect. Semantic title still
no-ops its PR-dependent steps on `merge_group`; dependency review retains its
PR/merge-group guard. CodeQL, Scorecard, gem publishing, trusted npm publishing,
platform/matrix runners and Docker coordinators keep their existing contracts.
The Docker classify/check-name work in #1241 is separate.

## Verified reusable pins

S = semantic PR title, L = PR labeler, D = dependency review. Each link opens
the affected definition at that immutable workflow pin. All ten linked
definitions have `runs-on: ubuntu-latest`.

<!-- markdownlint-disable MD013 -->

| Pin | Full lgtm-ci commit                        | Definitions read                                                                                                                                                                                                                                                                                                                                                                                                |
| --- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | `2097a900753e3e5ad0e336483501b278e99855ae` | [S](https://github.com/lgtm-hq/lgtm-ci/blob/2097a900753e3e5ad0e336483501b278e99855ae/.github/workflows/reusable-semantic-pr-title.yml), [L](https://github.com/lgtm-hq/lgtm-ci/blob/2097a900753e3e5ad0e336483501b278e99855ae/.github/workflows/reusable-pr-labeler.yml), [D](https://github.com/lgtm-hq/lgtm-ci/blob/2097a900753e3e5ad0e336483501b278e99855ae/.github/workflows/reusable-dependency-review.yml) |
| P2  | `710c7ba40bf7b48b4d7c3442e3b60fb4b542db91` | [S](https://github.com/lgtm-hq/lgtm-ci/blob/710c7ba40bf7b48b4d7c3442e3b60fb4b542db91/.github/workflows/reusable-semantic-pr-title.yml), [L](https://github.com/lgtm-hq/lgtm-ci/blob/710c7ba40bf7b48b4d7c3442e3b60fb4b542db91/.github/workflows/reusable-pr-labeler.yml)                                                                                                                                         |
| P3  | `8f0fd9339df5d30a529aa572ceb51345b8be33a0` | [S](https://github.com/lgtm-hq/lgtm-ci/blob/8f0fd9339df5d30a529aa572ceb51345b8be33a0/.github/workflows/reusable-semantic-pr-title.yml), [L](https://github.com/lgtm-hq/lgtm-ci/blob/8f0fd9339df5d30a529aa572ceb51345b8be33a0/.github/workflows/reusable-pr-labeler.yml), [D](https://github.com/lgtm-hq/lgtm-ci/blob/8f0fd9339df5d30a529aa572ceb51345b8be33a0/.github/workflows/reusable-dependency-review.yml) |
| P4  | `c40cd60334b5b5f2952e1af99e2e083be50c1620` | [S](https://github.com/lgtm-hq/lgtm-ci/blob/c40cd60334b5b5f2952e1af99e2e083be50c1620/.github/workflows/reusable-semantic-pr-title.yml), [L](https://github.com/lgtm-hq/lgtm-ci/blob/c40cd60334b5b5f2952e1af99e2e083be50c1620/.github/workflows/reusable-pr-labeler.yml)                                                                                                                                         |

<!-- markdownlint-enable MD013 -->

## Consumers at default-branch snapshots

All paths below are under `.github/workflows/`. Each call links to its consumer
source at the snapshot commit. Cells list `file:caller-job` and the reusable pin
above; a dash means the workflow is not called. No affected caller supplied
`runner-image` at these snapshots.

<!-- markdownlint-disable MD013 -->

| Repository                | Default-branch commit                      | S calls                                                                                                                                                                                      | L calls                                                                                                                                                    | D calls                                                                                                                                                                                           |
| ------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| lgtm-hq/agent-infra       | `2c24adc5badb36a68db51831e2c496371c8cc990` | [`ci.yml:semantic-title`](https://github.com/lgtm-hq/agent-infra/blob/2c24adc5badb36a68db51831e2c496371c8cc990/.github/workflows/ci.yml) (P2)                                                | —                                                                                                                                                          | —                                                                                                                                                                                                 |
| lgtm-hq/ai-skills         | `7e9c91fffbfa4ef08cf6a863cf68675ea50e3123` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/ai-skills/blob/7e9c91fffbfa4ef08cf6a863cf68675ea50e3123/.github/workflows/semantic-pr-title.yml) (P3)                    | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/ai-skills/blob/7e9c91fffbfa4ef08cf6a863cf68675ea50e3123/.github/workflows/pr-labeler.yml) (P3)         | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/ai-skills/blob/7e9c91fffbfa4ef08cf6a863cf68675ea50e3123/.github/workflows/dependency-review.yml) (P3)                      |
| lgtm-hq/hass-turbo-themes | `f68ba0373c699a2d1dc5030306674b3c48a06876` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/hass-turbo-themes/blob/f68ba0373c699a2d1dc5030306674b3c48a06876/.github/workflows/semantic-pr-title.yml) (P3)            | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/hass-turbo-themes/blob/f68ba0373c699a2d1dc5030306674b3c48a06876/.github/workflows/pr-labeler.yml) (P3) | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/hass-turbo-themes/blob/f68ba0373c699a2d1dc5030306674b3c48a06876/.github/workflows/dependency-review.yml) (P3)              |
| lgtm-hq/holy-grail        | `559403295d816ef19d13ffafbb50e7e57c2eebe1` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/holy-grail/blob/559403295d816ef19d13ffafbb50e7e57c2eebe1/.github/workflows/semantic-pr-title.yml) (P3)                   | —                                                                                                                                                          | —                                                                                                                                                                                                 |
| lgtm-hq/podex             | `63f217755f6515bd1eee7dc4b0e7052fc4c4d35d` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/podex/blob/63f217755f6515bd1eee7dc4b0e7052fc4c4d35d/.github/workflows/semantic-pr-title.yml) (P3)                        | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/podex/blob/63f217755f6515bd1eee7dc4b0e7052fc4c4d35d/.github/workflows/pr-labeler.yml) (P3)             | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/podex/blob/63f217755f6515bd1eee7dc4b0e7052fc4c4d35d/.github/workflows/dependency-review.yml) (P3)                          |
| lgtm-hq/podex-ops         | `53d5b9852e88d9fe2e4860a039699afae2ba02db` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/podex-ops/blob/53d5b9852e88d9fe2e4860a039699afae2ba02db/.github/workflows/semantic-pr-title.yml) (P2)                    | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/podex-ops/blob/53d5b9852e88d9fe2e4860a039699afae2ba02db/.github/workflows/pr-labeler.yml) (P2)         | —                                                                                                                                                                                                 |
| lgtm-hq/py-lintro         | `a18058001a83be7b202cbd1c41e77dfe4794446c` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/py-lintro/blob/a18058001a83be7b202cbd1c41e77dfe4794446c/.github/workflows/semantic-pr-title.yml) (P1)                    | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/py-lintro/blob/a18058001a83be7b202cbd1c41e77dfe4794446c/.github/workflows/pr-labeler.yml) (P1)         | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/py-lintro/blob/a18058001a83be7b202cbd1c41e77dfe4794446c/.github/workflows/dependency-review.yml) (P1)                      |
| lgtm-hq/Rustume           | `935e7ac4ab1a039f7148d7363b5d4f7e5b54a214` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/Rustume/blob/935e7ac4ab1a039f7148d7363b5d4f7e5b54a214/.github/workflows/semantic-pr-title.yml) (P3)                      | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/Rustume/blob/935e7ac4ab1a039f7148d7363b5d4f7e5b54a214/.github/workflows/pr-labeler.yml) (P3)           | [`dependency-review.yml:review`](https://github.com/lgtm-hq/Rustume/blob/935e7ac4ab1a039f7148d7363b5d4f7e5b54a214/.github/workflows/dependency-review.yml) (P3)                                   |
| lgtm-hq/rustume-ops       | `4dd000ce206de4029dfbc6ef3076cf2dd60341ce` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/rustume-ops/blob/4dd000ce206de4029dfbc6ef3076cf2dd60341ce/.github/workflows/semantic-pr-title.yml) (P2)                  | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/rustume-ops/blob/4dd000ce206de4029dfbc6ef3076cf2dd60341ce/.github/workflows/pr-labeler.yml) (P2)       | —                                                                                                                                                                                                 |
| lgtm-hq/spotify-curator   | `d926872c4a95703ada420ccf8e6a3573686c03d8` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/spotify-curator/blob/d926872c4a95703ada420ccf8e6a3573686c03d8/.github/workflows/semantic-pr-title.yml) (P3)              | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/spotify-curator/blob/d926872c4a95703ada420ccf8e6a3573686c03d8/.github/workflows/pr-labeler.yml) (P3)   | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/spotify-curator/blob/d926872c4a95703ada420ccf8e6a3573686c03d8/.github/workflows/dependency-review.yml) (P3)                |
| lgtm-hq/turbo-themes      | `a396231da0d782f0ab7f6fb824d3fe6d4f06d033` | [`quality-semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/turbo-themes/blob/a396231da0d782f0ab7f6fb824d3fe6d4f06d033/.github/workflows/quality-semantic-pr-title.yml) (P3) | —                                                                                                                                                          | [`security-dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/turbo-themes/blob/a396231da0d782f0ab7f6fb824d3fe6d4f06d033/.github/workflows/security-dependency-review.yml) (P3) |
| lgtm-hq/winnow            | `1d119752185fb3505e7e0d76143016653fdeb878` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/winnow/blob/1d119752185fb3505e7e0d76143016653fdeb878/.github/workflows/semantic-pr-title.yml) (P3)                       | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/winnow/blob/1d119752185fb3505e7e0d76143016653fdeb878/.github/workflows/pr-labeler.yml) (P3)            | [`dependency-review.yml:dependency-review`](https://github.com/lgtm-hq/winnow/blob/1d119752185fb3505e7e0d76143016653fdeb878/.github/workflows/dependency-review.yml) (P3)                         |

<!-- markdownlint-enable MD013 -->

## Blocked private rollout heads

These PRs are still open at the recorded snapshots. They adopt P4 (v0.80.0),
which leaves the affected control-plane jobs on `ubuntu-latest`. They must
advance to the reviewed release containing this repair; publishing this change
alone does not update an immutable consumer pin.

<!-- markdownlint-disable MD013 -->

| Rollout PR                                                                 | Head commit                                | S calls                                                                                                                                                                     | L calls                                                                                                                                              | D calls |
| -------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| [lgtm-hq/agent-infra#28](https://github.com/lgtm-hq/agent-infra/pull/28)   | `f30a6009f8e7de5abdca2c36d54ce010fe101e27` | [`ci.yml:semantic-title`](https://github.com/lgtm-hq/agent-infra/blob/f30a6009f8e7de5abdca2c36d54ce010fe101e27/.github/workflows/ci.yml) (P4)                               | —                                                                                                                                                    | —       |
| [lgtm-hq/rustume-ops#108](https://github.com/lgtm-hq/rustume-ops/pull/108) | `a5dabef9c94b46115f74f4b352776794534b6786` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/rustume-ops/blob/a5dabef9c94b46115f74f4b352776794534b6786/.github/workflows/semantic-pr-title.yml) (P4) | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/rustume-ops/blob/a5dabef9c94b46115f74f4b352776794534b6786/.github/workflows/pr-labeler.yml) (P4) | —       |
| [lgtm-hq/podex-ops#43](https://github.com/lgtm-hq/podex-ops/pull/43)       | `874582a34673e8bf084036fa3cde5e767a52ba1a` | [`semantic-pr-title.yml:semantic-title`](https://github.com/lgtm-hq/podex-ops/blob/874582a34673e8bf084036fa3cde5e767a52ba1a/.github/workflows/semantic-pr-title.yml) (P4)   | [`pr-labeler.yml:label`](https://github.com/lgtm-hq/podex-ops/blob/874582a34673e8bf084036fa3cde5e767a52ba1a/.github/workflows/pr-labeler.yml) (P4)   | —       |

<!-- markdownlint-enable MD013 -->

The payment/spending-limit rejections cited in #1252 remain failures to start,
not passing executions. A rerun on those old pins cannot validate this repair.
In particular, podex-ops label job `124551777015` and agent-infra semantic-title
job `124547597520` are the issue's reported examples, not new acceptance
evidence.

## Snapshots with no affected calls

These repositories were scanned too; absence here refers only to the three
reusables above. It does not establish readiness of their other jobs.

<!-- markdownlint-disable MD013 -->

| Repository                            | Default-branch commit                                                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| lgtm-hq/.github                       | [`99d514d66e9097b6872d2b0f484979405d888686`](https://github.com/lgtm-hq/.github/tree/99d514d66e9097b6872d2b0f484979405d888686/.github/workflows)                       |
| lgtm-hq/bunq                          | [`362eb621199c6d1b9fa8a0323209a4d64ba515b8`](https://github.com/lgtm-hq/bunq/tree/362eb621199c6d1b9fa8a0323209a4d64ba515b8/.github/workflows)                          |
| lgtm-hq/homebrew-tap                  | [`e9019b05d730f14a77d3fc2f3ddd78e6ee8ea009`](https://github.com/lgtm-hq/homebrew-tap/tree/e9019b05d730f14a77d3fc2f3ddd78e6ee8ea009/.github/workflows)                  |
| lgtm-hq/lgtm-ci                       | [`87708428d4b529f031e6ea2b059c5145d5f0db2b`](https://github.com/lgtm-hq/lgtm-ci/tree/87708428d4b529f031e6ea2b059c5145d5f0db2b/.github/workflows)                       |
| lgtm-hq/lintro-ops                    | [`206ae876101fee8456697ad228fe2a8bf6b10590`](https://github.com/lgtm-hq/lintro-ops/tree/206ae876101fee8456697ad228fe2a8bf6b10590/.github/workflows)                    |
| lgtm-hq/lintro-pre-commit             | [`4b85a569dda08c88328f828e11e0b1298b1310ba`](https://github.com/lgtm-hq/lintro-pre-commit/tree/4b85a569dda08c88328f828e11e0b1298b1310ba/.github/workflows)             |
| lgtm-hq/lintro-review-corpus          | [`cda5e94bad7bfe0df7ff0f6dd9254c955dfb4003`](https://github.com/lgtm-hq/lintro-review-corpus/tree/cda5e94bad7bfe0df7ff0f6dd9254c955dfb4003/.github/workflows)          |
| lgtm-hq/plugin-engine-lab             | [`92cdd87d5bf5e490c29e4507979c679883c49162`](https://github.com/lgtm-hq/plugin-engine-lab/tree/92cdd87d5bf5e490c29e4507979c679883c49162/.github/workflows)             |
| lgtm-hq/runner-network-diagnostics    | [`5a57262a33b422aa5c58f85906880a27cd2a3063`](https://github.com/lgtm-hq/runner-network-diagnostics/tree/5a57262a33b422aa5c58f85906880a27cd2a3063/.github/workflows)    |
| lgtm-hq/ui-framework                  | [`014bc65134c115d2470de0fb317f683998d6c15a`](https://github.com/lgtm-hq/ui-framework/tree/014bc65134c115d2470de0fb317f683998d6c15a/.github/workflows)                  |
| TurboCoder13/lgtm-ci-consumer-fixture | [`d1013b17044b976c98c9a1362f491b82ffadcc24`](https://github.com/TurboCoder13/lgtm-ci-consumer-fixture/tree/d1013b17044b976c98c9a1362f491b82ffadcc24/.github/workflows) |

<!-- markdownlint-enable MD013 -->

`lintro-ops`, `lintro-review-corpus` and `plugin-engine-lab` are in the private
rollout list recorded in #1231 but have no calls to these three workflows at
these snapshots. lgtm-ci's own control-plane workflows use local logic; this
inventory does not convert unrelated caller-owned jobs.

## Acceptance after publication and consumer upgrades

Local contracts prove the runner expression and its fallback coverage, not
GitHub scheduling or runner execution. The operator still needs to:

- Publish through the normal Sonnet and Opus reviews, CI and resolved-thread
  gates, then upgrade the blocked consumers to the reviewed immutable pin.
- Record run/job links and actual Blacksmith runner evidence for semantic title
  and labeler in the private rollout, and dependency review in a capable
  consumer. Preserve existing required check names and investigate real
  failures; do not bypass checks or treat payment rejections as green.
- With no explicit input, verify an unset or invisible `LGTM_CI_RUNNER` actually
  falls back to `ubuntu-26.04`, and record the run/job evidence. Verify that an
  explicit `runner-image` wins over a visible org variable.
- Capture harden-runner endpoint observations on Blacksmith as described in
  [Runner selection](workflow-contract.md#runner-selection), using an explicitly
  requested audit run before accepting block-mode behavior. Add hosts only from
  observations through the shared presets. No egress policy or allowlist is
  relaxed by this repair.

No variable, secret, credential, billing or spend-control changes are part of
this implementation. The prior #1231 Blacksmith proof covered other
variable-aware jobs; it does not satisfy acceptance for these repaired jobs.
