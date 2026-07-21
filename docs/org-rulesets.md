# Org rulesets

Registry of lgtm-hq organization rulesets and the **required status check
contexts** they enforce. This document is the source of truth for check
**names**; GitHub is the source of truth for full ruleset payloads. Do not
commit exported ruleset JSON to this repository.

## Check-name contract

Org rulesets must require the **exact** check names workflows report:

- **`uses:` gates (workflow_call reusables):** GitHub reports the check as
  **`{caller_job_id} / {inner_job_name}`**. For `reusable-required-check.yml`
  that is the caller job id plus the `job-name` input (for example
  `test-suite-coverage / 🧪 Test Suite & Coverage`). The inner `job-name`
  alone is **not** sufficient for a ruleset.
- **Inline `runs-on` jobs:** the ruleset matches the job `name:` only (for
  example `🔐 Security Audit`).

See [workflow-contract.md](workflow-contract.md) (Org ruleset check names)
for the caller-side YAML pattern.

## Registry

<!-- markdownlint-disable MD013 -->

Shared rulesets (one logical check, uniform context, many repos):

| Ruleset          | GitHub id  | Repos                     | Required contexts                                                                                                                     |
| ---------------- | ---------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `checks-quality` | `18812462` | all except `py-lintro`    | `quality / 🛠️ Lintro Code Quality` (py-lintro gates its dogfood run as `lintro-code-quality / 🛠️ Lintro Code Quality` in its own row) |
| `checks-socket`  | `18809614` | all except `ui-framework` | `Socket Security: Pull Request Alerts` (external app check — name not renamable)                                                      |

