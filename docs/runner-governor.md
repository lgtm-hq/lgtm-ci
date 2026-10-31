# Runner governor

Part of #1232. The governor selects a runner for repositories opted into the
`LGTM_CI_RUNNER` org variable. Implementation and offline tests are available;
**live activation and live acceptance remain blocked** on usage accounting
proof and durable report reconciliation. The checked-in usage contract is
deliberately unverified. No field is claimed to measure Blacksmith's free-tier
usage yet.

The workflow runs on the literal `ubuntu-26.04`, independently of the switch.
After activation it evaluates hourly at minute 17, without overlapping runs.
The pure decision uses both usage inputs, even in a forced mode:

1. Blacksmith usage below its budget selects the configured Blacksmith label.
2. Otherwise, private GitHub Actions minutes below 95% of the included pool
   selects `ubuntu-26.04`.
3. Otherwise, the overage choice applies.

At equality a pool is exhausted. Blacksmith uses a UTC calendar cycle (owner
confirmed day 1); GitHub always uses the current UTC calendar month. Rollover
naturally restores Blacksmith without a separate reset job. Neither provider
usage nor an hourly poll is a hard spending cap. In-flight work and delayed
usage can consume the buffer; Blacksmith has no hard cap.

## Opt a repository in or out

An administrator owns the selected-repositories list on **Org settings → Secrets
and variables → Actions → Variables → LGTM_CI_RUNNER**. Tick a repository to opt
it in; untick it to opt it out. Keep visibility `selected`. The governor never
creates the variable, changes visibility, or changes repository selection.
It sends only `{"value": "<desired label>"}` in its PATCH, and only on a change.
It refuses a variable whose visibility is not `selected`.

Before opting in, make the consumer switch-ready:

- Its lgtm-ci pin includes #1231 (merged at
  `d743aff167112eb29db2c13ad3d5a8f74053a485`) and runner resolution.
- Generic consumer jobs use
  `${{ vars.LGTM_CI_RUNNER || 'ubuntu-26.04' }}`.
- The Blacksmith GitHub App is installed on the consumer repository.
- Explicit runner inputs and repository variables are understood: they can
  override this org switch. Trust Blacksmith for credentials, signing and OIDC
  on every affected job. Keep special platform and trusted-publishing pins.

High-volume public repositories, including py-lintro, remain outside the pool.
Removing access restores the default GitHub runner where no explicit override
exists. An administrator must perform these changes; this implementation does
not opt any repository in.

## Knobs

These optional org Actions variables must be visible to lgtm-ci, where the
workflow reads them. Empty values use defaults.

<!-- markdownlint-disable MD013 -->

| Variable | Default | Meaning |
| --- | --- | --- |
| `LGTM_CI_RUNNER_MODE` | `auto` | `auto`, forced `blacksmith`, or forced `github` |
| `LGTM_CI_RUNNER_BLACKSMITH_LABEL` | `blacksmith-2vcpu-ubuntu-2604` | Prefer 2 vCPU; larger runners consume the pool faster |
| `LGTM_CI_RUNNER_BUDGET_MINUTES` | `2700` | 2-vCPU-equivalent minutes; 300-minute buffer below 3,000 |
| `LGTM_CI_RUNNER_GITHUB_INCLUDED_MINUTES` | `3000` | Included private-repository GitHub minute pool |
| `LGTM_CI_RUNNER_OVERAGE` | `github` | `github` or `blacksmith` after both pools are spent |
| `LGTM_CI_RUNNER_CYCLE_DAY` | `1` | Blacksmith UTC reset day, bounded to 1–28 |
| `LGTM_CI_RUNNER_GOVERNOR_ENABLED` | unset | Exactly `true` permits scheduling; live changes also require the blocked acceptance work below |

<!-- markdownlint-enable MD013 -->

Set `MODE=github` to force GitHub, or `MODE=blacksmith` to deliberately select
Blacksmith. Both still require readable, validated sources. For an immediate
emergency when sources are broken, an administrator can disable scheduling and
change the switch value manually. Raising the budget above 3,000 deliberately
permits paid usage; changing the overage choice also permits paid usage.

## Credentials and data handling

