# Release actions

Semantic version calculation, changelog generation, and tag/release
creation. See
[release-changelog.md](../release-changelog.md) for the Keep a Changelog
migration and [reusable-workflows.md](../reusable-workflows.md#release) for
the two-stage release model these actions back.

Release actions typically need `contents: write` (creating tags/releases)
and `packages: write` (uploading assets to GitHub Packages).

## calculate-version

Calculate the next semantic version based on conventional commits.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/calculate-version@main
  with:
    max-bump: "minor" # optional, clamp max bump type
```

**Outputs:** `current-version`, `next-version`, `bump-type`,
`release-needed`.

## generate-changelog

Generate a changelog from conventional commits.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/generate-changelog@main
  with:
    version: "1.2.0" # optional
    format: "full" # full, simple, or with-type
```

**Outputs:** `changelog` (Markdown).

## create-release-tag

Create an annotated git tag for a release.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-release-tag@main
  with:
    version: "1.2.0"
    push: "true" # push tag to origin
```

**Outputs:** `tag-name`, `tag-sha`, `commit-sha`.

## create-github-release

Create a GitHub release with changelog and optional assets.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-github-release@main
  with:
    tag: "v1.2.0"
    draft: "false"
    prerelease: "false"
    files: "dist/*.tar.gz dist/*.whl" # optional
    token: ${{ steps.app-token.outputs.token }} # optional, see note below
```

> By default, `token` uses the built-in `GITHUB_TOKEN`. Events created by
> `GITHUB_TOKEN` do not trigger other workflows. If downstream workflows
> need to react to `release:published`, pass a GitHub App installation
> token or PAT instead.

**Outputs:** `release-url`, `release-id`.
