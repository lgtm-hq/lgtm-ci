# Duplication scan coverage repair: #1237

The successful [dry run 41323741728](https://github.com/lgtm-hq/lgtm-ci/actions/runs/41323741728)
still reported partial coverage and blocked reconciliation. This repair filters
proven documentation while preserving conservative executable dependency hints
and fail-closed omission handling. It does not establish complete coverage:
opaque Dockerfile and Markdown dependencies still reach the oversized py-lintro
source. Live reporting remains disabled. Owner review and a postmerge full-org
zero-omission dry run still gate the separate matcher PR.

## Public dependency trace

The supplied independent 21-repository diagnosis identified one oversized blob:
public py-lintro `tests/unit/test_workflow_wiring.py`, 397610 bytes, Git blob
`3680e989b3663114846ae8b9030ef38b11ec8323`. It was outside initial selection;
none of the initially selected sources was oversized.

A public-only, unauthenticated replay pinned py-lintro tree
`217fe667de12d2dd63b2431982690efe9fb74494` and verified every downloaded blob's
Git SHA. Source remained in memory and was never executed. The oversized blob
was rejected using tree metadata without downloading it. No private source was
fetched, retained or printed during this investigation.

The original discovery applied path patterns to entire raw documents, then
recursively expanded matching inventory suffixes. Eleven fetched files introduced
the oversized path; the resolver script's comment was one of several causes:

| Parent | Reference context |
| --- | --- |
| `.github/workflows/ai-contract-tests.yml` | Comment inside a run block, line 263 |
| `.github/workflows/dependency-vuln-gate.yml` | YAML comment, line 31 |
| `.github/workflows/docker-ci.yml` | YAML comment, line 27 |
| `.github/workflows/dogfood-nightly.yml` | YAML comments, lines 120 and 164 |
| `scripts/ci/resolve-pipeline-relevance.sh` | Shell comments, lines 33 and 113 |
| `scripts/ci/sync-pinned-release-image.py` | Python comment, line 69 |
| `.github/workflows/README.md` | Comment inside documentation, line 41 |
| `docker/tools.Dockerfile` | Comment, line 39 |
| `docs/npm-distribution.md` | Documentation prose, lines 137 and 214 |
| `lintro/_tool_versions.py` | Python comment, line 104 |
| `tests/integration/_tools.py` | Python comment, line 44 |

The first six parents were initially selected. Other routes included
`scripts/README.md` to `docs/npm-distribution.md`, and basename `README.md` from
the scripts/docs READMEs to `.github/workflows/README.md`. Selected manifest
helpers introduced `docker/tools.Dockerfile`; it introduced
`tests/integration/_tools.py` and `lintro/_tool_versions.py`. Multiple selected
workflows/helpers also referenced `lintro/_tool_versions.py` directly.

Replaying the original discovery fetched 1090 files from 216 initial sources,
with the single oversized omission. An initial repair version fetched 626 files
and reported zero omissions, but those figures do not describe the current
implementation. Conservative opaque-file discovery invalidated that result.

The final Opus review of `2a55759` independently replayed production selection
and dependency discovery over the same pinned public tree's local Git objects.
It reached 1078 files and the same 397610-byte oversized source through
`docker/tools.Dockerfile:39`. The review also reproduced the Markdown route at
R4 (`32af8e2`): `tests/test_documentation.py` to `scripts/README.md` to
`docs/npm-distribution.md:137/214`, reaching 1069 files. These are conservative
opaque dependency hints, so retaining them and reporting partial coverage is
intentional. No Dockerfile/Markdown filtering or size-bound expansion is part of
this repair. The next full-org dry run can remain partial and block the matcher
PR; no full-org zero-omission pass is claimed.

## Bounded repair

YAML discovery recognizes immediate `.github/workflows/*.yml`/`*.yaml` paths and
`action.yml`/`action.yaml` at any directory before filtering execution metadata.
It inspects workflow jobs, action execution steps, actual local
`uses` targets, JavaScript action entry points and Docker execution metadata.
Workflow/job defaults select
the effective run language; step shells override them. Descriptions and literal
comments inside those execution schemas remain inert. Run-block GitHub expression
spans retain raw hints before interpreter comment filtering because interpolation
can introduce executable newlines. Expressions are never evaluated.
Job/step output mappings retain
conservative hints when the document contains executable data consumers, including
downstream jobs. Exported action and callable-workflow output `value` fields retain
hints for consumers outside the document; their output names/descriptions remain
inert. Other YAML mappings,
including fetched runtime configuration with `jobs` or `runs` keys, retain
conservative raw dependency hints.
Workflow/job/step environments, action `with` values and action/dispatch/call
input defaults retain scoped hints when referenced or passed to an unresolved
consumer. Job matrix data, including include/exclude entries and unresolved
expressions, retains hints in that job's execution scope without expanding or
evaluating combinations. Scoped runtime mappings retain string keys as well as
values because opaque consumers can read either. Docker entrypoint,
pre-entrypoint, post-entrypoint, image and arguments retain hints alongside
scoped environment/input data;
Docker normalization remains opaque. Job container/service execution configuration
and explicit/default shell paths and arguments also retain hints. Nonempty
inherited `BASH_ENV` values retain scoped data even for literal commands because
startup can expand and execute those files first. Other literal shell data commands
without expansion can omit unused values. Shell comments use the existing bounded lexer.
Python comments use the standard tokenizer with AST validation. All Python
docstrings retain hints because external consumers can read them without local
reflection names; this bounded pass cannot prove them inert. Compiler warnings from
untrusted parsing are suppressed locally, without executing source or changing
the process-wide warning policy. Newline handling matches AST/tokenizer
coordinates, including strings containing control/Unicode separators. Invalid
Python and unsupported languages retain conservative raw hints. Unrecognized
file types, including text, Markdown, Dockerfiles and extensionless runtime data,
also retain raw hints; only supported shell suffixes or shebangs establish shell
comment semantics. YAML source
loading rejects cyclic container identities and nesting beyond 64 levels before
any downstream traversal. Such sources retain raw discovery hints; selected units
and local action consumers record invalid source and block reconciliation.
Hint collection visits shared container identities once per collection call,
deduplicates emitted string data and limits total hint work to 65,536 visits per
document. The identity set resets for each call so shared steps still receive each
job's environment. Work exhaustion retains raw hints instead of truncating them;
this conservative fallback can also retain metadata comments and descriptions.
Executable strings remain available for discovery; normalization independently keeps
uninspected launchers, imports and unknown execution opaque.

No size limit, byte budget, privacy rule, reconciliation guard or fingerprint
version changed. Genuine outside-selected dependencies remain discoverable,
including recursively sourced files with non-script extensions. Their oversized
omissions still make the scan partial and block matched reconciliation.
The fetched inventory can affect Python stdlib-shadowing opacity and therefore
fingerprints even though the normalization algorithm and version are unchanged.

## Verification

All commands unset inherited `UV_PROJECT_ENVIRONMENT`, `VIRTUAL_ENV` and
`PYTHONPATH` before launch. The following initial results predate this revision.

```sh
bats --filter 'dependency coverage' tests/bats/unit/maintenance/test_duplication_scan.bats
```

Before the production fix: exit 1, 2 failed and 2 passed. The shell/Python
documentation case failed on all four initial subcases; the YAML documentation
case failed on both initial subcases. Genuine executable controls passed.
After the fix: exit 0, all 4 passed. Expanded controls subsequently passed all
5 cases, including unknown execution, sourced data, inherited Python templates
and executable strings. The transport records attempted blobs as well as remote
blob reads, so size-based rejection cannot conceal a false dependency request.
Matched independent clusters remain blocked in both fake live and dry-run modes
when a genuine executable dependency is oversized; no real writes occur.

<!-- markdownlint-disable MD013 -- preserve the exact executed command -->

```sh
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py Cases.test_fetch_external_dependencies CatalogDependencyCases.test_catalog_non_yaml_dependency
```

<!-- markdownlint-enable MD013 -->

Exit 0: 2 existing relevant Python tests passed. No full repository suite,
environment creation or dependency installation was performed.

```sh
bats tests/bats/unit/maintenance/test_duplication_scan.bats
```

Final exit 0: 238 passed, zero failures and zero skips. The earlier full run
passed the 237 cases present at its launch. The final focused command below
passed all 7 cases, and running the new Python helper directly passed all 5
tests. BATS reported its existing missing bats-file fallback warning.

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_dependency_checks.py
```

Lint uses the prepared tool through
`uv run --no-sync python -m lintro fmt <changed>` followed by
`uv run --no-sync python -m lintro chk <scanner modules and helpers together>`.
The prepared Lintro import location was verified before checking. Formatting
passed. Black, Ruff, Pylint and typos passed, with
duplicate-code count zero against baseline zero. The initial worker check skipped
mypy because it was unavailable in that prepared environment; this was not treated
as a passing gate. Independent verification exposed the already-installed mypy
package through `PYTHONPATH`, keeping the intended Lintro wheel first, without
installing dependencies or changing another environment. It found two untyped
fixture return values. Explicit casts repaired those annotations; the scoped mypy
check then passed, and all seven focused BATS cases independently passed again.
A fresh authorized full-org dry run and owner review remain required before live
activation. Live reporting remains off.

## PR #1267 revision 1

Six regressions were added before changing production code: reachable YAML env,
reachable inputs/defaults, runtime Python docstrings, Python newline coordinates,
compiler-warning privacy and invalid YAML/default fallback. The same focused
command above exited 1 with all six new cases failing and all five existing
controls passing. After the fix it exited 0 with all eleven cases passing.
The tests exercise actual inventory requests and blocked reconciliation in
dry-run and simulated live modes; inspected source is never executed.

The privacy case captures actual warning stderr with a synthetic private sentinel
and temporary source-cache context. It checks discovery and normalization,
including literal parsing, and confirms unrelated warnings remain visible.
Newline controls cover form-feed, vertical-tab and Unicode separators under LF,
CRLF and CR. Ordinary class documentation and quoted/unquoted YAML `on` keys are
also covered.

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_dependency_checks.py
```

The focused BATS command passed all 13 cases. The helper passed all 11 tests;
the existing transport/catalog command above passed both tests. The complete
scanner BATS command exited 0: 244 passed, zero failures and zero skips.
No new environment or dependencies were installed. Before
linting, the actual Lintro and mypy import locations were checked. A separate
existing mypy package was exposed read-only, keeping the prepared Lintro
site-packages first on `PYTHONPATH`, followed by the scanner module directory.

Scoped lint can be reproduced in a prepared environment with those imports.
This argv builder includes the additional gitleaks gate used for revision 2:

```sh
uv run --no-sync python - <<'PY'
import subprocess
from pathlib import Path

changed = [
    "docs/duplication-scan-coverage-1237.md",
    "docs/duplication-scan.md",
    "scripts/ci/maintenance/duplication_python.py",
    "scripts/ci/maintenance/duplication_sources.py",
    "tests/bats/unit/maintenance/test_duplication_scan.bats",
    "tests/helpers/duplication_scan_dependency_checks.py",
]
patterns = (
    "scripts/ci/maintenance/duplication_*.py",
    "tests/helpers/duplication_scan_*.py",
)
scoped = sorted(set(changed) | {
    str(path) for pattern in patterns for path in Path(".").glob(pattern)
})
for action, tools, paths in (
    ("fmt", "black,ruff,typos,prettier", changed),
    ("chk", "black,ruff,mypy,pylint,typos,bandit,prettier,markdownlint,gitleaks", scoped),
):
    assert paths
    subprocess.run([
        "uv", "run", "--no-sync", "python", "-m", "lintro",
        action, "--tools", tools, *paths,
    ], check=True)
PY
```

Formatting exited 0. The scoped check exited 0 with all eight tools passing:
Black, Ruff, mypy, Pylint, typos, Bandit, Prettier and markdownlint. Duplicate-code
count stayed zero against baseline zero. Existing module-size notices remain
non-blocking. Early line-length and fixture-typing failures were corrected
before the passing checks; no required tool was skipped.

At revision 1, Docker action entrypoint discovery and the existing unnecessary
discovery of opaque JavaScript action entrypoints were deferred. Revision 2
below fixes Docker discovery after production inventory controls demonstrated
the coverage failure. No threshold, blob budget,
visibility rule, omission guard or activation setting changed. A fresh full-org
dry run after merge and the owner's triage review remain required; fixture
results and the earlier public replay do not establish full-org acceptance.

## PR #1267 revision 2

Production inventory controls demonstrated three genuine coverage omissions:
external Python docstring consumers, workflow matrix execution data and Docker
action entrypoints. Their existing opaque normalization did not satisfy the
separate coverage requirement: an oversized executable dependency must be
attempted, counted as an omission and block reconciliation.

Three BATS cases were added before the production changes. The exact RED command
was:

```sh
bats --filter 'dependency coverage' tests/bats/unit/maintenance/test_duplication_scan.bats
```

Exit 1: all three new cases failed at the real inventory's missing oversized
attempt; all eleven existing cases passed. The new cases cover decorated
functions, async functions and classes, module documentation and exported
objects without local reflection names; matrix axes, include/exclude data,
unresolved expressions and consumers through env/actions/reusable workflows;
and all three Docker entrypoint fields plus arguments, environment and input
defaults. Descriptions, Python/shell comments and unused matrix data in a
different job remain inert controls. Docker action fingerprints remain opaque
and repository-qualified.

After the fix, this focused command exited 0 with all sixteen cases passing:

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
```

The final complete scanner suite also exited 0: 247 passed, zero failures and
zero skips, including the 244 existing cases. It was rerun after the lint-driven
cleanup. BATS emitted only its existing missing bats-file fallback warning.

```sh
bats tests/bats/unit/maintenance/test_duplication_scan.bats
```

Every reachable oversized control exercises the real `GitHub.files()` inventory
and CLI reconciliation in dry-run and simulated live modes. Both repositories
attempt the dependency, reject it before downloading its contents and count
the omission; coverage is partial, matched reconciliation is blocked and the
transport records zero writes. Fixture source is never executed.

These small Python commands exited 0 with two and fourteen tests passing,
respectively:

```sh
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py \
  Cases.test_fetch_external_dependencies \
  CatalogDependencyCases.test_catalog_non_yaml_dependency
uv run --no-sync python tests/helpers/duplication_scan_dependency_checks.py
```

Initial test-class naming, fixture
typing and line-length errors were corrected before the passing checks. The
input-default helper was moved without changing its behavior to keep the YAML
traversal within the existing statement-count gate; no new lint suppression was
added.

The Python-built lint argv above exited 0 for formatting and checking. All nine
tools passed without skips: Black, Ruff, mypy, Pylint, typos, Bandit, Prettier,
markdownlint and gitleaks. All scanner modules and helper tests were checked
together; duplicate-code count remained zero against baseline zero. The existing
non-blocking module-size notices remain.

All docstrings now retain inventory hints because this bounded pass cannot prove
external consumer safety. That conservative choice can increase reads and reveal
genuine oversized omissions, which continue to block reconciliation. No public
pinned replay was repeated for revision 2; the earlier 626-blob/236-unit result
is historical, not a measurement of this revision. A postmerge full-org dry run
and owner review remain required. Live reporting remains off. Opaque JavaScript
overfetch, exotic shell heredocs, AST resource limits and broader refactors stay
in the existing #1258 backlog.

## PR #1267 revision 3

Four newly reproduced P2s required this gathered revision: fetched runtime YAML
mappings lost script hints; job container/service execution configuration and
explicit shell declarations lost paths and arguments; literal commands lost
inherited Bash startup dependencies; and recursive YAML aliases crashed source
traversal. No normalization or matching feature was added.

The RED command below exited 1: all four new cases failed, while all fourteen
existing dependency coverage cases passed. The cyclic alias controls reproduced
`RecursionError`. An initial fixture string escaping error was corrected before
that meaningful RED run.

```sh
bats --filter 'dependency coverage' tests/bats/unit/maintenance/test_duplication_scan.bats
```

After the fix, the focused command below passed all twenty cases. The Python
commands passed two existing regression tests and eighteen dependency tests.

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py \
  Cases.test_fetch_external_dependencies \
  CatalogDependencyCases.test_catalog_non_yaml_dependency
uv run --no-sync python tests/helpers/duplication_scan_dependency_checks.py
```

Every reachable oversized control uses the production inventory and CLI in both
dry-run and simulated live modes. Synthetic mapping, list and scalar runtime
configuration retains hints. Container/service environment values and options,
custom shell paths/arguments and scoped expressions retain hints. Workflow/job/
step `BASH_ENV` inheritance, expansion and empty overrides are covered. Cyclic
mapping/list aliases, recursive execution steps, output data and local action
inputs retain raw hints and fail closed. Even without an oversized hint, selected
cyclic sources and local action consumers count invalid source and block
reconciliation. Acyclic aliases shared by jobs keep each job's execution scope.
Nesting beyond 64 container levels also falls back and blocks selected units.
Oversized blobs are rejected before their contents are fetched; fixture writes
remain zero. Fixture sources are never executed.

All checks use the prepared environment described above, with inherited
`UV_PROJECT_ENVIRONMENT`, `VIRTUAL_ENV` and `PYTHONPATH` unset before launch.
The verified imports are the prepared Lintro installation and the compatible
existing mypy package exposed read-only. No environment or dependencies were
installed; the existing `.venv` link is excluded from staging. The R3 lint argv is
built explicitly as follows after setting the documented `PYTHONPATH` and
`LINTRO_LOG_DIR`:

```sh
uv run --no-sync python - <<'PY'
import subprocess
from pathlib import Path

changed = [
    "docs/duplication-scan-coverage-1237.md",
    "docs/duplication-scan.md",
    "scripts/ci/maintenance/duplication_model.py",
    "scripts/ci/maintenance/duplication_sources.py",
    "tests/bats/unit/maintenance/test_duplication_scan.bats",
    "tests/helpers/duplication_scan_dependency_checks.py",
]
scoped = sorted(set(changed) | {
    str(path)
    for pattern in (
        "scripts/ci/maintenance/duplication_*.py",
        "tests/helpers/duplication_scan_*.py",
    )
    for path in Path(".").glob(pattern)
})
for action, tools, paths in (
    ("fmt", "black,ruff,typos,prettier", changed),
    ("chk", "black,ruff,mypy,pylint,typos,bandit,prettier,markdownlint,gitleaks", scoped),
):
    assert paths and ".venv" not in paths
    subprocess.run([
        "uv", "run", "--no-sync", "python", "-m", "lintro",
        action, "--tools", tools, *paths,
    ], check=True)
PY
```

Formatting and the scoped check both exited 0. All nine tools passed without
skips: Black, Ruff, mypy, Pylint, typos, Bandit, Prettier, markdownlint and gitleaks.
All scanner modules and helpers were checked together with the changed docs and
BATS file; duplicate-code count stayed zero against baseline zero. Initial line
length, statement count and test method count findings were corrected without
new suppressions. Existing module-size notices remain non-blocking.

The complete scanner suite exited 0: 251 passed, zero failures and zero skips,
including all 247 existing cases. The final focused 20-case run also passed after
the lint cleanup. BATS emitted its existing missing bats-file fallback warning.

```sh
bats tests/bats/unit/maintenance/test_duplication_scan.bats
```

Conservative runtime YAML and startup hints can increase reads and expose genuine
omissions. Cyclic/deep YAML is unsupported and blocks reconciliation when selected
or consumed as a local action; it is never silently accepted as a valid unit.
Expressions and startup data flow are not evaluated. No fresh public replay or
full-org zero-omission claim is made for R3. A postmerge full-org dry run with zero
omissions and owner review still gates the separate subsequent PR. Live reporting
remains off, and no adoption issues, activation or settings were changed. The
256 KiB limit, privacy rules, warning/newline controls and reconciliation guards
remain intact. Existing #1258 deferrals remain unchanged.

## PR #1267 revision 4

Three gathered coverage P2s are repaired: runtime YAML with `jobs`/`runs` mappings
was misclassified as execution metadata; opaque consumers lost mapping-key paths;
and the new hint collector expanded shared acyclic aliases repeatedly. Filtering
now requires an actual workflow/action path, scoped data includes string keys,
and hint collection bounds repeated aliases, emitted strings and total work.
No normalization or matching feature was added.

The initial RED command exited 1 with eighteen existing cases passing and all
three new cases failing:

```sh
bats --filter 'dependency coverage' tests/bats/unit/maintenance/test_duplication_scan.bats
```

An extra fixture assertion incorrectly required intentionally fetched local
actions to be initially selected. That assertion and an imported test-class
discovery issue were corrected before this independent RED command:

```sh
uv run --no-sync python tests/helpers/duplication_scan_yaml_checks.py
```

Exit 1: all three tests failed on the original production code. Nine runtime
mapping subcases omitted the oversized attempt, the matrix-key consumer omitted
it too, and the safe alias graph emitted 1,026 hints. After the production change,
the same command exited 0 with all three tests passing.

Runtime controls cover `jobs`, `runs`, `jobs: {}` plus `startup`, and a `checks`
control at both YAML suffixes and a nested workflow-directory data path. Actual
workflow files and local action metadata retain inert comment/description
controls. A synthetic Python reader consumes `${{ toJSON(matrix) }}` from `DATA`
and executes its keys; unused keys in another job and metadata remain inert.
The alias fixture is under 600 bytes at depth ten and now emits fewer than 100
hints without raw fallback. A separate low work-budget control verifies raw
fallback, and aliases shared across jobs preserve the later job's inherited env.
All reachable controls use production inventory and the CLI in dry-run and
simulated live modes: oversized blobs are attempted, rejected before download,
counted twice across the two fixture repositories, and make coverage partial and
reconciliation blocked with zero writes. Fixture source is never executed.

The focused GREEN BATS command exited 0 with all 23 cases passing. The existing
transport/catalog Python command passed both cases, and the existing dependency
helper passed all eighteen tests:

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py \
  Cases.test_fetch_external_dependencies \
  CatalogDependencyCases.test_catalog_non_yaml_dependency
uv run --no-sync python tests/helpers/duplication_scan_dependency_checks.py
```

Initial formatting found an import-order issue and two long lines, which were
corrected. The first nine-tool check passed eight tools and duplicate-code
count zero against baseline zero; Pylint rejected the enlarged nested collector's
local/statement counts. The new collector was isolated in a small helper class
without suppressions, and all three new Python tests passed again. An earlier
full scanner run was stopped after 67 passing cases to restart on this final
implementation.

All commands clear `UV_PROJECT_ENVIRONMENT`, `VIRTUAL_ENV` and `PYTHONPATH` before
launch. Lintro and mypy imports were verified at the prepared Lintro installation
and the existing compatible mypy installation described above. The R4 lint argv
uses this explicit changed list and checks all scanner modules/helpers together:

```sh
unset UV_PROJECT_ENVIRONMENT VIRTUAL_ENV PYTHONPATH
export LINTRO_LOG_DIR=/home/eitel/.hermes/profiles/coder/ci-runner/evidence/lintro
export PYTHONPATH="/home/eitel/.local/share/uv/tools/lintro/lib/python3.14/site-packages:\
/home/eitel/Code/py-lintro/.venv/lib/python3.14/site-packages:\
$PWD/scripts/ci/maintenance"
uv run --no-sync python - <<'PY'
import subprocess
from pathlib import Path

changed = [
    "docs/duplication-scan-coverage-1237.md",
    "scripts/ci/maintenance/duplication_sources.py",
    "tests/bats/unit/maintenance/test_duplication_scan.bats",
    "tests/helpers/duplication_scan_yaml_checks.py",
]
scoped = sorted(set(changed) | {
    str(path)
    for pattern in (
        "scripts/ci/maintenance/duplication_*.py",
        "tests/helpers/duplication_scan_*.py",
    )
    for path in Path(".").glob(pattern)
})
for action, tools, paths in (
    ("fmt", "black,ruff,typos,prettier", changed),
    ("chk", "black,ruff,mypy,pylint,typos,bandit,prettier,markdownlint,gitleaks", scoped),
):
    assert paths and ".venv" not in paths
    subprocess.run([
        "uv", "run", "--no-sync", "python", "-m", "lintro",
        action, "--tools", tools, *paths,
    ], check=True)
PY
```

Formatting and the scoped check each exited 0. All nine tools passed with zero
skips: Black, Ruff, mypy, Pylint, typos, Bandit, Prettier, markdownlint and
gitleaks. Duplicate-code count stayed zero against baseline zero. Existing
module-size notices remain non-blocking. No packages or environments were
installed, and the shared untracked `.venv` link remains excluded from staging.

The final complete scanner command exited 0: all 254 cases passed, including all
251 existing cases, with zero failures and zero skips. BATS emitted its existing
missing bats-file fallback warning.

```sh
bats tests/bats/unit/maintenance/test_duplication_scan.bats
```

The 256 KiB blob limit, privacy, compiler-warning suppression, newline behavior,
cyclic/deep fail-closed handling and reconciliation guards remain intact. Raw
runtime/fallback hints can increase conservative reads and reveal genuine
omissions. Other preexisting YAML traversal behavior and #1258 deferrals remain
outside this repair. No public replay or full-org acceptance is claimed. A
postmerge full-org zero-omission dry run and owner review still gate the separate
subsequent PR. Live reporting remains off; no adoption issues, activation or
settings were changed.

## PR #1267 revision 5

This revision addresses only the two reproduced P2 omissions: hash-prefixed
opaque runtime data and executable paths carried through outputs. Unsupported
files now default to `unknown`. Supported `.sh`/`.bash` suffixes and supported
shebangs still remove genuine shell comments; unsupported shebangs retain raw
hints. Python comment, privacy and newline behavior is unchanged.

Output discovery defers job/step mapping hints until every producer has been
visited, so a downstream consumer can precede its producer in YAML source order.
Action and callable-workflow declarations collect only `value` fields, excluding
output names/descriptions. An exported value also makes its producer mappings
reachable: `${{ jobs.check.outputs.script }}` must retain the literal path in
`jobs.check.outputs.script` even if the called workflow has no internal consumer.
These hints use the existing deduplication, alias identities and work budget.
They do not resolve expressions or alter normalization/matching.

Two BATS regressions were added before the production changes:

```sh
unset UV_PROJECT_ENVIRONMENT VIRTUAL_ENV PYTHONPATH
bats --filter 'opaque hash-prefixed|reachable output values' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
```

RED: exit 1, both cases failed on missing oversized attempts. Six opaque file
subcases failed, as did direct, env-mediated and action-argument job-output
consumers. Separate production CLI probes reproduced both original findings in
both modes: `partial=False`, no oversized attempt and unblocked reconciliation;
simulated live recorded one opaque-data fixture write and two output fixture
writes. After the fixes, those four probes all attempted the oversized blob,
reported partial coverage and blocked reconciliation with zero fixture writes.
Dry-run exited 0 and simulated live exited 1, as required for partial coverage.

The callable-workflow output chain received its own RED/GREEN check. Before
marking exported values as consumers, this command exited 1 on the missing
oversized attempt; afterward it passed:

```sh
uv run --no-sync python tests/helpers/duplication_scan_yaml_checks.py \
  Cases.test_reachable_output_values
```

Opaque controls cover text, Markdown, Dockerfile, extensionless data, `.env`,
unsupported shell suffixes and unsupported shebangs. Supported shell comments
stay inert. Output controls cover job values, generated step outputs, action
exports, callable-workflow exports and inert output descriptions/names beside
opaque consumers. Every reachable oversized fixture input uses production inventory and
the real CLI in dry-run and simulated live modes, is rejected before download,
is counted as an omission and blocks all fixture issue writes. Subprocesses are
forbidden in these fixtures; scanned source is never executed.

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_yaml_checks.py
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py \
  Cases.test_fetch_external_dependencies \
  CatalogDependencyCases.test_catalog_non_yaml_dependency
bats --jobs 4 tests/bats/unit/maintenance/test_duplication_scan.bats
```

The focused BATS command passed all 25 cases. The YAML helper passed all five
tests, and the transport/catalog command passed both tests. The initial serial
full-suite run was stopped after 59 passing cases to restart after the exported
output-chain fix. The restarted command uses the already-installed GNU parallel;
no tools, packages or environments were installed.
The complete restarted scanner suite exited 0: all 256 cases passed, including
all 254 existing cases, with zero failures and zero skips. BATS emitted its
existing missing bats-file fallback warning.

Lint uses exactly the R4 environment and Python-built argv above, with the same
four changed paths and all scanner modules/helpers checked together. Initial
checks found long fixture lines, fixture type inference errors and collector
complexity; none was waived. The existing compatible Lintro/mypy imports were
verified before checking. The shared untracked `.venv` is excluded from staging.
Formatting exited 0. The scoped nine-tool check exited 0 with Black, Ruff,
mypy, Pylint, typos, Bandit, Prettier, markdownlint and gitleaks all passing,
zero skipped tools and duplicate-code count zero against baseline zero. Existing
module-size notices remain non-blocking.

Exact output-reference resolution remains unavailable. Job/step output hints are
conservative across the document when executable data consumers exist; exported
values are conservative for callers outside the document. Raw opaque data can
also increase reads and expose genuine omissions. Earlier public replay counts
do not establish acceptance for this revision. The 256 KiB limit, privacy and
genuine omission accounting remain unchanged. The postmerge full-org
zero-omission dry run still gates the separate matcher PR. Live reporting remains
off; no adoption issues or activation changes were made.

## PR #1267 revision 6

This revision repairs the reproduced P2 in thread `PRRT_kwDOREx45M6yfxJR`.
GitHub interpolates expressions before the run block's interpreter parses
comments. For example, this expression can produce a comment followed by an
executable command:

```yaml
run: |
  # ${{ fromJSON('"\n./tests/unit/oversized.py"') }}
```

Workflow and composite run-block discovery now retains expression spans as raw
dependency hints before shell/Python comment removal. It also keeps a hint copy
with literal backslash-n/r/t spellings treated as boundaries, so the spelling of
those directly embedded escapes cannot become a spurious path prefix. This
did not cover Unicode newline escapes or escapes in env/input/matrix/output
values; revision 7 below repairs those reproduced gaps. This is conservative
hint extraction, without evaluating expressions, decoding arbitrary payloads or
changing normalization/matching. The hints use the existing deduplication and
65,536-visit budget; exhaustion retains raw source. Fetched shell/Python script
files receive no GitHub interpolation treatment, and literal documentation
comments remain inert.

Both complete final reviews of the starting `2a55759` head were read before
editing: Sonnet and Opus approved. Opus also reproduced the opaque Dockerfile
and Markdown routes to the original oversized public source. The opening and
626-file claims above now distinguish historical measurements from that current
limitation. Opaque-file conservatism, the 256 KiB bound and genuine omission
accounting are unchanged; this revision claims no full-org acceptance.

Two regressions were added before the production repair:

```sh
unset UV_PROJECT_ENVIRONMENT VIRTUAL_ENV PYTHONPATH
bats --filter 'templated comment expressions|literal comment controls' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
```

RED: exit 1, one case failed and the literal-comment control passed. All four
workflow/composite Bash/Python expression subcases missed the oversized attempt.
Separate production-inventory CLI probes in both modes reproduced the original
shell finding at both metadata paths: no oversized attempt, `partial=False`,
unblocked reconciliation, and two workflow or three composite fixture writes in
simulated live mode. Matched literal command controls attempted the genuine
oversized blob, reported partial coverage and blocked reconciliation with zero
fixture writes. Merely retaining raw spans still failed the escaped-newline
shell cases; the boundary hints fixed those failures.

The direct two-test command then exited 0:

```sh
uv run --no-sync python tests/helpers/duplication_scan_yaml_checks.py \
  Cases.test_templated_comment_dependencies Cases.test_literal_comment_controls
```

Every reachable regression uses production inventory and the real CLI in dry-run
and simulated live modes. The oversized input is genuine tree metadata above
the bound, attempted and rejected before download, counted as an omission and
required to block fixture writes. The transport forbids subprocess execution;
fixture source and expressions are never executed. Controls include literal
shell/Python comments in both metadata schemas and expression-looking comments
in untemplated external shell/Python files.

The final focused commands exited 0: 27 BATS cases, seven YAML helper tests and
two existing transport/catalog tests passed:

```sh
bats --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
uv run --no-sync python tests/helpers/duplication_scan_yaml_checks.py
uv run --no-sync python tests/helpers/duplication_scan_regression_checks.py \
  Cases.test_fetch_external_dependencies \
  CatalogDependencyCases.test_catalog_non_yaml_dependency
```

After the repair, the twelve production CLI probes at both metadata paths also
passed their assertions. Expression and matched literal-command cases attempted
the oversized input, reported partial coverage and blocked reconciliation with
zero fixture writes: dry-run exit 0, simulated live exit 1. Inert comment cases
remained nonpartial and unblocked, with simulated fixture writes permitted.

The existing shared `.venv` link was preserved and excluded from staging.
Commands clear inherited `UV_PROJECT_ENVIRONMENT`, `VIRTUAL_ENV` and `PYTHONPATH`
and use exactly the R4 environment and Python-built nonempty lint argv above,
with the same four changed paths and all scanner modules/helpers together.
Lintro imported from the prepared tool installation, and mypy imported from the
existing compatible py-lintro environment. Formatting exited 0 with all four
tools passing. The scoped check exited 0: Black, Ruff, mypy, Pylint, typos,
Bandit, Prettier, markdownlint and gitleaks all passed, with zero skips and
duplicate-code count zero against baseline zero. Existing module-size notices
remain non-blocking. No packages, tools or environments were installed.

```sh
bats --jobs 4 tests/bats/unit/maintenance/test_duplication_scan.bats
```

The complete scanner suite exited 0: all 258 cases passed, including the 256
existing cases and both new regressions. No failures or skips occurred. BATS
emitted its existing missing bats-file fallback warning. The final verification
notes were then included in the scoped formatting/lint check; no scanner source
or fixture changed after the complete suite.

No whole-repository suite, Docker run, installation, real source execution or
GitHub mutation was performed. Live reporting remains off with no adoption
issues. The full-org zero-omission dry run remains a separate postmerge gate for
the matcher PR, and the opaque Dockerfile/Markdown limitation above can keep it
partial. Other nonblocking work remains deferred to #1258.

## PR #1267 revision 7

Both complete reviews of starting head `b265ae0` were read: Sonnet approved;
Opus requested changes for the reproduced escaped-newline gap. Fresh bot thread
`PRRT_kwDOREx45M6ygMmi` independently identified missing runtime conditions.

Scoped YAML string collection now keeps the original hint and at most one
separator copy for JSON whitespace spellings `\n`, `\r`, `\t` and their
`\u000a`, `\u000d`, `\u0009` equivalents. This covers directly interpolated
expressions and values carried through scoped env, input defaults, matrix and
outputs. It does not evaluate expressions or decode payloads, add hex escape
support, or change matching/normalization. Deduplication and the existing
65,536-visit bound remain; exhaustion retains raw source. Only already scoped
execution data reaches this collector. Documentation, unused data and data in
other job scopes retain their existing exclusions.

Recognized workflow job/step and composite step `if` expressions now contribute
runtime hints even when the run command is a literal `printf ok` that consumes
no environment data. Both implicit conditions and `${{ ... }}` forms are covered.
The same strings in descriptions and names remain inert.

Three new BATS cases exercise production inventory and the real CLI through the
offline transport. Escaped values cover workflow/job/step env, dispatch/call
inputs, matrix, cross-job outputs and composite env/inputs/exported outputs.
Matched controls include literal execution, unused scoped data, description/name
data and the existing workflow/composite and fetched-script literal comments.
Every reachable oversized dependency must be attempted and rejected before
download, counted as a genuine omission, and block reconciliation with zero
fixture writes in dry-run and simulated live modes. The transport forbids
subprocess execution; fixture code and expressions are never evaluated.

Evidence is outside the scanned source at
`/home/eitel/.hermes/profiles/coder/ci-runner/evidence/1237-coverage-r7/`.
`red-final-cli.json` records 94 probes over 47 fixtures: 56 failed the expected
reachability/blocking assertions on the starting production code. All inert and
literal executable controls passed. `red-final-bats.log` exited 1: the escaped
data case failed in twenty scopes/spellings, the condition case failed in six
scopes/forms, and the inert scope case passed. `green-final-cli.json` passes all
94 probes after the repair: all 78 reachable probes attempt the oversized blob,
report partial coverage and block reconciliation with zero fixture writes. The
sixteen inert probes remain nonpartial and unblocked; simulated fixture writes
are permitted. The first BATS launch overlapped an edit and is excluded from RED
evidence; the final RED run used the original production source throughout.

The focused verification command is:

```sh
bats --jobs 4 --filter 'dependency coverage|fetches external script|non-YAML catalog' \
  tests/bats/unit/maintenance/test_duplication_scan.bats
```

Lint uses the R4 environment and Python-built explicit nonempty argv above,
including all related scanner modules/helpers for the duplicate-code check.
Initial checks found formatting, fixture typing and statement/branch-budget
errors; those were corrected without suppressions or rule changes. An initial
full scanner run was stopped before collecting results to check the corrected
final source. No installations, environment synchronization, Docker runs or
whole-repository suites were used.

Final focused BATS exited 0 with all 30 cases passing. The complete scanner
command below also exited 0: all 261 cases passed, with zero failures or skips.
The source/test hashes remained unchanged through the completed suite.

```sh
bats --jobs 4 tests/bats/unit/maintenance/test_duplication_scan.bats
```

Formatting exited 0 with Black, Ruff, typos and Prettier passing. The scoped
nine-tool check exited 0: Black, Ruff, mypy, Pylint, typos, Bandit, Prettier,
markdownlint and gitleaks all passed, zero tools skipped, duplicate-code count
zero against baseline zero. Existing module-size notices and the BATS missing
bats-file fallback warning remain nonblocking. The existing shared `.venv`
was preserved and excluded from staging. Final documentation notes are included
in the scoped formatting/check commands; scanner source/tests are unchanged.

The 256 KiB limit, source/privacy/schema/context/alias guards and fail-closed
omission accounting remain unchanged. Genuine opaque Dockerfile/Markdown
dependencies can still reach the 397,610-byte source and keep the next full-org
dry run partial; this revision makes no zero-omission or CI-success claim.
The full-org zero-omission dry run remains a postmerge gate for the separate
matcher PR. Live reporting remains off, with no adoption issues or activation
changes. Other nonblocking work remains deferred to #1258.
