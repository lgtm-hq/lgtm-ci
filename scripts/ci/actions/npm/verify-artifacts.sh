#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify the artifacts a publish-set run is about to pack and
#          publish, BEFORE any irreversible step (pre-publish verification,
#          per the release security policy).
#
# Two checks per file:
#   1. sha256 equality against a checksums manifest shipped with the build
#      (`<hex>  <path>` lines, paths relative to PACKAGES_DIR), and
#   2. artifact attestation via `gh attestation verify --repo <signer-repo>
#      --signer-workflow <signer-workflow>`, proving the artifact was built
#      by the expected repository and workflow.
#
# Any tampered, missing, unlisted, or unattested file fails before npm pack
# runs; a failure here can never have published anything.
#
# Environment:
#   PACKAGES_DIR      Directory containing one subdirectory per package (required)
#   CHECKSUMS_FILE    Path to the SHA256SUMS manifest (required)
#   FILES             JSON array of glob patterns relative to PACKAGES_DIR,
#                     e.g. ["pkg-linux-x64/bin/tool","meta/package.json"].
#                     Empty array: verify only that every manifest entry exists.
#   SIGNER_REPO       Repository provenance must attest to, e.g. lgtm-hq/lgtm-ci (required)
#   SIGNER_WORKFLOW   Workflow path provenance must attest to (required)
#   GH_CMD            gh binary name (overridable in tests; default gh)

set -euo pipefail

: "${PACKAGES_DIR:?PACKAGES_DIR is required}"
: "${CHECKSUMS_FILE:?CHECKSUMS_FILE is required}"
: "${SIGNER_REPO:?SIGNER_REPO is required}"
: "${SIGNER_WORKFLOW:?SIGNER_WORKFLOW is required}"
FILES="${FILES:-[]}"
PACKAGES_DIR="${PACKAGES_DIR%/}"
GH="${GH_CMD:-gh}"

if [[ ! -f "$CHECKSUMS_FILE" ]]; then
	echo "ERROR: checksums manifest '$CHECKSUMS_FILE' not found" >&2
	exit 1
fi
if ! printf '%s' "$FILES" | jq -e 'type == "array"' >/dev/null 2>&1; then
	echo "ERROR: FILES must be a JSON array of glob patterns" >&2
	exit 1
fi

fail() {
	echo "ERROR: $1" >&2
	exit 1
}

# Expand the FILES globs (relative to PACKAGES_DIR) into a sorted file list.
declare -a TARGETS=()
while IFS= read -r pattern; do
	[[ -n "$pattern" ]] || continue
	shopt -s nullglob
	for hit in "$PACKAGES_DIR"/$pattern; do
		[[ -f "$hit" ]] && TARGETS+=("${hit#"$PACKAGES_DIR"/}")
	done
	shopt -u nullglob
done < <(printf '%s' "$FILES" | jq -r '.[]')

# Every file named by the manifest must exist: a missing artifact is exactly
# what this gate exists to catch, so it is checked even with an empty FILES.
while IFS= read -r line; do
	[[ -n "$line" ]] || continue
# Strip the leading checksum: awk clears $1 (portable on BSD and GNU).
	manifest_path="$(printf '%s\n' "$line" | awk '{ $1 = ""; sub(/^[[:space:]]+/, ""); print }')"
	[[ -n "$manifest_path" ]] || continue
	if [[ ! -f "$PACKAGES_DIR/$manifest_path" ]]; then
		fail "manifest lists '$manifest_path' but it does not exist under $PACKAGES_DIR"
	fi
done <"$CHECKSUMS_FILE"

((${#TARGETS[@]} > 0)) || fail "no files matched the verify-artifacts file list; refusing to publish unverified artifacts"

failures=0
for rel in "${TARGETS[@]}"; do
	file="$PACKAGES_DIR/$rel"
	echo "==> Verifying $rel"
	# `|| true` inside the substitution: a no-entry grep is the handled case,
	# and pipefail would otherwise kill the script before the error is printed.
	expected="$(grep -E "[[:space:]]${rel//./\\.}\$" "$CHECKSUMS_FILE" | awk '{print $1}' | tail -1 || true)"
	if [[ -z "$expected" ]]; then
		echo "ERROR: no checksums-manifest entry for '$rel'" >&2
		failures=$((failures + 1))
		continue
	fi
	# GNU coreutils first (CI runners); macOS ships only `shasum -a 256`.
	if command -v sha256sum >/dev/null 2>&1; then
		actual="$(sha256sum "$file" | awk '{print $1}')"
	else
		actual="$(shasum -a 256 "$file" | awk '{print $1}')"
	fi
	if [[ "$actual" != "$expected" ]]; then
		echo "ERROR: sha256 mismatch for '$rel': manifest $expected, actual $actual" >&2
		failures=$((failures + 1))
		continue
	fi
	if ! "$GH" attestation verify "$file" \
		--repo "$SIGNER_REPO" \
		--signer-workflow "$SIGNER_WORKFLOW" >/dev/null 2>&1; then
		echo "ERROR: attestation verification failed for '$rel' (expected $SIGNER_REPO / $SIGNER_WORKFLOW)" >&2
		failures=$((failures + 1))
		continue
	fi
	echo "    sha256 ok, attestation ok"
done

if [[ "$failures" -gt 0 ]]; then
	echo "ERROR: artifact verification failed for $failures file(s); nothing was published." >&2
	exit 1
fi

echo "All artifacts verified (sha256 + provenance attestation)."
