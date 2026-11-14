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
#   - Self-hosted runners (including GHES) then get a warning, also written
#     to the step summary, that egress enforcement is not verified; hosted
#     macOS and Windows get a notice. The agent check is skipped on both.
#   - A public repository on a self-hosted runner fails (#1552): it is never
#     intended and fork pull requests could run there. REPOSITORY_PRIVATE
#     comes from github.event.repository.private; only "false" is public, so
#     private and internal repositories (true) and an event without a
#     repository payload (empty) keep the warning.
#   - GitHub-hosted Linux: the agent must be installed, agent.service active
#     and /home/agent/agent.status "Initialized" within 60 seconds. Runners
#     where the agent cannot run (container jobs, ubuntu-slim, an agent that
#     was never installed) fail, as do a private repository whose agent has
#     no subscription and silently downgrades to audit, and an agent.json
#     that is missing or whose egress_policy is not block.
#   - The agent writes Initialized before it reads its setup error channel, so
#     a setup error can still revert it just after. After Initialized the
#     check waits a settle period, then requires agent.service active again
#     and no "Reverted changes" or "Error in Initialization" message of the
#     agent's own in agent.log (timestamp-anchored; logged process arguments
#     do not count). An agent.log or annotation.log that exists but cannot be
#     read fails.
#   - Reading agent.log is safe only here. The agent logs root-process
#     arguments unescaped (v0.18.0 eventhandler.go:119, %v), so an argument
#     with a newline can put a line identical to its own timestamped message
#     into the log. This step runs right after harden-runner and before any
#     job step, so no caller-controlled argument is in the log yet. The
#     end-of-job recheck runs after the job's steps and decides from systemd
#     state only.
#   - This is a startup snapshot. The generated "Recheck harden-runner agent"
#     step (recheck-harden-runner-agent.sh) takes a second one at job end.
#
# Environment variables:
#   EGRESS_POLICY      - The egress-policy the step passed to harden-runner
#   RUNNER_ENVIRONMENT - github-hosted or self-hosted (set by the runner)
#   RUNNER_OS          - Linux, Windows or macOS (set by the runner)
#   REPOSITORY_PRIVATE - github.event.repository.private: true, false or empty
#   USER               - Unset on ubuntu-slim, where harden-runner skips
#   GITHUB_STEP_SUMMARY - Step summary file; the self-hosted warning goes there
#   HARDEN_RUNNER_ROOT - Test-only filesystem prefix; workflows never set it
#   HARDEN_RUNNER_SETTLE_SECONDS - Test-only settle period (default 3)
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
  self-hosted/?*)
    # A public repository on a self-hosted runner is never intended (#1552):
    # fork pull requests could run there. Empty (no payload) is not public.
    # No exemption for GitHub Enterprise Server (owner decision): a public
    # repository there must be made internal or private to run.
    if [[ "${REPOSITORY_PRIVATE:-}" == false ]]; then
      echo "::error title=public repository on self-hosted runner::a public" \
        "repository must not run on a self-hosted runner (RUNNER_OS=${RUNNER_OS}):" \
        "fork pull requests could run code there. Use a GitHub-hosted runner" \
        "(check the runner variable or runner-image input), or make the" \
        "repository internal or private"
      exit 1
    fi
    line="harden-runner egress enforcement not verified; this job may run"
    line+=" without enforcement (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT},"
    line+=" RUNNER_OS=${RUNNER_OS})"
    echo "::warning title=hardening not verified::$line"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "$line" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
    ;;
  github-hosted/?*)
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
# The agent writes Initialized before it reads its setup error channel, so a
# setup error can revert it just after: settle, then look again.
sleep "${HARDEN_RUNNER_SETTLE_SECONDS:-3}"
if ! systemctl is-active --quiet agent.service; then
  echo "${failed}agent.service stopped just after Initialized; egress is not enforced"
  exit 1
fi
# Match only the agent's own messages: WriteLog prefixes each line with
# "Mon, 02 Jan 2006 15:04:05 GMT:", and root-process arguments it logs must
# not match. An argument with a newline could still forge a line, but no job
# step has run yet. grep exit 2 (unreadable log) fails closed.
agent_log="$root/home/agent/agent.log"
stamp='[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} '
stamp+='[0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]+:'
grep_status=1
if [[ -e "$agent_log" ]]; then
  grep_status=0
  grep -qE "^${stamp}(Reverted changes|Error in Initialization( .*)?)\$" \
    "$agent_log" || grep_status=$?
fi
case "$grep_status" in
  0)
    echo "${failed}agent.log reports a reverted initialization; egress is not enforced"
    exit 1
    ;;
  1) ;;
  *)
    echo "${failed}cannot read /home/agent/agent.log; egress enforcement is unproven"
    exit 1
    ;;
esac
# Without a subscription the agent turns a private repository's block into
# audit, notes it in annotation.log and still reports Initialized.
annotations="$root/home/agent/annotation.log"
grep_status=1
if [[ -e "$annotations" ]]; then
  grep_status=0
  grep -q 'subscription is required' "$annotations" || grep_status=$?
fi
case "$grep_status" in
  0)
    echo "::error title=StepSecurity subscription required::private repository" \
      "without a StepSecurity subscription: the agent downgraded block to audit." \
      "Resolve the repository's StepSecurity subscription or enrollment;" \
      "another runner will not help"
    exit 1
    ;;
  1) ;;
  *)
    echo "${failed}cannot read /home/agent/annotation.log; egress-policy is unproven"
    exit 1
    ;;
esac
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
