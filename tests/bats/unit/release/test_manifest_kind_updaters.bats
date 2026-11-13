#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/ecosystems kind updaters + runner

load "../../../helpers/common"

ECOSYSTEMS_DIR="${PROJECT_ROOT}/scripts/ci/release/ecosystems"
RUNNER="${ECOSYSTEMS_DIR}/_manifests_runner.sh"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# raw
# =============================================================================

@test "raw: rewrites VERSION file" {
	printf '1.0.0\n' >VERSION
	run env NEXT_VERSION=2.3.4 MANIFEST_PATH=VERSION bash "${ECOSYSTEMS_DIR}/raw.sh"
	assert_success
	assert_equal "$(tr -d '[:space:]' <VERSION)" "2.3.4"
}

@test "raw: is idempotent" {
	printf '9.9.9\n' >VERSION
	run env NEXT_VERSION=9.9.9 MANIFEST_PATH=VERSION bash "${ECOSYSTEMS_DIR}/raw.sh"
	assert_success
	run env NEXT_VERSION=9.9.9 MANIFEST_PATH=VERSION bash "${ECOSYSTEMS_DIR}/raw.sh"
	assert_success
	assert_equal "$(tr -d '[:space:]' <VERSION)" "9.9.9"
}

@test "raw: accepts prerelease version" {
	printf '1.0.0\n' >VERSION
	run env NEXT_VERSION=1.0.1-rc.1 MANIFEST_PATH=VERSION bash "${ECOSYSTEMS_DIR}/raw.sh"
	assert_success
	assert_equal "$(tr -d '[:space:]' <VERSION)" "1.0.1-rc.1"
}

@test "raw: fails when file missing" {
	run env NEXT_VERSION=1.0.0 MANIFEST_PATH=VERSION bash "${ECOSYSTEMS_DIR}/raw.sh"
	assert_failure
	assert_output --partial "not found"
}

# =============================================================================
# npm
# =============================================================================

@test "npm: updates package.json version" {
	printf '{\n  "name": "demo",\n  "version": "0.1.0"\n}\n' >package.json
	run env NEXT_VERSION=0.2.0 MANIFEST_PATH=package.json bash "${ECOSYSTEMS_DIR}/npm.sh"
	assert_success
	assert_equal "$(jq -r '.version' package.json)" "0.2.0"
}

@test "npm: is idempotent" {
	printf '{\n  "name": "demo",\n  "version": "3.0.0"\n}\n' >package.json
	run env NEXT_VERSION=3.0.0 MANIFEST_PATH=package.json bash "${ECOSYSTEMS_DIR}/npm.sh"
	assert_success
	run env NEXT_VERSION=3.0.0 MANIFEST_PATH=package.json bash "${ECOSYSTEMS_DIR}/npm.sh"
	assert_success
	assert_equal "$(jq -r '.version' package.json)" "3.0.0"
}

@test "npm: accepts prerelease version" {
	printf '{\n  "name": "demo",\n  "version": "1.0.0"\n}\n' >package.json
	run env NEXT_VERSION=1.0.0-beta.2 MANIFEST_PATH=package.json bash "${ECOSYSTEMS_DIR}/npm.sh"
	assert_success
	assert_equal "$(jq -r '.version' package.json)" "1.0.0-beta.2"
}

# =============================================================================
# gemspec
# =============================================================================

@test "gemspec: updates literal .version assignment" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.name = "demo"
  spec.version = "0.1.0"
end
EOF
	run env NEXT_VERSION=0.2.0 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_success
	run grep -F 'spec.version = "0.2.0"' demo.gemspec
	assert_success
}

@test "gemspec: is idempotent" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.version = "1.2.3"
end
EOF
	run env NEXT_VERSION=1.2.3 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_success
	run env NEXT_VERSION=1.2.3 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_success
	run grep -F 'spec.version = "1.2.3"' demo.gemspec
	assert_success
}

@test "gemspec: accepts prerelease version" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.version = "1.0.0"
end
EOF
	run env NEXT_VERSION=1.0.0-rc.1 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_success
	run grep -F 'spec.version = "1.0.0-rc.1"' demo.gemspec
	assert_success
}

