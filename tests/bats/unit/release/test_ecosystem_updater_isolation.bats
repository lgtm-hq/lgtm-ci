#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Ecosystem updaters never run caller-controlled code (#1545)
#
# The version-PR job holds the caller's release App token and runs
# scripts/ci/release/ecosystems/*.sh with the caller's checkout as the
# working directory. Each hostile fixture appends to $HOSTILE_IMPORT_MARKER
# when a tool picks it up. Every "never" test is paired with a control that
# shows the plain tool call does pick it up, so an absent marker means
# something.

load "../../../helpers/common"
load "../../../helpers/hostile_caller"

ECOSYSTEMS_DIR="${PROJECT_ROOT}/scripts/ci/release/ecosystems"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
	CALLS="${BATS_TEST_TMPDIR}/calls"
}

teardown() {
	teardown_temp_dir
}

# Put a recording wrapper for <cmd> into ${BATS_TEST_TMPDIR}/rec. It logs its
# arguments to $CALLS and then runs the real <cmd> when one exists, so a call
# that slipped through would still reach the hostile file.
# Usage: recording_wrapper <cmd>
recording_wrapper() {
	local cmd="$1" real
	real="$(command -v "$cmd" || true)"
	mkdir -p "${BATS_TEST_TMPDIR}/rec"
	cat >"${BATS_TEST_TMPDIR}/rec/${cmd}" <<EOF
#!/usr/bin/env bash
echo "${cmd} \$*" >>'${CALLS}'
[[ -n '${real}' ]] && exec '${real}' "\$@"
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/rec/${cmd}"
}

# uv.lock carrying the hostile caller's own package, as uv writes it.
write_hostile_uv_lock() {
	cat >uv.lock <<'EOF'
version = 1
revision = 3
requires-python = ">=3.9"

[[package]]
name = "hostile-caller"
version = "1.0.0"
source = { editable = "." }
EOF
}

# A committed .venv whose interpreter is the hostile script.
write_hostile_venv() {
	hostile_caller_copy venv-python .venv/bin/python
	chmod +x .venv/bin/python
	ln -s python .venv/bin/python3
	printf 'home = /usr/bin\n' >.venv/pyvenv.cfg
}

# A gem whose Gemfile is the hostile one.
write_hostile_gem() {
	hostile_caller_copy Gemfile
	mkdir -p lib/demo
	printf 'module Demo\n  VERSION = "1.0.0"\nend\n' >lib/demo/version.rb
	printf 'PATH\n  remote: .\n  specs:\n    demo (1.0.0)\n\nBUNDLED WITH\n   2.5.0\n' \
		>Gemfile.lock
}

# A crate whose rust-toolchain.toml points rustup at the hostile toolchain.
# rustup only accepts an absolute toolchain path.
write_hostile_crate() {
	mkdir -p src tc/bin
	printf '[package]\nname = "demo"\nversion = "1.0.0"\nedition = "2021"\n' >Cargo.toml
	printf 'fn main() {}\n' >src/main.rs
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	hostile_caller_copy toolchain-cargo tc/bin/cargo
	cp tc/bin/cargo tc/bin/rustc
	chmod +x tc/bin/cargo tc/bin/rustc
	printf '[toolchain]\npath = "%s/tc"\n' "$PWD" >rust-toolchain.toml
}

# True when `cargo` on PATH is the rustup proxy, which reads
# rust-toolchain.toml, and a stable toolchain is installed.
have_rustup_stable() {
	local rustup
	rustup="$(command -v rustup)" || return 1
	[[ "$(command -v cargo)" == "$(dirname "$rustup")/cargo" ]] || return 1
	(cd / && rustup run stable cargo --version) >/dev/null 2>&1
}

# =============================================================================
# python.sh
# =============================================================================

@test "python: never imports a caller tomlkit.py or pip.py" {
	hostile_caller_setup
	run env PATH="${BATS_TEST_TMPDIR}/shim:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/python.sh"
	# Proves python.sh reached its import and install calls, so the marker
	# check below cannot pass on an early exit.
	assert_output --partial "Installing tomlkit"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
}

@test "python: control: plain uv lock runs a caller .venv interpreter" {
	command -v uv >/dev/null 2>&1 || skip "uv not available"
	hostile_caller_setup
	write_hostile_venv
	uv lock --offline >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "venv-python"
}

@test "python: control: uv lock --no-build still imports an in-tree backend" {
	command -v uv >/dev/null 2>&1 || skip "uv not available"
	hostile_caller_setup
	hostile_caller_copy hostile_backend.py
	cat >pyproject.toml <<'EOF'
[project]
name = "hostile-caller"
dynamic = ["version"]
requires-python = ">=3.9"

[build-system]
requires = []
build-backend = "hostile_backend"
backend-path = ["."]
EOF
	uv lock --offline --no-build >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "backend"
}

