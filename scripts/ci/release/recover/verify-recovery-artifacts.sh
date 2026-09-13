#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify the ORIGINAL release artifacts a recovery run downloaded,
#          before any resume step uses them (#966 resolve stage).
#
# Same-bytes-same-version is enforced here, by tooling rather than
# discipline:
#   1. Every file in the artifacts directory (or every FILES glob hit) must
#      match its SHA256SUMS manifest entry — artifacts re-downloaded from a
#      run can be truncated or swapped.
#   2. Every verified file must carry a provenance attestation binding it to
#      the original signer repo/workflow (`gh attestation verify`).
#   3. OPTIONAL channel equality: when the channel already has the artifact
#      published (GitHub Release asset `digest`), the published sha256 must
#      equal the local artifact's — a mismatch stops the run with tier-three
#      guidance before any publish.
#
# Environment:
#   ARTIFACTS_DIR    Downloaded artifacts directory (required)
#   CHECKSUMS_FILE   SHA256SUMS manifest inside it (required; relative to dir)
#   FILES            Optional JSON glob list to restrict verification;
#                    default: every manifest entry must exist and verify
#   SIGNER_REPO, SIGNER_WORKFLOW  attestation bindings (required)
#   GH               gh binary override (default gh)
#   RELEASE_ASSET_DIGESTS  Optional JSON map {asset-name: "sha256:hex"} of
#                    already-published GitHub Release assets to compare
#                    against local files of the same name

set -euo pipefail

: "${ARTIFACTS_DIR:?ARTIFACTS_DIR is required}"
: "${CHECKSUMS_FILE:?CHECKSUMS_FILE is required}"
: "${SIGNER_REPO:?SIGNER_REPO is required}"
: "${SIGNER_WORKFLOW:?SIGNER_WORKFLOW is required}"
FILES="${FILES:-[]}"
RELEASE_ASSET_DIGESTS="${RELEASE_ASSET_DIGESTS:-}"
GH="${GH_CMD:-gh}"

[[ -d "$ARTIFACTS_DIR" ]] || { echo "ERROR: ARTIFACTS_DIR '$ARTIFACTS_DIR' not found" >&2; exit 1; }
manifest="$ARTIFACTS_DIR/$CHECKSUMS_FILE"
[[ -f "$manifest" ]] || { echo "ERROR: checksums manifest '$manifest' not found" >&2; exit 1; }
printf '%s' "$FILES" | jq -e 'type == "array"' >/dev/null 2>&1 ||
	{ echo "ERROR: FILES must be a JSON array" >&2; exit 1; }

failures=0
verify_file() {
	local rel="$1"
	local file="$ARTIFACTS_DIR/$rel"
	echo "==> Verifying $rel"
	[[ -f "$file" ]] || {
		echo "ERROR: '$rel' listed in the manifest but missing from the downloaded artifacts" >&2
		failures=$((failures + 1))
		return 0
	}
	local expected
	# `|| true`: a no-entry grep is the handled failure case; pipefail would
	# otherwise kill the script before the error prints.
	expected="$(grep -E "[[:space:]]${rel//./\\.}\$" "$manifest" | awk '{print $1}' | tail -1 || true)"
	if [[ -z "$expected" ]]; then
		echo "ERROR: no manifest entry for '$rel'" >&2
		failures=$((failures + 1))
		return 0
	fi
	local actual
	if command -v sha256sum >/dev/null 2>&1; then
		actual="$(sha256sum "$file" | awk '{print $1}')"
	else
		actual="$(shasum -a 256 "$file" | awk '{print $1}')"
	fi
	if [[ "$actual" != "$expected" ]]; then
		echo "ERROR: sha256 mismatch for '$rel': manifest $expected, actual $actual" >&2
		failures=$((failures + 1))
		return 0
	fi
	if ! "$GH" attestation verify "$file" --repo "$SIGNER_REPO" \
		--signer-workflow "$SIGNER_WORKFLOW" >/dev/null 2>&1; then
		echo "ERROR: attestation verification failed for '$rel' (expected $SIGNER_REPO / $SIGNER_WORKFLOW)" >&2
		failures=$((failures + 1))
		return 0
	fi
	# Optional channel equality: a GitHub Release asset already published for
	# this name must hash to the same bytes. A published digest that differs
	# from the attested artifact is the tier-three trigger, checked BEFORE any
	# resume write.
	if [[ -n "$RELEASE_ASSET_DIGESTS" ]]; then
		local published
		published="$(printf '%s' "$RELEASE_ASSET_DIGESTS" | jq -r --arg k "$(basename "$rel")" '.[$k] // empty' 2>/dev/null || true)"
		if [[ -n "$published" && "$published" != "sha256:$actual" ]]; then
			echo "ERROR: published GitHub Release asset '$(basename "$rel")' has $published but the attested original artifact is sha256:$actual — same version, different bytes; recovery refused (tier three: cut a new patch version)" >&2
			failures=$((failures + 1))
			return 0
		fi
	fi
	echo "    sha256 ok, attestation ok"
}

if [[ "$FILES" == "[]" ]]; then
	# Verify every manifest entry: the conservative default for a recovery.
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		rel="$(printf '%s\n' "$line" | awk '{ $1 = ""; sub(/^[[:space:]]+/, ""); print }')"
		[[ -n "$rel" ]] && verify_file "$rel"
	done <"$manifest"
else
	while IFS= read -r pattern; do
		[[ -n "$pattern" ]] || continue
		shopt -s nullglob
		for hit in "$ARTIFACTS_DIR"/$pattern; do
			[[ -f "$hit" ]] && verify_file "${hit#"$ARTIFACTS_DIR"/}"
		done
		shopt -u nullglob
	done < <(printf '%s' "$FILES" | jq -r '.[]')
fi

if [[ "$failures" -gt 0 ]]; then
	echo "ERROR: recovery artifact verification failed for $failures file(s); nothing was resumed." >&2
	exit 1
fi

echo "Recovery artifacts verified against manifest, attestations, and any published digests."
