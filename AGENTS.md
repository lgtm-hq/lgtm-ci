# AGENTS.md

Standing context for agents working in this repository. It is binding and holds repository facts
only; the docs it links hold the detail. Read it in full before changing anything.

## House standards pointers

Run every command from the repository root. Precondition for anything that starts with `uv run`:

```bash
uv sync --extra dev --extra test
```

- **Python:** `uv` only (`uv sync`, `uv run`). The project needs Python 3.11 or newer.
- **JavaScript:** `bun` is the house tool, but this repository has no JavaScript project of its
  own. The `package.json` and `package-lock.json` pairs under `scripts/ci/ai-review-cli/` are
  integrity-pinned install manifests that `scripts/ci/actions/install-ai-review-cli.sh` installs
  with `npm ci` on the runner; `tests/fixtures/npm-set/` is test data.
- **Lint and format:** `lintro` is the only entry point; never call ruff, black, prettier,
  markdownlint and the rest directly.

  ```bash
  uv run lintro chk
  uv run lintro fmt
  ```

  CI runs lintro inside the pinned `ghcr.io/lgtm-hq/py-lintro` image, which bundles pylint; a
  local `uv run lintro chk` skips pylint when it is not installed. Reproduce the CI pylint pass
  (pylint needs `pytest` and `pyyaml` beside it, as CI's init-hook in `pyproject.toml` provides),
  then remove the tool again:

  ```bash
  uv tool install 'pylint>=4.0.8' --with pytest --with pyyaml
  uv run lintro chk --tools pylint
  uv tool uninstall pylint
  ```

  The full Docker mirror of the CI lint job is in [docs/README.md](docs/README.md#development).

- **Generators.** Edit the source, regenerate, and commit both. Each `--check` exits 1 on drift:

  | Generated output                                                                | Check                                                              |
  | ------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
  | Inline blocks ([inline-shell.md](docs/inline-shell.md))                         | `uv run python scripts/ci/bootstrap/sync_inline_blocks.py --check` |
  | Egress presets in workflows                                                     | `bash scripts/ci/egress/sync-workflow-presets.sh --check`          |
  | Read-only and overlay workflow variants (incl. `reusable-test-node-custom.yml`) | `bash scripts/ci/workflows/sync-readonly-variants.sh --check`      |
  | `docs/catalog.md` and the README component index                                | `uv run python scripts/ci/catalog/render.py --check`               |

  Drop `--check` to write (`render.py --write` for the catalog).

- **Validators** (each is a CI job in `.github/workflows/ci.yml` or a bats contract test):

  ```bash
  uv run python scripts/ci/catalog/validate.py
  uv run bash scripts/ci/catalog/check-deprecations.sh
  uv run python scripts/ci/docs/validate-doc-pins.py
  uv run python scripts/ci/docs/validate-caller-permissions.py
  uv run python scripts/ci/quality/validate_inline_shell.py
  uv run python scripts/ci/quality/validate_test_standard.py
  uv run python scripts/ci/quality/validate_source_standard.py
  uv run bash scripts/ci/quality/validate-tooling-token.sh
  ```

  The deprecation gate compares with `origin/main`, so fetch it first. The `uv run bash` form puts
  the synced interpreter (with PyYAML) on `PATH` for the shell entry points. Rules:
  [governance.md](docs/governance.md#commands), [inline-shell.md](docs/inline-shell.md),
  [source-standard.md](docs/source-standard.md), test standard in
  [docs/README.md](docs/README.md#development).

- **Tests.** pytest suites live in `tests/python`, bats suites in
  `tests/bats/{unit,integration,contract}`, shared helpers in `tests/helpers`, fixtures in
  `tests/fixtures`. Run one file at a time:

  ```bash
  uv run pytest tests/python/test_coverage_config.py
  bats tests/bats/unit/actions/test_apply_build_env.bats
  ```

  The bats suite is about 6,800 tests in about 390 files and CI shards it eight ways; a full local
  run takes a long time and loads the machine, so run the files your change touches and leave the
  full suite to CI.

## Contract

- **Merges** are squash merges of signed commits, after every required check is green, every review
  thread is resolved, and the external consumer canary
  (`.github/workflows/external-consumer-canary.yml`) has passed. Required check names are in
  [org-rulesets.md](docs/org-rulesets.md). When the canary fails on an infrastructure flake,
  re-run it or ask; never add the owner-only `canary-informational` label to get past it.
- **Releases** come from the release bot (`.github/workflows/release-version-pr.yml` opens
  `chore(release): version X.Y.Z` pull requests); never bump a version by hand. Which commit types
  release is in the org conventions below. A change that breaks callers takes `!` in its title and
  an entry in the next `docs/migration/` note: [governance.md](docs/governance.md#release-notes),
  [deprecation lifecycle](docs/governance.md#deprecation-lifecycle).
- **Agent writes.** Every agent-performed git or GitHub write (commit, push, pull request, comment,
  review reply, thread resolution, release, merge) goes through the repository's agent identity
  tooling, never a personal credential. In the maintainer's local setup that is `lgtm-ai`. If it
  fails, stop the write and report the failure.
- **Review before a merge.** Run `uv run lintro chk`, the checks above that your change touches,
  and the affected test files. Read and answer every review comment on the pull request, fix what
  is right, say why for what is not, and resolve the thread.
- **Keep going or ask.** Proceed on your own unless the decision belongs to the owner. These do:
  a change to security posture (egress, permissions, token scopes, pinning policy), a breaking
  change for adopters, a ruleset or required-check change, and anything that spends money. Ask
  for those; do the rest.

## Standing constraints

- **Egress:** `block` mode with exact hosts. Never add a wildcard on a domain outsiders can
  register (for example `*.blob.core.windows.net`). See
  [workflow-contract.md](docs/workflow-contract.md#egress-allowlists).
- **No inline shell** in workflows or actions beyond the two documented exceptions (generated
  copies and trivial steps): [inline-shell.md](docs/inline-shell.md).
- **Actions pinned by full commit SHA:**
  [workflow-contract.md](docs/workflow-contract.md#action-pinning-policy).
- **Standard-library-only scripts.** Scripts run as `python3 -I` from the tooling checkout use
  only the standard library; `scripts/ci/lib/apt_helper.py` and the modules it loads
  (`apt_stream.py`, `apt_sources.py`, `apt_mirrors.py`, `apt_failover.py`, `apt_record.py`) also
  stay compatible with Python 3.10 (the `ubuntu-22.04` runner). The list and reasons are in
  [source-standard.md](docs/source-standard.md#python-version-and-python3--i) and
  `scripts/ci/quality/module-length-exceptions.txt`.
- **No downstream names.** Never name an organisation or company that runs a copy of this
  repository, in code, docs, commits, issues or pull request text. Write "an adopter" or "a copy
  under another namespace".

## Org preset

Shared organisation rules (commit conventions, pull request process, lint entry point) live in
[lgtm-hq/.github CONTRIBUTING.md](https://github.com/lgtm-hq/.github/blob/main/CONTRIBUTING.md).
This file adds only what is specific to lgtm-ci; the docs index is [docs/README.md](docs/README.md).