@test "python: rewrites uv.lock without running uv or a caller .venv" {
	hostile_caller_setup
	hostile_caller_real_tomlkit || skip "tomlkit not available"
	write_hostile_uv_lock
	write_hostile_venv
	recording_wrapper uv
	run env PATH="${BATS_TEST_TMPDIR}/rec:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/python.sh"
	assert_success
	assert_output --partial "Updating own-package version in"
	assert [ ! -e "$CALLS" ]
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	run python3 "${ECOSYSTEMS_DIR}/read-uv-lock-version.py" uv.lock hostile-caller
	assert_output "2.0.0"
}

# =============================================================================
# ruby.sh
# =============================================================================

@test "ruby: control: plain bundle lock evaluates a caller Gemfile" {
	command -v bundle >/dev/null 2>&1 || skip "bundle not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_hostile_gem
	bundle lock --local >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "gemfile"
}

@test "ruby: rewrites Gemfile.lock without running bundle" {
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_hostile_gem
	recording_wrapper bundle
	run env PATH="${BATS_TEST_TMPDIR}/rec:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{"gem":"demo","version-rb":"lib/demo/version.rb"}' \
		bash "${ECOSYSTEMS_DIR}/ruby.sh"
	assert_success
	assert [ ! -e "$CALLS" ]
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	run grep -F "demo (2.0.0)" Gemfile.lock
	assert_success
}

# =============================================================================
# rust.sh
# =============================================================================

# A fake cargo and rustup first on PATH: cargo records the toolchain and
# compiler environment it was given, then its working directory, CARGO_HOME
# (and how many entries it holds) and arguments; rustup records every call
# except `rustup which <tool>`, which answers with the fake directory. Tests
# can check what rust.sh passes without installing anything. For
# `metadata` cargo answers that the manifest's directory is the workspace
# root holding package demo; `generate-lockfile` writes demo 2.0.0 to it.
fake_rust_tools() {
	local fake="${BATS_TEST_TMPDIR}/fake"
	mkdir -p "$fake"
	cat >"${fake}/cargo" <<EOF2
#!/usr/bin/env bash
echo "cargo RUSTUP_TOOLCHAIN=\${RUSTUP_TOOLCHAIN:-} RUSTC=\${RUSTC-unset}" \
	"RUSTC_WRAPPER=\${RUSTC_WRAPPER-unset}" \
	"RUSTC_WORKSPACE_WRAPPER=\${RUSTC_WORKSPACE_WRAPPER-unset}" >>'${CALLS}'
echo "cargo-context cwd=\$PWD home=\${CARGO_HOME-unset}" \
	"home-entries=\$(ls -A "\${CARGO_HOME:-/nonexistent}" 2>/dev/null | wc -l | tr -d ' ')" \
	"args=\$*" >>'${CALLS}'
manifest="\${*: -1}"
case "\$1" in
metadata)
	printf '{"workspace_root":"%s","packages":[{"name":"demo","version":"2.0.0",' \
		"\$(dirname "\$manifest")"
	printf '"manifest_path":"%s"}]}\n' "\$manifest"
	;;
generate-lockfile)
	[[ -n "\${FAKE_CARGO_KEEP_LOCK:-}" ]] && exit 0
	printf 'version = 4\n\n[[package]]\nname = "demo"\nversion = "2.0.0"\n' \
		>"\$(dirname "\$manifest")/Cargo.lock"
	;;
esac
EOF2
	cat >"${fake}/rustup" <<EOF2
#!/usr/bin/env bash
if [[ "\$1" == "which" ]]; then
	echo "${fake}/\$2"
	exit 0
fi
echo "rustup \$* (cwd \$PWD)" >>'${CALLS}'
EOF2
	chmod +x "${fake}/cargo" "${fake}/rustup"
}

# Run rust.sh with the fake tools and no RUSTUP_TOOLCHAIN from the caller.
run_rust_fake() {
	run env -u RUSTUP_TOOLCHAIN PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
}

# A plain crate with a Cargo.lock, and no toolchain file.
write_plain_crate() {
	mkdir -p src
	printf '[package]\nname = "demo"\nversion = "1.0.0"\nedition = "2021"\n' >Cargo.toml
	printf 'fn main() {}\n' >src/main.rs
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
}

# An edition-2024 crate with a local path dependency (so resolution stays
# offline but cargo still asks rustc for the host), whose
# .cargo/config.toml names the hostile compiler under build.<key>. Also
# sets the MSRV-aware fallback resolver.
# Usage: write_wrapper_crate <rustc|rustc-wrapper|rustc-workspace-wrapper>
write_wrapper_crate() {
	local key="$1"
	mkdir -p src dep/src .cargo
	printf '[package]\nname = "dep"\nversion = "0.1.0"\nedition = "2024"\n' >dep/Cargo.toml
	: >dep/src/lib.rs
	cat >Cargo.toml <<'EOF2'
[package]
name = "demo"
version = "1.0.0"
edition = "2024"

[dependencies]
dep = { path = "dep" }
EOF2
	printf 'fn main() {}\n' >src/main.rs
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	hostile_caller_copy rustc-wrapper hostile-rustc
	chmod +x hostile-rustc
	printf '[build]\n%s = "%s/hostile-rustc"\n\n' "$key" "$PWD" >.cargo/config.toml
	printf '[resolver]\nincompatible-rust-versions = "fallback"\n' >>.cargo/config.toml
}

