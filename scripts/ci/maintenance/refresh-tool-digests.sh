#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compute or verify the committed digests in scripts/ci/versions.env
#          from the upstream release assets at the pinned versions (#1096).
#
# Usage:
#   scripts/ci/maintenance/refresh-tool-digests.sh --check [TOOL ...]
#   scripts/ci/maintenance/refresh-tool-digests.sh --write [TOOL ...]
#
#   --check  download every asset, hash it, and fail when a committed value
#            differs (exit 1). The default.
#   --write  rewrite the DEFAULT_<TOOL>_SHA256_*/_COMMIT values in place.
#   TOOL     restrict to one or more tools (osv-scanner syft cargo-nextest
#            cargo-llvm-cov cross cargo-binstall bats-core bats-support
#            bats-assert bats-file kcov). Default: all.
#
# Pin-time verification (this is where the supplier's own signatures are
# checked, so the runtime installers only ever compare against the committed
# value):
#   osv-scanner    every asset is verified against the release's SLSA
#                  provenance (multiple.intoto.jsonl) with slsa-verifier, then
#                  cross-checked against the upstream SHA256SUMS.
#   syft           checksums.txt is verified with cosign against its Sigstore
#                  bundle, then every asset digest is cross-checked against it.
#   cargo-nextest  the per-asset .sha256 files are cross-checked.
#   cargo-llvm-cov, cross, cargo-binstall  publish no checksum manifest; the
#                  digest is computed from the TLS-downloaded asset.
#   git clones     the tag is resolved to its commit with `git ls-remote`.
#
# slsa-verifier and cosign are hard prerequisites for the tools that use
# them. Set LGTM_CI_ALLOW_UNVERIFIED=1 to downgrade a missing verifier to a
# warning (the digests are then computed from the TLS download only); a
# signature or provenance verification FAILURE is never downgraded.
#
# Network: github.com, objects.githubusercontent.com,
# release-assets.githubusercontent.com, plus Sigstore for the verifiers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$CI_DIR/versions.env}"

# shellcheck source=../lib/log.sh
source "$CI_DIR/lib/log.sh"
# shellcheck source=../lib/network/download.sh
source "$CI_DIR/lib/network/download.sh"
# shellcheck source=../lib/supply_chain.sh
source "$CI_DIR/lib/supply_chain.sh"
# shellcheck source=../versions.env
source "$VERSIONS_FILE"

MODE="check"
TOOLS=()
for arg in "$@"; do
	case "$arg" in
	--check) MODE="check" ;;
	--write) MODE="write" ;;
	-h | --help)
		sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		log_error "Unknown option: $arg"
		exit 2
		;;
	*) TOOLS+=("$arg") ;;
	esac
