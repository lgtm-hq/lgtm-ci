#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post-publish verification for an npm package set. Read-only:
#          this script never writes to the registry; it confirms the
#          registry now serves what the publish step claimed.
#
# Per package (from the publish step's results file):
#   - `npm view <name>@<version> dist.attestations dist.integrity` exists —
#     provenance attestation and integrity MUST be present on the registry
#     for a trusted-publishing release; a package missing them fails the job
#     after all packages are processed (the loop finishes first so one bad
#     package does not hide the state of the rest).
#   - Bounded retry for registry propagation: a fresh publish can take a few
#     seconds to become visible through `npm view`.
# For the meta package (last in ORDER):
#   - `npm audit signatures` in a scratch install of the packed tarball.
# Optional:
#   - SMOKE command run in the scratch install directory (host platform).
#
# Dry-runs never touched the registry, so with DRY_RUN=1 this script only
# reports what it would have checked and exits 0.
#
# Environment:
#   PACKAGES_DIR   Directory containing one subdirectory per package (required)
#   ORDER          Same order input publish-set.sh took; meta package last (required)
#   DIST_TAG       Dist-tag used by the publish (default latest)
#   DRY_RUN        1 when the publish was a dry-run (default 0)
#   SMOKE          Optional command to run inside the scratch install
#   ATTEMPTS       Propagation lookup attempts (default 5)
#   DELAY          Seconds between propagation attempts (default 3)
#   GH_CMD         npm binary name (overridable in tests; default npm)

set -euo pipefail

: "${PACKAGES_DIR:?PACKAGES_DIR is required}"
: "${ORDER:?ORDER is required}"
PACKAGES_DIR="${PACKAGES_DIR%/}"
DIST_TAG="${DIST_TAG-latest}"
DRY_RUN="${DRY_RUN:-0}"
SMOKE="${SMOKE:-}"
ATTEMPTS="${ATTEMPTS:-5}"
DELAY="${DELAY:-3}"
NPM="${GH_CMD:-npm}"

