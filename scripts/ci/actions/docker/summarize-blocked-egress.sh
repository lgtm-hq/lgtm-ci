#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Surface likely blocked egress after a failed Docker build
#          (build-docker STEP: summarize-blocked-egress)
#
# When harden-runner runs with egress-policy: block, disallowed traffic is
# silently dropped. Clients with long timeouts (e.g. bun install) hang until
# buildkit is killed with an illegible "runner received shutdown signal";
# clients with short timeouts (e.g. apk) fail fast with a bare I/O error.
# This step makes those failures legible: it scans the build log for
# blocked-egress signatures, emits ::error:: annotations naming the
# likely-blocked host, and writes a step-summary section.
#
# Intended to run in an `if: failure()` step after the build. Exits 0 in all
# cases (including no log / no matches) — it is diagnostic only and must not
# mask the original build failure.
#
# Optional environment variables:
#   BUILD_LOG - Build log to scan (default: $RUNNER_TEMP/docker-build.log).
#               When the file is missing or empty (e.g. the build ran via
#               docker/build-push-action, which does not write a log file),
#               the script falls back to `docker buildx history logs` to
#               recover the most recent build's output.

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"

: "${BUILD_LOG:=${RUNNER_TEMP:-/tmp}/docker-build.log}"

# Fallback: recover the latest build's log from buildx history (buildx >= 0.20)
if [[ ! -s "$BUILD_LOG" ]] && command -v docker >/dev/null 2>&1; then
	mkdir -p "$(dirname "$BUILD_LOG")"
	docker buildx history logs >"$BUILD_LOG" 2>/dev/null || true
fi

if [[ ! -s "$BUILD_LOG" ]]; then
	log_info "No build log found at $BUILD_LOG — skipping blocked-egress scan"
	exit 0
fi

# Blocked-egress signatures observed when harden-runner drops packets:
# DNS failures (curl/apk), fast I/O errors (apk APKINDEX), stalled TCP
# (bun/go), and buildkit dying mid-build after a long silent hang.
signature_regex='could not resolve host'
signature_regex+='|temporary error \(try again later\)'
signature_regex+='|temporary failure in name resolution'
signature_regex+='|i/o error'
signature_regex+='|io error'
signature_regex+='|network error \(check Internet connection'
signature_regex+='|connection timed out'
signature_regex+='|i/o timeout'
signature_regex+='|connection reset by peer'
signature_regex+='|connect: connection refused'
signature_regex+='|context canceled'
signature_regex+='|failed to receive status: rpc error'

matched_lines=$(grep -iE "$signature_regex" "$BUILD_LOG" || true)

if [[ -z "$matched_lines" ]]; then
	log_info "No blocked-egress signatures found in $BUILD_LOG"
	exit 0
fi

# Extract candidate hosts near the matches: URLs, resolver errors, and Go
# dial/lookup errors all name the endpoint the build was trying to reach.
hosts=$(
	{
		grep -oiE 'https?://[a-z0-9.-]+' <<<"$matched_lines" | sed -E 's#https?://##I'
		sed -nE 's/.*[Cc]ould not resolve host:? ([A-Za-z0-9.-]+).*/\1/p' <<<"$matched_lines"
		sed -nE 's/.*lookup ([A-Za-z0-9.-]+)( on [0-9.:]+)?:.*/\1/p' <<<"$matched_lines"
		sed -nE 's/.*dial tcp:? (lookup )?([A-Za-z0-9.-]+)(:[0-9]+)?:.*/\2/p' <<<"$matched_lines"
		sed -nE 's/.*[Ff]ailed to connect to ([A-Za-z0-9.-]+)( port [0-9]+)?.*/\1/p' <<<"$matched_lines"
	} | sed '/^$/d' | sort -u
)

if [[ -n "$hosts" ]]; then
	while IFS= read -r host; do
		echo "::error::Likely blocked egress: ${host} — if legitimate, add ${host}:443 to allowed-endpoints"
	done <<<"$hosts"
else
	echo "::error::Build log contains blocked-egress signatures but no host could be extracted — check the matched lines in the step summary and the harden-runner allowed-endpoints list"
fi

# Step summary section
add_github_summary "## 🚫 Possible blocked egress"
add_github_summary ""
add_github_summary "The failed build's log matches blocked-egress signatures. With harden-runner \`egress-policy: block\`, disallowed traffic is silently dropped: short-timeout clients (apk) fail fast with I/O errors, long-timeout clients (bun) hang until buildkit is killed."
add_github_summary ""
if [[ -n "$hosts" ]]; then
	add_github_summary "**Likely blocked host(s):**"
	add_github_summary ""
	while IFS= read -r host; do
		add_github_summary "- \`${host}\` — if legitimate, add \`${host}:443\` to \`allowed-endpoints\`"
	done <<<"$hosts"
	add_github_summary ""
fi
# shellcheck disable=SC2016 # literal markdown code-fence backticks, not expansion
add_github_summary_details "Matched log lines" "$(printf '```\n%s\n```' "$matched_lines")"

exit 0