wrapper_control() {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_wrapper_crate "$1"
	env -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER RUSTUP_TOOLCHAIN=stable \
		cargo generate-lockfile --offline >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "rustc-wrapper"
}

wrapper_never() {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_wrapper_crate "$1"
	run env -u RUSTUP_TOOLCHAIN -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	assert_output --partial "Cargo.lock regenerated"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	run grep -A1 -F 'name = "demo"' Cargo.lock
	assert_line 'version = "2.0.0"'
}

# A crate with a local path dependency (offline, but cargo still runs
# `rustc -vV`) and an empty .cargo/config.toml, for tests to add to.
write_dep_crate() {
	mkdir -p src dep/src .cargo
	printf '[package]\nname = "dep"\nversion = "0.1.0"\nedition = "2021"\n' >dep/Cargo.toml
	: >dep/src/lib.rs
	cat >Cargo.toml <<'EOF2'
[package]
name = "demo"
version = "1.0.0"
edition = "2021"

[dependencies]
dep = { path = "dep" }
EOF2
	printf 'fn main() {}\n' >src/main.rs
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	: >.cargo/config.toml
}

# A crate whose .cargo/config.toml [env] forces PATH to a checkout directory
# holding a hostile `rustc`.
write_env_path_crate() {
	write_dep_crate
	hostile_caller_copy rustc-wrapper tools/rustc
	chmod +x tools/rustc
	printf '[env]\nPATH = { value = "%s/tools:/usr/bin:/bin", force = true }\n' "$PWD" \
		>.cargo/config.toml
}

# A crate whose .cargo/config.toml [env] preloads a library built from the
# hostile fixture: DYLD_INSERT_LIBRARIES on macOS, LD_PRELOAD elsewhere.
write_env_preload_crate() {
	local var=LD_PRELOAD
	[[ "$(uname -s)" == "Darwin" ]] && var=DYLD_INSERT_LIBRARIES
	write_dep_crate
	hostile_caller_copy preload.c "${BATS_TEST_TMPDIR}/preload.c"
	cc -shared -fPIC -o hostile-preload.so "${BATS_TEST_TMPDIR}/preload.c" || return 1
	printf '[env]\n%s = "%s/hostile-preload.so"\n' "$var" "$PWD" >.cargo/config.toml
}

# Run rust.sh on the crate in the working directory with the real toolchain,
# then check it never ran caller code and the lock was regenerated.
rust_never() {
	run env -u RUSTUP_TOOLCHAIN -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	assert_output --partial "Cargo.lock regenerated"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	run grep -A1 -F 'name = "demo"' Cargo.lock
	assert_line 'version = "2.0.0"'
}

# What rust.sh used to run: cargo in the checkout with RUSTC=rustc and both
# wrappers cleared. Then expect <marker> to have been written.
# Usage: old_cargo_control <marker-line>
old_cargo_control() {
	env -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER RUSTUP_TOOLCHAIN=stable RUSTC=rustc \
		RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER='' \
		cargo generate-lockfile --offline >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "$1"
}

@test "rust: control: [env] PATH forced in the checkout config runs a caller rustc" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_env_path_crate
	old_cargo_control "rustc-wrapper"
}

@test "rust: never runs a caller rustc through [env] PATH" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_env_path_crate
	rust_never
}

@test "rust: control: [env] preload in the checkout config loads a caller library" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	command -v cc >/dev/null 2>&1 || skip "no C compiler"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_env_preload_crate
	old_cargo_control "preload"
}

@test "rust: never loads a caller library through [env] preload" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	command -v cc >/dev/null 2>&1 || skip "no C compiler"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_env_preload_crate
	rust_never
}

# rust.sh relies on cargo not reading .cargo/config.toml next to the
# --manifest-path when the working directory is elsewhere. The control for
# the same crate run from its own directory is "plain cargo runs a caller
# build.rustc-wrapper".
@test "rust: cargo ignores a config in the manifest directory when run elsewhere" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	mkdir crate elsewhere
	(cd crate && write_wrapper_crate rustc-wrapper)
	(cd elsewhere && env -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		RUSTUP_TOOLCHAIN=stable cargo generate-lockfile --offline \
		--manifest-path ../crate/Cargo.toml)
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	run grep -c '^name = ' crate/Cargo.lock
	assert_output "2"
}

