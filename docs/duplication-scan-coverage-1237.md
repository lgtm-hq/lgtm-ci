# Duplication scan coverage repair: #1237

The successful [dry run 41323741728](https://github.com/lgtm-hq/lgtm-ci/actions/runs/41323741728)
still reported partial coverage and blocked reconciliation. This repair addresses
that existing acceptance item. Live reporting remains disabled pending owner
review, a fresh complete dry run and resolution of the remaining acceptance gate.

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

Before the PR revision described below, replaying the original discovery fetched
1090 files from 216 initial sources,
with the single oversized omission. Replaying the repaired discovery on that
same tree fetched 626 files, with zero oversized omissions and no parent edge to
the oversized file. A final replay through the production `GitHub.files()` and
`units()` functions confirmed 626 blob requests, 236 units and no partial scan.
Those measurements establish the initial public py-lintro repair. They have not
been repeated for this revision and do not replace the full-org acceptance run.

## Bounded repair

YAML discovery inspects workflow jobs, action execution steps, actual local
`uses` targets, JavaScript action entry points and Docker execution metadata.
Workflow/job defaults select
the effective run language; step shells override them. Descriptions, comments,
outputs and arbitrary mappings do not become executable dependency hints.
Workflow/job/step environments, action `with` values and action/dispatch/call
input defaults retain scoped hints when referenced or passed to an unresolved
consumer. Job matrix data, including include/exclude entries and unresolved
expressions, retains hints in that job's execution scope without expanding or
evaluating combinations. Docker entrypoint, pre-entrypoint, post-entrypoint,
image and arguments retain hints alongside scoped environment/input data;
Docker normalization remains opaque. Literal shell data commands without
expansion can omit unused values. Shell comments use the existing bounded lexer.
Python comments use the standard tokenizer with AST validation. All Python
docstrings retain hints because external consumers can read them without local
reflection names; this bounded pass cannot prove them inert. Compiler warnings from
untrusted parsing are suppressed locally, without executing source or changing
the process-wide warning policy. Newline handling matches AST/tokenizer
coordinates, including strings containing control/Unicode separators. Invalid
Python and unsupported languages retain conservative raw hints. Executable
strings remain available for discovery; normalization independently keeps
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
