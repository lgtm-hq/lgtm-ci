#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Pre-install Syft into the Actions tool cache with a retried,
#          checksum-verified download so a transient GitHub CDN 5xx cannot
#          fail the whole SBOM job (#697).
#
# Why this exists:
#   anchore/sbom-action downloads Syft via anchore's install.sh, which has no
#   retry. A single 504 from the release CDN writes the HTML error page to the
#   tarball path, the checksum verify then fails, and the SBOM job dies —
#   taking every downstream consumer release job with it.
#
#   sbom-action v0.24.0 resolves Syft through @actions/tool-cache
#   (`cache.find("syft", version)`) BEFORE downloading; it does NOT honour a
#   syft binary that merely sits on PATH. So the only way to pre-empt its
#   download is to populate the tool cache in the layout tool-cache expects:
#
#     $RUNNER_TOOL_CACHE/syft/<version>/<node-arch>/syft
#     $RUNNER_TOOL_CACHE/syft/<version>/<node-arch>.complete
#
#   The resolved version is emitted as the `syft-version` output so the caller
#   can pass it straight to sbom-action's `syft-version` input. That keeps the
#   two in lockstep by construction rather than by a hand-maintained mirror.
#
# Fail-closed contract:
#   - Transport failures (5xx, connection reset, curl-detected truncation) are
#     retried with exponential backoff by download_with_retries.
#   - The archive must match the sha256 committed in scripts/ci/versions.env
#     (DEFAULT_SYFT_SHA256_<OS>_<ARCH>, #1096). The upstream checksums.txt and
#     its Sigstore bundle are verified at pin time by
#     scripts/ci/maintenance/refresh-tool-digests.sh, not fetched here.
#   - A checksum mismatch on a fully downloaded artifact fails IMMEDIATELY with
#     no retry. A truncation that curl cannot detect is indistinguishable from
#     tampering, so it is treated as tampering and fails closed.
#
# Environment variables:
#   RUNNER_TOOL_CACHE - required; set by the GitHub Actions runner
#   SYFT_VERSION      - optional; overrides the pinned default (requires the
#                       matching SYFT_SHA256_<OS>_<ARCH>, or
#                       LGTM_CI_ALLOW_UNVERIFIED=1)
#   SYFT_DOWNLOAD_BASE_URL - optional; override for tests
#   SYFT_DOWNLOAD_ATTEMPTS - optional; download attempts (default 3)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/network.sh
source "$SCRIPT_DIR/../lib/network.sh"
# shellcheck source=../lib/platform.sh
source "$SCRIPT_DIR/../lib/platform.sh"
# shellcheck source=../lib/supply_chain.sh
source "$SCRIPT_DIR/../lib/supply_chain.sh"
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

SYFT_DOWNLOAD_BASE_URL="${SYFT_DOWNLOAD_BASE_URL:-https://github.com/anchore/syft/releases/download}"
SYFT_DOWNLOAD_ATTEMPTS="${SYFT_DOWNLOAD_ATTEMPTS:-3}"

# Normalise to a bare semver (no leading v); tool-cache stores semver.clean()
version="${SYFT_VERSION:-$DEFAULT_SYFT_VERSION}"
version="${version#v}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
	log_error "Invalid Syft version: ${version} (expected semver, e.g. 1.42.3)"
	exit 1
fi

# Publish the resolved version first so the caller can pin sbom-action to it
# even on the early-return paths below.
set_github_output "syft-version" "v${version}"

os="$(detect_os)"
if [[ "$os" == "windows" ]]; then
	# sbom-action uses a separate zip workaround on Windows that does not read
	# the same tool-cache entry. Leave it alone rather than guess.
	log_warn "Windows runner detected; leaving Syft install to sbom-action"
	exit 0
fi

case "$(detect_arch)" in
x86_64)
	goarch="amd64"
	# Node's os.arch(), which @actions/tool-cache uses for the cache path
	node_arch="x64"
	;;
arm64)
	goarch="arm64"
	node_arch="arm64"
	;;
*)
	log_warn "Unsupported architecture $(detect_arch); leaving Syft install to sbom-action"
	exit 0
	;;
esac

: "${RUNNER_TOOL_CACHE:?RUNNER_TOOL_CACHE is required (set by the Actions runner)}"

# @actions/tool-cache keys the directory on semver.clean(), whose `.version`
# drops build metadata (`1.42.3+ci` -> `1.42.3`). The release asset and the
# version we hand back to sbom-action keep the full string, but the cache path
# must not, or cache.find() would look somewhere we never wrote.
cache_version="${version%%+*}"
tool_dir="${RUNNER_TOOL_CACHE}/syft/${cache_version}/${node_arch}"
marker="${tool_dir}.complete"

if [[ -x "${tool_dir}/syft" && -f "$marker" ]]; then
	log_info "Syft v${version} already in the tool cache: ${tool_dir}"
	exit 0
fi

archive_name="syft_${version}_${os}_${goarch}.tar.gz"
archive_url="${SYFT_DOWNLOAD_BASE_URL}/v${version}/${archive_name}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/lgtm-syft.XXXXXXXXXX")"
trap 'rm -rf "$workdir"' EXIT

log_info "Downloading ${archive_url}"
if ! download_with_retries "$archive_url" "${workdir}/${archive_name}" \
	"$SYFT_DOWNLOAD_ATTEMPTS"; then
	echo "::error::Failed to download ${archive_name} after ${SYFT_DOWNLOAD_ATTEMPTS} attempts" >&2
	exit 1
fi

# Deliberately NOT retried: a mismatch here means the bytes we hold are not the
# release artifact. Retrying would turn a tamper signal into a flaky one.
supply_chain_verify_sha256 "${workdir}/${archive_name}" \
	"SYFT_SHA256_$(supply_chain_var_suffix "${os}_${goarch}")" \
	"$version" "$DEFAULT_SYFT_VERSION"

log_info "Checksum verified for ${archive_name}"

if ! tar -xzf "${workdir}/${archive_name}" -C "$workdir" syft; then
	echo "::error::Failed to extract syft from ${archive_name}" >&2
	exit 1
fi

# Install atomically-ish: populate the directory, then write the .complete
# marker last so a half-written cache entry is never considered valid.
rm -rf "$tool_dir" "$marker"
mkdir -p "$tool_dir"
mv "${workdir}/syft" "${tool_dir}/syft"
chmod +x "${tool_dir}/syft"
touch "$marker"

log_success "Primed Syft v${version} tool cache at ${tool_dir}"
