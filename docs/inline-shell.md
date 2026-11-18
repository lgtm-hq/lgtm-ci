# Inline shell in workflows and actions

The rule: shell code does not live inline in a workflow or composite action
file. It lives in a `.sh` or `.py` file under `scripts/`, where it is linted,
formatted and tested, and the `run:` step calls that file. Values reach the
script through the step's `env:`.

There are two documented exceptions, both decided by the owner on 2026-11-17
(#1624): **generated copies** of tested script files, and **trivial** steps
that only report or stop. Everything else moves to a script file.

The CI job `🐚 Inline Shell` runs
`scripts/ci/quality/validate_inline_shell.py`, which enforces all of this on
every `run:` step of `.github/workflows/*.yml` / `*.yaml` and
`.github/actions/**/action.yml` / `action.yaml`. Run it locally:

```bash
uv run python scripts/ci/quality/validate_inline_shell.py --summary
```

A step it rejects is printed as
`file:line: job / step: [rule N: title] what breaks it`, for example:

<!-- markdownlint-disable MD013 -- exact check output -->

```text
.github/workflows/x.yml:120: build / Fetch data: [rule 1: only echo, printf, exit, true, false in one conditional] line 1: runs `curl`, which is not echo, printf, exit, true or false
```

<!-- markdownlint-enable MD013 -->

## What counts as a script call

A step is a script call when its whole script is **one command that runs a
script file**, and nothing else: no `;`, `&&`, `||`, pipe, redirection,
second command or command substitution. Its shape is
`[INTERPRETER [OPTION]] PATH [ARGUMENT...]`:

- INTERPRETER is optional: `bash`, `sh`, `python`, `python3` or
  `/usr/bin/python3`. The only option allowed is `-I` for Python; `bash -c`
  and `python3 -c` run inline code and are rejected.
- Each ARGUMENT is a literal word or a plain variable: `$NAME`, `${NAME}` or
  `${NAME:-word}`.
- PATH is one of:
  - a file of this repository under `scripts/`, written relative to the
    repository (`scripts/...`, `./scripts/...`), to a tooling checkout of it
    (`.lgtm-ci-tooling/scripts/...`, `.lgtm-ci-readiness/scripts/...`), to
    `$GITHUB_WORKSPACE`, to `$SCRIPTS_DIR` (the composite actions' name for
    `scripts/`) or, in a composite action, to `$GITHUB_ACTION_PATH`
    (`$GITHUB_ACTION_PATH/../../../scripts/...`). The file must exist;
  - in a composite action, a file next to its `action.yml`
    (`$GITHUB_ACTION_PATH/name.sh`). The file must exist;
  - a path built from a variable set in the step's own `env:`, alone or after
    one of the prefixes above, such as `bash "$GITHUB_WORKSPACE/$AUDIT_SCRIPT"`
    for a caller-selected script. The runner hands the value over as data,
    never as shell code; the reusable documents which script it runs;
  - a staged copy listed in `STAGED_COPIES` in
    `scripts/ci/quality/inline_shell_rules.py`, with its tested source. Today
    that is `${RUNNER_TEMP}/check-tooling-ref-divergence.sh`, which
    `checkout-and-harden` copies out of its bootstrap checkout before the
    tooling it judges is on disk.

## Exception 1: generated copies

**Decided 2026-11-17.** Some steps run before this repository's scripts are
on disk in the calling job, for example the harden-runner agent check, which
runs before the first checkout. Such a step carries a **generated copy** of a
script file. The copy is kept because the file is linted, formatted and
tested as a script, the generator writes it into the workflows, and a check
fails when a copy differs from its source.

Not chosen: replacing the copies with composite actions referenced by commit.
That would remove all shell from the workflow files, but `uses:` cannot hold
an expression, so every reference would spell out the owner and repository,
and a copy under another namespace would have one more thing to rename in
every file (#1083).

A generated copy sits between `# lgtm-ci-inline:begin <id>` and
`# lgtm-ci-inline:end <id>` markers. What the exception requires:

- `scripts/ci/bootstrap/sync_inline_blocks.py` writes every copy and starts it
  with a header that says it is generated, names its source file and says why
  it is inline, for example:

  ```yaml
  # lgtm-ci-inline:begin fail-unknown-egress-preset
  # Generated from scripts/ci/bootstrap/fail-unknown-egress-preset.sh by
  # sync_inline_blocks.py: edit the source, not this copy. Inline because it
  # runs after harden-runner, before any checkout.
  ```

- The source of every block is a script file with tests (table below).
- `uv run python scripts/ci/bootstrap/sync_inline_blocks.py --check` stays a
  required check: it fails when a copy, its header or its number of copies
  differs from the source.
- The inline-shell check accepts a marked block only with an id the generator
  knows and with no hand-written line around the markers; rule 3 (no
  `${{ }}`) applies to the copy as well.
- A new generated block needs the same three things: a script file, tests, and
  a reason it cannot be called from disk. Add it to `BLOCKS` in
  `sync_inline_blocks.py` (with `reason=`, which goes into every header) and
  to the table below.

| Block id                       | Source                                                                | Copies | Inline because                                                                        | Tests                                                                                                                                    |
| ------------------------------ | --------------------------------------------------------------------- | -----: | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `verify-harden-runner-agent`   | `scripts/ci/bootstrap/verify-harden-runner-agent.sh`                  |    122 | it runs after harden-runner, before any checkout                                      | `tests/bats/unit/security/test_verify_harden_runner_agent.bats`, `tests/python/test_harden_runner_verify_contract.py`                    |
| `recheck-harden-runner-agent`  | `scripts/ci/bootstrap/recheck-harden-runner-agent.sh`                 |    159 | not every job checks the tooling out, and job steps can change it                     | `tests/bats/unit/security/test_recheck_harden_runner_agent.bats`, `tests/python/test_harden_runner_verify_contract.py`                   |
| `fail-unknown-egress-preset`   | `scripts/ci/bootstrap/fail-unknown-egress-preset.sh`                  |    103 | it runs after harden-runner, before any checkout                                      | `tests/bats/unit/security/test_fail_unknown_egress_preset.bats`, `tests/python/test_tooling_app_premint.py`                              |
| `install-verified-trivy`       | `scripts/ci/bootstrap/install-verified-trivy.sh`                      |      4 | on GHES the caller selects the tooling tree, which must not control Trivy's checksums | `tests/bats/contract/test_trivy_acquisition.bats`                                                                                        |
| `refuse-diverging-tooling-ref` | `.github/actions/checkout-and-harden/check-tooling-ref-divergence.sh` |     12 | it judges the tooling checkout, which must not supply its verdict                     | `tests/bats/unit/actions/test_check_tooling_ref_divergence.bats`, `tests/bats/integration/test_tooling_ref_divergence_guard.bats`        |
| `select-app-credential`        | `scripts/ci/bootstrap/select-app-credential.sh`                       |      3 | it runs before the tooling checkout, which needs its token                            | `tests/bats/unit/release/test_select_app_credential.bats`, `tests/bats/integration/test_release_app_credential_select.bats`              |
| `verify-extract-hook-tooling`  | `scripts/ci/bootstrap/verify-extract-hook-tooling.sh`                 |      2 | it puts the tooling on disk and must not run code from it                             | `tests/bats/unit/release/test_verify_extract_hook_tooling.bats`                                                                          |
| `tooling-app-flags`            | `scripts/ci/bootstrap/tooling-app-flags.yml`                          |    108 | job `env:` entries cannot call a script                                               | `tests/python/test_tooling_app_credential.py`, `tests/python/test_sync_inline_blocks.py`                                                 |
| `tooling-app-mint`             | `scripts/ci/bootstrap/tooling-app-mint.yml`                           |    108 | they mint the token the tooling checkout uses                                         | `tests/python/test_tooling_app_credential.py`, `tests/python/test_tooling_app_runtime.py`, `tests/python/test_validate_tooling_token.py` |

Copies are counted over `.github/workflows` and `examples/`. The two
`tooling-app-*` blocks are workflow YAML, not a `run:` body: the flags are job
`env:` entries and the mint block is two whole steps, whose `run:` the check
accepts because the step lies inside the marker pair.

## Exception 2: trivial steps

**Decided 2026-11-17.** The rule exists for security and so that code is
linted, formatted and tested. A simple "if this condition, print this, else
print that" carries none of that risk, and a dedicated script file for it is
waste. So such a step may stay inline, unless the same code is repeated in
many places, in which case one script file is right.

The test is what the code does before how long it is: a single line can be
harmful (`rm -rf`, a download, a token written somewhere) and would pass any
length or repeat limit. So the first condition is an allow-list of harmless
actions, and the two limits only apply to code that already passes it.

A step is trivial when **all** of these hold:

1. **It only reports or stops.** The commands allowed are `echo`, `printf`,
   `exit`, `true` and `false`, inside at most one conditional: one
   `if`/`elif`/`else`, one `case`, or one `A && B` / `A || B` list. A
   condition is a `[[ ]]`, `[ ]` or `test` that compares plain variables and
   literals with `-n`, `-z`, `-v`, `==`, `=`, `!=`, `=~`, `<`, `>`, `-eq`,
   `-ne`, `-lt`, `-le`, `-gt` or `-ge` (no file tests). A `case` subject is a
   plain variable or a literal. Nothing else may run: no other program or
   builtin (`rm`, `mv`, `cp`, `curl`, `git`, `gh`, `eval`, `source`,
   `export`, an assignment, `printf -v`), no pipe, no command substitution or
   arithmetic expansion, no expansion beyond `$NAME`, `${NAME}` and
   `${NAME:-word}`, no subshell, loop, function or background job.
2. **It writes nowhere but the console and the runner's own files.** No
   redirection except `>` or `>>` to `$GITHUB_OUTPUT`, `$GITHUB_ENV` or
   `$GITHUB_STEP_SUMMARY`, and `>&2` / `1>&2` to the console.
3. **It takes values from `env:` only.** No `${{ }}` expression inside the
   script text. That is the injection risk the rule exists for, so it holds
   for **every** inline step: script calls and generated copies too.
4. **At most 5 lines of code.** Confirmed by the owner on 2026-11-17. Reason:
   beyond a few lines even harmless code deserves to be read, linted and
   tested as a script. Blank and comment-only lines do not count; a line
   continued with `\` counts once per physical line.
5. **The same text in fewer than 10 places.** Confirmed by the owner on
   2026-11-17. Reason: repeated code is kept in one place, so one fix reaches
   every use. Two steps hold the same text when their code lines, stripped of
   indentation, blank lines and comments, are equal.

Anything that fails condition 1, 2 or 3 is code whatever its length, and moves
to a script file. The check enforces the allow-list mechanically; a reviewer
still reads what an inline step does. Typical trivial steps: the
`::warning::... upload failed; the result is unaffected` lines after a
best-effort upload, and the `echo "::error::..."; exit 1` that fails a gate
job.

## What changed when the rule was enforced (#1624)

On main before #1624, the 1179 `run:` steps were 540 script calls, 405 steps
in generated copies (297 marked `run:` bodies and the 108 steps of the
tooling App mint block), 66 trivial steps and 168 that broke a rule: 103
copies of the unknown-preset error (rule 5), 41 steps running something
outside the allow-list (rule 1) and 24 with a `${{ }}` in the script
(rule 3). Each became a script call or a generated copy:

- the unknown-preset error, 103 copies, which runs before any checkout,
  became the generated block `fail-unknown-egress-preset`;
- the "Resolve scripts directory" step of 35 composite actions calls
  `scripts/ci/actions/export-action-scripts-dir.sh`;
- `${{ github.workspace }}` and `${{ github.action_path }}` in a script path
  became `$GITHUB_WORKSPACE` and `$GITHUB_ACTION_PATH` (22 steps), and the
  two `exit ${{ steps.run.outputs.exit-code }}` steps call
  `fail-with-exit-code.sh` with the code in `env:`;
- six single steps moved to new scripts: `pause.sh`, `pin-release-date.sh`,
  `get-pr-author.sh`, `report-lighthouse-failure.sh`,
  `classify-lint-timeout-advisory.sh`, and the `umask 077` of the Codex CLI
  install into `install-ai-review-cli.sh`.

The `ALLOWED` ratchet of `tests/python/test_inline_run_blocks.py` (#1450),
which listed every block over three lines, is replaced by this rule-based
check.
