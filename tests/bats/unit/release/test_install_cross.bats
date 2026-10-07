#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/install-cross.sh (#1096): the release
#          archive is verified against the sha256 committed in versions.env.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/install-cross.sh"
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

	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-m) echo "x86_64";;
*) echo "Linux";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"
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

_sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

_publish() {
	local build="${BATS_TEST_TMPDIR}/build"
	rm -rf "$build"
	mkdir -p "$build"
	printf '#!/usr/bin/env bash\necho cross\n' >"${build}/cross"
	printf '#!/usr/bin/env bash\necho cross-util\n' >"${build}/cross-util"
	chmod +x "${build}/cross" "${build}/cross-util"
	tar -czf "${SERVER_DIR}/cross-x86_64-unknown-linux-gnu.tar.gz" -C "$build" cross cross-util
	_sha256_of "${SERVER_DIR}/cross-x86_64-unknown-linux-gnu.tar.gz"
}

_run() {
	run env PATH="${MOCK_BIN}:${PATH}" CARGO_HOME="$CARGO_HOME" "$@" bash "$SCRIPT"
}

@test "install-cross: version comes from versions.env, not the script" {
	run grep -E '^DEFAULT_CROSS_VERSION="[0-9.]+"' "$VERSIONS_ENV"
	assert_success
	run grep -F 'DEFAULT_CROSS_VERSION=' "$SCRIPT"
	assert_failure
	run grep -B1 '^DEFAULT_CROSS_VERSION=' "$VERSIONS_ENV"
	assert_output --partial "# renovate: datasource=github-releases depName=cross-rs/cross"
}

@test "install-cross: installs the release archive when the digest matches" {
	local version digest
	version="$(sed -n 's/^DEFAULT_CROSS_VERSION="\([^"]*\)".*/\1/p' "$VERSIONS_ENV")"
	digest="$(_publish)"
	_run CROSS_SHA256_X86_64_UNKNOWN_LINUX_GNU="$digest"
	assert_success
	assert_output --partial "sha256 verified against committed CROSS_SHA256_X86_64_UNKNOWN_LINUX_GNU"
	[[ -x "${CARGO_HOME}/bin/cross" ]]
	[[ -x "${CARGO_HOME}/bin/cross-util" ]]
	run cat "$CALLS_FILE"
	assert_output --partial "releases/download/v${version}/cross-x86_64-unknown-linux-gnu.tar.gz"
	refute_output --partial "cargo install"
}

@test "install-cross: a wrong digest fails the install" {
	_publish >/dev/null
	_run CROSS_SHA256_X86_64_UNKNOWN_LINUX_GNU=0000000000000000000000000000000000000000000000000000000000000000
	assert_failure
	assert_output --partial "::error title=digest mismatch::"
	[[ ! -e "${CARGO_HOME}/bin/cross" ]]
}

@test "install-cross: the committed digest rejects a tampered archive by default" {
	_publish >/dev/null
	_run
	assert_failure
	assert_output --partial "does not match committed CROSS_SHA256_X86_64_UNKNOWN_LINUX_GNU"
}

@test "install-cross: unsupported host falls back to cargo install --locked" {
	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-m) echo "aarch64";;
*) echo "Linux";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"
	local version
	version="$(sed -n 's/^DEFAULT_CROSS_VERSION="\([^"]*\)".*/\1/p' "$VERSIONS_ENV")"
	_run
	assert_success
	assert_output --partial "::notice::no committed digest for cross"
	run cat "$CALLS_FILE"
	assert_output --partial "cargo install cross --locked --version ${version}"
}

@test "install-cross: workflow still calls the script" {
	run grep -F "scripts/ci/release/install-cross.sh" \
		"${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"
	assert_success
}
