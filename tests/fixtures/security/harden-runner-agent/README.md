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
  negative tests use it: this mid-job shape is never re-run (a real failure
  until #1668).
