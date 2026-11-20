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
#   - Only the standard agent is trusted (#1668, owner decision). When its
#     TLS-status call fails, harden-runner v2.22.3 prints "[!] Unable to check
#     TLS_STATUS. Defaulting to TLS enabled." (src/tls-inspect.ts) and
#     installs the eBPF agent (step-security/agent-ebpf v1.9.5) in place of
#     step-security/agent v0.18.0, at the same path, with the same agent.json
#     and the same agent.service unit (src/install-agent.ts). The two differ
#     in the first line each writes to agent.log, its build info: v0.18.0
#     logs "[buildInfo] tag=<tag> commit=<sha> branch=<branch>"
#     (buildinfo.go), the eBPF agent "[buildInfo] name=AgentAlpha
#     branch=<branch> tag=<tag> commit=<sha>" (fixture run 44565576621). The
#     eBPF agent fails with its own message, and any agent whose build info
#     is not the standard agent's fails too. The standard agent points
#     /etc/systemd/resolved.conf at its DNS proxy (DNS=127.0.0.1) before it
#     writes Initialized, the eBPF agent never does, so that is required too.
#   - Opt-in (#1668, owner decision): with
#     LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT exactly "true" (the caller's
#     repository or organization variable of that name, passed through the
#     step's env:), the eBPF agent is accepted, never blind: its build line
#     must be the only build line, every NetMode it logs must be ebpf, its
#     tracer must log "block-policy applied" (waited for up to 30s) and no
#     other policy, and agent.service must still be active after that. These
#     replace the resolved.conf check for that agent only; the revert,
#     subscription and agent.json checks still apply. The step then writes a
#     warning saying the switch accepted it. Any other value is off.
#   - The step writes agent=standard or agent=ebpf to its output; the recheck
#     steps read it as steps.verify-harden-runner.outputs.agent, which no
#     later step can change.
#   - An inactive agent's own start-up errors (timestamped "Error ..." and
#     "Reverted changes" lines of agent.log) are printed before the step
#     fails (#1669), each prefixed with "verify-harden-runner-agent:
#     agent.log: ". harden-runner waits only 9 seconds for the agent, so an
#     agent that fails later is otherwise reported only in its post step,
#     after job steps ran. Printing is diagnostic only: at most the first
#     1 MiB of the log, 20 lines of at most 512 bytes, every byte outside a
#     small safe set (no "#", "[", "]" or control character) replaced by "?",
#     so a printed line cannot be a workflow command.
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
#   GITHUB_OUTPUT      - Step output file; gets agent=standard or agent=ebpf
#   LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT - vars.<same name>: exactly "true"
#                        accepts the eBPF fallback agent with proof (#1668)
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
# Match only the agent's own messages: WriteLog prefixes each line with
# "Mon, 02 Jan 2006 15:04:05 GMT:", and root-process arguments it logs must
# not match. An argument with a newline could still forge a line, but no job
# step has run yet.
agent_log="$root/home/agent/agent.log"
stamp='[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} '
stamp+='[0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]+:'
# Print the agent's own start-up errors (#1669); never changes the verdict.
agent_errors() (
  export LC_ALL=C
  set +e +o pipefail
  if [[ ! -e "$agent_log" ]]; then
    echo "agent.log is missing; no agent start-up error to show"
    exit 0
  fi
  if [[ ! -f "$agent_log" || ! -r "$agent_log" ]]; then
    echo "agent.log is not a readable file; no agent start-up error to show"
    exit 0
  fi
  unsafe='[^[:alnum:] .,:;_=/@()+-]'
  shown=0
  while IFS= read -r line; do
    line="${line:0:512}"
    printf 'verify-harden-runner-agent: agent.log: %s\n' "${line//$unsafe/?}"
    shown=$((shown + 1))
  done < <(head -c 1048576 -- "$agent_log" 2> /dev/null |
    grep -aE -m 20 "^${stamp}(Error .*|Reverted changes)\$") 2> /dev/null
  if ((shown == 0)); then
    echo "agent.log has no agent start-up error line"
  fi
)
deadline=$(($(date +%s) + 60))
while true; do
  if ! systemctl is-active --quiet agent.service; then
    agent_errors
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
  agent_errors
  echo "${failed}agent.service stopped just after Initialized; egress is not enforced"
  exit 1
fi
# Only the standard agent is trusted (#1668): refuse harden-runner's eBPF
# fallback agent, then require the standard agent's build info. grep exit 2
# (unreadable log) fails closed here and below.
if [[ ! -e "$agent_log" ]]; then
  echo "${failed}/home/agent/agent.log is missing; the agent build is unproven"
  exit 1
