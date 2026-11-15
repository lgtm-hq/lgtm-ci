#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail a job whose harden-runner agent stopped enforcing mid-job
#
# Source of truth for the inline "Recheck harden-runner agent" step, the last
# step of every job that runs the "Verify harden-runner agent" step (#1203),
# and of the "Recheck harden-runner agent before <step>" step right before
# each irreversible publish, push, release or attestation step (#1551).
# scripts/ci/bootstrap/sync_inline_blocks.py copies the lines between the
# markers below into each workflow and fails CI on drift. Keep the body
# self-contained: no sourcing, no checkout, no network.
#
# The pinned agent (v0.18.0) runs as a Type=simple unit with no Restart=, so
# an agent that reverts its changes exits and leaves agent.service inactive or
# failed. agent.status and agent.json do not change on a revert. The step:
#   - runs only when the startup verify step succeeded
#     (if: !cancelled() && steps.verify-harden-runner.outcome == 'success');
#   - exits 0 silently on self-hosted and non-Linux runners, where the
#     startup step already reported that hardening is not verified;
#   - on GitHub-hosted Linux fails if agent.service is not active, and names
#     the unit's ActiveState, SubState, Result and ExecMainStatus in the error;
#   - also fails if /etc/systemd/resolved.conf no longer points at the agent's
#     DNS proxy (DNS=127.0.0.1). A revert clears the firewall, restores this
#     file, then restarts Docker (slow) before the process exits, so an agent
#     still "active" mid-revert is caught here. The agent writes the file
#     (0644, "[Resolve] DNS=127.0.0.1 Domains=~.") before Initialized.
#
# The verdict never reads agent.log. The
# agent logs root-process arguments unescaped (v0.18.0 eventhandler.go:119,
# %v), so by job end any step can write a line into agent.log that looks
# exactly like the agent's own timestamped "Reverted changes" message (a
# newline inside an argument), and a log check would fail a healthy job. By
# job end a revert has long finished and the process has exited, so systemd
# state is enough. The startup step still reads agent.log: it runs before any
# job step, when no caller-controlled argument can be in the log.
#
# Limits: this is a second snapshot, not continuous monitoring. It fails the
# job (and so blocks needs: dependents) after an accidental agent failure, but
# it cannot undo what steps already did unhardened, and a malicious step with
# root or sudo can stop the agent and forge every file this step reads.
#
# Environment variables:
#   RUNNER_ENVIRONMENT - github-hosted or self-hosted (set by the runner)
#   RUNNER_OS          - Linux, Windows or macOS (set by the runner)
#   HARDEN_RUNNER_ROOT - Test-only filesystem prefix; workflows never set it
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin recheck-harden-runner-agent
# Recheck of the harden-runner agent, before each irreversible publish
# step (#1551) and at job end (#1203). Source:
# scripts/ci/bootstrap/recheck-harden-runner-agent.sh
case "${RUNNER_ENVIRONMENT:-}/${RUNNER_OS:-}" in
  github-hosted/Linux) ;;
  self-hosted/?* | github-hosted/?*) exit 0 ;; # Reported by the startup step.
  *)
    echo "::error title=unknown runner::RUNNER_ENVIRONMENT and RUNNER_OS are required"
    exit 1
    ;;
esac
stopped="::error title=harden-runner agent stopped::harden-runner agent stopped"
stopped+=" enforcing mid-job; steps after it ran unhardened"
if ! systemctl is-active --quiet agent.service; then
  # Detail only: the verdict above is is-active. systemctl show failing
  # leaves the detail empty.
  unit="$(systemctl show agent.service \
    -p ActiveState,SubState,Result,ExecMainStatus 2> /dev/null)" || unit=""
  unit="${unit//$'\n'/ }"
  echo "$stopped (agent.service is not active${unit:+: $unit})"
  exit 1
fi
# A revert in progress leaves the unit active but has already restored DNS.
resolved="${HARDEN_RUNNER_ROOT:-}/etc/systemd/resolved.conf"
if ! grep -qxF 'DNS=127.0.0.1' "$resolved" 2> /dev/null; then
  echo "$stopped (resolved.conf no longer uses the agent's DNS proxy: revert" \
    "in progress or DNS changed by a step)"
  exit 1
fi
echo "harden-runner agent is still active and enforcing DNS"
# lgtm-ci-inline:end recheck-harden-runner-agent
