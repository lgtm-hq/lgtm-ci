#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify the artifacts a publish-set run is about to pack and
#          publish, BEFORE any irreversible step (pre-publish verification,
#          per the release security policy).
#
# The file set is what `npm publish` will actually ship: for every package
# in ORDER the script asks npm which files it would pack (`npm pack
# --dry-run --json --ignore-scripts`, which writes nothing and runs no
# package scripts) and requires each of those files to carry a manifest
# entry. FILES may add further paths (build inputs that are not packed);
# an empty FILES additionally verifies every manifest entry.
#
# Two checks per file:
#   1. sha256 equality against a checksums manifest shipped with the build
#      (`<hex>  <path>` lines, paths relative to PACKAGES_DIR), and
#   2. artifact attestation via `gh attestation verify --repo <signer-repo>
#      --signer-workflow <signer-workflow>`, proving the artifact was built
#      by the expected repository and workflow.
#
# Any tampered, missing, unlisted, or unattested file — including a packed
# file the manifest does not know — fails before the real npm pack runs; a
# failure here can never have published anything.
#
# Environment:
#   PACKAGES_DIR      Directory containing one subdirectory per package (required)
#   ORDER             Package subdirectories, as publish-set.sh takes them
#                     (JSON array or comma/space separated; "." for the
#                     single-directory shape) (required)
#   CHECKSUMS_FILE    Path to the SHA256SUMS manifest (required), relative
#                     to the workspace (e.g. npm-dist/SHA256SUMS); a path
#                     relative to PACKAGES_DIR is accepted as a fallback.
#                     The entries INSIDE the manifest are relative to
#                     PACKAGES_DIR.
#   FILES             JSON array of glob patterns relative to PACKAGES_DIR,
#                     e.g. ["pkg-linux-x64/bin/tool","meta/package.json"].
#                     Empty array (the default): verify every file the
#                     manifest lists.
#   SIGNER_REPO       Repository provenance must attest to, e.g. lgtm-hq/lgtm-ci
#                     (required; the reusable's signer-repo input)
#   SIGNER_WORKFLOW   Workflow provenance must attest to, either a path inside
#                     SIGNER_REPO (.github/workflows/build.yml) or fully
#                     qualified ([host/]owner/repo/.github/workflows/build.yml)
#                     (required; the reusable's signer-workflow input)
#   GH_CMD            gh binary name (overridable in tests; default gh)
#   NPM_CMD           npm binary name (overridable in tests; default npm)

set -euo pipefail

: "${PACKAGES_DIR:?PACKAGES_DIR is required}"
: "${ORDER:?ORDER is required}"
: "${CHECKSUMS_FILE:?CHECKSUMS_FILE is required}"
# Fail closed, naming the workflow input: checksums-file without a signer
# would verify sha256 only, which is not the attestation the policy requires.
: "${SIGNER_REPO:?SIGNER_REPO is required: set the signer-repo input whenever checksums-file is set}"
: "${SIGNER_WORKFLOW:?SIGNER_WORKFLOW is required: set the signer-workflow input whenever checksums-file is set}"