# A workspace whose member crates/app (package demo, the configured
# cargo-toml) has a local path dependency on member crates/dep, with the
# Cargo.lock at the workspace root only, and an empty .cargo/config.toml
# at the root for tests to add to (#1554). resolver = "3" is MSRV-aware, so
# cargo runs `rustc -vV` for the virtual workspace even offline (with "2"
# it does not, and the controls would have nothing to catch).
write_workspace() {
	mkdir -p crates/app/src crates/dep/src .cargo
	printf '[workspace]\nmembers = ["crates/app", "crates/dep"]\nresolver = "3"\n' \
		>Cargo.toml
	cat >crates/app/Cargo.toml <<'EOF2'
[package]
name = "demo"
version = "1.0.0"
edition = "2021"

[dependencies]
dep = { path = "../dep" }
EOF2
	printf 'fn main() {}\n' >crates/app/src/main.rs
	printf '[package]\nname = "dep"\nversion = "0.1.0"\nedition = "2021"\n' \
		>crates/dep/Cargo.toml
	: >crates/dep/src/lib.rs
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	: >.cargo/config.toml
}

# Run rust.sh with the workspace member as cargo-toml and the real toolchain.
run_rust_member() {
	run env -u RUSTUP_TOOLCHAIN -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{"cargo-toml":"crates/app/Cargo.toml"}' \
		bash "${ECOSYSTEMS_DIR}/rust.sh"
}

# Check rust.sh regenerated the root lock with the member's new version,
# wrote no lock beside the member, and never ran caller code.
assert_member_lock_regenerated() {
	assert_success
	assert_output --partial "Cargo.lock regenerated ($(pwd -P)/Cargo.lock)"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	assert [ ! -e crates/app/Cargo.lock ]
	run grep -A1 -F 'name = "demo"' Cargo.lock
	assert_line 'version = "2.0.0"'
	run grep -A1 -F 'name = "dep"' Cargo.lock
	assert_line 'version = "0.1.0"'
}

@test "rust: workspace member: regenerates the root Cargo.lock with the new version" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_workspace
	run_rust_member
	assert_member_lock_regenerated
	run grep -A1 -F '[package]' crates/app/Cargo.toml
	assert_line 'name = "demo"'
}

# Check cargo was only asked for the workspace root: no lock generated.
assert_metadata_only() {
	run cat "$CALLS"
	assert_line --partial "args=metadata --no-deps"
	refute_line --partial "args=generate-lockfile"
}

@test "rust: workspace member without any Cargo.lock: only asks for the workspace" {
	write_workspace
	rm Cargo.lock
	fake_rust_tools
	run env -u RUSTUP_TOOLCHAIN PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{"cargo-toml":"crates/app/Cargo.toml"}' \
		bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	assert_output --partial "crates/app/Cargo.toml updated to 2.0.0"
	assert_output --partial "No Cargo.lock at the workspace root"
	refute_output --partial "Regenerating"
	assert_metadata_only
	assert [ ! -e Cargo.lock ]
}

@test "rust: no Cargo.lock: only asks for the workspace" {
	write_plain_crate
	rm Cargo.lock
	fake_rust_tools
	run_rust_fake
	assert_success
	assert_metadata_only
	assert [ ! -e Cargo.lock ]
}

@test "rust: a lock above a crate that is not its workspace: skips regeneration" {
	write_workspace
	mkdir -p other/src
	printf '[package]\nname = "other"\nversion = "1.0.0"\nedition = "2021"\n' \
		>other/Cargo.toml
	fake_rust_tools
	run env -u RUSTUP_TOOLCHAIN PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{"cargo-toml":"other/Cargo.toml"}' \
		bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	assert_output --partial "No Cargo.lock at the workspace root $(pwd -P)/other; skipping"
	run cat "$CALLS"
	assert_line --partial "args=metadata --no-deps"
	refute_line --partial "args=generate-lockfile"
}

@test "rust: fails closed when cargo cannot determine the workspace" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	write_workspace
	# The root no longer lists the member, so cargo refuses the manifest.
	printf '[workspace]\nmembers = ["crates/dep"]\nresolver = "3"\n' >Cargo.toml
	cp Cargo.lock Cargo.lock.before
	run_rust_member
	assert_failure
	assert_output --partial "::error::[rust] cargo cannot determine the workspace of"
	run cmp Cargo.lock Cargo.lock.before
	assert_success
}

@test "rust: fails when the regenerated lock lacks the new version" {
	write_plain_crate
	fake_rust_tools
	# generate-lockfile leaves the placeholder lock as it was.
	run env -u RUSTUP_TOOLCHAIN FAKE_CARGO_KEEP_LOCK=1 PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_failure
	assert_output --partial "records demo at '', expected 2.0.0"
}

# Run rust.sh with <cargo-toml> and the real toolchain.
# Usage: run_rust_real <cargo-toml>
run_rust_real() {
	run env -u RUSTUP_TOOLCHAIN -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON="{\"cargo-toml\":\"$1\"}" \
		bash "${ECOSYSTEMS_DIR}/rust.sh"
}

