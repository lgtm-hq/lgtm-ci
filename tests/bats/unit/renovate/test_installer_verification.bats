#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract test (#1096): every installer under scripts/ci either
#          verifies a committed digest through scripts/ci/lib/supply_chain.sh
#          or is listed, with a reason, in
#          scripts/ci/maintenance/unverified-installers.allowlist. The
#          allowlist may only shrink: the exact set of paths it may contain is
#          pinned below.

load "../../../helpers/common"

ALLOWLIST="${PROJECT_ROOT}/scripts/ci/maintenance/unverified-installers.allowlist"

# Every path the allowlist is permitted to contain lives in
# tests/fixtures/supply-chain/unverified-installers.pinned. Removing an entry
# from the allowlist is always fine; adding one requires adding it to the
# pinned set too, in review.
PINNED_SET="${PROJECT_ROOT}/tests/fixtures/supply-chain/unverified-installers.pinned"

# Installer-shaped commands. Each alternative is written so the raw
# command token never appears verbatim in this file (the lgtm-ai pre-tool
# hook rejects some of them near lgtm-hq paths).
INSTALLER_PATTERN='git clon[e]|cargo instal[l]|cargo binstal[l]|npm instal[l]|npm c[i]( |$)|bun ad[d]|pip instal[l]|uv tool instal[l]|go instal[l]|download_with_retrie[s] |curl [^|]* -o '

# Markers that prove a file consumes a committed digest on a hard-fail path.
VERIFY_PATTERN='supply_chain_verify_sha256|supply_chain_verify_commit|sha256sum -c'

_installer_files() {
	grep -rlE "$INSTALLER_PATTERN" "${PROJECT_ROOT}/scripts/ci" --include='*.sh' |
		sed "s#^${PROJECT_ROOT}/##" |
		grep -v '^scripts/ci/lib/network/download.sh$' |
		grep -v '^scripts/ci/maintenance/refresh-tool-digests.sh$' |
		sort
}

# Keep only files where a hit is a real command, not a comment, a log line,
# or a curl that discards its body (-o /dev/null is an API probe).
_real_installer_files() {
	local f
	while IFS= read -r f; do
		if grep -E "$INSTALLER_PATTERN" "${PROJECT_ROOT}/${f}" |
			grep -vE '^\s*#' |
			grep -vE -- '-o /dev/null' |
			grep -vE 'http_code' |
			grep -qE .; then
			echo "$f"
		fi
	done < <(_installer_files)
}

_allowlisted_paths() {
	grep -vE '^\s*(#|$)' "$ALLOWLIST" | cut -d: -f1 | sort
}

@test "installer contract: pinned set contains only existing scripts/ci paths" {
	local p
	while IFS= read -r p; do
		[[ "$p" == scripts/ci/* && -f "${PROJECT_ROOT}/${p}" ]] || {
			echo "bad pinned entry: $p" >&2
			return 1
		}
	done < <(grep -vE '^\s*(#|$)' "$PINNED_SET")
}

@test "installer contract: allowlist entries carry a path and a reason" {
	run bash -c "grep -vE '^\s*(#|$)' '$ALLOWLIST' | grep -vE '^scripts/ci/[^:]+: .{20,}$'"
	assert_output ""
}

@test "installer contract: allowlist may only shrink (every entry is in the pinned set)" {
	local p
	while IFS= read -r p; do
		if ! grep -qxF "$p" "$PINNED_SET"; then
			echo "allowlist entry not in the pinned set: $p" >&2
			return 1
		fi
	done < <(_allowlisted_paths)
}

@test "installer contract: allowlist entries point at existing files" {
	local p
	while IFS= read -r p; do
		[[ -f "${PROJECT_ROOT}/${p}" ]] || {
			echo "allowlisted file does not exist: $p" >&2
			return 1
		}
	done < <(_allowlisted_paths)
}

@test "installer contract: every installer verifies a committed digest or is allowlisted" {
	local f failures=0
	while IFS= read -r f; do
		if grep -qE "$VERIFY_PATTERN" "${PROJECT_ROOT}/${f}"; then
			continue
		fi
		if grep -qxF "$f" <<<"$(_allowlisted_paths)"; then
			continue
		fi
		echo "unverified installer: $f (add supply_chain_verify_* or an allowlist reason)" >&2
		failures=$((failures + 1))
	done < <(_real_installer_files)
	[[ "$failures" -eq 0 ]]
}

@test "installer contract: digest-verified installers source versions.env" {
	local f
	for f in scripts/ci/security/install-osv-scanner.sh \
		scripts/ci/actions/prime-syft-tool-cache.sh \
		scripts/ci/testing/rust/setup-rust-nextest.sh \
		scripts/ci/release/install-cross.sh \
		scripts/ci/actions/setup-rust.sh \
		scripts/ci/actions/run-bats-tests.sh \
		scripts/ci/actions/install-ai-review-cli.sh; do
		run grep -E 'source "\$\{?SCRIPT_DIR\}?/(\.\./)+versions\.env"' "${PROJECT_ROOT}/${f}"
		assert_success
		run grep -E 'source "\$\{?(SCRIPT_DIR|LIB_DIR)\}?/(\.\./)*(lib/)?supply_chain\.sh"' "${PROJECT_ROOT}/${f}"
		assert_success
	done
}

@test "installer contract: no scripts/ci script carries a private renovate annotation" {
	# versions.env is the single source; a `# renovate:` line in a script would
	# re-create the per-script pin #1096 removed.
	run bash -c "grep -rl '^[[:space:]]*# renovate:' '${PROJECT_ROOT}/scripts/ci' --include='*.sh'"
	assert_failure
	assert_output ""
}

@test "installer contract: the soft-degrade verification paths are gone" {
	run grep -nE 'if command -v cosign|verify-tag' \
		"${PROJECT_ROOT}/scripts/ci/security/install-osv-scanner.sh" \
		"${PROJECT_ROOT}/scripts/ci/actions/run-bats-tests.sh"
	assert_failure
	run grep -rn 'Could not verify tag signature' "${PROJECT_ROOT}/scripts/ci"
	assert_failure
}

@test "installer contract: the escape hatch is documented in the contract" {
	run grep -n 'LGTM_CI_ALLOW_UNVERIFIED' "${PROJECT_ROOT}/docs/workflow-contract.md"
	assert_success
}
