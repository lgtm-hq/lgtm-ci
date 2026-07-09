# AGENTS.md

## Cursor Cloud specific instructions

`lgtm-ci` is a CI/CD toolkit, not a long-running service. The "application" is a
set of Bash libraries/scripts (`scripts/ci/`), GitHub composite actions and
reusable workflows (`.github/`), tested with BATS and linted with `lintro`
(Python, run via `uv`). There is no server/daemon to start.

### Quick reference (standard commands live elsewhere)

- Tests: `make test-bats` (== `bats --recursive tests/bats`); coverage +
  threshold via the CI runner `scripts/ci/actions/run-bats-tests.sh`
  (`STEP=run-coverage`, then `STEP=parse-coverage`). CI wiring is in
  `.github/workflows/ci.yml` / `reusable-test-shell.yml`.
- Lint: `make lint` (== `uv run lintro chk`). `Makefile` also has `fmt`.
- Run a component directly, e.g. `bash scripts/ci/release/calculate-version.sh`
  (reads git history; see the script header for env vars).

### Non-obvious caveats

- **Two known BATS failures are environment-only, not code bugs.** The cloud VM
  installs a global git `insteadOf` rule that rewrites `github.com` remotes to an
  `https://x-access-token:...@github.com/` form (needed for `git push`). This
  breaks two `get_git_remote_url` tests in `tests/bats/unit/lib/test_git.bats`
  (expected raw `git@`/`https://` URLs). Expect `2724 passed / 2 failed` locally;
  all tests pass in CI. Do not "fix" these by editing code or the global git
  config.
- **Local lint is intentionally partial.** `uv run lintro chk` runs the tools
  present on this VM (`ruff`, `black`, `shellcheck`, `shfmt`, `yamllint`,
  `markdownlint`, `prettier`, `hadolint`) and **SKIPs** security/type tools not
  installed here (`bandit`, `mypy`, `gitleaks`, `osv-scanner`, `semgrep`,
  `taplo`, `pydoclint`, `actionlint`). SKIP does not fail the run. For full
  tool parity (what CI enforces) use the pinned Docker image via
  `STEP=check bash scripts/ci/quality/run-lintro-docker.sh` (see README
  "Development"); this needs Docker + `ghcr.io/lgtm-hq/py-lintro` pull.
- **`lintro` is strict about tool versions.** It SKIPs tools below its minimums
  (e.g. it wants `shellcheck>=0.11`, `shfmt>=3.13`, `yamllint>=1.37.1`); the
  distro-packaged versions are too old, so newer builds are installed to
  `/usr/local/bin` and `~/.local/bin` which precede `/usr/bin` on `PATH`.
- **BATS helper libs** (`bats-support`/`bats-assert`/`bats-file`) are symlinked
  into `/usr/lib/bats-*` because `tests/helpers/common.bash` searches that path;
  without them tests fall back to weaker built-in stubs.
- **Coverage needs `kcov`** (built from source, `v43`) plus `nc`
  (netcat-openbsd) for the `network/port.sh` listener test.
- **Run `make clean` before `uv run lintro chk` after a coverage run.** kcov
  writes generated `.sh` helpers into `coverage-report/`, which is git-ignored
  but is *not* in lintro's exclude list, so shellcheck lints them and fails
  (e.g. SC3040/SC3047). `make clean` removes `coverage-report/` and `.lintro/`.
- Tooling lives on `PATH` via `~/.bashrc`: `uv` at `~/.local/bin`, npm globals
  at `~/.npm-global/bin`. Python deps live in `.venv` (managed by
  `uv sync --extra dev`; dev tools are a `[project.optional-dependencies]`
  extra named `dev`, so `--extra dev` is required — plain `uv sync --dev` is a
  no-op here).
