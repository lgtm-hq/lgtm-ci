#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/install-osv-scanner.sh
#
# Regression coverage for the download-hardening contract: the osv-scanner
# install downloads must route through the shared hardened curl-args builder
# so they honor the TLS floor AND the opt-in LGTM_CI_CA_BUNDLE /
# LGTM_CI_PINNED_PUBKEY knobs, exactly like every other download path.

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/security/install-osv-scanner.sh"
	setup_temp_dir
	save_path
	export CALLS_FILE="${BATS_TEST_TMPDIR}/mock_calls_curl"
	export INSTALL_DIR="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$INSTALL_DIR"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Build mocks for curl, uname, and sha256sum so the install script can run to
# completion off-Linux without network access.
#
#   curl      - records every argv; serves a fake binary for the binary URL,
#               a checksum line for SHA256SUMS, and fails the .sig/.pem
#               fetches so signature verification is skipped.
#   uname     - reports Linux/x86_64 for a deterministic platform.
#   sha256sum - succeeds on `-c` so the checksum gate passes.
_setup_osv_mocks() {
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"
	: >"$CALLS_FILE"

	local fake_binary="${BATS_TEST_TMPDIR}/fake-osv-scanner"
	printf '#!/usr/bin/env bash\necho "osv-scanner 2.3.5 (mock)"\n' >"$fake_binary"
	chmod +x "$fake_binary"

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${CALLS_FILE}'
url=""
out=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-o) out="\$2"; shift 2;;
	http*|https*) url="\$1"; shift;;
	*) shift;;
	esac
done
case "\$url" in
*SHA256SUMS.sig|*SHA256SUMS.pem) exit 22;;
*_linux_amd64) cp '${fake_binary}' "\$out";;
*SHA256SUMS) printf '%s  osv-scanner_linux_amd64\n' deadbeef >"\$out";;
*) exit 22;;
esac
exit 0
EOF
	chmod +x "${mock_bin}/curl"

	cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-m) echo "x86_64";;
*) echo "Linux";;
esac
EOF
	chmod +x "${mock_bin}/uname"

	cat >"${mock_bin}/sha256sum" <<'EOF'
#!/usr/bin/env bash
# Consume stdin when invoked as `sha256sum -c -` and report success.
[[ "$1" == "-c" ]] && { cat >/dev/null; exit 0; }
exit 0
EOF
	chmod +x "${mock_bin}/sha256sum"

	export MOCK_BIN="$mock_bin"
}

@test "install-osv-scanner: downloads osv-scanner and installs it" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	assert_output --partial "installed to"
	[[ -x "${INSTALL_DIR}/osv-scanner" ]]
}

@test "install-osv-scanner: downloads enforce the HTTPS-only + TLS 1.2 floor" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "--proto =https"
	assert_output --partial "--tlsv1.2"
}

@test "install-osv-scanner: passes custom CA bundle to every download" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	local bundle="${BATS_TEST_TMPDIR}/ca.pem"
	echo "fake-ca" >"$bundle"
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		export LGTM_CI_CA_BUNDLE='${bundle}'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	# Every recorded curl invocation must carry --cacert: no download path may
	# bypass the configured CA bundle.
	run grep -c "^" "$CALLS_FILE"
	local total="$output"
	[[ "$total" -ge 2 ]]
	run grep -cv -- "--cacert ${bundle}" "$CALLS_FILE"
	assert_output "0"
}

@test "install-osv-scanner: passes pinned pubkey to downloads" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		export LGTM_CI_PINNED_PUBKEY='sha256//AAAA'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "--pinnedpubkey sha256//AAAA"
}

@test "install-osv-scanner: no pinning args by default" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	run cat "$CALLS_FILE"
	refute_output --partial "--cacert"
	refute_output --partial "--pinnedpubkey"
}

@test "install-osv-scanner: fails closed on unreadable CA bundle" {
	if ! bash4_available; then
		skip "bash 3 detected - requires bash 4+ (macOS system bash is outdated)"
	fi
	_setup_osv_mocks
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export INSTALL_DIR='${INSTALL_DIR}'
		export LGTM_CI_CA_BUNDLE='/nonexistent/ca.pem'
		bash '$SCRIPT' 2>&1
	"
	assert_failure
	assert_output --partial "CA bundle not readable"
}
