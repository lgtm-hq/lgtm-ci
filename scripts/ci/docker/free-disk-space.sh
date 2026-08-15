#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Reclaim unused GitHub-hosted runner disk before Docker builds.
#
# Removes well-known unused ubuntu-24.04 amd64 toolchains and large unused
# $AGENT_TOOLSDIRECTORY entries. Every removal is existence-guarded so the
# script is a no-op on lean images (e.g. ubuntu-24.04-arm).
#
# Environment variables:
#   AGENT_TOOLSDIRECTORY      - Hosted toolcache root (default: /opt/hostedtoolcache)
#   FREE_DISK_FIXED_PATHS     - Space-separated override of the fixed toolchain list
#                               (set, including empty, replaces the defaults)
#   FREE_DISK_TOOLCACHE_NAMES - Space-separated override of unused toolcache entries
#
# Usage:
#   free-disk-space.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

# Unused on ubuntu-24.04 amd64 hosted images; typically absent on ARM/lean VMs.
DEFAULT_FIXED_PATHS=(
	/usr/share/dotnet
	/usr/local/lib/android
	/opt/ghc
	/usr/local/share/powershell
)

# Large hosted-toolcache trees that docker/build-push-action does not use.
DEFAULT_TOOLCACHE_NAMES=(
	CodeQL
	go
	Java_Temurin-Hotspot_jdk
	PyPy
	Python
	Ruby
	node
)

if [[ -n "${FREE_DISK_FIXED_PATHS+x}" ]]; then
	# Intentionally word-split: override is a space-separated path list.
	# shellcheck disable=SC2206
	FIXED_PATHS=(${FREE_DISK_FIXED_PATHS})
else
	FIXED_PATHS=("${DEFAULT_FIXED_PATHS[@]}")
fi

if [[ -n "${FREE_DISK_TOOLCACHE_NAMES+x}" ]]; then
	# shellcheck disable=SC2206
	TOOLCACHE_NAMES=(${FREE_DISK_TOOLCACHE_NAMES})
else
	TOOLCACHE_NAMES=("${DEFAULT_TOOLCACHE_NAMES[@]}")
fi

TOOLCACHE_ROOT="${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"

print_df() {
	local label="$1"
	echo "=== Disk usage (${label}) ==="
	df -h /
}

path_size_kb() {
	local path="$1"
	local size
	size="$(du -sk "$path" 2>/dev/null | awk '{print $1}')" || true
	if [[ -n "$size" ]]; then
		echo "${size}"
	else
		echo "unknown"
	fi
}

remove_path() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		log_info "Skipping missing path: ${path}"
		return 0
	fi

	local size_kb
	size_kb="$(path_size_kb "$path")"
	log_info "Removing ${path} (${size_kb}K)"
	rm -rf -- "$path"
	log_success "Removed ${path} (reclaimed ${size_kb}K)"
}

avail_kb() {
	# Second line, 4th column is available 1K-blocks on GNU and BSD df -k.
	df -k / | awk 'NR==2 {print $4}'
}

print_df "before"
before_kb="$(avail_kb)"

for path in "${FIXED_PATHS[@]+"${FIXED_PATHS[@]}"}"; do
	remove_path "$path"
done

if [[ -d "$TOOLCACHE_ROOT" ]]; then
	for name in "${TOOLCACHE_NAMES[@]+"${TOOLCACHE_NAMES[@]}"}"; do
		remove_path "${TOOLCACHE_ROOT}/${name}"
	done
else
	log_info "Skipping toolcache (not present): ${TOOLCACHE_ROOT}"
fi

print_df "after"
after_kb="$(avail_kb)"

if [[ "$before_kb" =~ ^[0-9]+$ && "$after_kb" =~ ^[0-9]+$ ]]; then
	reclaimed_kb=$((after_kb - before_kb))
	log_info "Available space change: ${reclaimed_kb}K (before=${before_kb}K after=${after_kb}K)"
fi
