#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail a job whose harden-runner agent is not verifiably enforcing
#
# Source of truth for the inline "Verify harden-runner agent" steps that follow
# every step-security/harden-runner step in .github/workflows (#1203, #1450).
# The pinned harden-runner (v2.22.3) logs an agent startup failure, or skips
# the agent outright, and still exits 0, so the job would run unhardened. The
# step stays inline because it runs before any checkout: nothing else is on
# disk. scripts/ci/bootstrap/sync_inline_blocks.py copies the lines between
# the markers below into each workflow and fails CI on drift. Keep the body
# self-contained: no sourcing, no checkout, no network.
#
# Owner decision (#1203): a job never passes without verified hardening.
#   - The step has no platform if:, so it runs on every runner, including the
#     hosted macOS and Windows runners where harden-runner itself is skipped.
#   - egress-policy must be block; audit is rejected on every runner.
#   - Self-hosted (including GHES) and non-Linux runners then get a notice
#     that hardening is not verified, and the agent check is skipped.
#   - GitHub-hosted Linux: the agent must be installed, agent.service active
#     and /home/agent/agent.status "Initialized" within 60 seconds. Runners
#     where the agent cannot run (container jobs, ubuntu-slim, an agent that
#     was never installed) fail, as do a private repository whose agent has
#     no subscription and silently downgrades to audit, and an agent.json
#     that is missing or whose egress_policy is not block.
#   - This is a startup snapshot: an agent that fails after Initialized is
#     not caught.
#
# Environment variables:
#   EGRESS_POLICY      - The egress-policy the step passed to harden-runner
#   RUNNER_ENVIRONMENT - github-hosted or self-hosted (set by the runner)
#   RUNNER_OS          - Linux, Windows or macOS (set by the runner)
#   USER               - Unset on ubuntu-slim, where harden-runner skips
#   HARDEN_RUNNER_ROOT - Test-only filesystem prefix; workflows never set it
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin verify-harden-runner-agent
# harden-runner exits 0 when its agent fails to start (#1203). Source:
# scripts/ci/bootstrap/verify-harden-runner-agent.sh
if [[ "${EGRESS_POLICY:-}" != block ]]; then
  printf '::error title=egress-policy rejected::egress-policy %q is not accepted. ' \
    "${EGRESS_POLICY:-}"
  echo "Set egress-policy: block with an allow-list (egress-preset/allowed-endpoints)"
  exit 1
fi
case "${RUNNER_ENVIRONMENT:-}/${RUNNER_OS:-}" in
  github-hosted/Linux) ;;
  self-hosted/?* | github-hosted/?*)
    echo "::notice title=hardening not verified::harden-runner is not verified on" \
      "this runner (${RUNNER_ENVIRONMENT} ${RUNNER_OS}); no egress enforcement claimed"
    exit 0
    ;;
  *)
    echo "::error title=unknown runner::RUNNER_ENVIRONMENT and RUNNER_OS are required"
    exit 1
    ;;
esac
root="${HARDEN_RUNNER_ROOT:-}"
failed="::error title=harden-runner agent failed::"
reason=""
if [[ -e "$root/.dockerenv" || -e "$root/run/.containerenv" ]]; then
  reason="container job"
elif [[ -z "${USER:-}" ]]; then
  reason="no USER, e.g. ubuntu-slim"
elif ! command -v systemctl > /dev/null; then
  reason="no systemd"
elif [[ ! -e "$root/etc/systemd/system/agent.service" ]]; then
  reason="agent not installed (API 409 unavailable, skip-harden-runner property,"
  reason+=" or install error)"
fi
if [[ -n "$reason" ]]; then
  echo "::error title=harden-runner unavailable::harden-runner agent unavailable" \
    "on this runner ($reason): use a supported GitHub-hosted Linux runner"
  exit 1
fi
status_file="$root/home/agent/agent.status"
deadline=$(($(date +%s) + 60))
while true; do
  if ! systemctl is-active --quiet agent.service; then
    echo "${failed}agent.service is not active; egress is not enforced"
    exit 1
  fi
  status=""
  if [[ -e "$status_file" ]] && ! status="$(< "$status_file")"; then
    echo "${failed}cannot read /home/agent/agent.status"
    exit 1
  fi
  case "$status" in
    Initialized) break ;;
    "") ;; # Not written yet: file creation can precede the status write.
    *)
      printf '%sunexpected agent status %q\n' "$failed" "$status"
      exit 1
      ;;
  esac
  if (($(date +%s) >= deadline)); then
    echo "${failed}agent.status is not Initialized after 60s"
    exit 1
  fi
  sleep 1
done
# Without a subscription the agent turns a private repository's block into
# audit, notes it in annotation.log and still reports Initialized.
annotations="$root/home/agent/annotation.log"
if [[ -e "$annotations" ]] && grep -q 'subscription is required' "$annotations"; then
  echo "::error title=StepSecurity subscription required::private repository" \
    "without a StepSecurity subscription: the agent downgraded block to audit." \
    "Resolve the repository's StepSecurity subscription or enrollment;" \
    "another runner will not help"
  exit 1
fi
agent_json="$root/home/agent/agent.json"
if [[ ! -e "$agent_json" ]]; then
  echo "${failed}/home/agent/agent.json is missing; egress-policy block is unproven"
  exit 1
fi
if ! grep -q '"egress_policy":"block"' "$agent_json"; then
  echo "${failed}the agent configuration does not carry egress_policy block"
  exit 1
fi
echo "harden-runner agent is active and initialized with egress-policy block"
# lgtm-ci-inline:end verify-harden-runner-agent
