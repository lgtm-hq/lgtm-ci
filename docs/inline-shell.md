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
every `run:` step of `.github/workflows/*.yml` / `*.yaml`,
`examples/*.yml` / `*.yaml` and `.github/actions/**/action.yml` /
`action.yaml`. It fails closed: text it cannot read as shell is a broken
rule, never harmless. Run it locally:

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

## Every step

Whatever its class, a `run:` step must also:

- run under `bash` or `sh`: `shell:` (or the job's or workflow's
  `defaults.run.shell`) is absent, `bash` or `sh`. Any other value, such as
  `python {0}`, `pwsh` or `bash -c {0}`, reads the text as something else and
  is rejected. No step in the tree sets another shell (2026-11-18);
- have every `env:` around it, of the workflow, the job or the step (in a
  composite action, the step), written as a mapping of plain string names.
  An expression (`env: ${{ fromJSON(vars.E) }}`) or a list can set any
  name, `BASH_ENV` included, without showing it, and a `<<` merge key or a
  name that is not a string hides which names are set; each is refused;
- not run in a job `container:`. Its `env:` reaches every step, and its
  image decides which bash and which tools the steps run, so the check
  cannot judge them. No job in the tree has one (2026-11-18). A job's
  `services:` run in containers of their own; their `env:` does not reach
  the steps and is not read;
