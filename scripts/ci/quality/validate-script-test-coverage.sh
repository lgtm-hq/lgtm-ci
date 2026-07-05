#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ratchet check — every scripts/ci entrypoint must be referenced by a BATS test.
#
# For each shell entrypoint under scripts/ci (excluding scripts/ci/lib, which
# holds sourced libraries, not entrypoints), require its basename to appear in
# at least one tests/**/*.bats file. Known-untested scripts live in an
# allowlist; the check fails when a script is untested but not allowlisted
# (new untested script) or when an allowlist entry is stale (script gained a
# test or was removed) so the allowlist only ever shrinks.
#
# Optional environment variables (used by the BATS self-tests):
#   REPO_ROOT      - Repository root (default: derived from this script)
#   SCRIPTS_DIR    - Scripts root to scan (default: REPO_ROOT/scripts/ci)
#   TESTS_DIR      - BATS tests root (default: REPO_ROOT/tests)
#   ALLOWLIST_FILE - Allowlist path (default: alongside this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
SCRIPTS_DIR="${SCRIPTS_DIR:-${REPO_ROOT}/scripts/ci}"
TESTS_DIR="${TESTS_DIR:-${REPO_ROOT}/tests}"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-${SCRIPT_DIR}/script-test-coverage-allowlist.txt}"

if [[ ! -d "${SCRIPTS_DIR}" ]]; then
	echo "ERROR: scripts directory not found: ${SCRIPTS_DIR}" >&2
	exit 1
fi

if [[ ! -d "${TESTS_DIR}" ]]; then
	echo "ERROR: tests directory not found: ${TESTS_DIR}" >&2
	exit 1
fi

# Load allowlist (comments and blank lines ignored), entries are paths
# relative to SCRIPTS_DIR (e.g. release/create-tag.sh).
declare -a allowlist=()
if [[ -f "${ALLOWLIST_FILE}" ]]; then
	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -n "$line" ]] && allowlist+=("$line")
	done <"${ALLOWLIST_FILE}"
fi

allowlisted() {
	local candidate="$1"
	local entry
	for entry in "${allowlist[@]+"${allowlist[@]}"}"; do
		if [[ "$entry" == "$candidate" ]]; then
			return 0
		fi
	done
	return 1
}

# A script counts as tested when its basename appears in any .bats file.
is_tested() {
	local base="$1"
	grep -rqF --include='*.bats' -- "$base" "${TESTS_DIR}"
}

declare -a violations=()
declare -a untested=()
declare -a seen_scripts=()
tested_count=0

while IFS= read -r script; do
	rel="${script#"${SCRIPTS_DIR}/"}"
	seen_scripts+=("$rel")
	if is_tested "$(basename "$script")"; then
		tested_count=$((tested_count + 1))
		if allowlisted "$rel"; then
			violations+=("stale allowlist entry (script now has a BATS test, remove it): $rel")
		fi
	else
		untested+=("$rel")
		if ! allowlisted "$rel"; then
			violations+=("new untested script (add a BATS test referencing '$(basename "$script")'): $rel")
		fi
	fi
done < <(find "${SCRIPTS_DIR}" -type f -name '*.sh' -not -path "${SCRIPTS_DIR}/lib/*" | sort)

# Allowlist entries pointing at scripts that no longer exist are stale too.
for entry in "${allowlist[@]+"${allowlist[@]}"}"; do
	found=0
	for rel in "${seen_scripts[@]+"${seen_scripts[@]}"}"; do
		if [[ "$rel" == "$entry" ]]; then
			found=1
			break
		fi
	done
	if [[ "$found" -eq 0 ]]; then
		violations+=("stale allowlist entry (script does not exist, remove it): $entry")
	fi
done

if ((${#violations[@]} > 0)); then
	for violation in "${violations[@]}"; do
		echo "ERROR: ${violation}" >&2
	done
	echo "ERROR: ${#violations[@]} script test coverage violation(s)" >&2
	echo "Allowlist: ${ALLOWLIST_FILE}" >&2
	exit 1
fi

total=$((tested_count + ${#untested[@]}))
echo "OK: script test coverage ratchet satisfied (${tested_count}/${total} entrypoints tested, ${#untested[@]} allowlisted)"
