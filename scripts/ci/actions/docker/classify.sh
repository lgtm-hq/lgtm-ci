#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Classify platforms and determine build strategy (build-docker STEP: classify)
#
# Required environment variables:
#   PLATFORMS  - Comma-separated list of target platforms
#   PUSH       - Whether images will be pushed ("true"/"false")
#
# Optional environment variables:
#   VALIDATE_ON_PR    - Enable split builds without push for PR validation
#   RUNNER_MAP        - JSON object mapping platform → runner label (default: "{}")
#                       Platforms not in the map default to ubuntu-24.04 with QEMU.
#                       Example: {"linux/arm64":"ubuntu-24.04-arm"}
#   SMOKE_TEST        - Smoke-test shorthand command (validated only; not used here).
#   SMOKE_TEST_SCRIPT - Smoke-test script path (validated only; not used here).
#                       SMOKE_TEST and SMOKE_TEST_SCRIPT are mutually exclusive.
#   HEALTH_CHECK_CMD  - Optional detached-container health check command.
#   HEALTH_CHECK_PORT - Optional container port to expose and wait for.
#   HEALTH_CHECK_TIMEOUT - Optional wait timeout (default: 30s).
#
# Outputs:
#   use-split - "true" when split per-platform build should be used
#   matrix    - JSON array of {platform, runner, slug, qemu} entries

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"
# shellcheck source=health-lib.sh
source "$SCRIPT_DIR/health-lib.sh"

: "${PLATFORMS:?PLATFORMS is required}"
: "${PUSH:?PUSH is required}"
: "${VALIDATE_ON_PR:=false}"
: "${RUNNER_MAP:={}}"
: "${SMOKE_TEST:=}"
: "${SMOKE_TEST_SCRIPT:=}"
: "${HEALTH_CHECK_CMD:=}"
: "${HEALTH_CHECK_PORT:=}"
: "${HEALTH_CHECK_TIMEOUT:=30s}"

# Mutex: smoke-test and smoke-test-script cannot both be set
if [[ -n "$SMOKE_TEST" && -n "$SMOKE_TEST_SCRIPT" ]]; then
	die "smoke-test and smoke-test-script are mutually exclusive (set at most one)"
fi

if [[ -n "$HEALTH_CHECK_PORT" && (
	! "$HEALTH_CHECK_PORT" =~ ^[0-9]+$ ||
	"$HEALTH_CHECK_PORT" -eq 0 ||
	"$HEALTH_CHECK_PORT" -gt 65535) ]] \
	; then
	die "health-check-port must be a positive integer (1-65535): ${HEALTH_CHECK_PORT}"
fi
if [[ -n "$HEALTH_CHECK_CMD" ]]; then
	if [[ -z "$HEALTH_CHECK_PORT" ]]; then
		die "health-check-port is required when health-check-cmd is set (command runs on the runner against 127.0.0.1:PORT)"
	fi
	parse_duration_seconds "$HEALTH_CHECK_TIMEOUT" >/dev/null
fi

# Validate RUNNER_MAP is parseable JSON
if ! echo "$RUNNER_MAP" | jq empty 2>/dev/null; then
	die "RUNNER_MAP is not valid JSON: ${RUNNER_MAP}"
fi

# Parse comma-separated platforms into array, trimming whitespace
platforms=()
while IFS= read -r p; do
	p=$(echo "$p" | xargs)
	[[ -n "$p" ]] && platforms+=("$p")
done < <(echo "$PLATFORMS" | tr ',' '\n')

# Deduplicate platform entries (preserve order, drop repeats)
declare -A _seen_platforms=()
deduped_platforms=()
for p in "${platforms[@]}"; do
	if [[ -z "${_seen_platforms[$p]+x}" ]]; then
		_seen_platforms[$p]=1
		deduped_platforms+=("$p")
	fi
done
platforms=("${deduped_platforms[@]}")
unset _seen_platforms deduped_platforms

# Fail fast on empty/whitespace-only PLATFORMS input
if [[ "${#platforms[@]}" -eq 0 ]]; then
	die "PLATFORMS is empty or contains only whitespace"
fi

# push=false and validate-on-pr=false → use the QEMU build job
if [[ "$PUSH" != "true" && "$VALIDATE_ON_PR" != "true" ]]; then
	set_github_output "use-split" "false"
	set_github_output "matrix" "[]"
	log_info "Split disabled: push=${PUSH}, validate-on-pr=${VALIDATE_ON_PR}"
	exit 0
fi

# Single platform: use split only if a native runner is mapped for it
if [[ "${#platforms[@]}" -lt 2 ]]; then
	_single="${platforms[0]}"
	_mapped=$(echo "$RUNNER_MAP" | jq -r --arg p "$_single" '.[$p] // empty')
	if [[ -z "$_mapped" ]]; then
		set_github_output "use-split" "false"
		set_github_output "matrix" "[]"
		log_info "Split disabled: single platform '${_single}' has no runner mapping"
		exit 0
	fi
	log_info "Split enabled: single platform '${_single}' mapped to runner '${_mapped}'"
	unset _single _mapped
fi

# Build matrix JSON array
matrix_json="[]"
for platform in "${platforms[@]}"; do
	# Resolve runner from map; default to ubuntu-24.04
	runner=$(echo "$RUNNER_MAP" | jq -r --arg p "$platform" '.[$p] // "ubuntu-24.04"')

	# Generate slug: replace all / with - (e.g. linux/arm/v7 → linux-arm-v7)
	slug=$(echo "$platform" | tr '/' '-')

	# Determine runner architecture from label
	runner_arch="amd64"
	if [[ "$runner" == *"-arm"* ]]; then
		runner_arch="arm64"
	fi

	# Extract platform architecture (second path component, strip variant)
	platform_arch="${platform#*/}"       # linux/arm/v7 → arm/v7
	platform_arch="${platform_arch%%/*}" # arm/v7 → arm

	# QEMU not needed when runner and platform architectures match
	qemu=true
	if [[ "$runner_arch" == "amd64" && "$platform_arch" == "amd64" ]]; then
		qemu=false
	elif [[ "$runner_arch" == "arm64" && "$platform_arch" == "arm64" ]]; then
		qemu=false
	fi

	# Build JSON entry and append to matrix array
	entry=$(jq -n \
		--arg platform "$platform" \
		--arg runner "$runner" \
		--arg slug "$slug" \
		--argjson qemu "$qemu" \
		'{platform: $platform, runner: $runner, slug: $slug, qemu: $qemu}')
	matrix_json=$(echo "$matrix_json" | jq --argjson e "$entry" '. + [$e]')
done

set_github_output "use-split" "true"
set_github_output "matrix" "$(echo "$matrix_json" | jq -c .)"
log_info "Split enabled: ${#platforms[@]} platform(s)"
for platform in "${platforms[@]}"; do
	log_info "  ${platform}"
done
