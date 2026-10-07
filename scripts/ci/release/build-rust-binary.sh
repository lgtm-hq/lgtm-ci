#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build release binaries for a Rust target with the builder the
#          matrix entry names (cargo, cross, or cargo-xwin)
#
# Usage:
#   TARGET=x86_64-unknown-linux-gnu PACKAGES=cli,server \
#     scripts/ci/release/build-rust-binary.sh
#
# Optional:
#   BUILDER    native (cargo, default), cross, or xwin (cargo-xwin, MSVC
#              targets only). Validated before anything is built (#1076).
#   USE_CROSS  legacy; "true" selects cross when BUILDER is unset.
#
# Exit codes: 1 missing inputs; 2 builder/target combination rejected.

set -euo pipefail

TARGET="${TARGET:-}"
PACKAGES="${PACKAGES:-}"
BUILDER="${BUILDER:-}"

if [[ -z "$TARGET" || -z "$PACKAGES" ]]; then
	echo "TARGET and PACKAGES are required" >&2
	exit 1
fi

if [[ -z "$BUILDER" ]]; then
	if [[ "${USE_CROSS:-}" == "true" ]]; then
		BUILDER="cross"
	else
		BUILDER="native"
	fi
fi

case "$BUILDER" in
native)
	BUILD_CMD=(cargo)
	;;
cross)
	if [[ "$TARGET" == *-msvc ]]; then
		# cross ships no MSVC toolchain image; this pairing has never built
		# (#1076). Fail here, before cargo runs, with the fix in the message.
		echo "::error title=builder::cross cannot build MSVC targets; use builder=xwin or a native Windows runner (target ${TARGET})" >&2
		exit 2
	fi
	BUILD_CMD=(cross)
	;;
xwin)
	if [[ "$TARGET" != *-pc-windows-msvc ]]; then
		echo "::error title=builder::xwin only builds *-pc-windows-msvc targets (target ${TARGET}); use builder=native or builder=cross" >&2
		exit 2
	fi
	# Restrict the SDK/CRT download to the target's architecture: the xwin
	# default fetches x86_64 and aarch64 together.
	if [[ -z "${XWIN_ARCH:-}" ]]; then
		export XWIN_ARCH="${TARGET%%-*}"
	fi
	BUILD_CMD=(cargo xwin)
	;;
*)
	echo "::error title=builder::unknown BUILDER '${BUILDER}'; expected native, cross or xwin" >&2
	exit 2
	;;
esac

IFS=',' read -r -a package_list <<<"$PACKAGES"
for package in "${package_list[@]}"; do
	package="${package// /}"
	[[ -z "$package" ]] && continue
	echo "Building $package with ${BUILD_CMD[*]} for target $TARGET"
	"${BUILD_CMD[@]}" build --release --target "$TARGET" -p "$package"
done
