#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sync canonical egress scripts into the self-contained harden-runner action
#
# Usage:
#   bash scripts/ci/actions/sync-harden-runner-bundle.sh
#
# Copies scripts/ci/lib/egress assets and the resolver into
# .github/actions/harden-runner/ so the composite runs without monorepo layout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUNDLE_ROOT="$REPO_ROOT/.github/actions/harden-runner"
CANONICAL_LIB="$REPO_ROOT/scripts/ci/lib"

mkdir -p "$BUNDLE_ROOT/lib/egress" "$BUNDLE_ROOT/lib/github"

cp "$CANONICAL_LIB/egress/presets.sh" "$BUNDLE_ROOT/lib/egress/presets.sh"
cp "$CANONICAL_LIB/egress.sh" "$BUNDLE_ROOT/lib/egress.sh"
cp "$CANONICAL_LIB/github/output.sh" "$BUNDLE_ROOT/lib/github/output.sh"

CANONICAL_RESOLVE="$REPO_ROOT/scripts/ci/actions/resolve-egress-endpoints.sh"
# shellcheck disable=SC2016 # Sed patterns use literal $SCRIPT_DIR, not shell expansion
sed \
	-e 's|# Purpose: Resolve allowed-endpoints from explicit list or egress preset$|# Purpose: Resolve allowed-endpoints from explicit list or egress preset (action bundle)|' \
	-e 's|allowed-endpoints - Resolved allowlist for step-security/harden-runner|allowed-endpoints - Resolved allowlist for bundled harden-runner composite|' \
	-e 's|BASH_SOURCE:-\$0|BASH_SOURCE[0]|' \
	-e 's|LIB_DIR="\$SCRIPT_DIR/\.\./lib"|LIB_DIR="$SCRIPT_DIR/lib"|' \
	-e 's|# shellcheck source=\.\./lib/egress\.sh|# shellcheck source=lib/egress.sh|' \
	-e 's|# shellcheck source=\.\./lib/github/output\.sh|# shellcheck source=lib/github/output.sh|' \
	"$CANONICAL_RESOLVE" >"$BUNDLE_ROOT/resolve-egress-endpoints.sh"
chmod +x "$BUNDLE_ROOT/resolve-egress-endpoints.sh"

GENERATED="$BUNDLE_ROOT/resolve-egress-endpoints.sh"
fail=0
# shellcheck disable=SC2016 # Tokens contain literal $SCRIPT_DIR, not shell expansion
for token in \
	'# Purpose: Resolve allowed-endpoints from explicit list or egress preset (action bundle)' \
	'LIB_DIR="$SCRIPT_DIR/lib"' \
	'# shellcheck source=lib/egress.sh' \
	'# shellcheck source=lib/github/output.sh'; do
	if ! grep -qF "$token" "$GENERATED"; then
		echo "sync-harden-runner-bundle: missing expected token in resolver: $token" >&2
		fail=1
	fi
done
if [[ $fail -ne 0 ]]; then
	echo "sync-harden-runner-bundle: sed substitutions did not produce expected output" >&2
	exit 1
fi

echo "Synced harden-runner bundle into $BUNDLE_ROOT"