# Write <dir>/Cargo.toml for package <name> at <version> and an empty
# src/lib.rs, followed by any further manifest lines given.
# Usage: write_lib_crate <dir> <name> <version> [<line>...]
write_lib_crate() {
	local dir="$1" name="$2" version="$3"
	shift 3
	mkdir -p "$dir/src"
	printf '[package]\nname = "%s"\nversion = "%s"\nedition = "2021"\n' "$name" "$version" \
		>"$dir/Cargo.toml"
	[[ $# -eq 0 ]] || printf '%s\n' "$@" >>"$dir/Cargo.toml"
	: >"$dir/src/lib.rs"
}

@test "rust: fails closed when a symlink takes the workspace root outside the checkout" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	mkdir checkout outside
	cd checkout || return 1
	ln -s ../outside alias
	# cargo reports the root as checkout/alias, lexically inside the checkout.
	write_lib_crate member member 1.0.0 'workspace = "../alias"'
	printf '[workspace]\nmembers = ["../member"]\nresolver = "2"\n' >../outside/Cargo.toml
	printf '# outside lock\nversion = 4\n' >../outside/Cargo.lock
	cp ../outside/Cargo.lock ../outside.lock.before
	# A lock above the member, so the candidate search alone would go ahead.
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	run_rust_real member/Cargo.toml
	assert_failure
	assert_output --partial "::error::[rust] The workspace root of member/Cargo.toml"
	assert_output --partial "physically $(cd ../outside && pwd -P)) is outside the checkout"
	refute_output --partial "Regenerating"
	run cmp ../outside/Cargo.lock ../outside.lock.before
	assert_success
}

@test "rust: fails closed when the root Cargo.lock links outside the checkout" {
	mkdir checkout
	printf '# outside lock\nversion = 4\n' >outside.lock
	cp outside.lock outside.lock.before
	cd checkout || return 1
	write_plain_crate
	rm Cargo.lock
	ln -s ../outside.lock Cargo.lock
	fake_rust_tools
	run_rust_fake
	assert_failure
	assert_output --partial "Cargo.lock is a symlink to '$(cd .. && pwd -P)/outside.lock'"
	assert_output --partial "outside the checkout"
	assert_metadata_only
	run cmp ../outside.lock ../outside.lock.before
	assert_success
}

@test "rust: regenerates a root Cargo.lock that links inside the checkout" {
	write_plain_crate
	mkdir locks
	mv Cargo.lock locks/Cargo.lock
	ln -s locks/Cargo.lock Cargo.lock
	fake_rust_tools
	run_rust_fake
	assert_success
	assert [ -L Cargo.lock ]
	run grep -A1 -F 'name = "demo"' locks/Cargo.lock
	assert_line 'version = "2.0.0"'
}

@test "rust: a path dependency sharing the package name keeps its own version" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	write_lib_crate . app 1.0.0 '' '[dependencies]' \
		'old = { path = "vendor/app", package = "app" }' '' '[workspace]' \
		'exclude = ["vendor/app"]'
	write_lib_crate vendor/app app 0.1.0
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	run_rust_real Cargo.toml
	assert_success
	assert_output --partial "Cargo.lock regenerated"
	run grep -A1 -F 'name = "app"' Cargo.lock
	assert_line 'version = "2.0.0"'
	assert_line 'version = "0.1.0"'
}

@test "rust: regenerates the lock of a sibling workspace the member points to" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_lib_crate member member 1.0.0 'workspace = "../ws"'
	mkdir ws
	printf '[workspace]\nmembers = ["../member"]\nresolver = "2"\n' >ws/Cargo.toml
	printf '# placeholder lock\nversion = 4\n' >ws/Cargo.lock
	run_rust_real member/Cargo.toml
	assert_success
	assert_output --partial "Cargo.lock regenerated ($(pwd -P)/ws/Cargo.lock)"
	assert [ ! -e member/Cargo.lock ]
	assert [ ! -e Cargo.lock ]
	run grep -A1 -F 'name = "member"' ws/Cargo.lock
	assert_line 'version = "2.0.0"'
}

@test "rust: fails when another member pins the released version" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	printf '[workspace]\nmembers = ["app", "lib"]\nresolver = "2"\n' >Cargo.toml
	write_lib_crate app app 1.0.0 '[dependencies]' \
		'lib = { path = "../lib", version = "1.0.0" }'
	write_lib_crate lib lib 1.0.0
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	cp Cargo.lock Cargo.lock.before
	run_rust_real lib/Cargo.toml
	assert_failure
	assert_output --partial "cargo generate-lockfile failed"
	run cmp Cargo.lock Cargo.lock.before
	assert_success
}