- not have an `env:` that sets a protected name (`protected_reason` in
  `inline_shell_rules.py`, lists under Reference below). They are of two
  kinds:
  - runner paths the check trusts (`RUNNER_PATHS`): `env: {GITHUB_OUTPUT:
/etc/x}` would turn a write to the output file into a write anywhere,
    and `GITHUB_WORKSPACE` in a job `env:` would change which script a call
    runs;
  - a deny list of the startup hooks of bash, sh, the loader, python,
    node/npm, git, perl and ssh, and of variables that weaken TLS or
    redirect traffic, so the step would run more than its text shows or
    talk to another host. Hooks (`CODE_HOOK_ENV` and
    `PROTECTED_ENV_PREFIXES`): bash expands `BASH_ENV` and `ENV`
    (`'$(curl ...)'` runs before the first line), `PS4` runs under xtrace,
    which `SHELLOPTS` or `BASHOPTS` can turn on, an exported function
    (`BASH_FUNC_echo%%`) replaces `echo`; the loaders read `LD_*` and
    `DYLD_*`, glibc `GCONV_PATH` and `GLIBC_TUNABLES`; `PATH`, `IFS`,
    `CDPATH` and `GLOBIGNORE` change what a word or command means; `HOME`
    and `XDG_CONFIG_HOME` choose the config files of git, ssh, curl and npm.
    `PYTHON*` is protected because `python3` without `-I`, a script's own
    shebang and the programs a script starts read it; `NODE_OPTIONS`,
    `NODE_PATH`, `npm_config_*` and `NPM_CONFIG_*` because scripts reach
    node and npm; `GIT_CONFIG*`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`,
    `GIT_PAGER`, `EDITOR` and the rest because git runs them as commands;
    `PERL5*` and `PERLLIB` for perl; `SSH_ASKPASS` for ssh; `BROWSER`
    because programs that open a page run it; `JAVA_TOOL_OPTIONS`,
    `_JAVA_OPTIONS` and `RUBYOPT` for the java and ruby a tool may start.
    `ACTIONS_ALLOW_UNSECURE_COMMANDS` would bring back `::set-env`, so a
    value a step prints could set `BASH_ENV` for every later step. TLS and
    traffic (`TLS_ENV` and `PROXY_SUFFIXES`): `NODE_TLS_REJECT_UNAUTHORIZED`
    and `GIT_SSL_NO_VERIFY` turn verification off, `SSL_CERT_FILE`,
    `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS` and the rest trust another
    authority, the pip and uv index names fetch packages from another host,
    `HOSTALIASES`, `LOCALDOMAIN` and `RES_OPTIONS` change name lookup, and
    any name ending in `_proxy` (`http_proxy`, `HTTPS_PROXY`, `ALL_PROXY`,
    `NO_PROXY`) sends or keeps traffic off the proxy.

  How names match: exactly and case-sensitively, as these programs read
  them (`ld_preload` is not `LD_PRELOAD`); a name that starts with one of
  `PROTECTED_ENV_PREFIXES` matches too, also case-sensitively; a name
  ending in one of `PROXY_SUFFIXES` matches in any case, because curl and
  git read `http_proxy` and `HTTP_PROXY` alike. `ENV_EXCEPTIONS` are names
  a prefix covers that no program reads as a hook: `PYTHON_VERSION`, the
  version `setup-python.sh` and `run-ai-review.sh` install. The only other
  name in the tree on the list was the `BROWSER` of the `run-playwright`
  action, now `PLAYWRIGHT_BROWSER` (2026-11-18);

- hold no `${{ }}` expression (rule 3 below).

A hand-written step (a script call or a trivial step) also holds only
printable ASCII, tab and newline. A control character, such as an ANSI
escape or a carriage return, can hide what a line runs from a reader, and a
non-ASCII lookalike can make one command name read as another.

## What counts as a script call

A step is a script call when its whole script is **one command that runs a
script file**, and nothing else: no `;`, `&&`, `||`, pipe, redirection,
second command or command substitution. Its shape is
`[INTERPRETER [OPTION]] PATH [ARGUMENT...]`:

- INTERPRETER is optional: `bash`, `sh`, `python`, `python3` or
  `/usr/bin/python3`. The only option allowed is `-I` for Python; `bash -c`
  and `python3 -c` run inline code and are rejected.
- Each ARGUMENT is a literal word or a plain variable: `$NAME`, `${NAME}`,
  `${NAME:-word}` or `${NAME-word}`. PATH takes no default word.
- PATH is one of:
  - a file of this repository under `scripts/`, written relative to the
    repository (`scripts/...`, `./scripts/...`), to a tooling checkout of it
    (`.lgtm-ci-tooling/scripts/...`, `.lgtm-ci-readiness/scripts/...`), to
    `$GITHUB_WORKSPACE`, to `$SCRIPTS_DIR` (the composite actions' name for
    `scripts/`) or, in a composite action, to `$GITHUB_ACTION_PATH`
    (`$GITHUB_ACTION_PATH/../../../scripts/...`). The file must exist;
  - in a composite action, a file next to its `action.yml`
    (`$GITHUB_ACTION_PATH/name.sh`). The file must exist;
  - a path with one variable set in the step's own `env:`, alone or after one
    of the prefixes above. The check reads the `env:` value:
    - a literal must name a file by the rules above
      (`env: {X: scripts/ci/x.sh}` with `bash "$X"`); `env: {TOOL: rm}` with
      `$TOOL -rf .` is rejected;
    - exactly `${{ inputs.<name> }}` is a script the caller chose, for example
      `bash "$GITHUB_WORKSPACE/$AUDIT_SCRIPT"` in `reusable-security-audit.yml`,
      `reusable-vuln-suppression-check.yml` and
      `reusable-validate-lintro-version.yml`. It must follow an interpreter and
      stand alone or right after `$GITHUB_WORKSPACE/`. The caller is trusted
      for its own workflow: it can run any script in its own job anyway, so
      the check cannot and does not judge that file. This holds only where a
      calling workflow sets the inputs: in a composite action, and in a
      workflow whose `on:` is `workflow_call` and nothing else. Anywhere else
      the step is rejected: a `workflow_dispatch` input is chosen by whoever
      starts the run, who could then name any file. The three workflows above
      are `workflow_call` only (2026-11-18);
    - `${{ COND && 'a' || 'b' }}`, with no top-level `||` in COND, can only
      be `a` or `b`, and each must name a file
      (`VERSION_SCRIPT` in `reusable-release-version-pr.yml`);
    - any other value, or a variable the step's `env:` does not set, is
      rejected;
  - a staged copy listed in `STAGED_COPIES` in
    `scripts/ci/quality/inline_shell_rules.py`, with its tested source. Today
    that is `${RUNNER_TEMP}/check-tooling-ref-divergence.sh`, which
    `checkout-and-harden` copies out of its bootstrap checkout before the
    tooling it judges is on disk.

A named file must exist and be a regular file, and no part of its path may
be a symbolic link: a link under `scripts/` could point anywhere. There are no
links under `scripts/` or `.github/actions/` (2026-11-18). A relative PATH is
read from the step's `working-directory` (or the job's or workflow's
`defaults.run.working-directory`); when that is an expression the place is
unknown and the path is rejected, so such a step names its script through
`$GITHUB_WORKSPACE`, `$GITHUB_ACTION_PATH` or `$SCRIPTS_DIR`.

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
  knows, with no hand-written line around the markers, and with a body equal
  to what the generator writes from the source, header included. It
  compares the bodies itself, in workflows, examples and composite actions
  alike, so it does not depend on `--check` for that (the generator's
  `--check` reads workflows and examples only, and also checks the number of
  copies). A block in a `run:` is read from the parsed value, the text bash
  runs, so the YAML style of the value (`|`, `>`, `"..."` or `'...'`) cannot
  hide a changed body; only the markers around whole steps or `env:` entries
  (the `tooling-app-*` blocks) are read from the file text. A broken marker
  or a changed body makes the step a violation. Rule 3 (no `${{ }}`) applies
  to the copy as well.
- Every part of the check reads a marker the same way: spaces and tabs may
  follow the id, nothing else, so a marker ending in `\r` is not a marker
  (and the character rule refuses the `\r`). A `run:` value is split into
  lines on `\n` only, as bash splits it. A line break bash does not know
  (`\r`, `\v`, `\f`, `\x85`, U+2028) makes a body differ from its source:
  otherwise a copy whose `echo` and `exit 1` lines were joined by one would
  read as equal while bash runs one `echo` line and never exits.
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
   condition compares strings only:
   - `[[ ]]` with `-n`, `-z`, `==`, `=`, `!=`, `=~`, `<` or `>`;
   - `[ ]` or `test` as `A`, `-n A`, `-z A`, `! A` or `A OP B` with OP a
     literal `=`, `==` or `!=`, and every variable in double quotes (an
     unquoted value is split, so it could become an operator).

   No file test, and no `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge` or `-v`:
   inside `[[ ]]` the first six evaluate their operands as arithmetic, and
   `-v` evaluates an array subscript, so a value such as `a[$(curl ...)]`
   from `env:` would run. For the same reason there is no `$(( ))`, `(( ))`
   or `let`. None of the trivial steps used them (2026-11-18). A `case`
   subject is a plain variable or a literal. `printf` takes no option: its
   first argument is a literal format that does not start with `-` (so no
   `printf -v NAME`, attached or not, and no format from a variable). The
   format holds only the conversions `%s` and `%%` and the escapes `\n`, `\t`
   and `\\` (`PRINTF_CONVERSIONS`, `PRINTF_ESCAPES`): `%n` assigns a
   variable, `%b` and `%q` read escapes from the argument, and another escape
   could print a control character. The trivial steps use `'%s\n'` only.
   `echo` takes no option: its first argument, past any redirection, does
   not start with a literal `-` (`-e`, `-n`, `-E`, combined, or `"-e"`), so
   `echo -e` cannot turn a `\n` in a value into a second `$GITHUB_OUTPUT`
   line. A redirection before `printf`'s format does not hide an option
   either (`printf >> $GITHUB_OUTPUT -v NAME x`). None of the 67 trivial
   steps used an `echo` option (2026-11-18).

   Every word stays one fixed word. An argument holds a variable only in
   double quotes (`"$X"`, `x"$X"`): unquoted, bash splits and globs its value,
   so `echo $X` with `X='-e ...'` passes an option. No word is open to brace
   expansion (`{a,b}`, `{1..3}`; `printf {-v,NAME} x` becomes
   `printf -v NAME x`), pathname expansion (an unquoted `*`, `?` or `[`, which
   a file named `-vNAME` turns into an option) or tilde expansion (an
   unquoted `~` that starts a word or follows `=` or `:`; bash expands
   `a=~` and `a:~` too). Quote or escape such text. `[[ ]]` operands and `case` patterns are
   not expanded that way and may use them (`=~ ^[0-9a-f]{40}$`, `a*)`).
   None of the trivial steps relied on any of this (2026-11-18). Nothing else
   may run: no other program or builtin (`rm`, `mv`, `cp`, `curl`,
   `git`, `gh`, `eval`, `source`, `export`, an assignment), no pipe, no
   command substitution, no expansion beyond `$NAME`, `${NAME}`,
   `${NAME:-word}` and `${NAME-word}` (the word a literal), no `$'...'` or
   `$"..."` quoting, no subshell, loop, function or background job.

2. **It writes nowhere but the console and the runner's own files.** No
   redirection except `>` or `>>` to a plain `$GITHUB_OUTPUT` or
   `$GITHUB_STEP_SUMMARY` (braced or not, quoted or not, with no default,
   alternative, suffix or substitution), and `>&1` / `>&2` from descriptor 1
   or 2 (`>&2`, `1>&2`, `2>&1`) to the console. **Not `$GITHUB_ENV` or
   `$GITHUB_PATH`.** The owner narrowed rule 2 to these two files on
   2026-11-18
   ([#1624, decision](https://github.com/lgtm-hq/lgtm-ci/issues/1624#issuecomment-6969837264)):
   every later step of the job loads `$GITHUB_ENV` and `$GITHUB_PATH`, so one
   trivial line such as `BASH_ENV=...`, `LD_PRELOAD=...`, `PATH=...` or
   `NODE_OPTIONS=...` would make later steps run arbitrary code. No trivial
   step on main wrote them; a step that must set an environment variable does
   it in a tested script.
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
to a script file.

What a trivial step prints is not judged. `echo "$X"` may print a value from
`env:` that starts with `::`, which the runner reads as a workflow command
(`::add-mask::`, `::stop-commands::`, `::warning::`); a value `-e` as the
first argument of `echo` may print escapes; `!` flips a status, so
`! true || echo x` prints. None of these runs a program. Printed to
`$GITHUB_OUTPUT` or `$GITHUB_STEP_SUMMARY`, a value with a newline adds
lines there: `echo "name=$X" >> "$GITHUB_OUTPUT"` with `X=$'a\nother=b'`
sets a second output. Those are the only files a trivial step writes
(rule 2), and the commands that set variables or paths (`::set-env`,
`::add-path`) stay disabled because no `env:` may set
`ACTIONS_ALLOW_UNSECURE_COMMANDS`. A step that must print a
value it does not control safely, or must change what later steps see, is a
script. The check enforces the allow-list mechanically; a reviewer
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

The reviews of #1646 (2026-11-18) closed ways around the check. Writes to
`$GITHUB_ENV` and `$GITHUB_PATH` are refused by the owner's narrowing of
rule 2 (above). The other tightenings follow from rules 1 to 3 as written,
"plain variables" and "no command substitution", and add no new rule: a
substitution or default in a redirection target, arithmetic and `-v` tests,
`[ ]` and `test` in fixed shapes with quoted variables, `printf` options and
conversions other than `%s` and `%%` (`%n` assigns a variable), brace,
pathname and tilde expansion, unquoted variables in arguments, `env:` values
that name any program, `env:` names that run code (`BASH_ENV`, `LD_PRELOAD`,
`BASH_FUNC_*` and the rest), a script chosen by a `workflow_dispatch` input,
symbolic links, other shells, changed generated bodies in any YAML quoting,
control and non-ASCII characters, `$'...'` quoting, and relative paths under
a `working-directory`. No step changed class. Two steps were edited: the
lint-timeout classifier in `reusable-quality-lint.yml` is called by its path
instead of through an `env:` value built from `${{ github.workspace }}`, and
a warning in `reusable-publish-quality-summary.yml` uses `-` instead of an
em dash. `examples/` is now checked too.

A further review (2026-11-18) closed more: an `env:` that is not a mapping
of plain names, a `<<` merge key, a job `container:`, the startup hooks of
python, node/npm, git, perl, ssh and the loaders beyond the first list, the
variables that weaken TLS or redirect traffic, `echo` options, a `printf`
option after a redirection, a tilde after `=` or `:`, a marker followed by
anything but spaces and tabs, and line breaks other than `\n` in a
generated copy. No step changed class; the `run-playwright` action passes
the browser as `PLAYWRIGHT_BROWSER` instead of `BROWSER`.

## Reference

The lists the check uses, from `scripts/ci/quality/inline_shell_rules.py`.
`tests/python/test_validate_inline_shell.py` keeps them equal to the code.

- `ALLOWED_COMMANDS`: `echo`, `printf`, `exit`, `true`, `false`
- `RUNNER_FILES`: `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`
- `TEST_OPERATORS`: `-n`, `-z`
- `BRACKET_COMPARISONS`: `=`, `==`, `!=`
- `SHELLS`: `bash`, `sh`
- `RUNNER_PATHS`: `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, `GITHUB_ENV`,
  `GITHUB_PATH`, `GITHUB_WORKSPACE`, `GITHUB_ACTION_PATH`, `SCRIPTS_DIR`,
  `RUNNER_TEMP`
