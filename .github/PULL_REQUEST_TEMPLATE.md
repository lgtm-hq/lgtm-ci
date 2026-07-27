<!-- markdownlint-disable MD041 -->

## Summary

<!-- Brief description of what this PR does -->

## Type of Change

- [ ] New feature (composite action, reusable workflow, or utility script)
- [ ] Bug fix
- [ ] Documentation update
- [ ] Refactoring (no functional changes)
- [ ] CI/CD improvement

## Checklist

- [ ] I have tested these changes locally
- [ ] I have updated documentation if needed
- [ ] Shell scripts pass `shellcheck`
- [ ] YAML files pass `yamllint`
- [ ] Python code passes `ruff` and `black`
- [ ] If this changes a reusable workflow's permissions or inputs: checked
      whether `examples/**` and `docs/onboarding.md` need the same change —
      they are pinned to a released SHA (not the tip), so a fix landing here
      often does **not** need a matching example edit until the next pin bump
      (see `docs/reusable-workflows.md` "Scopes a caller cannot avoid
      granting" and #765)

## Breaking Changes

<!-- List any breaking changes and migration steps, or write "None" -->

## Related Issues

<!-- Link any related issues: Fixes #123, Relates to #456 -->
