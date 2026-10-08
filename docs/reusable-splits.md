# Reusable splits at permission boundaries (#1081)

GitHub checks a reusable workflow's whole permission union before any job
`if:` runs. A caller that only runs tests therefore grants every scope the
file's publish jobs declare. #1081 splits five high-branching reusables where
permissions, mutation, platform or lifecycle differ, and nowhere else. Each
facade keeps its inputs, outputs and check names.

## Inventory before the split

Measured on `main` at v0.76.0 (`2134b700`) from each file's YAML: jobs,
jobs with an `if:`, the job-level permission union (`write` outranks `read`),
the `secrets:` the jobs read, and the inputs that decide which jobs run.

<!-- markdownlint-disable MD013 -- wide inventory table -->

| Workflow | Jobs | Conditional | Permission union | Secrets | Inputs that switch jobs |
| --- | --- | --- | --- | --- | --- |
| `reusable-test-node.yml` | 5 | 5 | `actions: read`, `contents: read`, `pull-requests: write` | none | `draft-pr-skip` (all), `upload-pages-coverage-html` + `coverage` (`pages-coverage-status`), `publish-test-summary` (`publish-test-summary`) |
| `reusable-test-shell.yml` | 5 | 5 | `actions: read`, `contents: read`, `pull-requests: write` | none | `coverage` + `coverage-shards` (`test` or `shard-setup` / `test-sharded` / `aggregate`), `draft-pr-skip` (all), `publish-test-summary` (`publish-test-summary`) |
| `reusable-rust-test.yml` | 4 | 4 | `actions: read`, `contents: read`, `pull-requests: write` | none | `draft-pr-skip` (all), `publish-test-summary` (`publish-test-summary`) |
| `reusable-docker-multiplatform.yml` | 6 | 5 | `attestations: write`, `contents: read`, `id-token: write`, `packages: write`, `security-events: write` | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | `push` (`verify-per-platform`, `health-check-per-platform`, `merge`, `scan`, `summary-validate`), `smoke-test` / `smoke-test-script` (`verify-per-platform`), `health-check-cmd` (`health-check-per-platform`), `validate-on-pr` (`summary-validate`), `scan` (`scan`) |
| `reusable-release-recover.yml` | 5 | 4 | `actions: read`, `attestations: write`, `contents: write`, `id-token: write`, `issues: write` | `homebrew-dispatch-token` | `dry-run` (every resume job), `npm-artifact-name` + `npm-order` (`resume-npm`), `release-artifact-name` (`resume-github-release`), `homebrew-dispatch-repo` (`resume-homebrew`) |

| Workflow | Job | Permissions | Mutates |
| --- | --- | --- | --- |
| `reusable-test-node.yml` | `prepare`, `test-vitest`, `pages-coverage-status` | `contents: read` | no (artifacts only) |
| | `aggregate-tests` | `actions: read`, `contents: read` | no |
| | `publish-test-summary` (calls `reusable-publish-test-summary.yml`) | `contents: read`, `pull-requests: write` | PR comment |
| `reusable-test-shell.yml` | `test`, `shard-setup`, `test-sharded` | `contents: read` | no |
| | `aggregate` | `actions: read`, `contents: read` | no |
| | `publish-test-summary` (calls `reusable-publish-test-summary.yml`) | `contents: read`, `pull-requests: write` | PR comment |
| `reusable-rust-test.yml` | `prepare`, `test` | `contents: read` | no |
| | `aggregate` | `actions: read`, `contents: read` | no |
| | `publish-test-summary` (calls `reusable-publish-test-summary.yml`) | `contents: read`, `pull-requests: write` | PR comment |
| `reusable-docker-multiplatform.yml` | `build-per-platform` | `contents: read`, `packages: write`, `security-events: write` | registry push by digest when `push`; with `push: false` and `scan`, a code-scanning SARIF upload (`upload-sarif`), so a read-only validate entry must drop or move that step too |
| | `verify-per-platform`, `health-check-per-platform` | `contents: read`, `packages: read` | no |
| | `merge` | `contents: read`, `packages: write`, `id-token: write`, `attestations: write` | manifest, tags, signature, attestation |
| | `summary-validate` | `contents: read` | no |
| | `scan` | `contents: read`, `packages: read`, `security-events: write` | code-scanning upload |
| `reusable-release-recover.yml` | `resolve` | `actions: read`, `contents: read`, `id-token: write` | no (attestation verification) |
| | `resume-npm` | `contents: read`, `id-token: write`, `attestations: write` | npm publish |
| | `resume-github-release` | `contents: write` | release assets |
| | `resume-homebrew` | `contents: read` + `homebrew-dispatch-token` | cross-repo dispatch |
| | `record` | `actions: read`, `contents: read`, `issues: write` | recovery issue |