- `CODE_HOOK_ENV`: `ACTIONS_ALLOW_UNSECURE_COMMANDS`, `BASH_ENV`, `ENV`,
  `SHELLOPTS`, `BASHOPTS`, `PS4`, `PROMPT_COMMAND`, `BASH_LOADABLES_PATH`,
  `PATH`, `IFS`, `CDPATH`, `GLOBIGNORE`, `HOME`, `XDG_CONFIG_HOME`,
  `GCONV_PATH`, `GLIBC_TUNABLES`, `NODE_OPTIONS`, `NODE_PATH`,
  `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `PAGER`,
  `GIT_EDITOR`, `EDITOR`, `VISUAL`, `GIT_ASKPASS`, `SSH_ASKPASS`,
  `GIT_PROXY_COMMAND`, `GIT_EXEC_PATH`, `GIT_TEMPLATE_DIR`, `BROWSER`,
  `PERLLIB`, `JAVA_TOOL_OPTIONS`, `_JAVA_OPTIONS`, `RUBYOPT`, `CURL_HOME`
  (exact, case-sensitive)
- `TLS_ENV`: `NODE_TLS_REJECT_UNAUTHORIZED`, `NODE_EXTRA_CA_CERTS`,
  `GIT_SSL_NO_VERIFY`, `GIT_SSL_CAINFO`, `GIT_SSL_CAPATH`, `SSL_CERT_FILE`,
  `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`,
  `PIP_CONFIG_FILE`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`,
  `PIP_TRUSTED_HOST`, `UV_INDEX`, `UV_INDEX_URL`, `UV_DEFAULT_INDEX`,
  `UV_EXTRA_INDEX_URL`, `UV_INSECURE_HOST`, `HOSTALIASES`, `LOCALDOMAIN`,
  `RES_OPTIONS` (exact, case-sensitive)
- `PROTECTED_ENV_PREFIXES`: `BASH_FUNC_`, `LD_`, `DYLD_`, `PYTHON`,
  `GIT_CONFIG`, `PERL5`, `npm_config_`, `NPM_CONFIG_` (a name that starts
  with one, case-sensitive)
- `PROXY_SUFFIXES`: `_proxy` (a name that ends with one, in any case)
- `ENV_EXCEPTIONS`: `PYTHON_VERSION` (a prefix covers it; no program reads it)
- `PRINTF_CONVERSIONS`: `%s`, `%%`
- `PRINTF_ESCAPES`: `\n`, `\t`, `\\`
- `INTERPRETERS`: `bash`, `sh`, `python -I`, `python3 -I`, `/usr/bin/python3 -I`
  (an interpreter, then the one option it may take)

The modules: `validate_inline_shell.py` (classes and report),
`inline_shell_steps.py` (reading steps and generated blocks),
`inline_shell_context.py` (a step's `env:`, `container:` and defaults),
`inline_shell_calls.py` (script calls), `inline_shell_trivial.py` (rules 1,
2 and 4), `inline_shell_rules.py` (these lists) and `inline_shell_lexer.py`
(the shell tokenizer).
