#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/setup-rust.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/setup-rust.sh"
	setup_temp_dir
	save_path
	export CARGO_HOME="${BATS_TEST_TMPDIR}/cargo"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Create a curl mock that records calls and serves a tgz archive containing
# a fake cargo-binstall binary
create_binstall_curl_mock() {
	local mock_bin="${BATS_TEST_TMPDIR}/mock_bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_curl"
	: >"$calls_file"

	# Build a real tgz with a cargo-binstall executable
	local archive_dir="${BATS_TEST_TMPDIR}/archive_content"
	mkdir -p "$archive_dir"
	printf '#!/usr/bin/env bash\necho "cargo-binstall mock"\n' >"$archive_dir/cargo-binstall"
	chmod +x "$archive_dir/cargo-binstall"
	local archive_file="${BATS_TEST_TMPDIR}/cargo-binstall.tgz"
	tar -czf "$archive_file" -C "$archive_dir" cargo-binstall

	cat >"${mock_bin}/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
output_file=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) output_file="\$2"; shift 2;;
        *) shift;;
    esac
done
if [[ -n "\$output_file" ]]; then
    cp '${archive_file}' "\$output_file"
fi
exit 0
EOF
	chmod +x "${mock_bin}/curl"
	export MOCK_BIN="$mock_bin"
}

@test "setup-rust: binstall step downloads pinned release binary" {
	create_binstall_curl_mock

	# Mock uname for a deterministic target triple
	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -m) echo "x86_64";;
    *) echo "Linux";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"

	# Restricted PATH: mocks first, no ~/.cargo/bin (so cargo-binstall is
	# "not installed")
	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export STEP=binstall
		export CARGO_HOME='$CARGO_HOME'
		bash '$SCRIPT' 2>&1
	"
	assert_success
	assert_output --partial "Installing cargo-binstall"
	assert_output --partial "installed to"

	# Binary installed to CARGO_HOME/bin
	[[ -x "$CARGO_HOME/bin/cargo-binstall" ]]

	# Requested URL is the release pinned to the version literal in the script
	local pinned_version
	pinned_version=$(grep -oE 'CARGO_BINSTALL_VERSION="[0-9.]+"' "$SCRIPT" | grep -oE '[0-9.]+')
	[[ -n "$pinned_version" ]]

	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output --partial "releases/download/v${pinned_version}/cargo-binstall-x86_64-unknown-linux-musl.tgz"
	refute_output --partial "/main/"
	refute_output --partial "install-from-binstall-release.sh"
}

@test "setup-rust: binstall step skips install when cargo-binstall present" {
	create_binstall_curl_mock

	# Provide a cargo-binstall on PATH
	cat >"${MOCK_BIN}/cargo-binstall" <<'EOF'
#!/usr/bin/env bash
echo "cargo-binstall 1.0.0"
EOF
	chmod +x "${MOCK_BIN}/cargo-binstall"

	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export STEP=binstall
		bash '$SCRIPT' 2>&1
	"
	assert_success
	assert_output --partial "already installed"

	# curl must not have been invoked
	run cat "$BATS_TEST_TMPDIR/mock_calls_curl"
	assert_output ""
}

@test "setup-rust: binstall step fails on unsupported OS" {
	create_binstall_curl_mock

	cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -m) echo "x86_64";;
    *) echo "SunOS";;
esac
EOF
	chmod +x "${MOCK_BIN}/uname"

	run bash -c "
		export PATH='${MOCK_BIN}:/usr/bin:/bin'
		export STEP=binstall
		bash '$SCRIPT' 2>&1
	"
	assert_failure
	assert_output --partial "Unsupported OS"
}

@test "setup-rust: pinned version carries a renovate comment" {
	run bash -c "grep -B1 'CARGO_BINSTALL_VERSION=' '$SCRIPT' | head -2"
	assert_success
	assert_output --partial "renovate: datasource=github-releases depName=cargo-bins/cargo-binstall"
}

@test "setup-rust: does not pipe remote content to a shell" {
	run grep -nE '^[^#]*curl[^|#]*\|[[:space:]]*(ba)?sh' "$SCRIPT"
	assert_failure
}

@test "setup-rust: rejects unknown step" {
	run bash -c "STEP=bogus bash '$SCRIPT' 2>&1"
	assert_failure
	assert_output --partial "Unknown step"
}