fi
agent=standard
grep_status=0
grep -qE "^${stamp}\[buildInfo\] name=AgentAlpha( |\$)" "$agent_log" ||
  grep_status=$?
case "$grep_status" in
  0)
    # Opt-in (#1668): only the exact value true accepts the eBPF agent, and
    # only with its own evidence of block mode below.
    if [[ "${LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT:-}" != true ]]; then
      echo "::error title=harden-runner agent refused::harden-runner installed its" \
        "eBPF fallback agent; only the standard agent is trusted"
      exit 1
    fi
    agent=ebpf
    ;;
  1) ;;
  *)
    echo "${failed}cannot read /home/agent/agent.log; egress enforcement is unproven"
    exit 1
    ;;
esac
standard="^${stamp}\[buildInfo\] tag=v[0-9][^ ]* commit=[0-9a-f]{40} branch=[^ ]+ ?\$"
ebpf="^${stamp}\[buildInfo\] name=AgentAlpha branch=[^ ]+ tag=v[0-9][^ ]*"
ebpf+=" commit=[0-9a-f]{40}\$"
build="$standard"
[[ "$agent" == standard ]] || build="$ebpf"
grep_status=0
builds="$(grep -E "^${stamp}\[buildInfo\]" "$agent_log")" || grep_status=$?
if ((grep_status > 1)); then
  echo "${failed}cannot read /home/agent/agent.log; egress enforcement is unproven"
  exit 1
fi
if [[ -z "$builds" ]] || grep -qvE "$build" <<< "$builds"; then
  echo "${failed}agent.log does not identify the ${agent} agent; egress" \
    "enforcement is unproven"
  exit 1
fi
if [[ "$agent" == ebpf ]]; then
  # The eBPF agent's own evidence of block mode replaces resolved.conf, which
  # it never changes: every feature-flag line it logs has NetMode:ebpf, and
  # its tracer logs "block-policy applied", which can follow Initialized by
  # a second (fixture run 44396392356), so wait for it within 30s. Any other
  # "<x>-policy applied" line, a missing piece or an unreadable log fails.
  modes="$(grep -E "^${stamp}.*NetMode:" "$agent_log")" || modes=""
  if [[ -z "$modes" ]] || grep -qvE 'NetMode:ebpf[ }]' <<< "$modes"; then
    echo "${failed}the eBPF agent does not report NetMode:ebpf; egress" \
      "enforcement is unproven"
    exit 1
  fi
  deadline=$(($(date +%s) + 30))
  while true; do
    grep_status=0
    policies="$(grep -E "^${stamp}\[tracerManager\] [a-z-]+-policy applied\$" \
      "$agent_log")" || grep_status=$?
    if ((grep_status > 1)); then
      echo "${failed}cannot read /home/agent/agent.log; egress enforcement is unproven"
      exit 1
    fi
    if [[ -n "$policies" ]]; then
      if grep -qvE "^${stamp}\[tracerManager\] block-policy applied\$" <<< "$policies"; then
        echo "${failed}the eBPF agent applied a policy other than block; egress" \
          "is not enforced"
        exit 1
      fi
      break
    fi
    if (($(date +%s) >= deadline)); then
      echo "${failed}the eBPF agent did not log block-policy applied within 30s;" \
        "egress enforcement is unproven"
      exit 1
    fi
    sleep 1
  done
  if ! systemctl is-active --quiet agent.service; then
    agent_errors
    echo "${failed}agent.service stopped while the eBPF agent was checked;" \
      "egress is not enforced"
    exit 1
  fi
fi
grep_status=1
if [[ -e "$agent_log" ]]; then
  grep_status=0
  grep -qE "^${stamp}(Reverted changes|Error in Initialization( .*)?)\$" \
    "$agent_log" || grep_status=$?
fi
case "$grep_status" in
  0)
    agent_errors
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
if [[ "$agent" == standard ]] &&
  ! grep -qxF 'DNS=127.0.0.1' "$root/etc/systemd/resolved.conf" 2> /dev/null; then
  echo "${failed}resolved.conf does not use the agent's DNS proxy; egress is not enforced"
  exit 1
fi
# The recheck steps read which agent was verified from this step's output,
# which no later step can change.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'agent=%s\n' "$agent" >> "$GITHUB_OUTPUT"
fi
if [[ "$agent" == ebpf ]]; then
  echo "::warning title=harden-runner eBPF agent accepted::harden-runner's eBPF" \
    "fallback agent was accepted because LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT" \
    "is true; it logged NetMode:ebpf and block-policy applied"
fi
echo "harden-runner agent is active and initialized with egress-policy block"
# lgtm-ci-inline:end verify-harden-runner-agent