<!-- markdownlint-enable MD013 -->

## Check names constrain the split

A job in a nested reusable reports as `<caller job> / <facade job> / <job>`.
Moving a facade's jobs into a reusable the facade calls would add a segment
to every check name. Org rulesets require some of these names exactly
([org-rulesets.md](org-rulesets.md)): `shell-tests / 🐚 Shell Tests`
(`reusable-test-shell.yml`) in `checks-lgtm-ci` and `checks-homebrew-tap`, and
three `shell-tests / …` contexts in `checks-rustume-ops`.

So the language test facades keep their jobs inline. The read-only entry
point is a variant generated from the facade, minus the regions the facade
marks `# lgtm-ci-readonly:omit` (see
[Read-only variants](reusable-workflows.md#read-only-variants)). The mutation
boundary of these three families is already a separate reusable,
`reusable-publish-test-summary.yml`, which a caller of the variant can call
from its own job.

### Docker multi-platform and release recover: required-check scan

Before composing a facade, every required status-check context in lgtm-hq
was read on 2026-10-09 (98 contexts: org rulesets, repository rulesets and
classic branch protection of every repository). None names a job of
`reusable-docker-multiplatform.yml` or `reusable-release-recover.yml`. The
only Docker contexts are podex's `… / Docker build / Build and Push`, from
the separate `reusable-docker-build.yml` path, and two inline py-lintro jobs.
Organisation callers reach the multi-platform path only through
`reusable-docker.yml` (Rustume, podex, py-lintro, winnow); py-lintro calls
`reusable-release-recover.yml` from a dispatch-only workflow. So these two
families compose internal reusables, and their nested check names change
(listed in the catalog and the migration notes).

## Split per family

<!-- markdownlint-disable MD013 -- wide plan table -->

| Family | Boundary | Read-only entry point | Facade | Status |
| --- | --- | --- | --- | --- |
| Node tests | test (read) / PR comment (`pull-requests: write`) | `reusable-test-node-run.yml` (generated): `actions: read`, `contents: read` | unchanged | done (#1135) |
| Shell tests | same | `reusable-test-shell-run.yml` (generated): `actions: read`, `contents: read` | unchanged | done (#1140) |
| Rust tests | same | `reusable-rust-test-run.yml` (generated): `actions: read`, `contents: read` | unchanged | this change |
| Docker multi-platform | build and validate (read) / registry push, manifest, signing, attestation, code scanning (write) | `reusable-docker-multiplatform-validate.yml`: `contents: read`; SARIF kept as an artifact | composes `-validate` (`push: false`), an `upload-scan-results` job (`security-events: write`) and the internal `-publish` (`push: true`); nested check names gain a segment | this change |
| Release recover | resolve, dry run (read) / resume per channel (write, secret) / record (`issues: write`) | planned: a plan entry that resolves and reports | same rule as Docker | planned |

<!-- markdownlint-enable MD013 -->

Optional modes with no known consumer are removed only after the
deprecation path of #1082, not as part of a split.
