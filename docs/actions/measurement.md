# Actions usage measurement

`scripts/ci/maintenance/measure-actions.py` makes GET requests through the existing
`gh` authentication. It does not change workflows or create scheduled automation.
Keep its output outside the checkout: checkpoints and API pages can contain
private repository metadata. Do not publish raw responses or private source.

```sh
python3 scripts/ci/maintenance/measure-actions.py \
  --repo example/project --private-org example \
  --start 2026-10-01T00:00:00Z --end 2026-10-31T00:00:00Z \
  --api-seconds 720 --output /path/to/local/research
```

The window is a half-open UTC **run creation cohort**, not an invoice period.
Runs created before the start whose retries occur inside the window are excluded.
Every attempt from 1 through the observed `run_attempt` is fetched through
`/actions/runs/{id}/attempts/{attempt}/jobs`, with pagination. The default jobs
endpoint can omit earlier attempts and is deliberately unused. Runs created
during collection are outside the fixed snapshot; completed intervals after its
end, unfinished jobs, and missing timestamps are counted as unknown time.

`checkpoint.json` records inventory and per-repository listing completeness,
runs, fetched attempts, errors, and the last collection status. `cache/` retains
each successful API page atomically, including pages from interrupted pagination.
Re-run the same command to resume, add `--jobs-only` to use the existing run
inventory, or add `--offline` to reaggregate without API access. Each invocation
has its own maximum 12-minute budget; callers must budget
multiple invocations themselves. Exit code 2 means incomplete collection; zero
means all listed runs have all observed attempts, including empty attempts.
Inventory includes every private repository **visible to the credential**, even
archived repositories; token visibility cannot prove organization-wide access.

The collector lists runs before collecting jobs, recursively splitting time
ranges when GitHub's 1,000-result search cap is reached. Half the remaining
budget is reserved for jobs; interrupted listings retain observed runs from
cached pages and remain explicitly incomplete. Jobs are fetched round-robin
across repositories and workflows, newest first within each workflow, using
four workers at at most four
requests per second. At fewer than 100 remaining primary requests, or any
403/429, it stops network work instead of retrying. Other failed requests are
recorded as coverage gaps. The deadline bounds each subprocess timeout as well.

`measurements.json` contains per-workflow and per-job aggregates, with first and
retry counters separately. Workflow trigger counts describe **listed runs**;
job metrics describe **fetched attempts**. A partial ranking is only a ranking of
observed usage and cannot establish the organization's true top ten. No full
window extrapolation is applied. Minutes per run are null unless all attempts
were fetched; unknown intervals still need checking even then.

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
