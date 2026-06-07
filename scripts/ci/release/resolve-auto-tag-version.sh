#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve auto-tag version from commit message or Cargo.toml
#
# Required environment variables:
#   VERSION_SOURCE - commit (default) or cargo
#
# Optional environment variables:
#   VERSION_FILE   - Cargo manifest path when VERSION_SOURCE is cargo
#   COMMIT_MESSAGE - Override commit subject for commit source
#
# Outputs: version, found (from the selected resolver)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

: "${VERSION_SOURCE:=commit}"

case "$VERSION_SOURCE" in
cargo)
	exec "$SCRIPT_DIR/read-cargo-version.sh"
	;;
commit)
	exec "$SCRIPT_DIR/extract-version-from-commit.sh"
	;;
*)
	echo "Unknown VERSION_SOURCE: $VERSION_SOURCE (expected: commit or cargo)" >&2
	exit 1
	;;
esac