@test "gemspec: rejects constant-backed version" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.version = Demo::VERSION
end
EOF
	run env NEXT_VERSION=1.0.0 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_failure
	assert_output --partial "no literal"
}

@test "gemspec: ignores commented .version lines" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  # spec.version = "9.9.9"
  spec.version = "1.0.0"
end
EOF
	run env NEXT_VERSION=1.1.0 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_success
	run grep -F '# spec.version = "9.9.9"' demo.gemspec
	assert_success
	run grep -F 'spec.version = "1.1.0"' demo.gemspec
	assert_success
}

@test "gemspec: rejects multiple literal .version assignments" {
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.version = "1.0.0"
end
Gem::Specification.new do |spec|
  spec.version = "2.0.0"
end
EOF
	run env NEXT_VERSION=3.0.0 MANIFEST_PATH=demo.gemspec bash "${ECOSYSTEMS_DIR}/gemspec.sh"
	assert_failure
	assert_output --partial "expected exactly one"
}

# =============================================================================
# pep621
# =============================================================================

@test "pep621: updates [project].version" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not installed"
	fi
	cat >pyproject.toml <<'EOF'
[project]
name = "demo"
version = "0.1.0"
EOF
	run env NEXT_VERSION=0.3.0 MANIFEST_PATH=pyproject.toml bash "${ECOSYSTEMS_DIR}/pep621.sh"
	assert_success
	run grep -F 'version = "0.3.0"' pyproject.toml
	assert_success
}

@test "pep621: is idempotent" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not installed"
	fi
	cat >pyproject.toml <<'EOF'
[project]
name = "demo"
version = "2.0.0"
EOF
	run env NEXT_VERSION=2.0.0 MANIFEST_PATH=pyproject.toml bash "${ECOSYSTEMS_DIR}/pep621.sh"
	assert_success
	run env NEXT_VERSION=2.0.0 MANIFEST_PATH=pyproject.toml bash "${ECOSYSTEMS_DIR}/pep621.sh"
	assert_success
	run grep -F 'version = "2.0.0"' pyproject.toml
	assert_success
}

@test "pep621: accepts prerelease version" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not installed"
	fi
	cat >pyproject.toml <<'EOF'
[project]
name = "demo"
version = "1.0.0"
EOF
	run env NEXT_VERSION=1.0.0-alpha.1 MANIFEST_PATH=pyproject.toml bash "${ECOSYSTEMS_DIR}/pep621.sh"
	assert_success
	run grep -F 'version = "1.0.0-alpha.1"' pyproject.toml
	assert_success
}

# =============================================================================
# manifests runner
# =============================================================================

@test "manifests runner: updates multiple kinds in one pass" {
	if ! python3 -c 'import tomlkit' 2>/dev/null; then
		skip "tomlkit not installed"
	fi
	printf '1.0.0\n' >VERSION
	printf '{\n  "name": "demo",\n  "version": "1.0.0"\n}\n' >package.json
	cat >demo.gemspec <<'EOF'
Gem::Specification.new do |spec|
  spec.version = "1.0.0"
end
EOF
	cat >pyproject.toml <<'EOF'
[project]
name = "demo"
version = "1.0.0"
EOF
	local manifests='{"VERSION":"raw","package.json":"npm","demo.gemspec":"gemspec","pyproject.toml":"pep621"}'
	run env NEXT_VERSION=1.1.0 MANIFESTS="$manifests" bash "$RUNNER"
	assert_success
	assert_equal "$(tr -d '[:space:]' <VERSION)" "1.1.0"
	assert_equal "$(jq -r '.version' package.json)" "1.1.0"
	run grep -F 'spec.version = "1.1.0"' demo.gemspec
	assert_success
	run grep -F 'version = "1.1.0"' pyproject.toml
	assert_success
}

@test "manifests runner: rejects unknown kinds" {
	printf '1.0.0\n' >VERSION
	run env NEXT_VERSION=1.0.1 MANIFESTS='{"VERSION":"cargo"}' bash "$RUNNER"
	assert_failure
	assert_output --partial "Unknown kind"
}

