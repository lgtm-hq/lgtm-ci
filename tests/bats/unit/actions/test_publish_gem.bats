#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/publish-gem.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/publish-gem.sh"

setup() {
	setup_temp_dir
	setup_github_env

	GEM_DIR="${BATS_TEST_TMPDIR}/gem"
	mkdir -p "$GEM_DIR"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

write_gemspec() {
	cat >"${GEM_DIR}/testgem.gemspec" <<'EOF'
Gem::Specification.new do |spec|
  spec.name = "testgem"
  spec.version = "1.2.3"
  spec.summary = "Test gem"
  spec.authors = ["Test"]
end
EOF
}

# Mock gem CLI: "gem build" creates a .gem file, other commands succeed
mock_gem_cli() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gem" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "build" ]]; then
	touch "testgem-1.2.3.gem"
	echo "  Successfully built RubyGem"
	echo "  File: testgem-1.2.3.gem"
fi
exit 0
EOF
	chmod +x "${mock_bin}/gem"
	export PATH="${mock_bin}:$PATH"
}

@test "publish-gem: fails without STEP" {
	run env -u STEP bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "publish-gem: fails on unknown step" {
	STEP="bogus" WORKING_DIRECTORY="$GEM_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}

@test "publish-gem: validate passes for valid gemspec" {
	write_gemspec
	mock_gem_cli

	STEP="validate" WORKING_DIRECTORY="$GEM_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Gemspec valid: testgem@1.2.3"
}

@test "publish-gem: validate fails when no gemspec exists" {
	STEP="validate" WORKING_DIRECTORY="$GEM_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "No gemspec found"
}

@test "publish-gem: validate fails when explicit GEMSPEC is missing" {
	STEP="validate" WORKING_DIRECTORY="$GEM_DIR" GEMSPEC="missing.gemspec" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "No gemspec found"
}

@test "publish-gem: build produces gem file and outputs metadata" {
	write_gemspec
	mock_gem_cli

	STEP="build" WORKING_DIRECTORY="$GEM_DIR" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Built:"

	assert_file_contains "$GITHUB_OUTPUT" "name=testgem"
	assert_file_contains "$GITHUB_OUTPUT" "version=1.2.3"
	assert_file_contains "$GITHUB_OUTPUT" "gem-file=./testgem-1.2.3.gem"
}

@test "publish-gem: publish fails without GEM_FILE" {
	run env -u GEM_FILE STEP="publish" WORKING_DIRECTORY="$GEM_DIR" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "GEM_FILE is required"
}

@test "publish-gem: publish fails when gem file does not exist" {
	STEP="publish" WORKING_DIRECTORY="$GEM_DIR" GEM_FILE="missing.gem" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Gem file not found"
}

@test "publish-gem: publish pushes gem to RubyGems" {
	touch "${GEM_DIR}/testgem-1.2.3.gem"
	mock_command_record "gem" ""

	STEP="publish" WORKING_DIRECTORY="$GEM_DIR" GEM_FILE="testgem-1.2.3.gem" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Published successfully"

	run cat "${BATS_TEST_TMPDIR}/mock_calls_gem"
	assert_output --partial "push testgem-1.2.3.gem"
	assert_file_contains "$GITHUB_OUTPUT" "published=true"
}

@test "publish-gem: summary reports published with URL" {
	STEP="summary" WORKING_DIRECTORY="$GEM_DIR" GEM_NAME="testgem" \
		GEM_VERSION="1.2.3" PUBLISHED="true" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "RubyGems Publishing"
	assert_output --partial "https://rubygems.org/gems/testgem/versions/1.2.3"
}

@test "publish-gem: summary reports dry run" {
	STEP="summary" WORKING_DIRECTORY="$GEM_DIR" GEM_NAME="testgem" \
		GEM_VERSION="1.2.3" DRY_RUN="true" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Dry Run"
}
