# Governance: inclusion, tiers, pinning, deprecation and removal

How lgtm-ci changes what callers depend on, and what a caller can rely on in
return. The rules exist because a June breaking rename (#281/#282) was still
being migrated by four lgtm-hq consumers in October (#285, #1051–#1054):
nothing said who the consumers were, a floating `v0` carried the break to
everyone at once, and the deprecation window was a guess. Here the window is
a checked condition: an input, output or entry point leaves lgtm-ci when
every known consumer has stopped using it, or when an exception naming the
approving issue is recorded. **Time alone is never enough.**

- [Inclusion: what belongs in lgtm-ci](#inclusion-what-belongs-in-lgtm-ci)
- [Support tiers](#support-tiers)
- [Pinning](#pinning)
- [Deprecation lifecycle](#deprecation-lifecycle)
- [Known consumers](#known-consumers)
- [Removal gate](#removal-gate)
- [Release notes](#release-notes)
- [Commands](#commands)

## Inclusion: what belongs in lgtm-ci

lgtm-ci is where shared CI is maintained; other lgtm-hq repositories consume
it. Apply these rules to workflows, individual jobs, composite actions and
scripts:

1. **Moves to lgtm-ci.** The same logic exists in **two or more repositories**,
   and its differences can be expressed as inputs: paths, versions, flags or
   capability toggles. Maintain one shared implementation and replace the
   copies with callers. Inputs must describe capabilities, without per-repo
   control-flow branches such as `if: github.repository == 'owner/repo'`.
   For example, [#520](https://github.com/lgtm-hq/lgtm-ci/issues/520) moved
   turbo-themes and holy-grail's Node build and Playwright capabilities into
   shared reusables with configurable commands and paths.
2. **Also moves: re-implementations of shipped capabilities.** When a consumer
   duplicates something lgtm-ci already provides, adopt that reusable or
   composite even if no second consumer has the copy. If an input or behavior
   is missing, upstream it, release it, then migrate the consumer. For example,
   [#363](https://github.com/lgtm-hq/lgtm-ci/issues/363) ported py-lintro's GHCR
   referenced-digest protection and build-cache pruning into the existing
   cleanup capability instead of maintaining parallel implementations.
3. **Stays local.** Product-specific logic used by one repository, or logic
   whose unification would need per-repo branches inside the reusable, stays
   with the product. Examples include turbo-themes' theme synchronization and
   py-lintro's Docker dogfood lanes, the permanent exception recorded in
   [#520](https://github.com/lgtm-hq/lgtm-ci/issues/520). Local jobs still use
   full SHA-pinned actions, `step-security/harden-runner` on supported runners,
   and the shared runner expression
   `runs-on: ${{ vars.LGTM_CI_RUNNER || 'ubuntu-26.04' }}` for Linux jobs.
   Platform-specific jobs retain their required runner OS.
4. **Document concrete exceptions.** A copy that qualifies under rule 1 or 2
   but must remain local for a technical reason needs an entry in
   [`catalog/local-exceptions.yml`](../catalog/local-exceptions.yml), with the
   reason and a link to the decision. For example,
   [turbo-themes#647](https://github.com/lgtm-hq/turbo-themes/issues/647) defers
   release-workflow adoption because callers cannot inject the Bun/Node setup
   needed to regenerate version-stamped artifacts inside the reusable job.
   Re-check the default branch when adding or reviewing an exception, and
   remove it after the local logic is deleted or replaced with a shared call.
5. **Size does not matter.** A five-line script copied to three repositories
   qualifies just like a whole workflow. For example,
   [#1238](https://github.com/lgtm-hq/lgtm-ci/issues/1238) identifies GHCR tag
   sweeps shared by py-lintro and Rustume: a small snippet that lists tags and
   deletes those outside the retention policy belongs in lgtm-ci when its
   differences fit in inputs.

### Local exception allowlist

The allowlist uses `schema-version: 1` and an `exceptions` list. Every entry
has `repo` (`owner/name`), `path` (an exact repository-relative file path),
`reason` (one line) and `link` (the GitHub issue or PR recording the decision).
An optional `job` narrows a workflow exception to one job ID. Sort entries by
repository case-insensitively, then path and job; list each scope once. Do not
add job scopes for a repository/path already covered by a whole-file entry.

The future duplication scanner
([#1237](https://github.com/lgtm-hq/lgtm-ci/issues/1237)) must suppress only an
exact repository/path match, plus an exact job match when `job` is present.
Omit `job` only when the whole file needs to remain local. There are no glob
or repository-wide exemptions; an allowlisted job must not exempt its neighbors.

Product-specific logic under rule 3 needs no exception in principle. The
seeded entries also record established keep-local decisions from the consumer
adoption issues so the future scanner (#1237) will not re-flag them.

Today's only reader is the catalog validator in the CI **Support Catalog**
job. It checks shape and ordering against
[`schemas/local-exceptions.schema.json`](../schemas/local-exceptions.schema.json)
and rejects duplicate or redundant scopes. This is separate from
[`deprecation-exceptions.yml`](../catalog/deprecation-exceptions.yml), which
authorizes removals from lgtm-ci's public interface. Schema validation is
offline: maintainers re-check the linked consumer files and technical reasons
when reviewing an exception; it does not assert that every consumer already
follows the local-job conventions above.

## Support tiers

Every public reusable workflow and composite action has a tier in
[`catalog/catalog.yml`](../catalog/catalog.yml), rendered with its evidence,
permissions and limitations in [catalog.md](catalog.md) (#1079).

<!-- markdownlint-disable MD013 -- tier promise table -->

| Tier | What callers may rely on | How it changes |
| ---- | ------------------------ | -------------- |
| `stable` | Inputs, outputs, the permission union, check names, artifact names and the `results.v1` document stay as documented. Proven by a green run of the external consumer fixture at a commit on `main`. | Only through the [deprecation lifecycle](#deprecation-lifecycle). Removing anything that was never deprecated fails the [removal gate](#removal-gate). A caller-breaking change carries `!` in the PR title and an entry in the next `docs/migration/vX.Y.md`. |
| `preview` | Maintained and fixed, but not proven from outside the org. | May change without a deprecation. Prefer one anyway when a [known consumer](#known-consumers) uses the entry; the gate prints them. |
| `internal` | Nothing; lgtm-ci's own workflows and lgtm-hq infrastructure. | Freely. |
| `deprecated` | A shim that warns and keeps working until its consumers have migrated. | Removed only through the removal gate. |

<!-- markdownlint-enable MD013 -->

Promotion to `stable` needs the fixture evidence the catalog validator checks.
A tier change is caller-visible and appears in the release notes.

## Pinning

Pin every `uses:` of lgtm-ci, workflows and composite actions alike, to the
**full commit SHA of a release**, with the version as a comment:

```yaml
jobs:
  test:
    permissions:
      actions: read
      contents: read
      pull-requests: write
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-test-python.yml@<sha> # v0.76.0
```

[onboarding.md](onboarding.md#4-resolve-the-release-commit-sha) shows how to
resolve a tag to its commit. Renovate's `github-actions` manager updates a SHA
pin and its version comment together.

- **`vX.Y.Z` tags** name a release; they are not a pin. A tag can be moved by
  anyone who can push tags, so resolve it once and pin the commit.
- **`v0`** is a floating tag that the release workflow moves to every new
  release, including releases that break callers (lgtm-ci is pre-1.0, so a
  minor release may break). It is a convenience for trying lgtm-ci out, never
  for CI that has to keep passing.
- **`@main`** is unreleased code. Never pin it.
- **`tooling-ref`** is deprecated (#995): the tooling checkout follows the
  `uses:` pin. Delete the input.

This repository's own README, docs and examples follow the same rule:
`scripts/ci/docs/validate-doc-pins.py` (CI job `📌 Doc Pins`) fails on any
lgtm-ci reference in them that is not a 40-character SHA or a `<sha>`
placeholder.

## Deprecation lifecycle

A reusable workflow rejects an unknown input with a hard `startup_failure`,
so deleting an input breaks every pinned caller at parse time, before any job
runs and before any warning can be shown. Every retirement therefore goes
through three stages; #796 introduced the pattern and this is now the rule.

1. **Announce.** In the PR that deprecates the item:
   - its `description` says it is deprecated, cites the issue and names the
     replacement (`DEPRECATED (#<issue>), ...` is the usual form); the
     catalog validator requires the word "deprecated" (or "inert") there;
   - a record in the catalog's `deprecations` list gives the `since` release,
     the tracking `issue` and a one-line `replacement` (see the header of
     [`catalog/catalog.yml`](../catalog/catalog.yml)); the validator also
     fails when a description says "deprecated" and no record covers it;
   - when callers must act, the next `docs/migration/vX.Y.md` says so.
2. **Shim.** The item keeps parsing, and warns:
   - an input stays accepted. If it no longer does anything (inert), setting
     it to a non-default value emits a `::warning` and a job-summary note
     through `scripts/ci/actions/warn-deprecated-workflow-input.sh`; if it
     still works, it keeps working;
   - an output stays declared with an empty value (`${{ '' }}`) so
     expressions that read it still parse;
   - an entry point becomes a thin wrapper that warns and calls its
     replacement (`reusable-publish-npm.yml` → `reusable-publish-npm-set.yml`,
     tier `deprecated` with a `replacement`).
3. **Remove**, through the [removal gate](#removal-gate), once the
   [registry](#known-consumers) shows that no known consumer still uses the
   item. Consumers still using it get a tracking issue each, the way #285
   tracks #1051–#1054.

The deprecation must have shipped in at least one release before the removal
does, so a caller sees the warning before the break; reviewers check this
against the record's `since`, the gate does not. There is no calendar window:
an item nobody uses can go in the next release; one still used stays.

Every current deprecation, with its replacement and the entries it applies
to, is listed in [catalog.md](catalog.md#deprecations).

## Known consumers

A known consumer is a repository listed in
[`catalog/consumers.yml`](../catalog/consumers.yml). That is the whole
definition: lgtm-ci keeps those repositories working, and only those
repositories' usage is evidence. Today the registry holds the lgtm-hq
repositories that call lgtm-ci and the external fixture
`TurboCoder13/lgtm-ci-consumer-fixture`. To be protected, add your repository
in a PR (one row with `repository` and `tracking-issues: []`, then run the
scan below).

<!-- markdownlint-disable MD013 -- field table -->

| Field | Meaning |
| ----- | ------- |
| `repository` | `owner/name`; rows sorted case-insensitively |
| `tracking-issues` | Open lgtm-ci issues migrating this consumer, e.g. `[1051]` |
| `last-verified` | Date of the scan that produced the row |
| `pins` | lgtm-ci refs its default branch uses; anything but a full SHA is a floating ref and the validator prints a notice |
| `uses` | Catalog entries it calls |
| `deprecated-in-use` | Removal keys of deprecated (or already removed) items it still uses: `<entry>:input:<name>` for an input it passes, `<entry>:output:<name>` for an output it reads, `<entry>:secret:<name>` for a secret it passes (all of them with `secrets: inherit`), `<entry>:entry` for a deprecated entry point it calls |

<!-- markdownlint-enable MD013 -->

Rows are produced, not written: `check-deprecations.sh scan --write` reads
each repository's default branch with `gh` (workflow files and composite
`action.yml` files), finds every `lgtm-hq/lgtm-ci/...@<ref>` call and
rewrites the row with today's date. It needs a token that can read the
consumers; run it locally with your own `gh` login. Only `repository` and
`tracking-issues` are kept from the old row. A key stays in the row while the
consumer uses it, also after lgtm-ci has removed it: that is a consumer whose
next pin bump breaks, and the validator prints a notice for it.

The gate trusts the registry on `main`. A PR can add consumers and usage, but
the gate unions its registry with the one on `main`: rows and usage a PR
drops are kept, and a row's `last-verified` is the one on `main`. A refresh
that clears a consumer therefore lands in its own PR first.

## Removal gate

The CI job `🧭 Deprecation Gate` runs `scripts/ci/catalog/check-deprecations.sh`,
which compares the catalog and every entry point's inputs, outputs and
secrets with the commit the PR was built on (the merge commit's first parent;
`origin/main` when run locally) and lists what the PR removes. Each removal
passes only when one of these holds:

- the PR adds an entry to
  [`catalog/deprecation-exceptions.yml`](../catalog/deprecation-exceptions.yml)
  that names it, with the `issue` that approved the removal and a one-line
  `reason`. Exceptions stay in the file as the audit trail, and one already
  on `main` approves nothing new;
- it was deprecated on `main` (a `deprecations` record covered it), no
  registry row lists it under `deprecated-in-use` (for an entry point: no row
  `uses` it), and every row was verified within the last 14 days, so the
  evidence describes today's consumers;
- its entry was `preview` or `internal` on `main` and the item was never
  deprecated. Those tiers may change without a migration; the gate prints the
  known consumers of the entry so the author can decide to deprecate anyway.

Everything else fails: removing a never-deprecated item from a `stable` or
`deprecated` entry, removing a deprecated item a consumer still uses, relying
on evidence older than 14 days (or dated in the future), or deleting the
catalog. Making an existing input or secret of a `stable` or `deprecated`
entry required fails too, because every caller that does not pass it breaks;
the exception key is `<entry>:required:<name>` (input) or
`<entry>:required-secret:<name>` (secret). Changing an input's `type` is not checked;
review it as a breaking change.

A removal takes two PRs:

1. **Refresh** the registry (`scan --write`) and merge it, so `main` shows
   that no known consumer still uses the item.
2. **Remove** it within 14 days of that refresh: delete the input, output,
   secret or file; drop the entry from the record's `entries` (and the record
   when it is empty), since the validator requires every listed entry to
   still expose the item; put `!` in the PR title and add a migration-guide
   entry.

The output names each removal with the key an exception would use, for
example:

```text
ERROR: reusable-coverage:input:publish-pages: still used by known consumer(s)
  lgtm-hq/example; migrate them first, or add an exception naming the
  approving issue
```

## Release notes

lgtm-ci's own version PR sets `catalog-release-notes: true` on
`reusable-release-version-pr.yml`. `generate-changelog.sh` then merges the
catalog diff since the previous release into the new `CHANGELOG.md` section
as `**catalog**` bullets: entries added (`Added`), tier changes (`Changed`),
newly deprecated items with their replacement (`Deprecated`), and removed
entries and every removed input, output and secret, marked as deprecated
first or not (`Removed`).

## Commands

```sh
# Gate this branch the way CI does
scripts/ci/catalog/check-deprecations.sh

# Which known consumers still use each deprecation (registry only, offline)
scripts/ci/catalog/check-deprecations.sh report

# Refresh the registry from the consumers' default branches (needs gh)
scripts/ci/catalog/check-deprecations.sh scan --write
scripts/ci/catalog/check-deprecations.sh scan --write --repository owner/new-consumer

# Catalog, deprecation records, consumer registry and local-exception schema
python3 scripts/ci/catalog/validate.py

# Pins in README, docs and examples
python3 scripts/ci/docs/validate-doc-pins.py
```

### Review authentication adoption inventory

The consumer scan also records optional `review-auth-findings` in
`catalog/consumers.yml`. It inspects literal secret **source expressions**, including
bracket syntax, rather than just reusable slot names. Generic smoke sources and
API-key `secrets: inherit` produce errors (a nonzero scan result); unresolved
Actions-variable/config selectors or dynamic sources remain explicitly unverified.
Existing released pins are not silently migrated: catalog validation surfaces
these findings as adoption notices. Review the explicit mappings and actual secret
availability before adopting the new auth interface. The reusable cannot recover
a source secret's name from its encrypted value.
