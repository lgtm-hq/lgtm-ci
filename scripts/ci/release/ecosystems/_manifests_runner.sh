#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Orchestrate kind-dispatching manifest version updaters
#
# Parses MANIFESTS (JSON object of file path → kind) and invokes the matching
# kind script with MANIFEST_PATH + NEXT_VERSION.
#
# Required environment variables:
#   NEXT_VERSION - The version to set (e.g., 1.2.3 or 1.2.3-rc.1)
#   MANIFESTS    - JSON object, e.g. {"package.json":"npm","VERSION":"raw"}
#
# Allowed kinds: npm, raw, gemspec, pep621

set -euo pipefail

ECOSYSTEMS_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$ECOSYSTEMS_DIR/../../lib"

# shellcheck source=../../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../../lib/release.sh
source "$LIB_DIR/release.sh"

: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${MANIFESTS:?MANIFESTS is required}"

if ! validate_semver "$NEXT_VERSION"; then
	log_error "NEXT_VERSION is not valid semver: $NEXT_VERSION"
	exit 1
fi

export NEXT_VERSION

ALLOWED_KINDS="npm raw gemspec pep621"

if ! echo "$MANIFESTS" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_error "MANIFESTS is not a valid JSON object: $MANIFESTS"
	exit 1
fi

ENTRY_COUNT=$(echo "$MANIFESTS" | jq 'length')
if [[ "$ENTRY_COUNT" -eq 0 ]]; then
	log_error "MANIFESTS must list at least one file→kind entry"
	exit 1
fi

# --- path containment (#1356) -------------------------------------------------
# The paths come from the caller and the files from the caller checkout, and
# the updaters write through whatever the path resolves to. Before any updater
# runs, every path must name a file inside the checkout (the working
# directory), reach it through no symlink, and stay out of .git and the lgtm-ci
# tooling checkout, which later steps execute.

CHECKOUT_ROOT="$(pwd -P)"

# Canonical absolute form of a protected directory: realpath when it exists
# (folds ./, //, trailing slashes and symlinks), else the lexical join, since
# nothing can resolve into a directory that does not exist.
canonical_dir() {
	local dir="$1"
	[[ "$dir" == /* ]] || dir="${CHECKOUT_ROOT}/${dir}"
	if [[ -d "$dir" ]]; then
		realpath "$dir"
	else
		printf '%s' "${dir%/}"
	fi
}

# Directories no manifest may touch, as canonical absolute paths. TOOLING_DIR
# may be relative or absolute and in any spelling (./x, x//, $PWD/x).
PROTECTED_DIRS=()
for _dir in .git .lgtm-ci-tooling ${TOOLING_DIR:+"$TOOLING_DIR"}; do
	PROTECTED_DIRS+=("$(canonical_dir "$_dir")")
done

reject_path() {
	echo "::error title=unsafe manifest path::${1}: ${2}"
}

# Lower-case for comparisons: a case-insensitive filesystem would otherwise
# let .GIT/config through.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Resolve a path whose parent directory exists, without requiring the final
# component to exist (BSD realpath refuses a missing file).
resolve_path() {
	local parent
	parent="$(realpath "$(dirname "$1")")" || return 1
	printf '%s/%s' "$parent" "$(basename "$1")"
}

# check_manifest_path PATH: prints one ::error and returns 1 on a violation.
check_manifest_path() {
	local path="$1" segment prefix="" resolved protected
	if [[ -z "$path" ]]; then
		reject_path "$path" "empty path"
		return 1
	fi
	if [[ "$path" == /* ]]; then
		reject_path "$path" "absolute paths are not allowed"
		return 1
	fi
	local -a segments
	IFS='/' read -r -a segments <<<"$path"
	for segment in "${segments[@]}"; do
		if [[ "$segment" == ".." ]]; then
			reject_path "$path" "'..' segments are not allowed"
			return 1
		fi
	done
	for segment in "${segments[@]}"; do
		[[ -z "$segment" || "$segment" == "." ]] && continue
		prefix="${prefix:+${prefix}/}${segment}"
		if [[ -L "${CHECKOUT_ROOT}/${prefix}" ]]; then
			reject_path "$path" "'${prefix}' is a symlink"
			return 1
		fi
	done
	if ! resolved="$(resolve_path "${CHECKOUT_ROOT}/${path}")"; then
		reject_path "$path" "its parent directory does not exist"
		return 1
	fi
	if [[ "$(lower "$resolved")" != "$(lower "$CHECKOUT_ROOT")"/* ]]; then
		reject_path "$path" "resolves to ${resolved}, outside the checkout ${CHECKOUT_ROOT}"
		return 1
	fi
	for protected in "${PROTECTED_DIRS[@]}"; do
		protected="$(lower "$protected")"
		if [[ "$(lower "$resolved")" == "$protected" || "$(lower "$resolved")" == "$protected"/* ]]; then
			reject_path "$path" "resolves into the protected directory ${protected#"$(lower "$CHECKOUT_ROOT")/"}"
			return 1
		fi
	done
	return 0
}

# C0 controls, DEL and the C1 range (U+0080-U+009F, e.g. U+0085 NEL).
if ! echo "$MANIFESTS" | jq -e 'keys_unsorted | all(explode | all(. >= 32 and (. < 127 or . > 159)))' >/dev/null; then
	echo "::error title=unsafe manifest path::MANIFESTS keys must not contain control characters"
	exit 1
fi

UNSAFE=0
while IFS= read -r path; do
	check_manifest_path "$path" || UNSAFE=1
done < <(echo "$MANIFESTS" | jq -r 'keys_unsorted[]')
if [[ "$UNSAFE" -ne 0 ]]; then
	log_error "Refusing to run manifest updaters: unsafe path(s) above"
	exit 1
fi

log_info "Running manifest updaters for $ENTRY_COUNT path(s)"
log_info "Target version: $NEXT_VERSION"

FAILED=0

while IFS= read -r path; do
	[[ -z "$path" ]] && continue

	kind=$(echo "$MANIFESTS" | jq -r --arg p "$path" '.[$p] | if type == "string" then . else empty end')
	if [[ -z "$kind" ]]; then
		BAD=$(echo "$MANIFESTS" | jq -c --arg p "$path" '.[$p]')
		log_error "[$path] kind must be a string, got: $BAD"
		FAILED=1
		continue
	fi

	if [[ ! " $ALLOWED_KINDS " == *" $kind "* ]]; then
		log_error "[$path] Unknown kind: $kind (allowed: $ALLOWED_KINDS)"
		FAILED=1
		continue
	fi

	SCRIPT="$ECOSYSTEMS_DIR/${kind}.sh"
	if [[ ! -f "$SCRIPT" ]]; then
		log_error "[$path] Kind script missing: $SCRIPT"
		FAILED=1
		continue
	fi

	export MANIFEST_PATH="$path"
	log_info "[$kind] Updating $path..."
	# Intentionally continue after a kind failure so later manifests still run
	# and all errors are reported; workspace may contain partial updates, but
	# the step exits non-zero so no version PR is created (same as _runner.sh).
	if "$SCRIPT"; then
		log_success "[$kind] $path updated to $NEXT_VERSION"
	else
		log_error "[$kind] Update failed for $path"
		FAILED=1
	fi
done < <(echo "$MANIFESTS" | jq -r 'keys_unsorted[]')

if [[ "$FAILED" -ne 0 ]]; then
	log_error "One or more manifest updaters failed"
	exit 1
fi

log_success "All manifest updaters completed successfully"