# `gh attestation verify --signer-workflow` wants `[host/]owner/repo/path`,
# while the workflow input is documented as a path inside the signer
# repository (`.github/workflows/build.yml`). Accept both: a bare path is
# qualified with SIGNER_REPO; a value that already names a repository (or a
# host and repository) is passed through unchanged.
if [[ "$SIGNER_WORKFLOW" != */.github/workflows/* ]]; then
	SIGNER_WORKFLOW="${SIGNER_REPO}/${SIGNER_WORKFLOW#/}"
fi
FILES="${FILES:-[]}"
PACKAGES_DIR="${PACKAGES_DIR%/}"
GH="${GH_CMD:-gh}"
NPM="${NPM_CMD:-npm}"

normalize_order() {
	local order="$1"
	if [[ "$order" == \[*\] ]]; then
		printf '%s\n' "$order" | jq -r 'if type == "array" then .[] else empty end'
	else
		echo "$order" | tr ',' ' ' | tr -s ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
	fi
}

# The manifest usually ships inside the staged set (artifact-name lands it in
# PACKAGES_DIR), so accept a PACKAGES_DIR-relative path when the
# workspace-relative one does not exist.
if [[ ! -f "$CHECKSUMS_FILE" && -f "$PACKAGES_DIR/$CHECKSUMS_FILE" ]]; then
	CHECKSUMS_FILE="$PACKAGES_DIR/$CHECKSUMS_FILE"
fi
if [[ ! -f "$CHECKSUMS_FILE" ]]; then
	echo "ERROR: checksums manifest '$CHECKSUMS_FILE' not found (looked in the workspace and under $PACKAGES_DIR)" >&2
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

ORDERED_PACKAGES="$(normalize_order "$ORDER")"
[[ -n "$ORDERED_PACKAGES" ]] || fail "ORDER resolved to no packages (got '$ORDER'); nothing to verify"

# What npm would ship, per package: the authoritative file set. A package
# that cannot be enumerated fails closed — an unknown file set cannot be
# verified. `--dry-run` writes no tarball and `--ignore-scripts` keeps
# prepack hooks from running before verification.
declare -a PACKED=()
while IFS= read -r pkg; do
	[[ -n "$pkg" ]] || continue
	if [[ "$pkg" == "." ]]; then
		pkg_dir="$PACKAGES_DIR"
		prefix=""
	else
		pkg_dir="$PACKAGES_DIR/$pkg"
		prefix="$pkg/"
	fi
	[[ -f "$pkg_dir/package.json" ]] || fail "$pkg_dir/package.json not found (check the order input)"
	echo "==> Enumerating files npm would pack for $pkg"
	pack_json="$(cd "$pkg_dir" && "$NPM" pack --dry-run --json --ignore-scripts 2>/dev/null)" ||
		fail "npm pack --dry-run failed for $pkg; cannot determine the file set to verify"
	pack_paths="$(printf '%s' "$pack_json" | jq -r '.[0].files[]?.path' 2>/dev/null)" ||
		fail "could not parse the npm pack file list for $pkg"
	[[ -n "$pack_paths" ]] || fail "npm pack reported no files for $pkg; refusing to publish an empty package"
	while IFS= read -r packed; do
		[[ -n "$packed" ]] || continue
		PACKED+=("${prefix}${packed}")
	done <<<"$pack_paths"
done <<<"$ORDERED_PACKAGES"

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
declare -a MANIFEST_PATHS=()
while IFS= read -r line; do
	[[ -n "$line" ]] || continue
	# Strip the leading checksum: awk clears $1 (portable on BSD and GNU).
	manifest_path="$(printf '%s\n' "$line" | awk '{ $1 = ""; sub(/^[[:space:]]+/, ""); print }')"
	[[ -n "$manifest_path" ]] || continue
	if [[ ! -f "$PACKAGES_DIR/$manifest_path" ]]; then
		fail "manifest lists '$manifest_path' but it does not exist under $PACKAGES_DIR"
	fi
	MANIFEST_PATHS+=("$manifest_path")
done <"$CHECKSUMS_FILE"

# Every packed file must be known to the manifest; otherwise a modified or
# added publishable file would reach the registry unverified. Checked up
# front so the error lists every offender at once.
unlisted=()
for packed in "${PACKED[@]}"; do
	listed=0
	for mp in "${MANIFEST_PATHS[@]+"${MANIFEST_PATHS[@]}"}"; do
		if [[ "$mp" == "$packed" ]]; then
			listed=1
			break
		fi
	done
	((listed)) || unlisted+=("$packed")
done
if ((${#unlisted[@]} > 0)); then
	echo "ERROR: npm would pack file(s) the checksums manifest does not list; refusing to publish unverified artifacts:" >&2
	printf '  - %s\n' "${unlisted[@]}" >&2
	exit 1
fi

# An empty FILES list means "the manifest is the file list": every entry gets
# the full sha256 + attestation check, so the reusable's default ("[]")
# verifies the whole staged set rather than nothing. A non-empty FILES that
# matches nothing is a caller error.
if [[ "$(printf '%s' "$FILES" | jq 'length')" -eq 0 ]]; then
	TARGETS=("${MANIFEST_PATHS[@]+"${MANIFEST_PATHS[@]}"}")
else
	((${#TARGETS[@]} > 0)) || fail "no files matched the verify-artifacts file list; refusing to publish unverified artifacts"
fi
# The packed files are always verified; FILES only ever adds to that set.
TARGETS=("${PACKED[@]}" "${TARGETS[@]+"${TARGETS[@]}"}")
# Deduplicate, keeping first-seen order.
declare -a UNIQUE_TARGETS=()
for rel in "${TARGETS[@]}"; do
	seen=0
	for u in "${UNIQUE_TARGETS[@]+"${UNIQUE_TARGETS[@]}"}"; do
		[[ "$u" == "$rel" ]] && {
			seen=1
			break
		}
	done
	((seen)) || UNIQUE_TARGETS+=("$rel")
done
TARGETS=("${UNIQUE_TARGETS[@]}")

failures=0
for rel in "${TARGETS[@]}"; do
	file="$PACKAGES_DIR/$rel"
	echo "==> Verifying $rel"
	# Exact string match on the path (no regex: package paths may contain
	# +, [, ] and the like); the same "$1 is the hash, the rest is the path"
	# split as the existence check above. Last entry wins on duplicates.
	expected="$(awk -v p="$rel" '{ h = $1; $1 = ""; sub(/^[[:space:]]+/, ""); if ($0 == p) print h }' "$CHECKSUMS_FILE" | tail -1)"
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
