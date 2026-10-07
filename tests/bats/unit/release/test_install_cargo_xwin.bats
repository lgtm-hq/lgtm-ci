#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/install-cargo-xwin.sh (#1076): the
#          release archive is verified against the sha256 committed in
#          versions.env before cargo-xwin is installed.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/install-cargo-xwin.sh"
VERSIONS_ENV="${PROJECT_ROOT}/scripts/ci/versions.env"

setup() {
	setup_temp_dir
	export CALLS_FILE="${BATS_TEST_TMPDIR}/mock_calls"
	: >"$CALLS_FILE"
	export CARGO_HOME="${BATS_TEST_TMPDIR}/cargo"
	MOCK_BIN="${BATS_TEST_TMPDIR}/mock_bin"
	SERVER_DIR="${BATS_TEST_TMPDIR}/server"
	mkdir -p "$MOCK_BIN" "$SERVER_DIR" "$CARGO_HOME"
	export MOCK_BIN SERVER_DIR

	_mock_uname x86_64 Linux
	cat >"${MOCK_BIN}/cargo" <<EOF
#!/usr/bin/env bash
printf 'cargo %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${MOCK_BIN}/cargo"
	cat >"${MOCK_BIN}/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-o) out="\$2"; shift 2;;
	http*) url="\$1"; shift;;
	*) shift;;
	esac
done
printf 'curl %s\n' "\$url" >>'${CALLS_FILE}'
name="\${url##*/}"
if [[ -f '${SERVER_DIR}'/"\$name" ]]; then cp '${SERVER_DIR}'/"\$name" "\$out"; exit 0; fi
exit 22
EOF
	chmod +x "${MOCK_BIN}/curl"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${MOCK_BIN}/sleep"
	chmod +x "${MOCK_BIN}/sleep"
}

teardown() {
	teardown_temp_dir
}

_mock_uname() {
	local arch="$1" os="$2"
	cat >"${MOCK_BIN}/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
-m) echo "${arch}";;
*) echo "${os}";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"
}

_sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

_version() {
	sed -n 's/^DEFAULT_CARGO_XWIN_VERSION="\([^"]*\)".*/\1/p' "$VERSIONS_ENV"
}

# Publish a fake release archive for TARGET and print its digest.
_publish() {
	local target="${1:-x86_64-unknown-linux-musl}" build="${BATS_TEST_TMPDIR}/build"
	rm -rf "$build"
	mkdir -p "$build"
	printf '#!/usr/bin/env bash\necho cargo-xwin\n' >"${build}/cargo-xwin"
	chmod +x "${build}/cargo-xwin"
	tar -czf "${SERVER_DIR}/cargo-xwin-v$(_version).${target}.tar.gz" -C "$build" cargo-xwin
	_sha256_of "${SERVER_DIR}/cargo-xwin-v$(_version).${target}.tar.gz"
}

_run() {
	run env PATH="${MOCK_BIN}:${PATH}" CARGO_HOME="$CARGO_HOME" "$@" bash "$SCRIPT"
}

@test "install-cargo-xwin: version comes from versions.env, not the script" {
	run grep -E '^DEFAULT_CARGO_XWIN_VERSION="[0-9.]+"' "$VERSIONS_ENV"
	assert_success
	run grep -F 'DEFAULT_CARGO_XWIN_VERSION=' "$SCRIPT"
	assert_failure
	run grep -B1 '^DEFAULT_CARGO_XWIN_VERSION=' "$VERSIONS_ENV"
	assert_output --partial "# renovate: datasource=github-releases depName=rust-cross/cargo-xwin"
}

@test "install-cargo-xwin: versions.env commits a digest for both Linux hosts" {
	run grep -E '^DEFAULT_CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL="[a-f0-9]{64}" # v' "$VERSIONS_ENV"
	assert_success
	run grep -E '^DEFAULT_CARGO_XWIN_SHA256_AARCH64_UNKNOWN_LINUX_MUSL="[a-f0-9]{64}" # v' "$VERSIONS_ENV"
	assert_success
}

@test "install-cargo-xwin: installs the release archive when the digest matches" {
	local digest
	digest="$(_publish)"
	_run CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL="$digest"
	assert_success
	assert_output --partial "sha256 verified against committed CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL"
	[[ -x "${CARGO_HOME}/bin/cargo-xwin" ]]
	run cat "$CALLS_FILE"
	assert_output --partial "releases/download/v$(_version)/cargo-xwin-v$(_version).x86_64-unknown-linux-musl.tar.gz"
	refute_output --partial "cargo install"
}

@test "install-cargo-xwin: aarch64 Linux selects the aarch64 musl archive" {
	_mock_uname aarch64 Linux
	local digest
	digest="$(_publish aarch64-unknown-linux-musl)"
	_run CARGO_XWIN_SHA256_AARCH64_UNKNOWN_LINUX_MUSL="$digest"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "cargo-xwin-v$(_version).aarch64-unknown-linux-musl.tar.gz"
}

@test "install-cargo-xwin: a wrong digest fails the install" {
	_publish >/dev/null
	_run CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL=0000000000000000000000000000000000000000000000000000000000000000
	assert_failure
	assert_output --partial "::error title=digest mismatch::"
	[[ ! -e "${CARGO_HOME}/bin/cargo-xwin" ]]
}

@test "install-cargo-xwin: the committed digest rejects a tampered archive by default" {
	_publish >/dev/null
	_run
	assert_failure
	assert_output --partial "does not match committed CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL"
}

@test "install-cargo-xwin: an archive without the binary is rejected" {
	local build="${BATS_TEST_TMPDIR}/build" digest
	rm -rf "$build"
	mkdir -p "$build"
	printf 'nope\n' >"${build}/README"
	tar -czf "${SERVER_DIR}/cargo-xwin-v$(_version).x86_64-unknown-linux-musl.tar.gz" -C "$build" README
	digest="$(_sha256_of "${SERVER_DIR}/cargo-xwin-v$(_version).x86_64-unknown-linux-musl.tar.gz")"
	_run CARGO_XWIN_SHA256_X86_64_UNKNOWN_LINUX_MUSL="$digest"
	assert_failure
	assert_output --partial "does not contain a cargo-xwin binary"
}

@test "install-cargo-xwin: unsupported host falls back to cargo install --locked" {
	_mock_uname arm64 Darwin
	_run
	assert_success
	assert_output --partial "::notice::no committed digest for cargo-xwin"
	run cat "$CALLS_FILE"
	assert_output --partial "cargo install cargo-xwin --locked --version $(_version)"
}

@test "install-cargo-xwin: workflow installs it only for xwin matrix legs" {
	local wf="${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"
	run grep -F "scripts/ci/release/install-cargo-xwin.sh" "$wf"
	assert_success
	run awk '/- name: Install cargo-xwin/{show=1;next} show&&/- name:/{exit} show{print}' "$wf"
	assert_output --partial "if: matrix.builder == 'xwin'"
}
