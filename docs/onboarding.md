# Consumer onboarding

Task-ordered guide from an empty `.github/workflows/` directory to a first
green build on lgtm-ci reusable workflows. Read top to bottom; each step
builds on the previous one.

Reference material lives in [workflow-contract.md](workflow-contract.md)
(inputs, permissions, egress presets) and
[reusable-workflows.md](reusable-workflows.md) (per-workflow details). This
guide covers only the setup path around the starter examples.

Before copying CI logic, apply
[Inclusion: what belongs in lgtm-ci](governance.md#inclusion-what-belongs-in-lgtm-ci)
to decide what to upstream, consume or keep local, and when a documented
exception is required.

## 1. Pick a starter example

Choose by repository type and copy the example into your repository's
`.github/workflows/` directory. The full index with descriptions is in
[examples/README.md](../examples/README.md).

<!-- markdownlint-disable MD013 MD060 -- decision table; row text exceeds default line length -->

| Repository type                             | Starter example                                                                            | Copy as                      |
| ------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------- |
| Python (uv/pytest)                          | [ci-python.yml](../examples/ci-python.yml)                                                 | `ci.yml`                     |
| Node.js with Vitest                         | [ci-node-vitest.yml](../examples/ci-node-vitest.yml)                                       | `ci.yml`                     |
| Node.js custom test command (Bun, monorepo) | [ci-node-custom.yml](../examples/ci-node-custom.yml)                                       | `ci.yml`                     |
| Rust workspace                              | [ci-rust.yml](../examples/ci-rust.yml)                                                     | `ci.yml`                     |
| Docker image (multi-arch, GHCR)             | [ci-docker.yml](../examples/ci-docker.yml)                                                 | `ci.yml`                     |
| Lint-only (tag/release, no PR comments)     | [ci-quality-only.yml](../examples/ci-quality-only.yml)                                     | `ci.yml`                     |
| Automated releases (version PRs)            | [release-version-pr.yml](../examples/release-version-pr.yml)                               | `release-version-pr.yml`     |
| Automated releases (tag + GitHub Release)   | [release-auto-tag.yml](../examples/release-auto-tag.yml)                                   | `release-auto-tag.yml`       |
| Releases without package version files      | [release-version-pr-changelog-only.yml](../examples/release-version-pr-changelog-only.yml) | `release-version-pr.yml`     |
| PyPI publish on tag                         | [publish-python-release.yml](../examples/publish-python-release.yml)                       | `publish-python-release.yml` |

<!-- markdownlint-enable MD013 MD060 -->

A typical repository takes one CI example plus, when it releases, the
version-PR and auto-tag pair.

Most examples pin `uses:` refs to a specific lgtm-ci release commit SHA with
a `# vX.Y.Z` comment and pass no `tooling-ref` (releases from v0.75.3 resolve
their own tooling from the `uses:` pin, #995); examples that contain `<sha>`
placeholders must be filled in before use. The shipped pin ages; resolve the
current release SHA (see
[Resolve the release commit SHA](#4-resolve-the-release-commit-sha)) and
update every `uses:` pin before committing.

## 2. Prerequisites per capability

What each capability needs before its first run. Caller job `permissions:`
blocks are already correct in the starter examples; the authoritative matrix
is workflow-contract.md
["Permissions by mode"](workflow-contract.md#permissions-by-mode).

<!-- markdownlint-disable MD013 -- prerequisites table -->

| Capability                        | Caller permissions                                                            | Extra setup                                                                                                                |
| --------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Quality / lint                    | `contents: read`, `packages: read` (pulls `ghcr.io/lgtm-hq/py-lintro`)        | None                                                                                                                       |
| Quality / test PR summaries       | `contents: read`, `pull-requests: write` on the publish job                   | None                                                                                                                       |
| Tests / coverage                  | `contents: read`                                                              | None                                                                                                                       |
| Rust tests (`reusable-rust-test`) | `contents: read`                                                              | `.config/nextest.toml` with a `ci` profile — copy [examples/nextest-ci.toml](../examples/nextest-ci.toml) verbatim (below) |
| Release version PR                | `contents: write`, `pull-requests: write`, `actions: read`, `issues: write`   | GitHub App + two secrets (below); `CHANGELOG.md` is created on the first run if absent (below)                             |
| Release auto-tag                  | `contents: write`, `actions: read`, `issues: write`                           | GitHub App + two secrets (below)                                                                                           |
| PyPI publish (OIDC)               | `contents: read`; `id-token: write` + `attestations: write` on the upload job | PyPI trusted publisher (below)                                                                                             |

<!-- markdownlint-enable MD013 -->

### Rust tests: nextest `ci` profile

`reusable-rust-test.yml` runs `cargo nextest run --profile ci` and parses
`target/nextest/ci/junit.xml`, so the repository must define that profile
before the first run. Copy
[`examples/nextest-ci.toml`](../examples/nextest-ci.toml) to
`.config/nextest.toml` (relative to `working-directory`) as-is. Keep
`junit.path = "junit.xml"`: nextest resolves the path relative to the
profile's store directory (`target/nextest/ci/`), so a directory-qualified
path puts the report where the reusable cannot find it and the job fails
with `JUnit file not found` after the tests pass (#1086). Without the file the
run fails with `profile 'ci' not found`.

### Release workflows: GitHub App and secrets

`reusable-release-version-pr.yml` and `reusable-release-auto-tag.yml` create
commits, tags, and PRs with a GitHub App installation token
(`actions/create-github-app-token`), not the default `GITHUB_TOKEN` — so that
release pushes can trigger downstream workflows (see
[Which token for which write](#which-token-for-which-write)). The reusables
(`reusable-release-multi-ecosystem.yml` too) declare these secrets:

- `RELEASE_APP_CLIENT_ID` **or** `RELEASE_APP_ID`: set at least one. Each is
  optional on its own, but a `Select GitHub App credential` step fails with an
  `::error::` annotation when neither is set. When both are set (for example a
  `secrets: inherit` caller in an org that defines both), the client ID wins and
  a `::notice::` says `RELEASE_APP_ID` was ignored. The client ID (shown on the
  App's settings page) is the form `actions/create-github-app-token`
  recommends; the numeric App ID is still accepted.
- `RELEASE_APP_PRIVATE_KEY` (required)

Copying a release example without a credential and the private key fails at
the `Select GitHub App credential` or `Create GitHub App installation token`
step. One-time setup:

1. **Create the App** (org owner): _Organization Settings → Developer
   settings → GitHub Apps → New GitHub App_. Disable webhooks; no callback
   URL needed.
2. **Repository permissions**: `Contents: Read and write`,
   `Pull requests: Read and write`, `Issues: Read and write` (issues cover
   the `report-release-failure` follow-up job), and
   `Workflows: Read and write`.

   `Workflows` is required by `reusable-release-auto-tag`: the
   `Update floating tag` step force-pushes the major tag (`v0`) onto the
   release commit, and GitHub rejects that push as a workflow update when the
   range touches `.github/workflows/**` — which it does on any release that
   includes a workflow change. The reusable requests this scope explicitly, so
   an App without it fails at `Create GitHub App installation token`, before
   any tag or release is created.

   `reusable-release-version-pr` and `reusable-release-multi-ecosystem` rely
   on it by default too (#1449): their version-PR token requests
   `workflows: write`, so an App without the permission now fails at
   `Create GitHub App installation token` in the `version-pr` job. A caller
   that cannot grant it sets `request-workflows-permission: false`; the job
   then refuses any version PR that would change a file under
   `.github/workflows/`. See
   [migration/v0.94.md](migration/v0.94.md).

3. **Install the App** on the organization (the reusables request the token
   with `owner: ${{ github.repository_owner }}`), scoped to the repositories
   that run release workflows.
4. **Generate a private key** on the App's settings page (downloads a `.pem`
   file) and note the numeric **App ID** or the **Client ID**.
5. **Set the secrets** on the consumer repository (or as org secrets shared
   across release repos):

   ```bash
   gh secret set RELEASE_APP_ID --repo <org>/<repo> --body "<app-id>"
   # or, instead of RELEASE_APP_ID (preferred when both are set):
   gh secret set RELEASE_APP_CLIENT_ID --repo <org>/<repo> --body "<client-id>"
   gh secret set RELEASE_APP_PRIVATE_KEY --repo <org>/<repo> < release-app.private-key.pem
   ```

The starter examples forward the App ID form to the reusable. To use the
client ID, replace the `RELEASE_APP_ID` line with
`RELEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}`:

```yaml
secrets:
  RELEASE_APP_ID: ${{ secrets.RELEASE_APP_ID }}
  RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Two things the version-PR reusable handles itself, so they are **not**
prerequisites:

- **`CHANGELOG.md`.** A repository without one gets the file created on the
  first run — Keep a Changelog header, empty `## [Unreleased]` section, and
  the first release section — inside the same version PR (#1092). Existing
  changelogs are updated in place as before.
- **Registry egress for ecosystem bumps.** The default
  `egress-preset: release-version-pr` already allows PyPI (`ecosystems: python`
  installs `tomlkit` when the runner lacks it) and rustup/crates.io
  (`ecosystems: rust` regenerates `Cargo.lock`), so neither ecosystem needs
  `allowed-endpoints` under `egress-policy: block` (#1093). Callers that pinned
  `egress-preset: github-tooling` (the previous starter example) must switch to
  `release-version-pr` or drop the input. If you pass `allowed-endpoints` in the
  default `replace` mode, your list replaces the preset and must include those
  hosts; in `append` mode the base the extras are merged onto is now
  `release-version-pr` rather than `github-tooling`.

#### Upgrading an existing release App

Release Apps created before `Workflows: Read and write` was required must be
updated, or `reusable-release-auto-tag` fails at
`Create GitHub App installation token`. The version-PR reusables fail at the
same step unless the caller sets `request-workflows-permission: false`.

Editing the App's permissions is only half the change: GitHub queues the new
scope as a **pending approval on each installation**, and an org owner must
accept it before tokens carry it. Until then the installation keeps its old
permission set and the failure persists with no obvious cause.

1. _App settings → Permissions & events_ → set `Workflows: Read and write`.
2. _Organization Settings → Installed GitHub Apps_ → open the App → approve
   the requested permission update.
3. Verify the installation actually reflects it:

   ```bash
   gh api /orgs/<org>/installations \
     --jq '.installations[] | select(.app_slug=="<app-slug>") | {permissions, updated_at}'
   ```

   `permissions` must include `"workflows": "write"`, and `updated_at` should
   move to the approval time. If it has not changed, the approval in step 2 has
   not been accepted.

### Which token for which write

The default `GITHUB_TOKEN` is the right credential for most writes, but events
it creates (a push, a tag, a release, a merge) deliberately do **not** start
other workflow runs. Pick the token by what the write must trigger:

| Write                                                               | Token                           | Why                                                                                                                                    |
| ------------------------------------------------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| PR or issue comment, check run, artifact upload, label              | `GITHUB_TOKEN`                  | Nothing downstream needs to react, and the token expires with the job.                                                                 |
| Commit, tag, release, or merge that must start downstream workflows | App installation token or a PAT | Pushes and releases made with `GITHUB_TOKEN` never trigger `push`, `release`, or tag workflows, so CI and publish silently do not run. |

Prefer the App installation token: it is short-lived, scoped to the caller
repository, and not tied to a person. The release reusables mint it and fail
closed if no credential is set. The selection step writes the
chosen value to a step output, so the mint step never needs a `secrets.*`
reference in an `if:`:

```yaml
- name: Select GitHub App credential
  id: app-cred
  shell: bash
  env:
    APP_ID: ${{ secrets.RELEASE_APP_ID }}
    APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}
  run: |
    if [[ -z "${APP_ID}" && -z "${APP_CLIENT_ID}" ]]; then
      echo "::error title=missing App credential::set RELEASE_APP_CLIENT_ID or RELEASE_APP_ID"
      exit 1
    fi
    if [[ -n "${APP_CLIENT_ID}" ]]; then
      if [[ -n "${APP_ID}" ]]; then
        echo "::notice title=RELEASE_APP_ID ignored::both are set; using RELEASE_APP_CLIENT_ID"
      fi
      APP_ID=""
    fi
    {
      echo "app-id=${APP_ID}"
      echo "client-id=${APP_CLIENT_ID}"
    } >> "${GITHUB_OUTPUT}"
- name: Create GitHub App installation token
  id: app-token
  uses: actions/create-github-app-token@<sha> # pinned
  with:
    app-id: ${{ steps.app-cred.outputs.app-id }}
    client-id: ${{ steps.app-cred.outputs.client-id }}
    private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

The installation token is scoped to the **caller** repository
(`repositories: ${{ github.event.repository.name }}`). If the caller checks out
a private mirror of the tooling repository, that token cannot read it: supply a
separate, read-only clone token for that checkout rather than widening the
release token. The reusables take that token as the optional secret
`LGTM_CI_TOOLING_TOKEN`, which is being added one reusable at a time; see
[Tooling token](workflow-contract.md#tooling-token-1451).

### PyPI publish: trusted publisher

`publish-python-release.yml` uploads via OIDC (no API token secret).
Register your **consumer repository and workflow filename** as a PyPI
trusted publisher — not `lgtm-hq/lgtm-ci`. See
[python-release-publish.md](python-release-publish.md), "PyPI trusted
publishing".

## 3. Egress: verify the allowlist

Reusable workflows default to `egress-policy: block` with a per-workflow
`egress-preset` baseline (canonical definitions:
`scripts/ci/lib/egress/presets.sh`; full preset table in
workflow-contract.md ["Egress presets"](workflow-contract.md#egress-presets)).
Repositories with standard toolchains usually pass on the preset alone. If
your build pulls from hosts outside the preset, the first run fails with
blocked connections. For workflows that permit audit, use this flow:

1. **Onboard in audit mode.** Set `egress-policy: audit` on the reusable
   `with:` block. Nothing is blocked; all outbound calls are recorded.
2. **Read the report.** Open the failing-or-passing job in the Actions UI —
   the StepSecurity harden-runner step summary links to the egress report
   listing every endpoint the job contacted.
3. **Build the allowlist.** Keep the preset and append only your extra hosts:

   ```yaml
   with:
     egress-policy: block
     egress-preset: quality
     allowed-endpoints-mode: append
     allowed-endpoints: >
       example-registry.internal:443
   ```

   `allowed-endpoints-mode: append` merges preset + extras (deduped). The
   default `replace` mode discards the preset when `allowed-endpoints` is
   non-empty — use it only when you want full manual control.

4. **Flip to block.** Set `egress-policy: block` (or remove the input — block
   is the default) and re-run. Repeat 2–3 if a host was missed.

Workflows with [`strict` or `hardened` runner tiers](workflow-contract.md#runner-policy-tiers)
reject audit. Start these in `block` with the default preset, inspect denied
connections in the StepSecurity report, then append required hosts as in
step 3 and re-run.

Audit mode is a bring-up tool; production callers should run `block`.
`reusable-publish-rust-release.yml` accepts `egress-policy` (default `block`)
and forwards it to the nested binary build. Tag verification and GitHub
release jobs enforce a fixed `block` policy at tier `strict`.

## 4. Resolve the release commit SHA

The [action pinning policy](workflow-contract.md#action-pinning-policy)
requires pinning `uses:` refs to the **release commit SHA** with a
`# vX.Y.Z` comment — not the tag name and not the annotated tag
object SHA. Resolve a release tag to its commit:

```bash
git ls-remote https://github.com/lgtm-hq/lgtm-ci 'refs/tags/v0.59.30^{}'
```

Or via the API (fetch the tag ref, then peel the annotated tag object to its
commit):

```bash
gh api repos/lgtm-hq/lgtm-ci/git/ref/tags/v0.59.30 --jq '.object.sha' |
  xargs -I{} gh api repos/lgtm-hq/lgtm-ci/git/tags/{} --jq '.object.sha'
```

Both print the release commit SHA (for v0.59.30:
`cc5b3cc982868fa4c0718d4b26045ca9f56f0f5b`). lgtm-ci release tags are
annotated; if a tag ever does not peel (lightweight tag), the `^{}` query
prints nothing and the `git/tags/{}` API call fails — in that case the tag
ref itself already points at the commit, so use
`git ls-remote https://github.com/lgtm-hq/lgtm-ci refs/tags/vX.Y.Z` or
`gh api repos/lgtm-hq/lgtm-ci/git/ref/tags/vX.Y.Z --jq '.object.sha'`
directly. Use the commit SHA on every `uses:` line:

_Fragment: permissions omitted for brevity, not copyable as-is. See
[Permissions by mode](workflow-contract.md#permissions-by-mode)._

<!-- markdownlint-disable MD013 -- pinned uses: line exceeds line length by design -->

```yaml
uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@b830ca6972f0c9cbaeb1363283de594f68d66acf # v0.87.0
```

<!-- markdownlint-enable MD013 -->

`tooling-ref` is only needed on pins older than v0.75.3 and in
`release-recover.yml`; where it is passed it must equal the `uses:` SHA. The
direct `prepare-pypi-upload` action step needs it only on pins older than the
change in #1451; from then on the action takes its tooling from its own
`uses:` pin and ignores the input.

**Repinning** to a newer release is the same procedure: resolve the new tag,
replace every `uses:` SHA (and any `tooling-ref` still passed) plus their
`# vX.Y.Z` comments in one commit. A mismatched pair (workflow at one release, scripts
at another) is the most common source of drift bugs.

## 5. Align org ruleset check names

Reusable workflows report checks as `caller_job_id / inner_job_name`. If your
organization rulesets require named status checks, either update the ruleset
to the new check path or bridge with `reusable-required-check.yml` — see
workflow-contract.md
["Org ruleset check names"](workflow-contract.md#org-ruleset-check-names).
Ruleset documentation and sync tooling are tracked in
[lgtm-ci#301](https://github.com/lgtm-hq/lgtm-ci/issues/301).

## First green build checklist

- [ ] Starter example copied and `on:` triggers match your branch layout
- [ ] `uses:` SHA repinned to the current release (step 4); `tooling-ref` only
      where still required
- [ ] Release repos: GitHub App installed; `RELEASE_APP_CLIENT_ID` or
      `RELEASE_APP_ID` (the client ID wins when both are set) and
      `RELEASE_APP_PRIVATE_KEY` secrets set (step 2)
- [ ] Release repos: App holds `Workflows: Read and write`, and the
      installation has **accepted** the permission (step 2) — see
      "Upgrading an existing release App" below
- [ ] Publish repos: PyPI trusted publisher registered (step 2)
- [ ] Egress audited and allowlist appended where needed; policy on `block`
      (step 3)
- [ ] Org ruleset required checks match the new check paths (step 5)
