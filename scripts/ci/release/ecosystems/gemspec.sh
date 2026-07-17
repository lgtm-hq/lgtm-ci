#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update a literal .version = "..." assignment in a gemspec
#
# Required environment variables:
#   NEXT_VERSION  - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFEST_PATH - Path to the *.gemspec file
#
# Note: Gemspecs that load version from a Ruby constant (e.g.
#   spec.version = Foo::VERSION) are not updated here — point a raw/
#   version-rb updater or version-update-script at the constant file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/fs.sh
source "$LIB_DIR/fs.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFEST_PATH:?MANIFEST_PATH is required}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
	log_error "[gemspec] gemspec not found at: $MANIFEST_PATH"
	exit 1
fi

# Collect active (non-comment) literal string version assignments.
# Bash 3.2 compatible — no mapfile.
LITERAL_COUNT=0
while IFS= read -r _line; do
	LITERAL_COUNT=$((LITERAL_COUNT + 1))
done < <(grep -E '^[[:space:]]*[^#[:space:]].*\.version[[:space:]]*=[[:space:]]*["'\''][^"'\'']+["'\'']' "$MANIFEST_PATH" || true)

if [[ "$LITERAL_COUNT" -eq 0 ]]; then
	log_error "[gemspec] $MANIFEST_PATH has no literal .version = \"...\" assignment to update"
	exit 1
fi
if [[ "$LITERAL_COUNT" -gt 1 ]]; then
	log_error "[gemspec] $MANIFEST_PATH has $LITERAL_COUNT literal .version assignments; expected exactly one"
	exit 1
fi

log_info "[gemspec] Updating $MANIFEST_PATH → $NEXT_VERSION"

# Escape for sed replacement (NEXT_VERSION is semver; still quote safely).
ESC_VERSION=$(printf '%s' "$NEXT_VERSION" | sed 's/[&/\]/\\&/g')

# Only rewrite non-comment lines that contain a literal .version assignment.
write_file_atomic "$MANIFEST_PATH" \
	sed -E "/^[[:space:]]*#/! s/(\\.version[[:space:]]*=[[:space:]]*)[\"'][^\"']+[\"']/\\1\"${ESC_VERSION}\"/" \
	"$MANIFEST_PATH"

ACTUAL=$(grep -E '^[[:space:]]*[^#[:space:]].*\.version[[:space:]]*=[[:space:]]*["'\''][^"'\'']+["'\'']' "$MANIFEST_PATH" | head -1 |
	sed -E 's/.*\.version[[:space:]]*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/')
if [[ "$ACTUAL" != "$NEXT_VERSION" ]]; then
	log_error "[gemspec] Verification failed: expected $NEXT_VERSION, got $ACTUAL"
	exit 1
fi

log_success "[gemspec] $MANIFEST_PATH updated to $NEXT_VERSION"
