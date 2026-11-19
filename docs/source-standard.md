# Python source standard

The Python under `scripts/ci` follows the repository's Python standard (#1626). Two parts of it
are enforced in CI; the rest is recorded here with the decisions taken.

## Enforced: the `🐍 Source Standard` job

`scripts/ci/quality/validate_source_standard.py` reads every `*.py` file under `scripts/ci` and
fails on:

- **A missing docstring.** Every module, class and function needs a Google-style docstring:
  private and nested functions and dunder methods included. One line is enough when it says what
  the function does. `__init__` is the exception: its class docstring documents it, and pydoclint
  (`DOC301`, run by lintro) rejects a docstring on it. There is no baseline: the tree has none
  left.
- **A module over 400 lines** that `scripts/ci/quality/module-length-exceptions.txt` does not
  list. Each entry there is `path reason`. The list only shrinks:
  - an entry whose module is now within 400 lines, or gone, fails until it is deleted;
  - on a pull request or merge group the check compares the list with the copy in `HEAD^1`, the
    base the merge commit was built on, and fails on a new entry. Split a new long module instead
    of listing it. A push skips this comparison. The CI job passes `fetch-depth: 2` to
    `reusable-validate.yml` so that commit is in the checkout; renaming a listed module counts as
    a new entry and needs a maintainer override.

Run it locally:

```bash
uv run python scripts/ci/quality/validate_source_standard.py --summary
uv run python scripts/ci/quality/validate_source_standard.py --base-ref origin/main
```

ruff's `D1` rules were not used for the docstring rule: they skip private and nested functions,
which the standard covers, and the repository's single ruff configuration would apply them to
`tests/` as well. Module length has no ruff rule.

## Python version and `python3 -I`

Some scripts run as `python3 -I` from the tooling checkout. Isolated mode leaves the script's
directory off `sys.path`, but it does not bind a script to one file: a split module loads through a
`sys.path` fallback. `scripts/ci/lib/apt_helper.py` puts its own directory on `sys.path` when it is
missing, then imports `apt_failover.py`, `apt_mirrors.py`, `apt_sources.py` and `apt_stream.py`
from there (the imports carry `noqa: E402` and pylint's `wrong-import-position` disable).
`apt_mirrors.py` loads `apt_failover.py` and `apt_sources.py`, and `apt_failover.py` loads
`apt_sources.py`, through a `try`/`except ImportError` fallback that inserts the same directory.
No module under `scripts/ci` is bound to a single file today.

`apt_helper.py` and the modules it loads (`apt_stream.py`, `apt_sources.py`, `apt_mirrors.py`,
`apt_failover.py`) run on whatever `python3` the runner has, which is 3.10 on `ubuntu-22.04`. They
stay standard-library only and 3.10-compatible. That is why their two
enumerations (`_Mode`, `_End`) stay plain `Enum` with `auto()` rather than `StrEnum`, which needs
Python 3.11; their values are never read, only compared by identity.

## Keyword arguments

The standard asks for explicit keyword arguments when a call passes more than one argument.

No ruff rule available through lintro enforces that. The nearest rules are partial:

- `FBT001`, `FBT002` and `FBT003` cover boolean positional parameters and boolean positional values
  only (31 findings under `scripts/ci` on 2026-11-18);
- `PLR0917` limits positional parameters in a definition (more than five), not positional arguments
  at a call.

Decision (#1626): no linter rule is enabled for this. Calls to this repository's own functions that
pass two or more positional arguments are changed to keyword arguments in a later slice of #1626,
module by module, and new code writes them with keywords. Calls into the standard library and
third-party packages are left alone: many of their parameters are positional-only.
