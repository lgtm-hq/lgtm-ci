#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Committed-digest verification for supplier tool installers (#1096).
#
# Every installer under scripts/ci verifies the bytes it is about to run
# against a value committed in scripts/ci/versions.env, never against a
# checksum fetched from the same release at install time. The helpers here
# are the only place that policy is implemented, so every installer fails the
# same way for the same reasons.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/supply_chain.sh"
#   supply_chain_verify_sha256 "$file" OSV_SCANNER_SHA256_LINUX_AMD64 \
#       "$resolved_version" "$DEFAULT_OSV_SCANNER_VERSION"
#   supply_chain_verify_commit "$clone_dir" BATS_CORE_COMMIT \
#       "$resolved_version" "$DEFAULT_BATS_CORE_VERSION"
#
# Escape hatch:
#   LGTM_CI_ALLOW_UNVERIFIED=1  Set by the CALLER (never by lgtm-ci's own
#       workflows) to turn a missing digest, a missing verification tool, or a
#       version override without a matching digest into a ::warning and
#       continue. A digest or commit MISMATCH is never downgraded: wrong bytes
#       fail regardless. Documented in docs/workflow-contract.md.
#
# Variable resolution:
#   The digest for variable NAME is "${NAME:-${DEFAULT_NAME:-}}": a caller may
#   export NAME to override the committed default (the same pattern the
#   cursor-agent pins have used since #889). When the caller also overrode the
#   tool VERSION but left the digest at its committed default, the default
#   cannot describe the overridden bytes, so that combination is an error
#   rather than a guaranteed mismatch later.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SUPPLY_CHAIN_LOADED:-}" ]] && return 0
readonly _LGTM_CI_SUPPLY_CHAIN_LOADED=1

_LGTM_CI_SUPPLY_CHAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

# shellcheck source=log.sh
source "$_LGTM_CI_SUPPLY_CHAIN_LIB_DIR/log.sh"
# shellcheck source=network/checksum.sh
source "$_LGTM_CI_SUPPLY_CHAIN_LIB_DIR/network/checksum.sh"

# =============================================================================
# Policy
# =============================================================================

# True when the caller opted into unverified installs.
supply_chain_unverified_allowed() {
	[[ "${LGTM_CI_ALLOW_UNVERIFIED:-}" == "1" ]]
}

# Report a verification gap. Hard error unless LGTM_CI_ALLOW_UNVERIFIED=1, in
# which case the gap is a workflow warning and the caller continues.
# Usage: _supply_chain_gap "message"
# Returns 0 when the caller may continue unverified, exits 1 otherwise.
_supply_chain_gap() {
	local message="$1"
	if supply_chain_unverified_allowed; then
		echo "::warning title=unverified install::${message} (LGTM_CI_ALLOW_UNVERIFIED=1 set by caller)" >&2
		return 0
	fi
	echo "::error title=unverified install::${message}. Set LGTM_CI_ALLOW_UNVERIFIED=1 to continue unverified." >&2
	exit 1
}

# Require a verification tool on PATH.
# Usage: supply_chain_require_tool "cosign" "SHA256SUMS signature check"
# Returns 0 when present; with the escape hatch set returns 1 so the caller
# skips the step; otherwise exits 1.
supply_chain_require_tool() {
	local tool="$1" purpose="${2:-verification}"
	if command -v "$tool" >/dev/null 2>&1; then
		return 0
	fi
	_supply_chain_gap "${tool} is required for ${purpose} and is not installed" || return 1
	return 1
}

# Resolve the effective digest for NAME: env override, then committed default.
# Usage: supply_chain_resolve_digest NAME
# Prints the value (possibly empty).
supply_chain_resolve_digest() {
	local name="$1" default_name="DEFAULT_$1"
	printf '%s' "${!name:-${!default_name:-}}"
}

# Exit status _supply_chain_prepare uses for "skip verification" (escape
# hatch). Any other non-zero status from it is fatal to the caller, so a
# missing helper in a child shell (127) can never read as "skip".
readonly _SUPPLY_CHAIN_SKIP=3

