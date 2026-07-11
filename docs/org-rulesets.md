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

| Ruleset | GitHub id | Repos | Required contexts |
| ------- | --------- | ----- | ----------------- |
| `checks-py-lintro` | `16132640` | `py-lintro` | `test-suite-coverage / 🧪 Test Suite & Coverage`, `lintro-code-quality / 🛠️ Lintro Code Quality`, `🔐 Security Audit` |
| `checks-rustume` | `16132643` | `Rustume` | `quality / 🛠️ Lintro Code Quality & Analysis`, `rust-build / 🔨 Build Check`, `rust-coverage / 🦀 Rust Coverage`, `web-coverage / 🌐 Web Coverage`, `🔐 Security Audit` |
| `checks-turbo-themes` | `16132642` | `turbo-themes` | `Socket Security: Pull Request Alerts`, `♿ E2E Accessibility Tests`, `semantic-title / ✅ Validate Conventional Commits`, `🎭 E2E Tests`, `🏗️ Build & Quality Checks (20)`, `🏗️ Build & Quality Checks (22)`, `sbom / SBOM & Supply Chain`, `📦 Validate Examples`, `quality / 🔍 Code Quality & Linting`, `codeql / 🔍 CodeQL Security Analysis`, `security-audit / 🔐 Security Audit`, `🔥 E2E Smoke Tests` |
| `checks-holy-grail` | `16132645` | `holy-grail` | `Analyze GitHub Actions`, `Analyze JavaScript/TypeScript`, `Build & Test`, `Check SHA Pinning`, `E2E Tests`, `Socket Security: Pull Request Alerts`, `Validate PR Title`, `quality / Lintro Quality Checks`, `🔐 Security Audit` |

<!-- markdownlint-enable MD013 -->

All rows follow the prefixed-path pattern: every `uses:` gate context is
`{caller_job_id} / {job-name}`, and only inline jobs (`🔐 Security Audit`,
holy-grail's hand-rolled workflow jobs) appear unprefixed. Consumer repos
must keep caller job ids stable — renaming a caller job id changes the
reported check path and breaks the ruleset gate (checks stay **Expected**
while Actions shows green under the new name).

Never require an **app-generated code-scanning summary check** (for example
the bare `CodeQL` context from the github-advanced-security app) in a repo
that uses a merge queue: the app only produces it on `pull_request` commits,
never merge-group commits, so every queue entry times out and is silently
ejected (holy-grail, 2026-07-11). Require the workflow-job contexts instead.

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
