# harden-runner agent.log fixtures

`healthy-agent.log` follows the line format of step-security/agent v0.18.0:
`WriteLog` in `log.go` writes `Mon, 02 Jan 2006 15:04:05 GMT:<message>`. The
file holds non-fatal errors and root-process argument lines (from
`eventhandler.go`) that contain "Reverted changes" and "Error in
Initialization" as arguments, some split across lines by embedded newlines.
The verify and recheck scripts must pass on it. The bats tests append the
agent's real fatal lines to make it fail.

The two `job-*.log` files are trimmed raw job logs (`GET
/repos/{owner}/{repo}/actions/jobs/{job_id}/logs`) of real fixture runs, with
the repository name removed, for the #1616 rule in
`scripts/ci/lib/infra-signatures.sh`:

- `job-startup-dns.log`: run 44549619441, job 135649511127. The v0.18.0 agent
  exited on a DNS SERVFAIL (`status 2`) while resolving its allowed hosts;
  harden-runner printed the agent log in its own pre-step output, before the
  verify step failed with `agent.service is not active; egress is not
  enforced`. The provenance tests inject forged lines into a copy of it.
- `job-recheck-tls-fallback.log`: run 44565576621, job 135707070821.
  harden-runner could not reach the TLS-status endpoint, installed the eBPF
  agent (v1.9.5), and the end-of-job recheck failed on resolved.conf. Only
  negative tests use it: this mid-job shape is never re-run (since #1668 the
  verify step refuses that agent at job start).

`healthy-agent.log` opens with the build line v0.18.0 writes first
(`[buildInfo] tag=v0.18.0 commit=<sha> branch=HEAD` and a trailing space, `buildinfo.go`), which
the verify step requires since #1668.

For #1668 and #1669:

- `ebpf-agent.log`: the first `agent.log` lines of the eBPF fallback agent
  v1.9.5 ("AgentAlpha"), as harden-runner's post step printed them in fixture
  run 44565576621 (job 135707070821). The verify step refuses this agent.
- `late-failure-agent.log`: a trimmed `agent.log` of fixture run
  43858549864 (job 133283077774). The agent failed on a DNS SERVFAIL 11
  seconds into the verify step's polling, after harden-runner had stopped
  waiting; the verify step prints its `Error ...` and `Reverted changes`
  lines.
- `job-verify-late-dns.log`: the trimmed raw job log of that job. The two
  `verify-harden-runner-agent: agent.log:` lines in the verify step's output
  are not in the real log: they are what the #1669 verify step prints, copied
  from the agent's own lines that harden-runner's post step printed (same
  timestamps). Everything else is the real log.
- `job-verify-ebpf.log`: the real harden-runner pre-step of fixture run
  44565576621, with the TLS-status fallback line, followed by the verify
  step's #1668 refusal in place of the end-of-job recheck failure that run
  had. The second harden-runner group carries its `with:` line, which
  `job-recheck-tls-fallback.log` trims.