The #1233 owner setup reports these existing lgtm-ci secrets:
`BLACKSMITH_ORG_TOKEN`, `RUNNER_GOVERNOR_APP_ID`, and
`RUNNER_GOVERNOR_APP_PRIVATE_KEY`; variable `BLACKSMITH_ORG=lgtm-hq`.
The governor App is `lgtm-runner-governor`, id 5547291. The workflow mints its
installation token with owner `lgtm-hq`.

The App requires org Variables read/write and org Administration read. The
owner confirmed HTTP 200 from the billing endpoint with Administration read.
The pinned token action has no org Variables permission input, so it retains
the App installation's permissions. Keep the App itself minimal. Repository
metadata read must cover **every repository attributed in the billing report**,
including metered repositories outside the opt-in pool. The setup reports the
App installed on lgtm-ci only; parent must demonstrate visibility coverage or
adjust installation access. Missing metadata fails closed, never means public.

Before activation, the parent must move the App private key and Blacksmith org
token into a protected Actions environment restricted to `main`, bind this job
to that environment, and review its deployment rules. The job and script both
require `refs/heads/main` before credential-bearing execution; that check does
not replace protecting credentials from other workflows or unreviewed code on
main. The script requires `SETUP_READY=true` exactly for network runs. Standalone
fixture previews need neither setting. No environment or secret is configured
by this revision.

Dry-runs do not receive `STATUS_TOKEN`. The App token still inherits Variables
write because the pinned token action cannot narrow that organization
permission. Review a separate read-only billing credential before activation
if dry-run least privilege requires it; do not widen the App installation.

A separate repository `github.token` with issues write reports status. Org
credentials are never used for repository status writes. There is no installed
secret retrieval. Blacksmith auth passes the org token through stdin to
`auth login --api-token - --non-interactive --organization lgtm-hq`. Child
processes have an isolated temporary HOME, cleaned on success and failure,
and receive no GitHub credentials. CLI output and diagnostics are captured,
never dumped. `BLACKSMITH_DISABLE_AUTO_UPDATE=1` prevents background updates.

Unreadable sources, missing aggregates, negative/non-finite/boolean numbers,
unknown private SKUs, wrong billing month, missing attribution and inconsistent
visibility fail before mutation. Public Actions minute rows and non-minute
usage are excluded. No net-dollar inference or summing limited Blacksmith
breakdown rows is used. No automatic write retries occur. A concurrent variable
change detected before PATCH aborts (GitHub offers no compare-and-swap here).

Each script invocation writes a step summary. The summary distinguishes
`value_changed` from `report_completed`; an already selected value proves
neither a prior governor change nor a completed report. Initial unchanged runs
and dry-runs write nothing. Live **changes currently fail before PATCH**, even
with verified usage and the enable variable set, because the old PATCH-then-POST
sequence could permanently lose a report. The guard is unconditional; there
is no environment flag that bypasses it. Existing main-failure reporting
observes failed workflow runs.

Status lookup requires an open issue titled `Runner governor status`, labeled
`infrastructure`, with the marker `<!-- lgtm-ci:runner-governor -->` on its first
nonblank line. Quoting the marker in #1232, a PR, or an arbitrary issue does not
qualify. Closed status issues remain history; the next known change creates a
new open status issue instead of commenting on a closed one. The parent must
ensure the label exists. The offline-tested publication helper is not connected
to the blocked live path.

## Durable reporting design required before live writes

This is a bounded follow-up for PR thread `PRRT_kwDOREx45M6yQwb3`, not an enabled
backend. The issue's value-only org PATCH and post-change status notifications
provide no durable transaction or POST idempotency key. A file on an ephemeral
runner, cache, best-effort artifact upload, or the current variable value cannot
close the crash window. Do not create a receipt or post a notification before
a known change. Do not add a second org variable, alter the selected list, or
silently repurpose a status issue as a pre-change journal.

The parent must review and provision a durable outbox outside the current
specification before replacing the live guard. It needs atomic conditional
updates, acknowledged durable commits, access restricted to this workflow, and
a single-writer lease spanning recovery and new changes. Preserve the workflow
concurrency group; the lease must also cover interrupted/repeated invocations.
Keep only validated decision fields, previous/desired values, an unpredictable
transaction ID, timestamps, phase and API receipt identifiers; never tokens or
raw usage. Retain completed IDs for deduplication. Storage, permissions,
retention and egress need their own review; none are added here.

Required state machine:

1. An unchanged initial run with no pending transaction returns without any
   write or notification. A dry-run does no outbox, org or issue writes and
   does not drain pending work. Recover any existing transaction before a new
   live decision can mutate the variable.
2. For a different desired value, persist a **prepared intent**, not a change
   receipt. Re-read the selected-visibility variable to catch human overrides.
   Persist `patch_started` before sending exactly one PATCH containing only
   `value`. No automatic retry of an ambiguous PATCH is permitted. A known
   success advances durably to `changed_report_pending`, storing the original
   decision and confirmed change separately from reporting completion.
3. A timeout, lost PATCH response, or interruption between PATCH and the
   durable success acknowledgement leaves `patch_unknown`. Neither an equal
   current value nor a prepared intent proves this workflow changed it. Stop
   further mutation/reporting and require operator reconciliation using server
   evidence/audit records. Never infer success or manufacture a receipt. An
   outbox outage before PATCH must block PATCH; after PATCH it must retain the
   started state and block new transitions until reconciled.
4. Retry known pending reports even when today's value is unchanged or today's
   usage source is unavailable, using the stored original decision. Before
   any notification, scan the genuine status issue body and all comment pages
   for a transaction marker and expected workflow author; validate IDs and
   bound pagination. For an ambiguous issue creation, also scan closed status
   issues so closure cannot cause a duplicate. Include the transaction ID in
   the initial issue body or comment. The posted text must say `value changed`
   and `status report published`; the outbox alone owns the pending state.
5. Persist `report_submitting` before the single POST. A scan failure or a
   failure known to occur before POST leaves a retryable pending report. A
   matching existing transaction notification completes the outbox without
   another POST. An ambiguous POST or interruption after POST stays
   `report_unknown`: scan again on subsequent invocations, but **absence from
   a scan is not proof the POST failed**. Do not automatically POST again until
   authoritative nonacceptance is established. If uncertainty persists, an
   operator must reconcile it; fail visibly while preserving the pending
   record. Exactly-once delivery with automatic retries is not promised by
   GitHub's POST API.
6. Mark `report_completed` only after a known POST success or a validated
   existing notification. An interrupted completion write is safe to reconcile
   by transaction ID. Once complete, unchanged invocations write nothing.
   A new decision must not overwrite, discard or coalesce a pending change.

Required backend acceptance tests must inject crashes before/after each durable
commit, accepted PATCH with a lost response, PATCH rejection, failed report
lookup, accepted POST with a lost response, stale/failed/paginated scans,
ambiguous issue creation, failure recording completion, repeated invocations,
human overrides, source outages during recovery, and cycle changes while a
report is pending. Prove minimal value-only mutation and no duplicate
notifications, plus initial unchanged and dry-run zero-write controls. The
current regression tests prove the live gate prevents these loss windows;
they **do not claim an implemented durable backend or successful recovery**.

## Deleted, renamed or inaccessible billed repositories

Metadata 404s and redirects fail closed, including for repositories renamed or
deleted after they accrued usage. Do not skip their billing rows, guess public
visibility, or add an unreviewed alias. The parent should first restore App
metadata visibility for an existing repository. For a rename or deletion that
cannot be resolved with the billed name, disable scheduling and manually set
only the runner variable's value after reviewing cost and capacity; retain
selected visibility and membership. `MODE=github` still needs healthy sources,
so it is not a source-outage escape. Keep the governor off until the monthly
report no longer contains the attribution, or land a separately reviewed,
month-bounded mapping with historical visibility evidence and tests. Such an
override is not implemented here.

## Verified artifact and manual pin updates

On 2026-10-31, the official installer at <https://get.blacksmith.sh> established
the binary URL layout. These versioned sources were downloaded read-only and
cross-checked:

- <https://clireleases.blacksmith.sh/cli/v0.5.3/linux/amd64/blacksmith>
- <https://clireleases.blacksmith.sh/cli/v0.5.3/linux/amd64/blacksmith.sha256>

The binary SHA-256 is
`089a301ea5cc93a7560c7f1106911547fdfd46fc5c0cef7079e2a62a22e971ce`.
The installer verifies against this **committed** digest in `versions.env`,
not a remotely supplied checksum at execution time. There is no unverified
escape hatch. Only Linux x64 is supported, matching the governor runner.