done
if [[ ${#TOOLS[@]} -eq 0 ]]; then
	TOOLS=(osv-scanner syft cargo-nextest cargo-llvm-cov cross cargo-binstall
		bats-core bats-support bats-assert bats-file kcov)
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/lgtm-ci-digests.XXXXXXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
GH_DL="https://github.com"
FAILURES=0
# Optional per-asset verifier run by asset_digest before hashing:
#   ASSET_VERIFIER <downloaded-file> <asset-name>
ASSET_VERIFIER=""

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

fetch() {
	local url="$1" out="$2"
	log_info "  downloading ${url##*/}"
	if ! download_with_retries "$url" "$out"; then
		log_error "download failed: $url"
		exit 1
	fi
}

# Compare or write one DEFAULT_ variable.
# Usage: record VAR_NAME value
record() {
	local name="$1" value="$2" current
	current="${!name:-}"
	if [[ "$current" == "$value" ]]; then
		log_success "  ${name} unchanged"
		return 0
	fi
	if [[ "$MODE" == "write" ]]; then
		if ! grep -q "^${name}=\"" "$VERSIONS_FILE"; then
			log_error "  ${name} is not declared in ${VERSIONS_FILE}; add the annotated line first"
			FAILURES=$((FAILURES + 1))
			return 0
		fi
		# Replace only the quoted value; the trailing `# <tag>` comment stays.
		sed -i.bak "s|^\(${name}=\"\)[^\"]*\(\"\)|\1${value}\2|" "$VERSIONS_FILE"
		rm -f "${VERSIONS_FILE}.bak"
		log_warn "  ${name} updated: ${current:-<unset>} -> ${value}"
		return 0
	fi
	log_error "  ${name} differs: committed ${current:-<unset>}, upstream ${value}"
	FAILURES=$((FAILURES + 1))
}

# Look up a filename's digest in a checksum manifest ("<hex>  <name>").
manifest_digest() {
	local manifest="$1" filename="$2"
	awk -v fn="$filename" '$2 == fn || $2 == "*" fn { print $1; exit }' "$manifest"
}

# Hash a release asset, run ASSET_VERIFIER on it when set, and cross-check it
# against a manifest when given.
# Usage: asset_digest repo tag asset VAR_NAME [manifest]
asset_digest() {
	local repo="$1" tag="$2" asset="$3" var="$4" manifest="${5:-}"
	local out="$WORKDIR/${repo//\//_}-${asset}" digest listed
	fetch "${GH_DL}/${repo}/releases/download/${tag}/${asset}" "$out"
	if [[ -n "$ASSET_VERIFIER" ]]; then
		"$ASSET_VERIFIER" "$out" "$asset"
	fi
	digest="$(sha256_of "$out")"
	if [[ -n "$manifest" ]]; then
		listed="$(manifest_digest "$manifest" "$asset")"
		if [[ -z "$listed" ]]; then
			log_error "  ${asset} is not listed in the upstream checksum manifest"
			exit 1
		fi
		if [[ "$listed" != "$digest" ]]; then
			log_error "  ${asset}: upstream manifest says ${listed}, download hashes to ${digest}"
			exit 1
		fi
	fi
	rm -f "$out"
	record "$var" "$digest"
}

# cosign verify-blob with a Sigstore bundle (keyless).
# Usage: cosign_verify_bundle blob bundle identity_regexp
cosign_verify_bundle() {
	local blob="$1" bundle="$2" identity="$3"
	supply_chain_require_tool cosign "upstream checksum manifest signature verification" || return 0
	cosign verify-blob \
		--bundle "$bundle" \
		--certificate-identity-regexp="$identity" \
		--certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
		"$blob"
	log_success "  cosign: manifest signature verified"
}

# slsa-verifier for a release asset against the release's SLSA provenance.
# Usage: slsa_verify_asset file asset   (reads SLSA_PROVENANCE, SLSA_SOURCE, SLSA_TAG)
slsa_verify_asset() {
	local file="$1" asset="$2"
	supply_chain_require_tool slsa-verifier "SLSA provenance verification of ${asset}" || return 0
	slsa-verifier verify-artifact "$file" \
		--provenance-path "$SLSA_PROVENANCE" \
		--source-uri "$SLSA_SOURCE" \
		--source-tag "$SLSA_TAG" >/dev/null
	log_success "  slsa-verifier: ${asset} provenance verified"
}

# Resolve a tag to its commit without cloning.
# Usage: tag_commit repo tag VAR_NAME
tag_commit() {
	local repo="$1" tag="$2" var="$3" commit
	# Prefer the dereferenced (^{}) line for annotated tags; fall back to the
	# tag ref itself for lightweight tags.
	commit="$(git ls-remote --tags "${GH_DL}/${repo}.git" "refs/tags/${tag}" "refs/tags/${tag}^{}" |
		awk -v deref="refs/tags/${tag}^{}" -v plain="refs/tags/${tag}" '
			$2 == deref { d = $1 } $2 == plain { p = $1 }
			END { if (d != "") print d; else print p }')"
	if [[ ! "$commit" =~ ^[a-f0-9]{40}$ ]]; then
		log_error "  cannot resolve ${repo} tag ${tag} to a commit"
		exit 1
	fi
	record "$var" "$commit"
}

refresh_osv_scanner() {
	local tag="v${DEFAULT_OSV_SCANNER_VERSION}" base manifest
	base="${GH_DL}/google/osv-scanner/releases/download/${tag}"
	manifest="$WORKDIR/osv-scanner_SHA256SUMS"
	fetch "${base}/osv-scanner_SHA256SUMS" "$manifest"
	SLSA_PROVENANCE="$WORKDIR/osv-scanner.intoto.jsonl"
	SLSA_SOURCE="github.com/google/osv-scanner"
	SLSA_TAG="$tag"
	fetch "${base}/multiple.intoto.jsonl" "$SLSA_PROVENANCE"
	ASSET_VERIFIER=slsa_verify_asset
	asset_digest google/osv-scanner "$tag" osv-scanner_linux_amd64 \
		DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64 "$manifest"
	asset_digest google/osv-scanner "$tag" osv-scanner_linux_arm64 \
		DEFAULT_OSV_SCANNER_SHA256_LINUX_ARM64 "$manifest"
	ASSET_VERIFIER=""
}

refresh_syft() {
	local v="$DEFAULT_SYFT_VERSION" tag base manifest
	tag="v${v}"
	base="${GH_DL}/anchore/syft/releases/download/${tag}"
	manifest="$WORKDIR/syft_${v}_checksums.txt"
	fetch "${base}/syft_${v}_checksums.txt" "$manifest"
	fetch "${base}/syft_${v}_checksums.txt.sigstore.json" "$manifest.sigstore.json"
	cosign_verify_bundle "$manifest" "$manifest.sigstore.json" \
		'https://github\.com/anchore/syft/.*'
	local platform
	for platform in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
		asset_digest anchore/syft "$tag" "syft_${v}_${platform}.tar.gz" \
			"DEFAULT_SYFT_SHA256_$(supply_chain_var_suffix "$platform")" "$manifest"
	done
}

refresh_cargo_nextest() {
	local v="$DEFAULT_CARGO_NEXTEST_VERSION" tag target asset manifest
	tag="cargo-nextest-${v}"
	for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
		universal-apple-darwin x86_64-pc-windows-msvc; do
		asset="cargo-nextest-${v}-${target}.tar.gz"
		manifest="$WORKDIR/${asset}.sha256"
		fetch "${GH_DL}/nextest-rs/nextest/releases/download/${tag}/cargo-nextest-${v}-${target}.sha256" "$manifest"
		asset_digest nextest-rs/nextest "$tag" "$asset" \
			"DEFAULT_CARGO_NEXTEST_SHA256_$(supply_chain_var_suffix "$target")" "$manifest"
	done
}

refresh_cargo_llvm_cov() {
	local tag="v${DEFAULT_CARGO_LLVM_COV_VERSION}" target
	for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
		universal-apple-darwin x86_64-pc-windows-msvc; do
		asset_digest taiki-e/cargo-llvm-cov "$tag" "cargo-llvm-cov-${target}.tar.gz" \
			"DEFAULT_CARGO_LLVM_COV_SHA256_$(supply_chain_var_suffix "$target")"
	done
}

refresh_cross() {
	local tag="v${DEFAULT_CROSS_VERSION}" target
	for target in x86_64-unknown-linux-gnu x86_64-apple-darwin; do
		asset_digest cross-rs/cross "$tag" "cross-${target}.tar.gz" \
			"DEFAULT_CROSS_SHA256_$(supply_chain_var_suffix "$target")"
	done
}

refresh_cargo_binstall() {
	local tag="v${DEFAULT_CARGO_BINSTALL_VERSION}" target ext
	for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
		universal-apple-darwin x86_64-pc-windows-msvc aarch64-pc-windows-msvc; do
		case "$target" in
		*linux*) ext="tgz" ;;
		*) ext="zip" ;;
		esac
		asset_digest cargo-bins/cargo-binstall "$tag" "cargo-binstall-${target}.${ext}" \
			"DEFAULT_CARGO_BINSTALL_SHA256_$(supply_chain_var_suffix "$target")"
	done
}

for tool in "${TOOLS[@]}"; do
	log_info "${tool}"
	case "$tool" in
	osv-scanner) refresh_osv_scanner ;;
	syft) refresh_syft ;;
	cargo-nextest) refresh_cargo_nextest ;;
	cargo-llvm-cov) refresh_cargo_llvm_cov ;;
	cross) refresh_cross ;;
	cargo-binstall) refresh_cargo_binstall ;;
	bats-core) tag_commit bats-core/bats-core "v${DEFAULT_BATS_CORE_VERSION}" DEFAULT_BATS_CORE_COMMIT ;;
	bats-support) tag_commit bats-core/bats-support "$DEFAULT_BATS_SUPPORT_VERSION" DEFAULT_BATS_SUPPORT_COMMIT ;;
	bats-assert) tag_commit bats-core/bats-assert "$DEFAULT_BATS_ASSERT_VERSION" DEFAULT_BATS_ASSERT_COMMIT ;;
	bats-file) tag_commit bats-core/bats-file "$DEFAULT_BATS_FILE_VERSION" DEFAULT_BATS_FILE_COMMIT ;;
	kcov) tag_commit SimonKagstrom/kcov "$DEFAULT_KCOV_VERSION" DEFAULT_KCOV_COMMIT ;;
	*)
		log_error "Unknown tool: $tool"
		exit 2
		;;
	esac
done

if [[ "$FAILURES" -gt 0 ]]; then
	log_error "${FAILURES} committed digest(s) differ from upstream; run with --write to update"
	exit 1
fi
log_success "all committed digests match upstream"
