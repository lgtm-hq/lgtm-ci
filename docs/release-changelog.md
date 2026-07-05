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
- [ ] `[Unreleased]` was reset with the empty KAC section skeleton
- [ ] Markdown lint passes without manual heading edits

## References

- Generator implementation: `scripts/ci/lib/release/changelog.sh`
- Unreleased-section merge: `scripts/ci/lib/release/changelog_merge.sh`
- Workflow entry point: `reusable-release-version-pr.yml` (see
  [reusable-workflows.md](reusable-workflows.md))
