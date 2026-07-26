# Release changelog migration (Keep a Changelog)

The release changelog generator was aligned with
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) in
**v0.43.1** (#344). Consumers pinned to an older
`reusable-release-version-pr.yml` still receive the legacy section headings
(`### Features`, `### Bug Fixes`, ...), which forces manual heading edits and
lint fixes on every release PR. This guide covers upgrading a consumer
repository to the KAC-aligned generator.

## Minimum pin

Bump `reusable-release-version-pr.yml` to **v0.43.1 or later** (pin the SHA of
that tag or newer). Ideally bump all lgtm-ci refs in the repository to the same
release so the version-PR and publish workflows do not run split versions —
for example, publishing on a current release while the release PR workflow is
still pinned to an older one generates legacy headings on new release PRs.

```yaml
jobs:
  version-pr:
    # v0.43.1+ — KAC-aligned changelog generator
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-release-version-pr.yml@<sha>
```

## Heading mapping

| Commit type                       | Pre-v0.43.1 heading    | v0.43.1+ heading |
| --------------------------------- | ---------------------- | ---------------- |
| `feat`                            | `### Features`         | `### Added`      |
| `fix`                             | `### Bug Fixes`        | `### Fixed`      |
| breaking (`!` / `BREAKING CHANGE`)| `### Breaking Changes` | `### Changed`    |
| `docs`                            | `### Documentation`    | `### Changed`    |
| other (`chore`, `refactor`, ...)  | `### Other Changes`    | `### Changed`    |

Generated version sections use only `Added`, `Changed`, and `Fixed`. The
reset `[Unreleased]` template additionally includes the empty `Deprecated`,
`Removed`, and `Security` sections for hand-written entries.

## Unreleased entries

Hand-written `[Unreleased]` bullets are merged into the matching Keep a
Changelog sections of the new version block (generated commit lines first).
Near-duplicates of generated conventional-commit bullets are collapsed.
Wrapped bullets are compared as a unit (continuation lines are folded into the
bullet, then kept or dropped with it), and two bullets are duplicates when
either their normalized text is near-identical — in which case the generated
line wins — or, within the same `**scope**`, they name the same feature
identifier: the kebab-case workflow or script token, with a leading verb
(`add`, `introduce`, `create`, `new`) and a `.yml`/`.yaml`/`.sh` extension
stripped. Same-identifier duplicates keep the more informative (longer)
display text, merge the PR references from both bullets (`(#521, #596)`), and
keep the generated commit sha.

Matching fails closed: without a confident identifier on both sides, differing
bullets are kept. Unreleased bullets that remain unique (security notes,
migrations, and other curated detail) are always preserved.

Prefer **not** restating conventional commits under `[Unreleased]`. Use
Unreleased for context the commit subject does not carry. The merger still
attempts to dedupe when contributors restate the same change.

## Historical entries

Do **not** rewrite existing `Features` / `Bug Fixes` sections in a consumer
`CHANGELOG.md`. Only version sections generated after the pin bump follow the
KAC headings; mixed history is expected and fine.

## Markdownlint (MD024)

Changelog files repeat the same section headings in every version block, which
trips MD024 (`no-duplicate-heading`). Org convention is a top-of-file HTML
comment in `CHANGELOG.md`:

```markdown
<!-- markdownlint-disable MD024 -- duplicate headings are standard in changelogs -->
```

Alternatively, configure `"MD024": { "siblings_only": true }` in the
repository's markdownlint config.

## Verification checklist

On the next release PR after bumping the pin:

- [ ] Generated section headings are `### Added` / `### Changed` / `### Fixed`
      (no `### Features` / `### Bug Fixes` / `### Other Changes`)
- [ ] Hand-written `[Unreleased]` entries were merged into the matching KAC
      sections of the new version block
- [ ] Near-duplicate Unreleased bullets that restate generated commits were
      collapsed (generated line kept for near-identical restatements; the
      longer text with merged PR references for same-identifier duplicates)
- [ ] `[Unreleased]` was reset with the empty KAC section skeleton
- [ ] Markdown lint passes without manual heading edits

## References

- Generator implementation: `scripts/ci/lib/release/changelog.sh`
- Unreleased-section merge: `scripts/ci/lib/release/changelog_merge.sh`
- Workflow entry point: `reusable-release-version-pr.yml` (see
  [reusable-workflows.md](reusable-workflows.md))
