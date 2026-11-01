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

Replaying the original discovery fetched 1090 files from 216 initial sources,
with the single oversized omission. Replaying the repaired discovery on that
same tree fetched 626 files, with zero oversized omissions and no parent edge to
the oversized file. A final replay through the production `GitHub.files()` and
`units()` functions confirmed 626 blob requests, 236 units and no partial scan.
This establishes the public py-lintro repair; it does not replace the full-org
workflow acceptance run.

## Bounded repair

YAML discovery inspects workflow jobs, action execution steps, actual local
`uses` targets and JavaScript action entry points. Workflow/job defaults select
the effective run language; step shells override them. Descriptions, comments,
outputs and input/environment data do not become executable dependency hints.
Shell comments use the existing bounded lexer. Python comments and proven
module/function/class docstrings use the standard tokenizer and AST. Invalid
Python and unsupported languages retain conservative raw hints. Executable
strings remain available for discovery; normalization independently keeps
uninspected launchers, imports and unknown execution opaque.

No size limit, byte budget, privacy rule, reconciliation guard or fingerprint
version changed. Genuine outside-selected dependencies remain discoverable,
including recursively sourced files with non-script extensions. Their oversized
omissions still make the scan partial and block matched reconciliation.

## Verification

All commands unset inherited `UV_PROJECT_ENVIRONMENT`, `VIRTUAL_ENV` and
`PYTHONPATH` before launch. Evidence logs remain in the worker's local
`.1237-evidence/` directory.

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
The resolved `lintro.__file__` was
`/home/eitel/.local/share/uv/tools/lintro/lib/python3.14/site-packages/lintro/__init__.py`.
Exact file arguments and the explicit Pylint tool-process `PYTHONPATH` are kept
in the lint logs. Formatting passed. Black, Ruff, Pylint and typos passed, with
duplicate-code count zero against baseline zero. The initial worker check skipped
mypy because it was unavailable in that prepared environment; this was not treated
as a passing gate. Independent verification exposed the already-installed mypy
package through `PYTHONPATH`, keeping the intended Lintro wheel first, without
installing dependencies or changing another environment. It found two untyped
fixture return values. Explicit casts repaired those annotations; the scoped mypy
check then passed, and all seven focused BATS cases independently passed again.
A fresh authorized full-org dry run and owner review remain required before live
activation. Live reporting remains off.