@test "rust: warns and skips when cargo cannot read a crate with no Cargo.lock" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	write_workspace
	rm Cargo.lock
	printf '[workspace]\nmembers = ["crates/dep"]\nresolver = "3"\n' >Cargo.toml
	run_rust_member
	assert_success
	assert_output --partial "::warning::[rust] cargo cannot determine the workspace of"
	assert_output --partial "the checkout holds no Cargo.lock"
	assert [ ! -e Cargo.lock ]
}

@test "rust: fails closed when cargo cannot read a member of a locked sibling workspace" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	# ws lists a member that does not exist, so `cargo metadata` fails; the
	# lock sits in a sibling, not above the member, and must not go stale.
	write_lib_crate member member 1.0.0 'workspace = "../ws"'
	mkdir ws
	printf '[workspace]\nmembers = ["../member", "../missing"]\nresolver = "2"\n' \
		>ws/Cargo.toml
	printf 'version = 4\n\n[[package]]\nname = "member"\nversion = "1.0.0"\n' >ws/Cargo.lock
	cp ws/Cargo.lock lock.before
	run_rust_real member/Cargo.toml
	assert_failure
	assert_output --partial "::error::[rust] cargo cannot determine the workspace of"
	assert_output --partial "whether ws/Cargo.lock or another Cargo.lock"
	refute_output --partial "::warning::"
	run cmp ws/Cargo.lock lock.before
	assert_success
}

@test "rust: a lock in the release tooling's checkout does not count as the caller's" {
	write_plain_crate
	rm Cargo.lock
	# Copy the tooling into the checkout, as the workflow's .lgtm-ci-tooling.
	mkdir -p .lgtm-ci-tooling/scripts/ci
	cp -R "${PROJECT_ROOT}/scripts/ci/release" "${PROJECT_ROOT}/scripts/ci/lib" \
		.lgtm-ci-tooling/scripts/ci/
	printf 'version = 4\n' >.lgtm-ci-tooling/Cargo.lock
	fake_rust_tools
	# metadata answers with no workspace_root, as when cargo cannot read it.
	printf '#!/usr/bin/env bash\n[[ "$1" == metadata ]] && exit 101\nexit 0\n' \
		>"${BATS_TEST_TMPDIR}/fake/cargo"
	run env -u RUSTUP_TOOLCHAIN PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' \
		bash .lgtm-ci-tooling/scripts/ci/release/ecosystems/rust.sh
	assert_success
	assert_output --partial "the checkout holds no Cargo.lock"
}

@test "rust: a member listed through a symlinked directory: regenerates the root lock" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	# The root lists `alias`, alias -> real: cargo reports alias/Cargo.toml
	# and only accepts the member through that lexical path.
	write_lib_crate real member 1.0.0
	ln -s real alias
	printf '[workspace]\nmembers = ["alias"]\nresolver = "2"\n' >Cargo.toml
	printf '# placeholder lock\nversion = 4\n' >Cargo.lock
	run_rust_real alias/Cargo.toml
	assert_success
	assert_output --partial "Cargo.lock regenerated ($(pwd -P)/Cargo.lock)"
	assert [ ! -e real/Cargo.lock ]
	run grep -A1 -F 'name = "member"' Cargo.lock
	assert_line 'version = "2.0.0"'
}

@test "rust: package.workspace through a symlink in the checkout: regenerates its lock" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	# alias -> ws, inside the checkout. cargo reports the root as alias and
	# refuses to regenerate through ws/Cargo.toml ("member of the wrong
	# workspace"); the lexical root works.
	write_lib_crate member member 1.0.0 'workspace = "../alias"'
	mkdir ws
	ln -s ws alias
	printf '[workspace]\nmembers = ["../member"]\nresolver = "2"\n' >ws/Cargo.toml
	printf '# placeholder lock\nversion = 4\n' >ws/Cargo.lock
	run_rust_real member/Cargo.toml
	assert_success
	assert_output --partial "Cargo.lock regenerated ($(pwd -P)/ws/Cargo.lock)"
	assert [ ! -e member/Cargo.lock ]
	run grep -A1 -F 'name = "member"' ws/Cargo.lock
	assert_line 'version = "2.0.0"'
}

@test "rust: fails closed on a cargo-toml with a trailing newline" {
	write_plain_crate
	cp Cargo.toml Cargo.toml.before
	fake_rust_tools
	run env -u RUSTUP_TOOLCHAIN PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" NEXT_VERSION=2.0.0 \
		ECOSYSTEM_CONFIG_JSON='{"cargo-toml":"Cargo.toml\n"}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_failure
	assert_output --partial "::error::[rust] cargo-toml must be a string path without newlines"
	run cmp Cargo.toml Cargo.toml.before
	assert_success
	assert [ ! -e "$CALLS" ]
}

@test "rust: fails closed when cargo's metadata names a root with a trailing newline" {
	write_plain_crate
	cp Cargo.lock Cargo.lock.before
	fake_rust_tools
	# metadata reports `<dir>\n` as the root (a JSON-escaped newline).
	cat >"${BATS_TEST_TMPDIR}/fake/cargo" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == metadata ]] || exit 0
