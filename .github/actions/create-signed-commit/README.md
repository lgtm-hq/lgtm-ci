# create-signed-commit

Create a GitHub-signed commit from files in the job's working tree, using the
GraphQL `createCommitOnBranch` mutation.

A GitHub App token has no signing key, so `git commit` + `git push` with it
produces an unsigned commit that rulesets with `required_signatures` reject.
GitHub signs commits it creates through the API itself, so the commit shows as
verified. Nothing is pushed with the git CLI: the action reads each listed file,
uploads it as base64, and GitHub writes the commit server-side.

The action wraps
[`scripts/ci/git/create-signed-commit.sh`](../../../scripts/ci/git/create-signed-commit.sh),
which you can also run directly (`--help` lists its flags).

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `token` | yes | | Token with `contents: write`, normally a GitHub App token |
| `repository` | no | `${{ github.repository }}` | Target repository (`owner/repo`) |
| `branch` | yes | | Branch to commit on |
| `mode` | no | `append` | `append` or `reset` (see below) |
| `expected-head` | append | | Full SHA the branch head must equal |
| `base` | reset | | Full SHA to create or force-reset the branch at |
| `message` | yes | | Commit headline (single line) |
| `body` | no | | Commit message body |
| `files` | no | | Newline-separated repo-relative paths to add or update |
| `delete` | no | | Newline-separated repo-relative paths to delete |

At least one of `files` or `delete` must be set. Paths are relative to the
repository root and are read from the step's working directory (the workspace
by default), so check out the target repository at its root.

## Outputs

| Output | Description |
| ------ | ----------- |
| `commit-sha` | OID of the created commit |
| `commit-url` | URL of the created commit |

## Modes

### `append`: add a commit on top of someone else's branch

Use this when another actor (for example Renovate) owns the branch and the bot
only adds one commit to it. The ref is never created or moved. The branch must
already exist, and its head must equal `expected-head`. The action checks this
first and fails with a clear message. It also passes `expected-head` as the
mutation's `expectedHeadOid`, so if someone pushes between the check and the
commit, GitHub rejects the mutation and the action fails instead of overwriting
their work.

```yaml
- uses: actions/create-github-app-token@<sha> # vX.Y.Z
  id: app-token
  with:
    app-id: ${{ vars.BOT_APP_ID }}
    private-key: ${{ secrets.BOT_PRIVATE_KEY }}

- uses: lgtm-hq/lgtm-ci/.github/actions/create-signed-commit@<sha> # vX.Y.Z
  with:
    token: ${{ steps.app-token.outputs.token }}
    branch: ${{ github.head_ref }}
    mode: append
    expected-head: ${{ github.event.pull_request.head.sha }}
    message: "chore(deps): pin tools candidate digest"
    files: |
      Dockerfile
      docker/ai-tools.Dockerfile
```

### `reset`: own the branch

Use this when the bot owns the branch, as with a release or update PR. The
action creates `refs/heads/<branch>` at `base`, or force-resets it to `base` if
it already exists, then commits on top with `expectedHeadOid = base`. Any
earlier commits on the branch are discarded.

The full payload is built before the ref moves. If the commit then fails, the
action restores the branch to its previous head, or deletes it if this run
created it, so a failed run never leaves the branch parked at `base`.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/create-signed-commit@<sha> # vX.Y.Z
  id: commit
  with:
    token: ${{ steps.app-token.outputs.token }}
    branch: homebrew/lintro-1.2.3
    mode: reset
    base: ${{ github.sha }}
    message: "chore(homebrew): update lintro to 1.2.3"
    body: |
      Automated formula update.
    files: Formula/lintro.rb
    delete: |
      Formula/old-name.rb

- run: echo "Committed ${COMMIT_URL}"
  env:
    COMMIT_URL: ${{ steps.commit.outputs.commit-url }}
```

## Commit author

The commit author is the token's identity. For a GitHub App the author email is:

```text
<app-user-id>+<app-slug>[bot]@users.noreply.github.com
```

`<app-user-id>` is the id of the App's bot user (`gh api users/<app-slug>[bot]
--jq .id`), not the App id. Tools that match commit authors, such as Renovate
`gitIgnoredAuthors`, must use this form.

## Workflow triggers

A commit created with a GitHub App token **does** trigger `push` and
`pull_request` workflows, so required checks re-run on the new head. A commit
created with the default `GITHUB_TOKEN` does not trigger them. Use an App token
when you rely on CI running against the bot's commit.

## Limits of `createCommitOnBranch`

- **Regular files only.** The action rejects any `files` entry that is a
  symlink, a directory, missing, or otherwise not a regular file. The mutation
  cannot write symlinks or submodules.
- **No file modes.** It cannot set or change file modes such as the executable
  bit. Commit mode changes another way.
- **Payload size.** GitHub caps the size of a GraphQL request, and every file is
  sent base64-encoded (about a third larger than the file). Keep commits small
  and split large changes.
- **Full SHAs.** `expected-head` and `base` must be full commit SHAs.
- **Single-line headline.** Put anything after the first line in `body`.

## Required permissions

The token needs `contents: write` on the target repository. `reset` mode also
creates or force-updates the branch ref, so branch rulesets must allow the token
to do that on the target branch.
