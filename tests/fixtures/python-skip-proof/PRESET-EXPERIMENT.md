# Invalid preset experiment — NEVER MERGE

This separate #1297 experimental branch and eventual PR **MUST NEVER MERGE**.
Parent owns source review, push, PR lifecycle and evidence collection. Open a
genuine same-repository ready PR from exactly `proof/1297-preset` in
`lgtm-hq/lgtm-ci`. The new workflow accepts only real `pull_request` events;
there is no dispatch, main push or merge group trigger. Do not fake metadata or
change the existing positive/negative proof callers, production defaults or gates.
The guards are procedural checks in mutable candidate YAML, not an immutable
security boundary.

The caller uses production reusable SHA
`761e2f173be08f57f0be18d8332e2b063387d987`, supported `pipeline-skip: true`,
one Python 3.12 passing fixture leg and deliberately absent
`egress-preset: nonexistent_1297_preset`. Default block enforcement and endpoint
selection remain intact. Draft skipping retains its production default; this
case expects a ready PR. It requests a single leg, but production `prepare` may
reject the preset **before generating the matrix**.

The observer retains literal `toJSON(needs)`, parsed data when valid, unchanged
output strings and event/repository/head branch/head SHA/evaluated SHA/ref/run
ID/attempt/draft/case before asserting. Caller result must be `failure` and
delivered `passed` must differ from string `true`. Missing outputs remain absent;
neither false nor zero is synthesized. This proves caller failure propagation,
not execution of failing tests or the test job's `job.status` branch.

After normal exact-head review, parent must retain the actual production
**Fail on unknown egress-preset** prepare-job log naming the selected preset,
the exact PR head/evaluated ref, run ID/attempt and caller result. Compare these
with the raw `proof_invalid_preset_observation` artifact. An unrelated setup or
network failure does not establish intended preset rejection even if the observer
succeeds. The reusable and overall workflow should remain intentionally red;
observer success never changes their verdict or waives a required gate.

Download and verify the raw artifact and actual logs externally before the
seven-day artifact expiry. Keep red runs. After evidence is retained and runs
settle, close the experiment PR **without merging**, then clean up only its
owned branch under parent control. Worker commits locally only. Hosted acceptance,
merge-group controls, workload/overhead measurement and savings remain open;
local tests/lint do not establish any hosted result or green aggregate.