Per-repo rulesets (stack-specific gates only; canonical emoji names per #514):

| Ruleset                    | GitHub id  | Repos               | Required contexts                                                                                                                                                                                                                                                                                                                                                                                                                     |
| -------------------------- | ---------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `checks-ai-skills`         | `16132646` | `ai-skills`         | `validate / 📚 Validate Skill Structure`                                                                                                                                                                                                                                                                                                                                                                                              |
| `checks-dot-github`        | `16438323` | `.github`           | `validate / 🧾 Validate Org Config`                                                                                                                                                                                                                                                                                                                                                                                                   |
| `checks-hass-turbo-themes` | `19175367` | `hass-turbo-themes` | `semantic-title / 📝 Validate PR Title`, `codeql / 🔬 CodeQL Analysis`, `security-audit / 🔐 Security Audit`, `validate / 📌 Validate Action Pinning`                                                                                                                                                                                                                                                                                 |
| `checks-holy-grail`        | `16132645` | `holy-grail`        | `codeql / 🔬 CodeQL Analysis`, `semantic-title / 📝 Validate PR Title`, `validate / 📌 Validate Action Pinning`, `🎭 E2E Tests`, `🏗️ Build & Test`, `🔐 Security Audit`                                                                                                                                                                                                                                                               |
| `checks-homebrew-tap`      | `16438312` | `homebrew-tap`      | `shell-tests / 🐚 Shell Tests`, `🍺 Validate Formula`                                                                                                                                                                                                                                                                                                                                                                                 |
| `checks-lgtm-ci`           | `16438310` | `lgtm-ci`           | `shell-tests / 🐚 Shell Tests`, `semantic-title / 📝 Validate PR Title`, `validate / 📌 Validate Action Pinning`                                                                                                                                                                                                                                                                                                                      |
| `checks-podex`             | `16438314` | `podex`             | `semantic-title / 📝 Validate PR Title`, `test / Aggregate Python Results`                                                                                                                                                                                                                                                                                                                                                            |
| `checks-podex-ops`         | `19427618` | `podex-ops`         | `semantic-title / 📝 Validate PR Title`, `security-audit / 🔐 Security Audit`, `validate / 📌 Validate Action Pinning`, `🏗️ Terraform Validate`                                                                                                                                                                                                                                                                                       |
| `checks-py-lintro`         | `16132640` | `py-lintro`         | `🚦 Test Gate`, `codeql / 🔬 CodeQL Analysis`, `lintro-code-quality / 🛠️ Lintro Code Quality`, `semantic-title / 📝 Validate PR Title`, `test-compat / Aggregate Python Results`, `test-compat / Python Compatibility`, `test-coverage / Aggregate Python Results`, `test-coverage / Python Coverage`, `test-suite-coverage / 🧪 Test Suite & Coverage`, `🐳 Build Docker Images`, `🔐 Security Audit`, `🧪 Docker Integration Tests` |
| `checks-rustume`           | `16132643` | `Rustume`           | `codeql / 🔬 CodeQL Analysis`, `semantic-title / 📝 Validate PR Title`, `validate / 📌 Validate Action Pinning`, `rust-build / 🔨 Build Check`, `rust-coverage / 🦀 Rust Coverage`, `web-coverage / 🌐 Web Coverage`, `🔐 Security Audit`                                                                                                                                                                                             |
| `checks-rustume-ops`       | `19427364` | `rustume-ops`       | `semantic-title / 📝 Validate PR Title`, `security-audit / 🔐 Security Audit`, `validate / 📌 Validate Action Pinning`, `Terraform fmt & validate`                                                                                                                                                                                                                                                                                     |
| `checks-spotify-curator`   | `19138064` | `spotify-curator`   | `codeql / 🔬 CodeQL Analysis`, `security-audit / 🔐 Security Audit`, `semantic-title / 📝 Validate PR Title`                                                                                                                                                                                                                                                                                                                          |
| `checks-turbo-themes`      | `16132642` | `turbo-themes`      | `♿ E2E Accessibility Tests`, `semantic-title / 📝 Validate PR Title`, `🎭 E2E Tests`, `🏗️ Build & Quality Checks (20)`, `🏗️ Build & Quality Checks (22)`, `sbom / 📋 SBOM & Supply Chain`, `📦 Validate Examples`, `codeql / 🔬 CodeQL Analysis`, `security-audit / 🔐 Security Audit`, `🔥 E2E Smoke Tests`                                                                                                                         |
| `checks-winnow`            | `17448561` | `winnow`            | `codeql / 🔬 CodeQL Analysis`, `security-audit / 🔐 Security Audit`, `semantic-title / 📝 Validate PR Title`, `test / Aggregate Python Results`, `test / 🧪 Python Compatibility`, `validate / 🧾 Validate Lintro Version`                                                                                                                                                                                                            |

There is no `checks-ui-framework` row: the repo's only gate is the shared
`checks-quality` context. `ui-framework` is not in `checks-socket` because
the Socket app does not scan it yet.

Repo-level `merge-queue` rulesets (one per repo, targeting
`~DEFAULT_BRANCH`) are structural — merge method, batch sizes, timeouts —
and require no status-check contexts, so they are deliberately not
registered in the tables above; this document registers check **names**
only.

`hass-turbo-themes` (HACS distribution repo for turbo-themes) onboarded
2026-07-19: included in `main`, `review-required`, `checks-quality`, and
`checks-socket`; repo-level `merge-queue` ruleset is `19175368`. Its inline
`🎨 Theme Drift Check` context joined the row when the regen workflow
landed (hass-turbo-themes#4).

`spotify-curator` went public on 2026-07-18, lifting its earlier
private-repo caps: the repo-level `merge-queue` ruleset now exists
(`19138667`) and the full security workflow set landed via
spotify-curator#43. Its CodeQL caller runs `actions` only until app code
lands on `main` (spotify-curator#44); its `test-coverage` contexts join the
row once the repo has tests (spotify-curator#36).

`podex-ops` and `rustume-ops` (private ops repos, Shell + Terraform)
onboarded 2026-07-21: both included in `main`, `review-required`,
`checks-quality`, and `checks-socket`. Private-repo caps apply — no
repo-level `merge-queue` rulesets and no GHAS-gated features (CodeQL,
dependency review, secret scanning, Scorecards) until the repos go public
or GHAS is enabled. `rustume-ops`'s two `shell-tests / …` contexts join
its row once rustume-ops#10 lands the shell-test workflows on `main`.

<!-- markdownlint-enable MD013 -->

All rows follow the prefixed-path pattern: every `uses:` gate context is
`{caller_job_id} / {job-name}`, and only inline jobs (`🔐 Security Audit`,
holy-grail's hand-rolled workflow jobs) appear unprefixed. Consumer repos
must keep caller job ids stable — renaming a caller job id changes the
reported check path and breaks the ruleset gate (checks stay **Expected**
while Actions shows green under the new name).

Never require an **app-generated code-scanning summary check** (for example
the bare `CodeQL` context from the github-advanced-security app, without a
`{caller_job_id} /` prefix) in a repo that uses a merge queue: the app produces
that check only on `pull_request` commits, never on `merge_group` commits, so
every queue entry times out and is silently ejected
([holy-grail#143](https://github.com/lgtm-hq/holy-grail/pull/143)). Require
the workflow-job contexts from `reusable-codeql.yml` instead — for example
`codeql / 🔬 CodeQL Analysis` — matching the exact `{caller_job_id} / {job-name}`
path in this registry. Never combine a merge queue with required app-level
code-scanning summary checks.

When migrating additional rulesets, update this table in the same PR that
updates the live ruleset.

## Tooling

Operator scripts live under `scripts/ci/org/`. They require org-admin `gh`
auth and honor `LGTM_ORG` (default `lgtm-hq`). Workflow: **discover → export
→ edit locally → dry-run sync → apply**.

```bash
# Discover: list all org rulesets (id, name, enforcement, target repos)
scripts/ci/org/list-rulesets.sh

# Fetch a live ruleset (read-only; stdout by default, -o for a local file)
scripts/ci/org/export-ruleset.sh checks-py-lintro 16132640 -o /tmp/ruleset.json

# Edit /tmp/ruleset.json, then preview the sanitized PUT payload (no API call)
scripts/ci/org/sync-ruleset.sh /tmp/ruleset.json

# Apply the change to the live org ruleset
scripts/ci/org/sync-ruleset.sh --apply /tmp/ruleset.json
```

`list-rulesets.sh` prints a compact table of ruleset id, name, enforcement
level, and target repositories — use it to find the id before exporting.
Pass `-q` to suppress informational log lines.

`sync-ruleset.sh` strips read-only fields (`id`, `node_id`, `source`,
`created_at`, `_links`, …) before the PUT and is a dry run unless `--apply`
is passed. Exported JSON is a local working file only — never check it in.