# Shared pre-checks for sha256 and commit pins.
# Usage: _supply_chain_prepare NAME expected_pattern version default_version
# Sets _SUPPLY_CHAIN_EXPECTED. Returns _SUPPLY_CHAIN_SKIP when verification
# must be skipped (escape hatch), exits on a hard error.
_supply_chain_prepare() {
	local name="$1" pattern="$2" version="${3:-}" default_version="${4:-}"
	local default_name="DEFAULT_${name}"
	local expected override
	override="${!name:-}"
	expected="${override:-${!default_name:-}}"
	# Hex digests compare case-insensitively; the cursor-agent contract
	# accepted upper-case overrides and still does.
	expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"

	if [[ -z "$expected" ]]; then
		_supply_chain_gap "no committed digest for ${name} in scripts/ci/versions.env" || return 1
		return "$_SUPPLY_CHAIN_SKIP"
	fi
	if [[ ! "$expected" =~ $pattern ]]; then
		echo "::error title=unverified install::${name} is not a valid digest: '${expected}'" >&2
		exit 1
	fi
	if [[ -n "$version" && -n "$default_version" && "$version" != "$default_version" && -z "$override" ]]; then
		_supply_chain_gap "version overridden to ${version} (pinned ${default_version}) without a matching ${name}" || return 1
		return "$_SUPPLY_CHAIN_SKIP"
	fi
	_SUPPLY_CHAIN_EXPECTED="$expected"
	return 0
}

# Run _supply_chain_prepare and translate its status: 0 = verify, 1 = skip,
# anything else (including 127 when the helper is missing) = fatal.
# Usage: _supply_chain_gate NAME pattern version default_version
_supply_chain_gate() {
	local rc=0
	_supply_chain_prepare "$@" || rc=$?
	case "$rc" in
	0) return 0 ;;
	"$_SUPPLY_CHAIN_SKIP") return 1 ;;
	*)
		echo "::error title=unverified install::digest pre-check for ${1} failed (status ${rc}); refusing to install" >&2
		exit 1
		;;
	esac
}

# =============================================================================
# Verification
# =============================================================================

# Verify a downloaded file against a committed sha256.
# Usage: supply_chain_verify_sha256 FILE NAME [version] [default_version]
#   FILE            path to the downloaded artifact
#   NAME            digest variable name without the DEFAULT_ prefix, e.g.
#                   OSV_SCANNER_SHA256_LINUX_AMD64
#   version         resolved tool version (for the override check)
#   default_version committed DEFAULT_<TOOL>_VERSION
# A mismatch always exits 1. Returns 0 on match or on an allowed skip.
supply_chain_verify_sha256() {
	local file="$1" name="$2" version="${3:-}" default_version="${4:-}"
	local expected

	if ! _supply_chain_gate "$name" '^[a-f0-9]{64}$' "$version" "$default_version"; then
		return 0
	fi
	expected="$_SUPPLY_CHAIN_EXPECTED"

	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
		supply_chain_require_tool sha256sum "sha256 verification of $(basename "$file")" || return 0
	fi

	# Deliberately never retried: wrong bytes are a tamper signal, not a flake.
	if ! verify_checksum "$file" "$expected" sha256; then
		echo "::error title=digest mismatch::$(basename "$file") does not match committed ${name}; refusing to install" >&2
		exit 1
	fi
	log_success "sha256 verified against committed ${name}"
	return 0
}

# Verify a git clone sits at the committed commit for its tag.
# Usage: supply_chain_verify_commit DIR NAME [version] [default_version]
supply_chain_verify_commit() {
	local dir="$1" name="$2" version="${3:-}" default_version="${4:-}"
	local expected actual

	if ! _supply_chain_gate "$name" '^[a-f0-9]{40}$' "$version" "$default_version"; then
		return 0
	fi
	expected="$_SUPPLY_CHAIN_EXPECTED"

	if ! actual="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"; then
		echo "::error title=unverified install::cannot resolve HEAD in ${dir} for ${name}" >&2
		exit 1
	fi
	if [[ "$actual" != "$expected" ]]; then
		echo "::error title=commit mismatch::${dir} is at ${actual}, committed ${name} is ${expected}; refusing to install" >&2
		exit 1
	fi
	log_success "commit verified against committed ${name}"
	return 0
}

# Upper-case a target triple or platform id for use in a digest variable name.
# Usage: supply_chain_var_suffix "x86_64-unknown-linux-gnu" -> X86_64_UNKNOWN_LINUX_GNU
supply_chain_var_suffix() {
	printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# =============================================================================
# Export functions
# =============================================================================
# The private helpers are exported too: an exported verify function that
# cannot find them in a child shell would fail open.
export -f supply_chain_unverified_allowed supply_chain_require_tool \
	supply_chain_resolve_digest supply_chain_verify_sha256 \
	supply_chain_verify_commit supply_chain_var_suffix \
	_supply_chain_gap _supply_chain_prepare _supply_chain_gate
