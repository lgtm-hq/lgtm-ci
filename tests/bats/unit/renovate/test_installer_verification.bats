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
#
# Deliberately not matched: `docker pull` (the image reference is the pin;
# lgtm-ci's own pulls are @sha256 digest refs managed by renovate.json, and
# consumer images are the consumer's) and `npx`/`bunx` (they run packages the
# consumer's lockfile already installed; lgtm-ci never installs through them).
INSTALLER_PATTERN='git clon[e]|cargo instal[l]|cargo binstal[l]|npm instal[l]|npm c[i]( |$)|bun ad[d]|pip instal[l]|uv tool instal[l]|go instal[l]|pipx instal[l]|gem instal[l]|download_with_retrie[s] |(^|[^a-z])cur[l]( [^|]*)? (-o|-O|--output)( |$)|(^|[^a-z])wge[t] '

# Markers that prove a line consumes a committed digest on a hard-fail path.
VERIFY_PATTERN='supply_chain_verify_sha256|supply_chain_verify_commit|sha256sum -c'
# Explicit per-line declarations for installs that are verified some other
# way (lockfile integrity) or deliberately run with a registry trust root.
MARKER_PATTERN='# (unverified-fallback|verified-by): .{12,}'
# A verify call must follow the installer line within this many lines.
VERIFY_WINDOW=12

# Files under ROOT that contain an installer-shaped line.
# Usage: _installer_files ROOT
_installer_files() {
	local root="$1"
	grep -rlE "$INSTALLER_PATTERN" "${root}/scripts/ci" --include='*.sh' |
		sed "s#^${root}/##" |
		grep -v '^scripts/ci/lib/network/download.sh$' |
		grep -v '^scripts/ci/maintenance/refresh-tool-digests.sh$' |
		sort
}

# Print "file:lineno" for every real installer line in FILE: not a comment,
# not a log line, not a curl that discards its body (-o /dev/null) or reads an
# HTTP status (API probes).
# Usage: _installer_lines ROOT FILE
_installer_lines() {
	local root="$1" f="$2"
	grep -nE "$INSTALLER_PATTERN" "${root}/${f}" |
		grep -vE '^[0-9]+:\s*#' |
		grep -vE -- '-o /dev/null' |
		grep -vE 'http_code' |
		cut -d: -f1 |
		sed "s#^#${f}:#"
}

# Does installer line N of FILE satisfy the contract? A non-comment verify
# call within VERIFY_WINDOW lines after it, or a marker on the line itself or
# the three lines above it.
# Usage: _line_verified ROOT FILE N
_line_verified() {
	local root="$1" f="$2" n="$3" from to
	to=$((n + VERIFY_WINDOW))
	if sed -n "${n},${to}p" "${root}/${f}" | grep -vE '^\s*#' | grep -qE "$VERIFY_PATTERN"; then
		return 0
	fi
	from=$((n > 3 ? n - 3 : 1))
	sed -n "${from},${n}p" "${root}/${f}" | grep -qE "$MARKER_PATTERN"
}

# Print every unverified installer line under ROOT that is not allowlisted.
# Usage: _unverified_installers ROOT ALLOWLIST
_unverified_installers() {
	local root="$1" allowlist="$2" f entry n
	local allowed
	allowed="$(grep -vE '^\s*(#|$)' "$allowlist" | cut -d: -f1)"
	while IFS= read -r f; do
		if grep -qxF "$f" <<<"$allowed"; then
			continue
		fi
		while IFS= read -r entry; do
			n="${entry##*:}"
			if ! _line_verified "$root" "$f" "$n"; then
				echo "$entry"
			fi
		done < <(_installer_lines "$root" "$f")
	done < <(_installer_files "$root")
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

@test "installer contract: every installer line verifies a committed digest, carries a marker, or is allowlisted" {
	run _unverified_installers "$PROJECT_ROOT" "$ALLOWLIST"
	assert_success
	assert_output ""
}

# Planted fixtures prove the enumeration catches what it must and accepts
# what it should. Each case is a tiny scripts/ci tree under a temp root.
_plant() {
	local root="$1" name="$2" body="$3"
	mkdir -p "${root}/scripts/ci/x"
	printf '%s\n' "$body" >"${root}/scripts/ci/x/${name}"
	printf '# none\n' >"${root}/allowlist"
}

@test "installer contract: a wget download with no verify call is caught" {
	local root="${BATS_TEST_TMPDIR}/r1"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\nwget "$url" -O "$dest"\ntar -xzf "$dest"'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output "scripts/ci/x/tool.sh:2"
}

@test "installer contract: a bare curl -o download with no verify call is caught" {
	local root="${BATS_TEST_TMPDIR}/r2"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\ncurl -o "$dest" "$url"\ninstall "$dest" /usr/local/bin/tool'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output "scripts/ci/x/tool.sh:2"
}

@test "installer contract: a verify call inside a comment does not count" {
	local root="${BATS_TEST_TMPDIR}/r3"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\ncurl -o "$dest" "$url"\n# supply_chain_verify_sha256 TODO\ninstall "$dest" /usr/local/bin/tool'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output "scripts/ci/x/tool.sh:2"
}

@test "installer contract: a second unverified install branch in a verified file is caught" {
	local root="${BATS_TEST_TMPDIR}/r4"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\ncurl -o "$dest" "$url"\nsupply_chain_verify_sha256 "$dest" TOOL_SHA256_X\n'"$(printf 'x\n%.0s' {1..14})"$'\ncargo install tool --locked'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output "scripts/ci/x/tool.sh:18"
}

@test "installer contract: a verify call within the window satisfies the line" {
	local root="${BATS_TEST_TMPDIR}/r5"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\ncurl -o "$dest" "$url"\nif [[ -f x ]]; then\n  echo y\nfi\nsupply_chain_verify_sha256 "$dest" TOOL_SHA256_X'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output ""
}

@test "installer contract: an explicit marker satisfies the line" {
	local root="${BATS_TEST_TMPDIR}/r6"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\n# unverified-fallback: crates.io trust root on hosts without a digest\ncargo install tool --locked'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output ""
}

@test "installer contract: a marker that is too short to be a reason is rejected" {
	local root="${BATS_TEST_TMPDIR}/r7"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\n# unverified-fallback: tbd\ncargo install tool --locked'
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output "scripts/ci/x/tool.sh:3"
}

@test "installer contract: an allowlisted file is exempt" {
	local root="${BATS_TEST_TMPDIR}/r8"
	_plant "$root" tool.sh $'#!/usr/bin/env bash\npip install something'
	printf 'scripts/ci/x/tool.sh: consumer-owned pins, PyPI trust root\n' >"${root}/allowlist"
	run _unverified_installers "$root" "${root}/allowlist"
	assert_output ""
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
