#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables use local harden-runner (same-repository composite pattern)
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

for workflow in "$REPO_ROOT"/.github/workflows/reusable-*.yml; do
	[[ -f "$workflow" ]] || continue
	# Thin wrappers that only delegate to other reusable workflows have no steps
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

echo "All reusables use ./.github/actions/harden-runner (same-repo composite)"
