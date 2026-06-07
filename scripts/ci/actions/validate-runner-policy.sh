#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate runner security policy tier before harden-runner
#
# Required environment variables:
#   TIER                strict, hardened, or permissive
#   EGRESS_POLICY       block or audit
#   RUNNER_ENVIRONMENT  github-hosted or self-hosted
#   RUNNER_OS           Linux, Windows, or macOS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/github/output.sh
source "$LIB_DIR/github/output.sh"

: "${TIER:?TIER is required}"
: "${EGRESS_POLICY:?EGRESS_POLICY is required}"
: "${RUNNER_ENVIRONMENT:?RUNNER_ENVIRONMENT is required}"
: "${RUNNER_OS:?RUNNER_OS is required}"

_tier_warning=""
_effective_policy="none"
_enforce_egress="false"

_fail() {
	echo "$1" >&2
	exit 1
}

_can_enforce_block() {
	if [[ "$RUNNER_OS" == "Linux" ]]; then
		return 0
	fi
	if [[ "$RUNNER_ENVIRONMENT" == "self-hosted" ]]; then
		return 0
	fi
	return 1
}

case "$TIER" in
strict | hardened | permissive) ;;
*)
	_fail "validate-runner-policy: unknown tier '$TIER' (expected strict, hardened, or permissive)"
	;;
esac

case "$EGRESS_POLICY" in
block | audit) ;;
*)
	_fail "validate-runner-policy: unknown egress-policy '$EGRESS_POLICY' (expected block or audit)"
	;;
esac

if [[ "$EGRESS_POLICY" == "audit" ]]; then
	if [[ "$TIER" == "permissive" ]]; then
		_tier_warning="permissive tier: audit-only egress is not enforced (advisory only)"
		_effective_policy="none"
		_enforce_egress="false"
		echo "::warning::$_tier_warning"
	else
		_fail "validate-runner-policy: egress-policy 'audit' is not permitted (org requires block). Use egress-policy: block or choose permissive tier only for exotic builds with documented justification."
	fi
elif _can_enforce_block; then
	case "$TIER" in
	strict | hardened)
		_effective_policy="block"
		_enforce_egress="true"
		;;
	permissive)
		if [[ "$RUNNER_ENVIRONMENT" == "self-hosted" ]]; then
			_tier_warning="permissive tier: egress enforcement skipped on self-hosted runner (advisory only)"
			_effective_policy="none"
			_enforce_egress="false"
			echo "::warning::$_tier_warning"
		else
			_tier_warning="permissive tier: egress enforced on GitHub-hosted Linux (advisory — document justification in workflow)"
			_effective_policy="block"
			_enforce_egress="true"
			echo "::notice::$_tier_warning"
		fi
		;;
	esac
else
	case "$TIER" in
	strict)
		_fail "validate-runner-policy: strict tier requires block-mode egress on all legs, but GitHub-hosted $RUNNER_OS runners cannot enforce egress today. Use Linux runners, self-hosted runners with the StepSecurity agent, or a hardened/permissive tier for native platform builds. See docs/workflow-contract.md#runner-policy-tiers."
		;;
	hardened)
		_tier_warning="hardened tier: GitHub-hosted $RUNNER_OS cannot enforce egress — harden-runner skipped (Linux legs still enforced)"
		_effective_policy="none"
		_enforce_egress="false"
		echo "::warning::$_tier_warning"
		;;
	permissive)
		_tier_warning="permissive tier: GitHub-hosted $RUNNER_OS — egress enforcement skipped (advisory only)"
		_effective_policy="none"
		_enforce_egress="false"
		echo "::notice::$_tier_warning"
		;;
	esac
fi

set_github_output "enforce-egress" "$_enforce_egress"
set_github_output "effective-policy" "$_effective_policy"
set_github_output "tier-warning" "$_tier_warning"

if [[ -n "$_tier_warning" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo "### Runner policy"
		echo ""
		echo "- **Tier:** \`$TIER\`"
		echo "- **Runner:** \`$RUNNER_OS\` / \`$RUNNER_ENVIRONMENT\`"
		echo "- **Effective policy:** \`$_effective_policy\`"
		echo "- **Enforce egress:** \`$_enforce_egress\`"
		echo ""
		echo "> $_tier_warning"
	} >>"$GITHUB_STEP_SUMMARY"
fi
