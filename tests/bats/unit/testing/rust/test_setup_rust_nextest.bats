#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Behavioral tests for scripts/ci/testing/rust/setup-rust-nextest.sh
#          (#1096): release archives are downloaded and verified against the
#          sha256 committed in scripts/ci/versions.env before install.

load "../../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/testing/rust/setup-rust-nextest.sh"
VERSIONS_ENV="${PROJECT_ROOT}/scripts/ci/versions.env"

setup() {
	setup_temp_dir
	export CALLS_FILE="${BATS_TEST_TMPDIR}/mock_calls"
	: >"$CALLS_FILE"
	export CARGO_HOME="${BATS_TEST_TMPDIR}/cargo"
	mkdir -p "$CARGO_HOME/bin"
	MOCK_BIN="${BATS_TEST_TMPDIR}/mock_bin"
	SERVER_DIR="${BATS_TEST_TMPDIR}/server"
	mkdir -p "$MOCK_BIN" "$SERVER_DIR"
	export MOCK_BIN SERVER_DIR

	# Deterministic host: x86_64 Linux.
	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-m) echo "x86_64";;
*) echo "Linux";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"

	# cargo records calls (crates.io fallback must not run on a pinned host).
	cat >"${MOCK_BIN}/cargo" <<EOF
#!/usr/bin/env bash
printf 'cargo %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${MOCK_BIN}/cargo"
	cat >"${MOCK_BIN}/rustup" <<EOF
#!/usr/bin/env bash
printf 'rustup %s\n' "\$*" >>'${CALLS_FILE}'
exit 0
EOF
	chmod +x "${MOCK_BIN}/rustup"

	# curl serves archives out of SERVER_DIR by basename and records URLs.
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

_pin() {
	sed -n "s/^${1}=\"\([^\"]*\)\".*/\1/p" "$VERSIONS_ENV"
}

# Publish a fake release archive for a crate at the pinned version and return
# its sha256 so a test can pass it as the digest override.
_publish() {
	local crate="$1" version="$2" archive build
	build="${BATS_TEST_TMPDIR}/build-${crate}"
	rm -rf "$build"
	mkdir -p "$build"
	printf '#!/usr/bin/env bash\necho "%s %s"\n' "$crate" "$version" >"${build}/${crate}"
	chmod +x "${build}/${crate}"
	case "$crate" in
	cargo-nextest) archive="cargo-nextest-${version}-x86_64-unknown-linux-gnu.tar.gz" ;;
	cargo-llvm-cov) archive="cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz" ;;
	esac
	tar -czf "${SERVER_DIR}/${archive}" -C "$build" "$crate"
	_sha256_of "${SERVER_DIR}/${archive}"
}

_run() {
	run env PATH="${MOCK_BIN}:${PATH}" CARGO_HOME="$CARGO_HOME" "$@" bash "$SCRIPT"
}

@test "setup-rust-nextest: installs the pinned nextest release when the digest matches" {
	local version digest
	version="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	digest="$(_publish cargo-nextest "$version")"
	_run INSTALL_COVERAGE_TOOLS=false CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU="$digest"
	assert_success
	assert_output --partial "sha256 verified against committed CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU"
	[[ -x "${CARGO_HOME}/bin/cargo-nextest" ]]
	run cat "$CALLS_FILE"
	assert_output --partial "releases/download/cargo-nextest-${version}/cargo-nextest-${version}-x86_64-unknown-linux-gnu.tar.gz"
	refute_output --partial "cargo install"
	refute_output --partial "binstall"
}

@test "setup-rust-nextest: a wrong digest fails the install and leaves nothing behind" {
	local version
	version="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	_publish cargo-nextest "$version" >/dev/null
	_run INSTALL_COVERAGE_TOOLS=false \
		CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU=0000000000000000000000000000000000000000000000000000000000000000
	assert_failure
	assert_output --partial "::error title=digest mismatch::"
	[[ ! -e "${CARGO_HOME}/bin/cargo-nextest" ]]
}

@test "setup-rust-nextest: the committed digest is used when no override is set" {
	# The served archive is not the real release, so the committed digest must
	# reject it: proves the default is read from versions.env, not skipped.
	local version
	version="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	_publish cargo-nextest "$version" >/dev/null
	_run INSTALL_COVERAGE_TOOLS=false
	assert_failure
	assert_output --partial "does not match committed CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU"
}

@test "setup-rust-nextest: installs llvm-cov when coverage tools are requested" {
	local nv lv nd ld
	nv="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	lv="$(_pin DEFAULT_CARGO_LLVM_COV_VERSION)"
	nd="$(_publish cargo-nextest "$nv")"
	ld="$(_publish cargo-llvm-cov "$lv")"
	_run INSTALL_COVERAGE_TOOLS=true \
		CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU="$nd" \
		CARGO_LLVM_COV_SHA256_X86_64_UNKNOWN_LINUX_GNU="$ld"
	assert_success
	[[ -x "${CARGO_HOME}/bin/cargo-llvm-cov" ]]
	run cat "$CALLS_FILE"
	assert_output --partial "rustup component add llvm-tools-preview"
	assert_output --partial "releases/download/v${lv}/cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz"
}

@test "setup-rust-nextest: version override without a matching digest is refused" {
	_publish cargo-nextest 0.9.1 >/dev/null
	_run INSTALL_COVERAGE_TOOLS=false CARGO_NEXTEST_VERSION=0.9.1
	assert_failure
	assert_output --partial "version overridden to 0.9.1"
	assert_output --partial "without a matching CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU"
}

@test "setup-rust-nextest: version override with its own digest is installed" {
	local digest
	digest="$(_publish cargo-nextest 0.9.1)"
	_run INSTALL_COVERAGE_TOOLS=false CARGO_NEXTEST_VERSION=0.9.1 \
		CARGO_NEXTEST_SHA256_X86_64_UNKNOWN_LINUX_GNU="$digest"
	assert_success
	run cat "$CALLS_FILE"
	assert_output --partial "cargo-nextest-0.9.1-x86_64-unknown-linux-gnu.tar.gz"
}

@test "setup-rust-nextest: skips when the pinned version is already installed" {
	local version
	version="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	printf '#!/usr/bin/env bash\necho "cargo-nextest %s"\n' "$version" >"${MOCK_BIN}/cargo-nextest"
	chmod +x "${MOCK_BIN}/cargo-nextest"
	_run INSTALL_COVERAGE_TOOLS=false
	assert_success
	assert_output --partial "already installed, skipping"
	run cat "$CALLS_FILE"
	refute_output --partial "curl"
}

@test "setup-rust-nextest: unsupported host falls back to cargo install --locked" {
	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-m) echo "riscv64";;
*) echo "Linux";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"
	local version
	version="$(_pin DEFAULT_CARGO_NEXTEST_VERSION)"
	_run INSTALL_COVERAGE_TOOLS=false
	assert_success
	assert_output --partial "::notice::no committed digest for cargo-nextest"
	run cat "$CALLS_FILE"
	assert_output --partial "cargo install cargo-nextest --locked --force --version ${version}"
}
