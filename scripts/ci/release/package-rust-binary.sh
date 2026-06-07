#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Package Rust release binaries per package with SHA256SUMS manifest
#
# Usage:
#   VERSION=1.0.0 TARGET=x86_64-unknown-linux-gnu PACKAGES=cli,server \
#     ARCHIVE_FORMAT=tar.gz scripts/ci/release/package-rust-binary.sh
#
# Optional:
#   BINARY_NAMES  Comma-separated binary names parallel to PACKAGES (defaults via cargo metadata)

set -euo pipefail

VERSION="${VERSION:-}"
TARGET="${TARGET:-}"
PACKAGES="${PACKAGES:-}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-tar.gz}"
BINARY_NAMES="${BINARY_NAMES:-}"

if [[ -z "$VERSION" || -z "$TARGET" || -z "$PACKAGES" ]]; then
	echo "VERSION, TARGET, and PACKAGES are required" >&2
	exit 1
fi

if [[ "$ARCHIVE_FORMAT" != "tar.gz" && "$ARCHIVE_FORMAT" != "zip" ]]; then
	echo "ARCHIVE_FORMAT must be tar.gz or zip" >&2
	exit 1
fi

_resolve_binary_name() {
	local package="$1"
	local index="$2"

	if [[ -n "$BINARY_NAMES" ]]; then
		IFS=',' read -r -a name_list <<<"$BINARY_NAMES"
		if [[ -n "${name_list[$index]:-}" ]]; then
			echo "${name_list[$index]// /}"
			return 0
		fi
	fi

	cargo metadata --format-version=1 --no-deps |
		jq -r --arg pkg "$package" \
			'.packages[] | select(.name == $pkg) | .targets[] | select(.kind[] == "bin") | .name' |
		head -1
}

IFS=',' read -r -a package_list <<<"$PACKAGES"
checksums=()
index=0

for package in "${package_list[@]}"; do
	package="${package// /}"
	if [[ -z "$package" ]]; then
		index=$((index + 1))
		continue
	fi

	bin_name="$(_resolve_binary_name "$package" "$index")"
	if [[ -z "$bin_name" ]]; then
		echo "Could not resolve binary name for package $package" >&2
		exit 1
	fi

	if [[ "$ARCHIVE_FORMAT" == "zip" ]]; then
		bin_path="target/${TARGET}/release/${bin_name}.exe"
	else
		bin_path="target/${TARGET}/release/${bin_name}"
	fi

	if [[ ! -f "$bin_path" ]]; then
		echo "Required binary not found: $bin_path" >&2
		exit 1
	fi

	archive_base="${package}-${VERSION}-${TARGET}"
	staging="${archive_base}"
	rm -rf "$staging"
	mkdir -p "$staging"

	if [[ "$ARCHIVE_FORMAT" == "zip" ]]; then
		cp "$bin_path" "$staging/${bin_name}.exe"
		(
			cd "$staging" && zip -q "../${archive_base}.zip" "${bin_name}.exe"
		)
		archive="${archive_base}.zip"
	else
		cp "$bin_path" "$staging/${bin_name}"
		(
			cd "$staging" && tar czf "../${archive_base}.tar.gz" "${bin_name}"
		)
		archive="${archive_base}.tar.gz"
	fi

	rm -rf "$staging"
	digest="$(sha256sum "$archive" | awk '{print $1}')"
	checksums+=("$digest  $archive")
	echo "Packaged $archive"
	index=$((index + 1))
done

if [[ ${#checksums[@]} -eq 0 ]]; then
	echo "No packages packaged" >&2
	exit 1
fi

checksums_file="SHA256SUMS-${TARGET}"
printf '%s\n' "${checksums[@]}" >"$checksums_file"
echo "Wrote $checksums_file"
