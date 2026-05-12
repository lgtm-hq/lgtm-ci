# LGTM CI

Reusable CI/CD components: composite actions, workflows, and shell libraries for GitHub Actions.

## Structure

- `.github/workflows/reusable-*.yml` — Reusable workflows
- `.github/actions/` — Composite actions
- `scripts/` — Shell and Python helper scripts

## Standards

- Actions must be pinned to full commit SHAs, not version tags
- Shell scripts in dedicated files, not inline in YAML
- Scripts must have shebang and `set -euo pipefail`
- Use `lintro` for linting (`lintro chk`, `lintro fmt`)