@test "manifests runner: rejects non-object manifests" {
	run env NEXT_VERSION=1.0.0 MANIFESTS='["VERSION"]' bash "$RUNNER"
	assert_failure
	assert_output --partial "not a valid JSON object"
}

@test "manifests runner: rejects empty manifests object" {
	run env NEXT_VERSION=1.0.0 MANIFESTS='{}' bash "$RUNNER"
	assert_failure
	assert_output --partial "at least one"
}

# =============================================================================
# path containment (#1356)
# =============================================================================

# Lay out a caller checkout (repo/) next to a file outside it (outside/):
#   repo/nested/dir/VERSION            normal manifest
#   repo/link-dir -> ../outside        parent-directory symlink
#   repo/link-file -> ../outside/VERSION
#   repo/.lgtm-ci-tooling/.../check-version-files-changed.sh
#   repo/.git/VERSION
# Every target starts as "1.0.0" so a rejected run can be shown not to touch it.
_containment_setup() {
	OUTSIDE="${BATS_TEST_TMPDIR}/outside"
	REPO="${BATS_TEST_TMPDIR}/repo"
	TOOL_SCRIPT="${REPO}/.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh"
	mkdir -p "$OUTSIDE" "${REPO}/nested/dir" "$(dirname "$TOOL_SCRIPT")" "${REPO}/.git"
	for target in "${OUTSIDE}/VERSION" "${REPO}/nested/dir/VERSION" "$TOOL_SCRIPT" \
		"${REPO}/.git/VERSION"; do
		printf '1.0.0\n' >"$target"
	done
	ln -s ../outside "${REPO}/link-dir"
	ln -s ../outside/VERSION "${REPO}/link-file"
	cd "$REPO" || return 1
}

# _assert_rejected PATH TARGET REASON: the runner refuses PATH, names it and
# the reason in an ::error, and leaves TARGET as it was.
_assert_rejected() {
	run env NEXT_VERSION=2.0.0 MANIFESTS="{\"$1\":\"raw\"}" bash "$RUNNER"
	assert_failure
	assert_output --partial "::error title=unsafe manifest path::$1: $3"
	refute_output --partial "Updating"
	assert_equal "$(cat "$2")" "1.0.0"
}

@test "manifests runner: rejects a parent-directory symlink out of the checkout" {
	_containment_setup
	_assert_rejected "link-dir/VERSION" "${OUTSIDE}/VERSION" "'link-dir' is a symlink"
}

@test "manifests runner: rejects a symlinked manifest file" {
	_containment_setup
	_assert_rejected "link-file" "${OUTSIDE}/VERSION" "'link-file' is a symlink"
}

@test "manifests runner: rejects a '..' escape" {
	_containment_setup
	_assert_rejected "../outside/VERSION" "${OUTSIDE}/VERSION" "'..' segments are not allowed"
}

@test "manifests runner: rejects an absolute path" {
	_containment_setup
	_assert_rejected "${OUTSIDE}/VERSION" "${OUTSIDE}/VERSION" "absolute paths are not allowed"
}

@test "manifests runner: rejects a path into the tooling checkout" {
	_containment_setup
	_assert_rejected ".lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh" \
		"$TOOL_SCRIPT" "resolves into the protected directory .lgtm-ci-tooling"
}

@test "manifests runner: rejects a path into .git" {
	_containment_setup
	_assert_rejected "./.git/VERSION" "${REPO}/.git/VERSION" \
		"resolves into the protected directory .git"
}

@test "manifests runner: rejects every manifest when one path is unsafe" {
	_containment_setup
	run env NEXT_VERSION=2.0.0 \
		MANIFESTS='{"nested/dir/VERSION":"raw","link-dir/VERSION":"raw"}' bash "$RUNNER"
	assert_failure
	assert_equal "$(cat nested/dir/VERSION)" "1.0.0"
	assert_equal "$(cat "${OUTSIDE}/VERSION")" "1.0.0"
}

@test "manifests runner: updates a normal nested path" {
	_containment_setup
	run env NEXT_VERSION=2.0.0 MANIFESTS='{"nested/dir/VERSION":"raw"}' bash "$RUNNER"
	assert_success
	refute_output --partial "::error"
	assert_equal "$(tr -d '[:space:]' <nested/dir/VERSION)" "2.0.0"
	assert_equal "$(cat "${OUTSIDE}/VERSION")" "1.0.0"
}

