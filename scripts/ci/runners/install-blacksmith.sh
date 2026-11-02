#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install the committed Blacksmith CLI pin for Linux x64 only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"
# shellcheck source=../lib/network/download.sh
source "$SCRIPT_DIR/../lib/network/download.sh"
# shellcheck source=../lib/network/checksum.sh
source "$SCRIPT_DIR/../lib/network/checksum.sh"
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || {
	echo 'Blacksmith governor requires Linux x64' >&2
	exit 1
}
: "${RUNNER_TEMP:?RUNNER_TEMP required}"
: "${GITHUB_PATH:?GITHUB_PATH required}"
install_scratch="$(mktemp -d "${TMPDIR:-/tmp}/blacksmith.XXXXXXXX")"
trap 'rm -rf "$install_scratch"' EXIT
_lgtm_ci_build_curl_args 120
curl "${_LGTM_CI_CURL_ARGS[@]}" \
	"https://clireleases.blacksmith.sh/cli/v${DEFAULT_BLACKSMITH_VERSION}/linux/amd64/blacksmith" \
	-o "$install_scratch/blacksmith"
# Deliberately no unverified-install escape hatch for the governor.
verify_checksum "$install_scratch/blacksmith" "$DEFAULT_BLACKSMITH_SHA256_LINUX_AMD64"
mkdir -p "$RUNNER_TEMP/runner-governor-bin"
install -m 0755 "$install_scratch/blacksmith" "$RUNNER_TEMP/runner-governor-bin/blacksmith"
printf '%s\n' "$RUNNER_TEMP/runner-governor-bin" >>"$GITHUB_PATH"
