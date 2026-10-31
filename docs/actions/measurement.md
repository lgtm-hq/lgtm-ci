# Actions usage measurement

`scripts/ci/maintenance/measure-actions.py` makes GET requests through the existing
`gh` authentication. It does not change workflows or create scheduled automation.
The collector refuses output inside a Git checkout: checkpoints and API pages
can contain private repository metadata. Output and cache directories use mode
0700 and JSON files use 0600, including existing collector files. Do not publish
raw responses or private source. This tooling is **Part of #1235**; completing
the live measurement, publishing a reviewed public-safe report, and validating
savings remain separate work. A bounded sample does not establish complete
organization coverage.

```sh
python3 scripts/ci/maintenance/measure-actions.py \
  --repo example/project --private-org example \
  --start 2026-10-01T00:00:00Z --end 2026-10-31T00:00:00Z \
  --api-seconds 720 --output /path/to/local/research
```

The window is a half-open UTC **run creation cohort**, not an invoice period.
Both bounds must use whole seconds and the end must be in the past; an open
future window cannot provide stable pagination.
Runs created before the start whose retries occur inside the window are excluded.
Every attempt from 1 through the observed `run_attempt` is fetched through
`/actions/runs/{id}/attempts/{attempt}/jobs`, with pagination. The default jobs
endpoint can omit earlier attempts and is deliberately unused. Runs created
during collection are outside the fixed snapshot; completed intervals after its
end, unfinished jobs, and missing timestamps are counted as unknown time.

`checkpoint.json` records inventory and per-repository listing completeness,
runs, fetched attempts, errors, and the last collection status. `cache/` retains
each successful API page atomically, including pages from interrupted pagination.
Re-run the same command to resume. A run-listing pass retains its cached pages,
accumulated rows and next-page cursor across bounded invocations until the entire
pass finishes, including split searches. Partial listings never establish complete
coverage. The next normal resume starts a new listing generation to discover
status changes and new retries. A mutable run observed on an early page can remain
incomplete until that next generation observes its terminal status; completed job
rows alone cannot close that gap. Finished attempts retain explicit terminal-fetch
provenance. Each run's `terminal_attempts`
map records whether an attempt was immutable **before** fetching its jobs: the
parent run was listed as completed, or a later attempt had already been observed.
Completed job rows alone cannot prove that downstream jobs have all appeared.
If a run finishes between listing and fetching, its latest attempt is refreshed
on the next normal resume. Legacy checkpoints without provenance retain their
measured usage but require a refresh before coverage or averages can be complete.
Interrupted terminal attempts retain their cursor, accumulated jobs and pages until
pagination finishes. Mutable attempts start a fresh pass on resume, including when
the parent first becomes terminal, so early pages cannot become terminal snapshots.
Pages are grouped by exact endpoint route, so invalidation touches only that
endpoint, including pages after pagination gaps and split-window query variants.
Legacy flat cache pages are ignored; the first upgraded resume refetches them.
Checkpoints persist the normalized selection: repository names are case-insensitive,
sorted and deduplicated, with the selected organization stored separately. Normal
resumes reject changed repository or organization selections before API work; use a
new output directory for a different scope. Legacy checkpoints without scope can be
adopted only when they have no organization inventory and the explicit repository
selection exactly matches the stored repositories (or the inventory is empty).
Ambiguous legacy scopes require a new output directory or checkpoint-only modes.