# =============================================================================
# caller-module isolation (#1356)
# =============================================================================

HOSTILE_CALLER="${PROJECT_ROOT}/tests/fixtures/release/hostile-caller"

# Copy the hostile caller checkout (tomlkit.py, pip.py) into the test dir and
# put a python3 shim first on PATH. The shim forwards every call to the real
# python3 from the same working directory, so caller modules resolve exactly
# as they would. It makes `-c 'import tomlkit'` report "missing" after the
# real import ran, and turns `-m pip install` into a network-free
# `-m pip --version`, so both lookups happen without installing anything.
_hostile_caller_setup() {
	cp "${HOSTILE_CALLER}/tomlkit.py" "${HOSTILE_CALLER}/pip.py" \
		"${HOSTILE_CALLER}/pyproject.toml" .
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	REAL_PYTHON3="$(command -v python3)"
	export REAL_PYTHON3
	mkdir -p "${BATS_TEST_TMPDIR}/shim"
	cat >"${BATS_TEST_TMPDIR}/shim/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "import tomlkit" ]]; then
	"$REAL_PYTHON3" "$@" >/dev/null 2>&1
	exit 1
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
	"$REAL_PYTHON3" -m pip --version >/dev/null 2>&1
	exit 0
fi
exec "$REAL_PYTHON3" "$@"
EOF
	chmod +x "${BATS_TEST_TMPDIR}/shim/python3"
}

@test "hostile caller fixture: plain python3 -c/-m from the checkout imports it" {
	_hostile_caller_setup
	python3 -c 'import tomlkit' 2>/dev/null || true
	python3 -m pip --version >/dev/null 2>&1 || true
	run cat "$HOSTILE_IMPORT_MARKER"
	assert_success
	assert_line "tomlkit"
	assert_line "pip"
}

@test "pep621: never imports a caller tomlkit.py or pip.py" {
	_hostile_caller_setup
	run env PATH="${BATS_TEST_TMPDIR}/shim:${PATH}" NEXT_VERSION=2.0.0 \
		MANIFEST_PATH=pyproject.toml bash "${ECOSYSTEMS_DIR}/pep621.sh"
	assert_output --partial "Installing tomlkit"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
}

@test "manifests runner: pep621 never imports caller modules" {
	_hostile_caller_setup
	run env PATH="${BATS_TEST_TMPDIR}/shim:${PATH}" NEXT_VERSION=2.0.0 \
		MANIFESTS='{"pyproject.toml":"pep621"}' bash "$RUNNER"
	assert [ ! -e "$HOSTILE_IMPORT_MARKER" ]
	# The update itself needs the real tomlkit, which may be absent locally
	# (checked from / so the hostile copy here does not answer).
	if (cd / && "$REAL_PYTHON3" -c 'import tomlkit' 2>/dev/null); then
		assert_success
		run grep -F 'version = "2.0.0"' pyproject.toml
		assert_success
	fi
}


@test "manifests runner: TOOLING_DIR is protected in any spelling (./x, x//, absolute)" {
	_containment_setup
	mkdir -p custom
	local dir
	for dir in ./custom custom// "$PWD/custom"; do
		printf '1.0.0\n' >custom/tool.sh
		run env NEXT_VERSION=2.0.0 TOOLING_DIR="$dir" \
			MANIFESTS='{"custom/tool.sh":"raw"}' bash "$RUNNER"
		assert_failure
		assert_output --partial "resolves into the protected directory custom"
		assert_equal "$(cat custom/tool.sh)" "1.0.0"
	done
}

@test "manifests runner: rejects C1 control characters in keys" {
	_containment_setup
	run env NEXT_VERSION=2.0.0 \
		MANIFESTS="$(printf '{"nested/dir/VERSION\xc2\x85":"raw"}')" bash "$RUNNER"
	assert_failure
	assert_output --partial "must not contain control characters"
	assert_equal "$(cat nested/dir/VERSION)" "1.0.0"
}
