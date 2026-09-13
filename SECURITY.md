# Security Policy

## Reporting Security Issues

Please do **not** open public GitHub issues for security vulnerabilities.
Report them privately via
[GitHub private vulnerability reporting](https://github.com/lgtm-hq/lgtm-ci/security/advisories/new)
or email [security@lgtm-hq.com](mailto:security@lgtm-hq.com).

## Threat Model: Self-Gating CI Checks

This repository's own quality gates (`validate-action-pinning.yml`, quality,
shell tests) run on `pull_request` events and execute code **from the PR
branch**. That means the gates are self-gating: a pull request can modify a
validator script and the workflow that runs it in the same change, so the
checks validate the attacker's version of the validator rather than the
trusted one on `main`.

This is an accepted residual risk, mitigated by controls outside the
workflows themselves:

- **CODEOWNERS** — changes to workflows and CI scripts require review by
  designated owners.
- **Organization rulesets and branch protection** — merges to `main` require
  an approving review; direct pushes are blocked.
- **Required human review** — reviewers are the trust boundary. A malicious
  change to a validator plus its workflow passes CI by construction; only
  review catches it.

### Consumer impact

Consumer repositories pull `scripts/ci/` and composite actions at a pinned
`tooling-ref`. A malicious change merged to this repository does **not**
reach consumers immediately — it ships at each consumer's next repin. This
limits blast radius but does not remove it: once a consumer repins past a
malicious merge, that consumer runs the compromised tooling. Review
requirements on this repository are therefore a security control for every
downstream consumer, not just for lgtm-ci itself.

## Release integrity

Every artifact an lgtm-hq repository publishes through lgtm-ci reusables, or
alongside them, is held to the
[release security policy](docs/release-security-policy.md): mandatory evidence
per artifact class (GitHub build-provenance attestations, PyPI and npm
provenance, container provenance, SBOM and Cosign signatures), build-then-publish
ordering so no irreversible write happens before every attestation exists,
blocking failures, a three-tier recovery rule with a 90-day artifact retention
window, and the requirement that backfills carry the same evidence as tag
builds. The policy lists the one-command verification for each artifact class.
