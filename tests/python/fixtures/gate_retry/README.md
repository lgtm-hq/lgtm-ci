# Captured CodeQL retry evidence

Captured on 2026-10-28 from `lgtm-hq/spotify-curator`, run `39800719692`,
the incident in lgtm-ci issue #1197:

| Job ID | Attempt | Job | Conclusion |
| --- | --- | --- | --- |
| 119900303171 | 1 | codeql / Setup CodeQL matrix | cancelled |
| 119914396811 | 2 | codeql / Setup CodeQL matrix | success |
| 119914588071 | 2 | codeql / 🔬 CodeQL Analysis | success |

The cancelled setup ID was obtained from
`gh api repos/lgtm-hq/spotify-curator/actions/runs/39800719692/attempts/1/jobs`.
Each header was fetched with
`gh api --allow-escape-sequences repos/lgtm-hq/spotify-curator/actions/jobs/<id>/logs`.
The runnerless attempt-1 placeholder `119914161024` (`codeql / inputs.job-name`)
returns HTTP 404 for its logs. No substitute run was needed.

The header files retain the original bytes from the start of each log through
the first `##[group]Run` line (with a following space), inclusive. Everything
after that boundary is omitted to exclude step output and credentials. The
retained headers contain no tokens or secret-bearing URLs, so no redaction was
necessary. Timestamps, the
UTF-8 BOM, trailing spaces, empty input values, and the blank allowed-endpoints
continuation line are preserved. Do not format these captured text files.

The two source `.txt` files are the unmodified, base64-decoded GitHub contents
API responses for `.github/workflows/reusable-codeql.yml` and
`scripts/ci/actions/generate-codeql-matrix.sh` at commit
`9ea778eb4e6b876d60b7b3d7d0d0aee5182717bb`. The mock serves these historical
bytes for that immutable ref, rather than the current checkout: subsequent
workflow changes must not rewrite evidence for the audited incident contract.