printf '{"workspace_root":"%s\\n","packages":[]}\n' "$(dirname "${*: -1}")"
EOF2
	run_rust_fake
	assert_failure
	assert_output --partial "workspace root for Cargo.toml that holds a newline"
	run cmp Cargo.lock Cargo.lock.before
	assert_success
}

@test "rust: control: plain cargo in a workspace root runs its build.rustc-wrapper" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_workspace
	hostile_caller_copy rustc-wrapper hostile-rustc
	chmod +x hostile-rustc
	printf '[build]\nrustc-wrapper = "%s/hostile-rustc"\n' "$PWD" >.cargo/config.toml
	(cd crates/app && env -u RUSTC -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
		RUSTUP_TOOLCHAIN=stable cargo generate-lockfile --offline >/dev/null 2>&1) || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "rustc-wrapper"
}

@test "rust: workspace member: never runs a root build.rustc-wrapper" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_workspace
	hostile_caller_copy rustc-wrapper hostile-rustc
	chmod +x hostile-rustc
	printf '[build]\nrustc-wrapper = "%s/hostile-rustc"\n' "$PWD" >.cargo/config.toml
	run_rust_member
	assert_member_lock_regenerated
}

# Put a hostile `rustc` in tools/ and force PATH to it from the workspace
# root's .cargo/config.toml [env].
write_workspace_env_path() {
	write_workspace
	hostile_caller_copy rustc-wrapper tools/rustc
	chmod +x tools/rustc
	printf '[env]\nPATH = { value = "%s/tools:/usr/bin:/bin", force = true }\n' "$PWD" \
		>.cargo/config.toml
}

@test "rust: control: [env] PATH in a workspace root config runs a caller rustc" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_workspace_env_path
	old_cargo_control "rustc-wrapper"
}

@test "rust: workspace member: never runs a caller rustc through root [env] PATH" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_workspace_env_path
	run_rust_member
	assert_member_lock_regenerated
}

@test "rust: control: plain cargo runs a caller rust-toolchain.toml path" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_hostile_crate
	env -u RUSTUP_TOOLCHAIN cargo generate-lockfile >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "toolchain-cargo"
}

@test "rust: refuses a caller rust-toolchain.toml path and never runs it" {
	have_rustup_stable || skip "rustup with a stable toolchain not available"
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	write_hostile_crate
	run env -u RUSTUP_TOOLCHAIN NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' \
		bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_failure
	assert_output --partial "::error::[rust] rust-toolchain.toml sets [toolchain] path"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
}

@test "rust: control: plain cargo runs a caller build.rustc" {
	wrapper_control rustc
}

@test "rust: never runs a caller build.rustc" {
	wrapper_never rustc
}

@test "rust: control: plain cargo runs a caller build.rustc-wrapper" {
	wrapper_control rustc-wrapper
}

@test "rust: never runs a caller build.rustc-wrapper" {
	wrapper_never rustc-wrapper
}

@test "rust: control: plain cargo runs a caller build.rustc-workspace-wrapper" {
	wrapper_control rustc-workspace-wrapper
}

@test "rust: never runs a caller build.rustc-workspace-wrapper" {
	wrapper_never rustc-workspace-wrapper
}

@test "rust: overrides the compiler and wrappers for cargo" {
	write_plain_crate
	fake_rust_tools
	run env RUSTC=/caller/rustc RUSTC_WRAPPER=/caller/w RUSTC_WORKSPACE_WRAPPER=/caller/ww \
		RUSTUP_TOOLCHAIN=stable PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	run cat "$CALLS"
	# Workspace discovery (index 0) and lock regeneration (index 2) alike.
	assert_line --index 0 "cargo RUSTUP_TOOLCHAIN=stable RUSTC=${BATS_TEST_TMPDIR}/fake/rustc \
RUSTC_WRAPPER= RUSTC_WORKSPACE_WRAPPER="
	assert_line --index 2 "cargo RUSTUP_TOOLCHAIN=stable RUSTC=${BATS_TEST_TMPDIR}/fake/rustc \
RUSTC_WRAPPER= RUSTC_WORKSPACE_WRAPPER="
}

@test "rust: runs cargo outside the checkout with an empty CARGO_HOME" {
	write_plain_crate
	fake_rust_tools
	run env CARGO_HOME="${HOME}/.cargo" RUSTUP_TOOLCHAIN=stable \
		PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	# cargo gets the lexical path ($PWD), not the physical one (pwd -P).
	run cat "$CALLS"
	assert_line --index 1 --regexp \
		"^cargo-context cwd=(.*) home=(.*) home-entries=0 args=metadata --no-deps \
--format-version 1 --manifest-path ${PWD}/Cargo.toml$"
	assert_line --index 3 --regexp \
		"^cargo-context cwd=(.*) home=(.*) home-entries=0 args=generate-lockfile \
--manifest-path ${PWD}/Cargo.toml$"
	local i
	for i in 1 3; do
		refute_line --index "$i" --partial "cwd=${BATS_TEST_TMPDIR} "
		refute_line --index "$i" --partial "cwd=$(pwd -P) "
		refute_line --index "$i" --partial "home=${HOME}/.cargo "
	done
}

