# Cross-repository duplication scan

`.github/workflows/duplication-scan.yml` reads non-archived, non-fork lgtm-hq repositories
each Monday at 03:37 UTC, with lgtm-ci's catalog as the reference implementation.
It also supports manual dispatch. Repository code is read as immutable Git
blobs, held in memory, and never executed. Only the public-safe Markdown report
is written to the step summary.

The scanner covers workflow jobs (`.yml` and `.yaml`), composite actions, and
scripts under `scripts/` and `.github/scripts/`. It removes comments, normalizes
spacing, action refs, repository/image names, paths and versions. Known version
inputs to setup-python, setup-node and setup-uv are parameters. Unknown action
inputs, executable programs, environment values and execution metadata
(including dependencies, permissions and runner selection) remain significant.
Step ordering, conditions, shell command boundaries, decimal command arguments
(including quoted durations, thresholds and timeouts), and Python indentation and
numeric tokens also remain significant. Python operators retain their exact text,
including floor division `//` and augmented assignment `//=`. Python numeric tokens
retain their exact text, including floating-point and exponential constants.
Python strings retain their exact text by default, including slash-containing
comparisons and regular-expression patterns. Only a direct `Path("build/output")`
literal after a single top-level `from pathlib import Path` import normalizes as
a path parameter; aliases, other uses or bindings of `Path`, computed arguments
and non-path strings disable this bounded rule. Numeric strings remain significant,
including decimal values and version-like text outside explicit setup-action inputs.
Python f-strings and template strings stay repository-specific: replacement expressions and format specs
are not modeled, including when Python 3.11 exposes them as a single string token
or newer tokenizers expose separate f-string tokens. This applies to standalone
scripts, called scripts and inline Python run blocks; scanned source is never executed.
Explicit local script paths resolve
exactly, including extensionless scripts and nested calls; cycles and unresolved
calls retain their repository-qualified identity, so unknown implementations
cannot match across repositories. Referenced programs outside the script directories and local
composite actions are read as additional immutable blobs. Suffix lookup expands
the blob inventory only; matching always resolves an exact execution path.
Inventory discovery recognizes workflow/action YAML execution fields; descriptions,
comments and output mappings within those schemas remain inert. Other YAML,
including runtime configuration mappings and lists, retains conservative raw hints.
Shell/Python comments do not introduce dependency reads. All Python docstrings retain hints:
decorators and external consumers can read them without local reflection names,
so this bounded pass cannot establish that they are inert. Executable strings,
JavaScript action entry points and unsupported syntax retain conservative hints.
Scoped environment values, input defaults and job matrix data also retain hints
when consumed by commands or unresolved actions. Matrix include/exclude data is
retained conservatively without evaluating combinations. Docker action
entrypoint, pre-entrypoint, post-entrypoint, image and argument fields retain
hints, with environment/input data; Docker normalization remains opaque.
Job container and service execution configuration, including environment values
and options, also retains hints and scoped execution data. Explicit and default
shell declarations retain executable paths and arguments. A nonempty inherited
`BASH_ENV` retains environment, input and matrix hints even for literal commands,
because Bash startup can expand and execute it before the command runs. This does
not evaluate expressions or model shell startup data flow.
Source YAML containers are checked by identity and bounded to 64 levels before
discovery, runner-context checks or normalization traverses them. Cyclic or deeper
documents retain raw discovery hints; selected units and local action consumers
record invalid source and block reconciliation. Acyclic aliases remain supported.
Descriptions stay documentation;
an unknown implementation remains opaque. The normalization algorithm and version
are unchanged, but changes to fetched inventory can change fingerprints: Python's
stdlib-shadowing opacity depends on inventoried module names. The 256 KiB blob limit and omission
accounting still apply to genuine dependencies outside the selected directories;
an oversized dependency makes coverage partial and blocks reconciliation.
The [#1237 coverage investigation](duplication-scan-coverage-1237.md) records the
public reproduction and offline regression evidence.
Step `working-directory` and workflow/job `defaults.run` remain significant;
relative script paths resolve against their effective directory. Quoted string
whitespace also remains significant. Adjacent quoted/unquoted fragments within a
shell word stay repository-specific, including empty quoted fragments: the bounded
recognizer does not interpret shell concatenation. Separate quoted data arguments
remain comparable. Direct script execution retains the exact shebang interpreter
and arguments; supported explicit interpreter invocations ignore that declaration.
Run blocks use the effective shell: step settings override job defaults, which
override workflow defaults. Inline `shell: python` uses the same token and
dependency guards as Python files. Explicit shell declarations retain their
literal executable paths and arguments. Bounded Bash/sh and Python file-execution
templates are recognized; unsupported languages, dynamic shell expressions and
ambiguous custom commands remain repository-specific.
Script-looking arguments such as
`echo scripts/missing.sh` are data, not executable dependencies. The scanner
recognizes common keyword/group positions, `timeout`, interpreter flags and
option-free `sudo`, `nohup`, `command`, `env`, `exec` and `time` wrappers.
Explicit `uv run python3 scripts/check.py` uses the named interpreter and its
dependency guards. Bare `uv run scripts/check.py`, other bare uv file forms,
and all `bun run` forms stay repository-specific, even with a shebang: runner
dispatch and package-script dependencies are not inspected. Runner identity is
part of the script normalization cache context.
Unrecognized wrappers or options with possible executable paths
stay repository-specific; this bounded recognition does not parse arbitrary
shell syntax. For example, `xargs -n1 bash scripts/check.sh` stays unknown.
Shell blocks that change directories with `cd`, `pushd` or `popd` stay
repository-specific; their control flow is not modeled. `gh api` operations also
stay repository-specific because their endpoints and payloads are executable behavior.
Shell `test`, `[` and `[[` conditions combining equality, ordering, file identity or file age comparisons
with path-looking operands stay opaque before path masking; those operands may select different
branches. Comparisons without paths and unary filesystem predicates such as `test -f` and
`[ -d ... ]` retain path parameter normalization.
Blocks combining active output redirections and local script calls stay opaque
before executable lookup. A write may replace a committed script before it runs;
write destinations and ordering are not modeled. Quoted, commented and escaped
redirection text remains data.
HTTP clients and literal URLs of any scheme stay opaque until endpoint and payload
semantics are modeled. Shell blocks that change `PATH` also stay repository-specific.
Variable-writing builtins (`printf -v`, `read`, `mapfile`, `readarray`, `getopts`
and `let`) stay opaque before data-command exemptions. Their destinations and
assignment effects are not modeled, even when a literal target looks unrelated
to `PATH`. Ordinary `printf` format/data arguments, comments and literal command
text remain comparable.
Command-position guards and script resolution recognize empty prefix assignments
as well as nonempty ones, including `IFS= read -r PATH` and `X= cd app`.
Expanded `GITHUB_PATH` or `GITHUB_ENV` references stay opaque wherever they appear,
including double-quoted arguments, braced parameter forms, aliases, pipelines and
called scripts. These runner files can change executable selection across steps,
so the containing job or composite cannot match another repository or the catalog.
The scanner does not infer which commands can mutate the files or propagate their
names: even `echo "$GITHUB_PATH"` and `cat "$GITHUB_ENV"` stay opaque. Comments,
single-quoted text and escaped references remain inert; double quotes still expand
variables, including inside command-looking text. Actions expressions referencing
`github.path` or `github.env` also stay opaque, including case variants and literal
index access. Actions evaluates them before shell quoting, escaping or comments
can hide them. This guard also covers inherited workflow/job/step environments
and execution inputs on action calls, including composite steps. Composite action
input declarations/defaults also make descendant steps opaque, both when expanding
a local action call and when inventorying an action definition. Runner-file
references in strategy, container or service metadata also keep descendant
steps opaque. This guard does not
evaluate expressions or infer alias/data flow; literal expression strings,
ordinary environment values and output data remain comparable.
Active indirect expansions such as `${!name}` stay opaque even in
data commands, since the selected variable may name a runner file. Python code
names or decoded string literals containing `GITHUB_PATH` or `GITHUB_ENV` also
keep inline and called Python code repository-specific; comments remain inert.
This includes adjacent literals and bounded literal-only `+` concatenations of
strings or bytes, including continuation newlines/comments and literal grouping.
Computed keys and argument-to-environment data flow remain
outside this guard.
Forwarded arguments such as `$@`, `$*`, `$1`, `${1}`, `$TOOL` and `${TOOL}`,
including bounded parameter forms such as `${TOOL:-fallback}`, stay repository-specific
unless passed to a proven data command (`echo`, `cat`, `printf`, `ls`, `test` or `[`),
including when unknown wrappers or inspected scripts receive them or a command-prefix
assignment supplies their values. Executable selection through these arguments is not
modeled; proven data arguments such as `echo "$1"` remain comparable. Runner-file
references follow the stricter rule above even in data commands.
Pipelines require every downstream consumer to be a proven data command, `tee`
(which copies stdin) or `true`/`false` (which ignore it). Runner-file references
remain subject to their stricter guard. Unknown or
grouped consumers stay opaque because they may execute the producer's output;
this includes pipelines inside inspected scripts. Quoted or backslash-escaped
executable names also stay opaque before dependency resolution until command-word
interpretation is modeled; quoted data arguments
remain comparable, and adjacent shell-word fragments retain their existing guard.
Shell heredocs and
here-strings also stay opaque and repository-specific, preserving payloads that
look like comments or commands. Simple arithmetic shifts inside `$((...))` remain
comparable; bare `((...))` with `<<` stays opaque because POSIX sh can interpret
it as nested subshells with a heredoc. Backslash-newline continuations and parameter
expansions beyond the bounded data-only form stay repository-specific, including
inside double quotes. Bounded expansions preserve shell word adjacency:
`${dir}/*` and `${dir} /*` have different script shapes. Only shell
comments hide subsequent shell text; `//` and `/*...*/` remain ordinary words.
Python process launchers,
including `os.startfile`, asyncio's subprocess helpers and event-loop
`subprocess_exec`/`subprocess_shell` methods, and `pty.spawn`, also stay
unknown until command identities can be compared. Reflective lookup names
(`getattr`, `__getattribute__`, `vars`, `__dict__`, `attrgetter`, `methodcaller`,
`globals` and `locals`) alongside process-module names conservatively keep scripts
unknown, including imported aliases and computed targets reached through
`sys.modules`, `builtins` or `__builtins__`. References to `__builtins__`,
`ctypes` and `webbrowser` also stay unknown, including imported aliases:
native calls and browser commands are not inspected. Launcher detection examines
code names, so strings containing those words remain ordinary data.
This bounded token guard does not model arbitrary Python data flow or promise
to identify every indirect execution mechanism. The same conservative rule covers runpy
file/module execution and dynamic imports, including imported aliases and computed targets.
Local, relative and third-party Python imports
keep the entrypoint repository-specific, even when helper source is available:
their implementations are not inspected. Standard-library imports remain
comparable unless an inventoried Python module or package could shadow them.
Python module invocations (`python -m`, including third-party tools such as
`python -m build`) stay repository-specific: module implementations and their
execution context are not resolved. Explicit Python file invocations still use
the inspected script body.
Local JavaScript/Docker actions, shell command substitutions, inline programs,
unresolved dynamic paths and cycles stay unknown. Bare names never use basename fallback.
Active process substitutions (`>(...)` and `<(...)`) also stay opaque before
data-command or pipeline exemptions; quoted, escaped and commented forms are data.
Parameter expansions containing process substitutions stay opaque as well.
Absence of findings does not establish absence of duplication.

Two consumer repositories qualify a cluster; one consumer qualifies when it
matches a catalog implementation. Automatic issues require identical normalized
structure to establish parameter-only differences. Public near matches use
Jaccard similarity of ordered shingles and appear separately for manual review,
without creating issues. `--threshold` controls these suggestions; its default
is **0.8**. At most 20 public near matches are shown. Private source never appears
in these suggestions. Reusable-workflow calls and jobs composed entirely of
lgtm-ci actions plus hardening/checkout are already adoption and are skipped.
Catalog entry points and directly referenced scripts form the reference set.
For a catalog composite, equality compares the ordered operations and effective
step environment, shell and working directory. A consumer job still retains its
runner, dependencies and permissions when compared with other consumers; the
composite does not need job-only fields such as `runs-on`. Automatic matches
score 1.000; threshold tuning affects manual suggestions only. Forks are omitted
because upstream copies are not adoption candidates.

`catalog/local-exceptions.yml`, defined by
[#1236 / PR #1240](https://github.com/lgtm-hq/lgtm-ci/pull/1240), requires
`schema-version: 1` and an `exceptions` list. Each row has exactly `repo`, `path`,
optional `job`, `reason`, and `link`: an exact repository and file path, optional
job ID, a one-line technical reason, and a GitHub issue or PR decision link.
Omitting `job` exempts the whole file. Unknown fields, traversal, globs and invalid
values are rejected before reporting. Missing setup skips the scheduled scan;
an invalid allowlist fails before any issue writes.

Each logic fingerprint gets one issue with `ci` and `needs-triage` labels. The
fingerprint excludes the current member list, so adding a repository updates the
existing issue. The fingerprint payload carries a normalizer version; changing
that version requires an explicit migration of existing issue markers and
rejections. The current normalizer version is **2**; historical audit markers
are not current evidence. Every page of open and closed issues is read before writing; an API
error aborts reporting. Open issues refresh when membership changes or retained
generated source needs redaction. The marked member section is replaced, and
historical examples and input names are retained only while their source repository
remains the current public example; otherwise they are regenerated or removed.
Human notes remain intact. Web-edited CRLF bodies compare identically. Updates and
reopens refresh the count only on generated titles, preserving human titles.
Catalog matches use "adopt … from lgtm-ci" and singular "1 repo" wording.
Privacy cleanup also applies to every matched closed or rejected issue and any
duplicate matches, preserving their state, rejection decision and human notes.
An independent pass checks all scanner-owned issues against current repository
visibility, including historical clusters that no longer qualify. It removes
generated examples, their input names, and member job names when their repository
is private or cannot be verified public. Repository/path membership remains intact,
and human titles and notes remain unchanged. This pass also runs with partial
source coverage and failed or malformed tree/blob responses; source-read errors
still fail the scan and block ordinary reconciliation. Failed or malformed initial
repository enumeration runs this pass with an empty verified-public set, then
propagates the original scan failure even if cleanup also fails. Dry runs never write.
After clustering and all historical issue pages have been read, the scanner refreshes
validated repository identities and public visibility before issue mutations, including
privacy cleanup. It refreshes visibility again after reconciliation and rebuilds exact
findings and public near matches before publishing stdout, `--report` or the step summary.
Missing, malformed or unreadable metadata removes public details; visibility lost during
a run is not restored. These checks minimize the request gap; visibility checks and
publication cannot be atomic.
After successful enumeration, source-credential coverage failures also run this
privacy pass using only public visibility reverified after historical issue reads;
unseen repositories remain unverifiable. These failures preserve all historical
membership and adoption decisions and then fail the scan.
Suppressed matches receive only a body patch when cleanup is needed, counted as
`redacted`; dry-runs count these without writing. Not-planned closures otherwise
stay silent; completed closures reopen with a comment when the copy is found again.
Closed issues with an absent or unrecognized `state_reason` remain suppressed.
Reopening also stores one bounded transaction receipt in the scanner-owned body.
Subsequent complete scans reconcile pending explanations even for unchanged open
issues, checking every comment page for a transaction-specific comment from the
authenticated writer before posting. Live runs validate the writer's numeric
account ID and login through GitHub's authenticated viewer query before any
mutation, including privacy cleanup. The same frozen write credential is used
for that query, issue reads and mutations; unsupported or malformed authentication
fails closed. Both the POST receipt and recovery lookup require that exact account
and transaction. Recovery with a different writer cannot prove delivery and
retains the uncertain receipt without posting again.
A known failure to start the request remains retryable;
an accepted response records delivery. A lost response or interruption retains an
uncertain receipt and fails visibly until delivery can be verified, without blindly
posting again. Human notes and the public-source cleanup rules still apply.
HTTP errors also retain `sending`: an unsuccessful client response alone does
not prove that GitHub did not accept the comment. For manual recovery, stop
concurrent scanner runs and inspect the exact receipt transaction and every
comment page under the original authenticated writer. If its matching comment
exists, rerun with that writer so normal recovery records delivery. Only after
independently establishing that the request was rejected or never sent may an
operator change that receipt's `sending` state to `ready` and rerun. Preserve the
transaction, duplication identity marker and human notes; deleting the receipt
can lose delivery evidence and permit a duplicate explanation. If delivery
remains uncertain, retain the receipt for investigation.
At most five new issues are created per run; deferred
candidates remain in the summary. Untrusted identifiers and snippets cannot
inject scanner markers. Removing an issue's identity marker makes it unseen;
retain the marker when editing to avoid a duplicate candidate.

Private members contribute only repository and path to findings, never job
names, input names/values, snippets or suggested names derived from their code.
Markers are stable, unsalted logic digests, not a confidentiality boundary: a
person guessing a private implementation could confirm its normalized digest
offline. This is an accepted tradeoff for stable deduplication; private source
and job/input names remain excluded from public output.
The inventory lists public repository names and only a count for private repos.
Malformed, oversized and binary files are skipped with aggregate counts and a
partial-scan notice; no private names or parser source are logged. Partial
coverage blocks cluster reconciliation, including membership updates,
reopening and creation. Independent privacy redactions remain permitted and are
counted separately, with zero writes in dry-run mode. Dry-runs emit the partial
report; live runs emit it and fail. Existing membership is preserved until a
complete scan. Empty repos are skipped only when a tree request returns 409 and
repository metadata reports zero size. Authentication errors, inaccessible
repositories, GraphQL errors and truncated trees abort the scan rather than
presenting an incomplete inventory.

## Setup and rollout

Install a GitHub App on **all lgtm-hq repositories**, with repository
**Contents: read** (and implicit Metadata: read) only. Store its credentials as
lgtm-ci repository secrets `DUPLICATION_SCAN_APP_ID` and
`DUPLICATION_SCAN_APP_PRIVATE_KEY`. App setup is tracked under
[#1233](https://github.com/lgtm-hq/lgtm-ci/issues/1233).

A prerequisite job checks for both secrets and `catalog/local-exceptions.yml`.
If any are absent, it succeeds with a skip notice and the scan job is skipped.
When present, it validates the allowlist and uses an App JWT to verify the
installation has
`repository_selection: all`, Contents: read and read-only values for every
installation permission before minting the source token. Additional write
permissions and malformed permission mappings fail this check, as does a
partially installed App. The temporary signing key is deleted
immediately after signing; credentials and installation responses are not logged.

Every scan independently checks the **actual source credential**, including local
dry-runs. GitHub's documented
[`GET /installation/repositories`](https://docs.github.com/en/rest/apps/installations#list-repositories-accessible-to-the-app-installation)
response requires `total_count` and `repositories`. Its
[OpenAPI schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json)
makes `repository_selection` optional, and the documented response example omits
it. Token grants cannot establish all-organization coverage alone.

The scan therefore rechecks the configured App's all-repository, read-only
installation using its JWT. It independently
[mints a Contents: read token](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app)
for that installation, omitting both `repositories` and `repository_ids` so the
token receives every installed repository. Conflicting optional selection or
permission metadata in the mint response is rejected. Both tokens' full
`/installation/repositories` inventories must match each other and the org listing,
with ownership bound to the verified installation's organization ID. Each inventory
must exhaust a consistent positive integer `total_count` across all pages and
contain unique repository IDs/names. Boolean IDs/counts and nonboolean visibility,
archive or fork flags are rejected.

Missing App credentials, malformed metadata, unreadable pages, narrowed source
grants and inventory gaps fail closed before normal issue mutations. Readiness
flags or an unrelated App's metadata cannot substitute for comparing actual
source grants with independently obtained full grants. The source token stays
fixed for coverage and blob reads; the verification token remains only in memory
and expires after one hour. This uses the existing App secrets and permissions;
it creates a temporary read token without changing the App or its installation.

`GH_READ_TOKEN` reads source. Issue reads and writes use the job's separate
repository-scoped `GH_TOKEN` with Contents: read and Issues: write. Both jobs use
the literal `ubuntu-26.04` runner, pinned actions and block-mode harden-runner.
The dedicated `duplication-scan` egress preset is registered in
`scripts/ci/lib/egress/presets.sh`; generated workflow maps are maintained by
`scripts/ci/egress/sync-workflow-presets.sh`. It permits only `github.com:443` and
`api.github.com:443`. No package installation or consumer source checkout is
needed.

Live reporting requires repository variable `DUPLICATION_SCAN_LIVE_ENABLED` to
be `true`. Otherwise schedules and dispatches are dry-runs. Once enabled,
schedules report live and manual dispatches honor `dry-run` (default true).
Before enabling it:

1. Merge #1236 and apply its local exceptions.
2. Configure the read-only App and verify its installation covers the org.
3. Rerun the audit, tune the public near-match threshold if useful, and triage
   candidates against existing adoption trackers. The historical
   [audit](duplication-scan-audit.md) records the first provisional findings.
   Post the reviewed summary on
   [#1237](https://github.com/lgtm-hq/lgtm-ci/issues/1237).
4. Link existing adoption trackers or resolve their copies before the first live
   run. Confirm `ci` and `needs-triage` labels exist on lgtm-ci.

## Local commands

Source reads use `GH_READ_TOKEN` or the local `gh` login, discarding `GH_TOKEN`
and `GITHUB_TOKEN` so a repository-only Actions token cannot narrow the source
inventory. Set the existing `DUPLICATION_SCAN_APP_ID` and
`DUPLICATION_SCAN_APP_PRIVATE_KEY` credentials as well, for the independent
coverage proof described above. A general local login alone cannot establish
all-repository App coverage.
Issue reads use `GH_TOKEN` or the local
login. The system Python needs PyYAML, as do the catalog scripts. No scanned
source is cached.

```sh
/usr/bin/python3 scripts/ci/maintenance/duplication_scan.py --dry-run=true \
  --report /tmp/duplication-scan.md
```

A provisional read-only audit may explicitly use `--allow-missing-exceptions`
when the prerequisite file is absent. This option is rejected with
`--dry-run=false`. `--threshold` accepts `(0, 1]`; `--max-new-issues` accepts 0
through 5. Writes require an explicit `--dry-run=false` and a repository-scoped
`GH_TOKEN`.
