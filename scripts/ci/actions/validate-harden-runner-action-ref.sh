#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables use local harden-runner (same-repository composite pattern)
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HARDEN_ACTION="$REPO_ROOT/.github/actions/harden-runner/action.yml"

violations=0
while IFS= read -r -d '' file; do
	line_num=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ "$line" == *"lgtm-hq/lgtm-ci/.github/actions/harden-runner@"* ]]; then
			echo "$file:$line_num: use ./.github/actions/harden-runner (remote @sha breaks PR refs)" >&2
			echo "  $line" >&2
			violations=$((violations + 1))
		fi
		if [[ "$line" == *".lgtm-ci-egress"* ]]; then
			echo "$file:$line_num: remove .lgtm-ci-egress workaround" >&2
			violations=$((violations + 1))
		fi
	done <"$file"
done < <(find "$REPO_ROOT/.github/workflows" -name 'reusable-*.yml' -print0)

if grep -qE "steps\.resolve\.outputs\['allowed-endpoints'\]" "$HARDEN_ACTION"; then
	echo "harden-runner/action.yml: must pass inputs['allowed-endpoints'] (pre-hook cannot read composite step outputs)" >&2
	violations=$((violations + 1))
fi

if grep -qE "^\s+egress-preset:" "$HARDEN_ACTION"; then
	echo "harden-runner/action.yml: egress-preset belongs on resolve-egress-allowlist, not harden-runner" >&2
	violations=$((violations + 1))
fi

for workflow in "$REPO_ROOT"/.github/workflows/reusable-*.yml "$REPO_ROOT"/.github/workflows/renovate.yml; do
	[[ -f "$workflow" ]] || continue
	if ! grep -qE '^[[:space:]]+uses:[[:space:]]+\./\.github/actions/harden-runner([[:space:]]|$)' "$workflow"; then
		continue
	fi
	if ! grep -qE '^[[:space:]]+uses:[[:space:]]+\./\.github/actions/resolve-egress-allowlist([[:space:]]|$)' "$workflow"; then
		echo "${workflow##*/}: uses harden-runner but missing resolve-egress-allowlist step" >&2
		violations=$((violations + 1))
	fi
	if grep -A20 'uses: \./\.github/actions/harden-runner' "$workflow" | grep -qE 'egress-preset:'; then
		echo "${workflow##*/}: pass egress-preset to resolve-egress-allowlist, not harden-runner" >&2
		violations=$((violations + 1))
	fi
	if ! grep -qF "steps.egress.outputs['allowed-endpoints']" "$workflow"; then
		echo "${workflow##*/}: harden-runner must use steps.egress.outputs['allowed-endpoints']" >&2
		violations=$((violations + 1))
	fi
done

for workflow in "$REPO_ROOT"/.github/workflows/reusable-*.yml; do
	[[ -f "$workflow" ]] || continue
	if ! grep -qE '^[[:space:]]*steps:[[:space:]]*$' "$workflow"; then
		continue
	fi
	if ! grep -qE '^[[:space:]]+uses:[[:space:]]+\./\.github/actions/harden-runner([[:space:]]|$)' "$workflow"; then
		echo "${workflow##*/}: missing ./.github/actions/harden-runner step" >&2
		violations=$((violations + 1))
	fi
done

if [[ $violations -gt 0 ]]; then
	exit 1
fi

echo "All reusables use resolve-egress-allowlist + ./.github/actions/harden-runner"