@test "rust: no toolchain file: stable, nothing installed" {
	write_plain_crate
	fake_rust_tools
	run_rust_fake
	assert_success
	run cat "$CALLS"
	assert_output --partial "cargo RUSTUP_TOOLCHAIN=stable "
	refute_output --partial "rustup"
}

@test "rust: a job-set RUSTUP_TOOLCHAIN wins over the toolchain file" {
	write_plain_crate
	printf '[toolchain]\nchannel = "1.94.0"\n' >rust-toolchain.toml
	fake_rust_tools
	run env RUSTUP_TOOLCHAIN=1.90.0 PATH="${BATS_TEST_TMPDIR}/fake:${PATH}" \
		NEXT_VERSION=2.0.0 ECOSYSTEM_CONFIG_JSON='{}' bash "${ECOSYSTEMS_DIR}/rust.sh"
	assert_success
	run cat "$CALLS"
	assert_output --partial "cargo RUSTUP_TOOLCHAIN=1.90.0 "
	refute_output --partial "rustup"
}

@test "rust: honours a pinned official channel in rust-toolchain.toml" {
	local channel
	for channel in 1.94.0 1.94 stable beta nightly nightly-2026-01-15 \
		1.94.0-x86_64-unknown-linux-gnu stable-aarch64-apple-darwin \
		nightly-2026-01-01-x86_64-unknown-linux-gnu 1.95.0-beta.2 1.95.0-beta \
		beta-2026-01-01 stable-x86_64-pc-windows-msvc; do
		rm -rf ./* "$CALLS"
		write_plain_crate
		printf '[toolchain]\nchannel = "%s"\ncomponents = ["clippy"]\n' "$channel" \
			>rust-toolchain.toml
		fake_rust_tools
		run_rust_fake
		assert_success
		run cat "$CALLS"
		assert_line --index 0 --regexp \
			"^rustup toolchain install --profile minimal --no-self-update ${channel} \(cwd .*\)$"
		refute_line --index 0 --partial "(cwd ${BATS_TEST_TMPDIR})"
		assert_line --index 1 --partial "cargo RUSTUP_TOOLCHAIN=${channel} "
	done
}

@test "rust: honours a legacy one-line rust-toolchain file" {
	write_plain_crate
	printf '1.94.0\n' >rust-toolchain
	fake_rust_tools
	run_rust_fake
	assert_success
	run cat "$CALLS"
	assert_line --index 1 --partial "cargo RUSTUP_TOOLCHAIN=1.94.0 "
}

@test "rust: a toolchain file without a channel means stable" {
	write_plain_crate
	printf '[toolchain]\ncomponents = ["rustfmt"]\n' >rust-toolchain.toml
	fake_rust_tools
	run_rust_fake
	assert_success
	run cat "$CALLS"
	assert_output --partial "cargo RUSTUP_TOOLCHAIN=stable "
	refute_output --partial "rustup"
}

@test "rust: refuses a path toolchain before running cargo or rustup" {
	write_hostile_crate
	fake_rust_tools
	run_rust_fake
	assert_failure
	assert_output --partial "cannot run in the release job"
	assert [ ! -e "$CALLS" ]
}

@test "rust: refuses a channel that is not an official name" {
	local channel
	for channel in path my-linked-toolchain '1.94.0; touch pwned' nightly-26-01-15 \
		'stable x86_64-unknown-linux-gnu' stable/../x stable-x86_64 stable-x86_64-linux \
		1.94.0-X86_64-unknown-linux-gnu stable-a-b-c-d-e 1.94.0-mytoolchain \
		1.94.0-beta.x stable-2026-01-01-; do
		rm -rf ./* "$CALLS"
		write_plain_crate
		printf '[toolchain]\nchannel = "%s"\n' "$channel" >rust-toolchain.toml
		fake_rust_tools
		run_rust_fake
		assert_failure
		assert_output --partial "pins channel '${channel}', which is not an official"
		assert [ ! -e "$CALLS" ]
	done
}

@test "rust: refuses an unreadable or ambiguous toolchain file" {
	write_plain_crate
	printf '[toolchain\nchannel = \n' >rust-toolchain.toml
	fake_rust_tools
	run_rust_fake
	assert_failure
	assert_output --partial "Cannot read the toolchain from rust-toolchain.toml"
	printf '[toolchain]\nchannel = "stable"\n' >rust-toolchain.toml
	printf 'stable\n' >rust-toolchain
	run_rust_fake
	assert_failure
	assert_output --partial "Both rust-toolchain and rust-toolchain.toml exist"
	assert [ ! -e "$CALLS" ]
}
