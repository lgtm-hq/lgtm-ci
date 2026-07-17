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
