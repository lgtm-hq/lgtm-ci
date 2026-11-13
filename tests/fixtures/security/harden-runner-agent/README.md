# harden-runner agent.log fixtures

`healthy-agent.log` follows the line format of step-security/agent v0.18.0:
`WriteLog` in `log.go` writes `Mon, 02 Jan 2006 15:04:05 GMT:<message>`. The
file holds non-fatal errors and root-process argument lines (from
`eventhandler.go`) that contain "Reverted changes" and "Error in
Initialization" as arguments, some split across lines by embedded newlines.
The verify and recheck scripts must pass on it. The bats tests append the
agent's real fatal lines to make it fail.