Online discovery bypasses cached repository metadata and updates visibility for
explicit repositories and the organization inventory. Interrupted organization
discovery retains its pages and cursor until the pass completes; the next normal
resume starts a fresh pass. A successful pass reconciles prior organization
members, including older checkpoints without membership fields. Missing repositories
retain their observed runs and jobs, but lose trusted visibility and metadata
provenance. Their billing becomes unknown and coverage stays incomplete, including
offline and jobs-only resumes, until they reappear or an explicit repository
metadata request succeeds. Previously observed private
repositories remain in the cohort if they become public, with their usage
reclassified as public execution. Inventory reports the currently visible private
count. Add `--jobs-only` to use the existing run inventory; this cannot
discover new retries or refresh an unfinished run's status, so use a normal
resume to finish such runs. Add `--offline` to reaggregate without API access.
Both modes skip repository discovery and visibility refresh, use the entire stored
checkpoint and ignore `--repo` and `--private-org` for scope; their completeness
describes only that checkpoint. Jobs-only preserves existing inventory errors.
Each invocation has its own maximum 12-minute budget; callers must budget
multiple invocations themselves. Exit code 2 means incomplete collection; zero
requires complete listings and finished runs with all observed attempts,
including empty terminal attempts. Unknown timing and billing remain visible
in the stdout summary even when API collection is complete.
Inventory includes every private repository **visible to the credential**, even
archived repositories; token visibility cannot prove organization-wide access.

The collector lists runs before collecting jobs, recursively splitting time
ranges when GitHub's 1,000-result search cap is reached. Half the remaining
budget is reserved for jobs; interrupted listings retain observed runs from
cached pages and remain explicitly incomplete. Unfinished repository listings
finish across invocations before completed listings start another refresh;
legacy listings without cursor provenance also need a pass. Jobs are fetched round-robin
across repositories and workflows, newest first within each workflow, using
four workers and a global limit of four requests per second. At fewer than 100
remaining primary requests, or any
403/429, it stops network work instead of retrying. Other failed requests are
recorded as coverage gaps. Optional organization inventory failures preserve
incomplete coverage while independently requested and checkpointed repositories
continue within the remaining budget. A global 403/429 stop still applies to
all repositories without automatic retry. The deadline bounds each subprocess
timeout as well.

`measurements.json` contains per-workflow and per-job aggregates, with first and
retry counters separately. Workflow trigger counts describe **listed runs**;
job metrics describe **fetched attempts**. A partial ranking is only a ranking of
observed usage and cannot establish the organization's true top ten. No full
window extrapolation is applied. Minutes per run are null unless the repository
listing is complete, all observed runs and attempts have finished, and every
relevant job duration is known.

- `wall_seconds / 60`: summed elapsed job minutes, including parallel jobs.
  This is neither pipeline latency nor billed time.
- `rounded_job_minutes`: round **each** timed, non-skipped job up to a whole
  minute before summing. Skipped jobs consume zero; unknown time consumes an
  unknown amount, rather than an invented zero. Zero-length intervals round to
  zero; the API does not establish whether allocation overhead was charged.
- `estimated_private_plan_minutes`: rounded minutes times the standard hosted
  OS factor (Linux/ARM 1, Windows 2, macOS 10), for private repositories only.
  This estimates included-plan consumption, not money or invoice usage. It does
  not subtract remaining included minutes or infer discounts/credits.
- `public_free_rounded_minutes`: standard GitHub-hosted public execution is
  free. OS weighting is not a charge for these jobs.
- Self-hosted jobs and unknown/custom/larger runner labels are separate. Larger
  runners may incur charges even in public repositories. Labels are evidence,
  not authoritative billing records; new runner types and ambiguous labels are
  unknown. Exact invoiced usage requires billing records and runner pricing.

Job names retain matrix suffixes. Jobs per attempt measure observed fan-out,
including gates and skipped jobs; they do not prove a configured matrix size.
Shared push/PR SHAs are candidates for duplication, not proof that both jobs do
the same work; PR merge SHAs can hide overlap. Renovate branch/actor counts and
repeat runs indicate volume, not confirmed rebases. Retry counts do not identify
whether retries were manual, automated, or caused by infrastructure. Inspect
workflow configuration and sampled attempts before attributing causes or
estimating savings. Preserve required checks, merge-queue coverage and security
controls when proposing follow-up changes.
