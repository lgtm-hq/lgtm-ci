# Python skip proof source (part of #1297)

The callers use the production reusable at published v0.83.9, immutable
`761e2f173be08f57f0be18d8332e2b063387d987`. Its Python reusable is unchanged
from merged #1301 (`1c4ae704f8f81ea8a856d1d240f254a64f90d2ad`).
It runs on real PR, main push and merge group events. No dispatch input impersonates
an event. No consumer filtering is enabled.

The positive workflow adds four reusable calls (five test legs on the full route,
plus prepare/aggregate jobs) to each eligible event. This ongoing proof overhead
is unmeasured; review retiring the workflow after hosted acceptance closes.

The four stable callers are `single`, `matrix`, `empty`, and `commas`, with distinct
literal job names and artifact prefixes. The matrix requests 3.12 and 3.13;
empty/comma-only strings fall back to one 3.12 leg. For the parent-owned baseline,
change only each caller's supported `pipeline-skip` input to false, complete that
run, then restore true on a new head. Preserve IDs, names, versions and pins.
The observer accepts either zero or full sentinel counts on PRs to support this
input-only switch; parent readback must verify the selected route from actual
step logs and the recorded source input. Non-PR controls require full counts
(single/empty/commas: 1; matrix: 2), even with skip true. Draft PRs must retain
skipped results without claiming `passed=true`. Exercise draft opens or
synchronizations; the existing required gate does not subscribe to conversion
to draft, so this proof caller does not add that event.
Use same-repository heads for this comparison; fork and Dependabot tokens can
have downgraded permissions and require separate evidence.

This is an independent uv project/workspace with its own committed lockfile.
`uv lock --project tests/fixtures/python-skip-proof --check` validates that lock;
production runs frozen sync from this directory. The root pytest configuration
selects `tests/python`, while this project selects only `tests/pass`. The
`controls/failure.py` and `controls/sleep.py` filenames are outside default pytest
discovery and require explicit selection. The sleeping control is bounded to
90 seconds and emits a start marker with pytest capture disabled.

The negative workflow is dispatch-only. Its sole required input is `case`:

| case | Required ref | Actual expected result |
| --- | --- | --- |
| `pytest-failure` | `proof/1297-negative` | failure; delivered passed=false, passed/failed/total counts 0/1/1 |
| `cancel` | `proof/1297-cancel` | cancelled; delivered passed must not be true |

The procedural guard checks the exact event/repository/ref and rejects open PRs
on that ref; API errors fail closed. It runs from the dispatched ref's reviewed
source, which a workflow-editing writer can change; it is not an immutable
enforcement boundary. Parent must create a fresh exclusive commit with no open
PR and verify its SHA is absent from all mergeable heads before dispatch. Keep
these refs exclusive until runs settle. Never dispatch on main or the source PR.
A successful observer cannot make a failed child workflow green. Letting the
sleep complete is not cancellation proof. Whole-workflow cancellation can prevent
the always observer from running; absent artifacts/outputs remain unknown.
Pytest-failure acceptance requires the single failing control's delivered counts;
setup failure or missing outputs cannot certify it. Parent must also retain the
actual step log identifying `controls/failure.py::test_failure` and its intentional
assertion. Cancellation may retain missing outputs without inferring test failure.

Every observer retains exact raw `toJSON(needs)`, parsed results, unmodified string
outputs, event, head/evaluated SHA, ref, run ID and attempt before asserting. A
missing output is never converted into a fabricated cancelled output. Artifacts
expire after seven days; parent must retain raw evidence externally before expiry
or owned-ref cleanup. Do not delete red/cancelled runs.

Residual hosted work remains parent-owned after normal source review: compare
actual baseline/skip check names and steps, draft/default and separately reviewed
draft override, real main and merge group execution, exclusive pytest failure,
and one bounded cancellation after pytest starts. The lightweight invalid-preset
failure needs a separately owned non-merging proof-ref PR because dispatch cannot
exercise PR-only skip; it is deliberately absent from automatic source/main
controls. Keep genuine red results and close that proof PR without merging.
Unknown-path classification, eligible workload, actual overhead and savings
remain unmeasured. #1298 supersession probes are separate and unchanged.

Local YAML/expression tests are source checks, not hosted acceptance. No hosted
proof or measured savings are claimed; #1297 remains open.
