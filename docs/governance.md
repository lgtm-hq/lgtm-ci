# Governance: tiers, pinning, deprecation and removal

How lgtm-ci changes what callers depend on, and what a caller can rely on in
return. The rules exist because a June breaking rename (#281/#282) was still
being migrated by four lgtm-hq consumers in October (#285, #1051–#1054):
nothing said who the consumers were, a floating `v0` carried the break to
everyone at once, and the deprecation window was a guess. Here the window is
a checked condition: an input, output or entry point leaves lgtm-ci when
every known consumer has stopped using it, or when an exception naming the
approving issue is recorded. **Time alone is never enough.**

- [Support tiers](#support-tiers)
- [Pinning](#pinning)
- [Deprecation lifecycle](#deprecation-lifecycle)
- [Known consumers](#known-consumers)
- [Removal gate](#removal-gate)
- [Release notes](#release-notes)
- [Commands](#commands)

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
| `deprecated-in-use` | Removal keys of deprecated items it still uses: `<entry>:input:<name>` for an input it passes, `<entry>:output:<name>` for an output it reads, `<entry>:entry` for a deprecated entry point it calls |

<!-- markdownlint-enable MD013 -->

Rows are produced, not written: `check-deprecations.sh scan --write` reads
each repository's default branch with `gh` (workflow files and composite
`action.yml` files), finds every `lgtm-hq/lgtm-ci/...@<ref>` call and
rewrites the row with today's date. It needs a token that can read the
consumers; run it locally with your own `gh` login. Only `repository` and
`tracking-issues` are kept from the old row.

## Removal gate

The CI job `🧭 Deprecation Gate` runs `scripts/ci/catalog/check-deprecations.sh`,
which compares the catalog and every entry point's inputs and outputs at
`origin/main` with the PR and lists what the PR removes. Each removal passes
only when one of these holds:

- an entry in
  [`catalog/deprecation-exceptions.yml`](../catalog/deprecation-exceptions.yml)
  names it, with the `issue` that approved the removal and a one-line
  `reason`; exceptions stay in the file as the audit trail;
- it was deprecated on `main` (a `deprecations` record covered it), no
  registry row lists it under `deprecated-in-use` (for an entry point: no row
  `uses` it), and every row was verified within the last 14 days, so the
  evidence describes today's consumers;
- its entry was `preview` or `internal` on `main` and the item was never
  deprecated. Those tiers may change without a migration; the gate prints the
  known consumers of the entry so the author can decide to deprecate anyway.

Everything else fails: removing a never-deprecated item from a `stable` or
`deprecated` entry, removing a deprecated item a consumer still uses, or
relying on stale evidence. A removal PR therefore:

1. deletes the input, output or file;
2. drops the entry from the record's `entries` (and the record when it is
   empty), since the validator requires every listed entry to still expose
   the item;
3. refreshes the registry (`scan --write`) in the same PR;
4. carries `!` in the PR title and a migration-guide entry.

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
entries and deprecated items (`Removed`).

## Commands

```sh
# Gate this branch the way CI does
scripts/ci/catalog/check-deprecations.sh

# Which known consumers still use each deprecation (registry only, offline)
scripts/ci/catalog/check-deprecations.sh report

# Refresh the registry from the consumers' default branches (needs gh)
scripts/ci/catalog/check-deprecations.sh scan --write
scripts/ci/catalog/check-deprecations.sh scan --write --repository owner/new-consumer

# Catalog, deprecation records and registry schema
python3 scripts/ci/catalog/validate.py

# Pins in README, docs and examples
python3 scripts/ci/docs/validate-doc-pins.py
```