No documented machine-readable release version feed or suitable existing
Renovate datasource was found. The pin carries an explicit manual annotation,
like the existing manually maintained Cursor exception, rather than claiming a
working automatic updater. For a bump, download the new versioned binary and
its sibling checksum into temporary scratch, verify that they match, review
upstream changes and `usage --help`, then update the version and digest together
in `scripts/ci/versions.env`. Reconfirm the usage contract for a schema change.
Do not use `latest`, the installer pipe, or an unreviewed digest override.

## Remaining parent acceptance and activation

The following evidence is still required for a PR body **Part of #1232**;
this change must not claim to close the live acceptance criteria.

1. Obtain nonzero Blacksmith usage from the #1231 proof run and compare the
   aggregate against the dashboard's calendar-month free allowance. The pinned
   CLI's `usage --help` says a 2-vCPU x64 Linux minute records **2** raw
   `billable_minutes`; `billing_minutes` additionally applies platform factors
   (macOS 6.67, Windows 2, ARM 0.625). This identifies units, **not** which
   aggregate the 3,000 free 2-vCPU minutes counter uses. Official
   [usage docs](https://docs.blacksmith.sh/blacksmith-cli/usage.md) and
   [CLI auth docs](https://docs.blacksmith.sh/blacksmith-cli/overview.md) do not
   prove that mapping. All-zero usage cannot prove it. No live source was read
   in this implementation session.
2. Confirm the complete Blacksmith JSON aggregate path and the conversion to
   2-vCPU-equivalent minutes, using explicit UTC start/end boundaries. Record
   timestamp, CLI version, aggregate path, scale, nonzero dashboard comparison,
   and treatment of other runner platforms. Do not infer it from column names.
3. Compare the GitHub monthly billing report with Settings → Billing, resolving
   each repository's visibility through the API. Verify App metadata coverage
   and the SKU names/multipliers for this account's included minute pool.
   The official [API schema](https://docs.github.com/rest/billing/usage#get-billing-usage-report-for-an-organization)
   defines `usageItems`, quantity, repository attribution, and unit type. Its
   examples use `Actions` / `minutes` / `Actions Linux`, so parsing is
   case-insensitive, without inventing aliases. Current
   [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)
   describes cost-based included compute and different SKU spellings; it does
   not establish the issue's minute multipliers for this account. Do not assume
   the synthetic tests' illustrative 1/2/10 mapping is live billing proof.
4. Review `scripts/ci/runners/usage-contract.json`: replace nulls with the
   proven aggregate path (list of object keys), positive minutes-per-unit
   scale, and casefolded SKU-to-positive-multiplier map. Record the evidence in
   `evidence`, then set `verified=true`. Until then **even a network dry-run
   fails before collecting data**, and live scheduling remains off. New or
   unsupported private SKUs must fail pending an explicit reviewed mapping.
5. Parent dispatches `runner-governor.yml` with `dry-run=true`. Verify the
   decision, mode, both usages, thresholds and current/desired labels in the
   summary, and verify zero variable/status writes. This uses harden-runner
   audit mode. Confirm observed hosts for auth and usage against the candidate
   `runner-governor` preset: GitHub checkout/API hosts,
   `clireleases.blacksmith.sh`, `backend.blacksmith.sh`. The backend host was
   found in the pinned binary, **not confirmed by an audit run**. Add required
   audited hosts to the preset, sync generated maps, and review before live.
6. Complete and review the durable outbox implementation and failure-injection
   tests above; the current live guard must remain until that work is accepted.
   Protect activation credentials as described above. Parent verifies selected
   visibility/list, switch-ready pool, `infrastructure` label, App permissions
   and successful changed-file CI checks. Only then set
   `LGTM_CI_RUNNER_GOVERNOR_ENABLED=true`. Dispatch with `dry-run=false` in a
   controlled window and prove one value-only flip plus one status report.
   Save the selected list/visibility before and after to prove preservation.
   Repeat with unchanged inputs and prove no PATCH or comment. Verify reset
   behavior at the next cycle, then observe hourly scheduling in block mode.

Offline preview (explicitly synthetic inputs, no network or credentials):

```bash
python3 scripts/ci/runners/runner_governor.py \
  --fixture-dir tests/fixtures/runner-governor --fixture-month 2026-10
```

The fixture contract and its invented aggregate key are **test data only**.
Fixture mode cannot authorize live writes, even with `--live`. Neither the
fixture numbers nor its multipliers represent a real billing observation.