if [[ ! "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
	echo "ERROR: ATTEMPTS must be a positive integer (got '$ATTEMPTS')" >&2
	exit 1
fi
if [[ ! "$DELAY" =~ ^(0|[1-9][0-9]*)$ ]]; then
	echo "ERROR: DELAY must be a non-negative integer (got '$DELAY')" >&2
	exit 1
fi

normalize_order() {
	local order="$1"
	if [[ "$order" == \[*\] ]]; then
		printf '%s\n' "$order" | jq -r 'if type == "array" then .[] else empty end'
	else
		echo "$order" | tr ',' ' ' | tr -s ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
	fi
}

package_field() {
	node -p "require('$1/package.json').$2"
}

package_dir_for() {
	if [[ "$1" == "." ]]; then
		echo "$PACKAGES_DIR"
	else
		echo "$PACKAGES_DIR/$1"
	fi
}

# Wait for a fresh publish to become visible, then require attestations and
# integrity. Failures accumulate; every package is checked before deciding.
declare -a FAILURES=()

verify_one() {
	local name="$1" version="$2"
	local attempt view
	local visible=0
	for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
		echo "==> Verifying registry state for $name@$version (attempt $attempt/$ATTEMPTS)"
		if view="$("$NPM" view "$name@$version" dist.attestations dist.integrity --json 2>/dev/null)"; then
			visible=1
			if printf '%s' "$view" | jq -e '."dist.attestations"' >/dev/null 2>&1 &&
				printf '%s' "$view" | jq -e '."dist.integrity"' >/dev/null 2>&1; then
				echo "    provenance attestation and integrity present"
				return 0
			fi
			# Visible but incomplete: attestation/integrity metadata propagates
			# separately from the version itself, so keep waiting.
			echo "    visible, but provenance attestation or integrity not yet present"
		fi
		if ((attempt < ATTEMPTS)); then
			sleep "$DELAY"
		fi
	done
	if ((visible)); then
		echo "ERROR: $name@$version is on the registry without provenance attestation or integrity after $ATTEMPTS attempts" >&2
		FAILURES+=("$name@$version missing dist.attestations/dist.integrity after $ATTEMPTS propagation attempts")
		return 0
	fi
	echo "ERROR: $name@$version not visible on the registry after $ATTEMPTS attempts" >&2
	FAILURES+=("$name@$version not found after $ATTEMPTS propagation attempts")
}

audit_meta_signatures() {
	local pkg="$1"
	# Global on purpose: the EXIT trap below fires at script exit, outside
	# this function's scope, where a function-local would be unbound under
	# set -u.
	SCRATCH_DIR="$(mktemp -d)"
	trap 'rm -rf "$SCRATCH_DIR"' EXIT
	local scratch="$SCRATCH_DIR"
	echo "==> Packing and scratch-installing $pkg for npm audit signatures"
	(cd "$pkg" && "$NPM" pack --silent --pack-destination "$scratch" >/dev/null 2>&1) || {
		echo "ERROR: failed to pack $pkg for the signature audit" >&2
		FAILURES+=("$pkg npm pack for signature audit failed")
		return 0
	}
	local tarball
	tarball="$(find "$scratch" -maxdepth 1 -name '*.tgz' | head -1)"
	if [[ -z "$tarball" ]]; then
		echo "ERROR: no tarball produced for the signature audit" >&2
		FAILURES+=("signature audit: no tarball")
		return 0
	fi
	(cd "$scratch" && "$NPM" install --silent --no-audit --no-fund --ignore-scripts "$tarball" >/dev/null 2>&1) || {
		echo "ERROR: scratch install of $pkg failed" >&2
		FAILURES+=("$pkg scratch install failed")
		return 0
	}
	if (cd "$scratch" && "$NPM" audit signatures >/dev/null 2>&1); then
		echo "    npm audit signatures passed"
	else
		echo "ERROR: npm audit signatures failed for $pkg" >&2
		FAILURES+=("$pkg npm audit signatures failed")
	fi
	if [[ -n "$SMOKE" ]]; then
		echo "==> Running smoke command: $SMOKE"
		if (cd "$scratch" && bash -c "$SMOKE" >/dev/null 2>&1); then
			echo "    smoke command passed"
		else
			echo "ERROR: smoke command failed: $SMOKE" >&2
			FAILURES+=("smoke command failed: $SMOKE")
		fi
	fi
}

if [[ "$DRY_RUN" == "1" ]]; then
	echo "Dry-run publish: post-publish registry verification skipped (nothing was written)."
	echo "Would check: provenance attestation + integrity per package; npm audit signatures on the meta package."
	exit 0
fi

# Same guard as publish-set.sh: an empty order would verify nothing and pass.
ORDERED_PACKAGES="$(normalize_order "$ORDER")"
if [[ -z "$ORDERED_PACKAGES" ]]; then
	echo "ERROR: ORDER resolved to no packages (got '$ORDER'); nothing to verify" >&2
	exit 1
fi

meta_pkg=""
while IFS= read -r pkg; do
	[[ -n "$pkg" ]] || continue
	pkg_dir="$(package_dir_for "$pkg")"
	name="$(package_field "$pkg_dir" name)"
	version="$(package_field "$pkg_dir" version)"
	verify_one "$name" "$version"
	# ORDER's last entry is the meta package; its tarball gets the audit.
	meta_pkg="$pkg_dir"
done <<<"$ORDERED_PACKAGES"

if [[ -n "$meta_pkg" ]]; then
	audit_meta_signatures "$meta_pkg"
fi

if ((${#FAILURES[@]} > 0)); then
	echo "ERROR: post-publish verification failed:" >&2
	for failure in "${FAILURES[@]}"; do
		echo "  - $failure" >&2
	done
	exit 1
fi

echo "Post-publish verification passed for all packages."
