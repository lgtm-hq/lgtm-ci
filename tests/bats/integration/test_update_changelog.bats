#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/release/update-changelog.sh

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# =============================================================================
# Helpers
# =============================================================================

# Create a mock repo with a CHANGELOG.md and a remote
setup_changelog_repo() {
	setup_mock_git_repo || return 1
	cd "$MOCK_GIT_REPO" || return 1

	local bare_dir="${BATS_TEST_TMPDIR}/bare.git"
	git init -q --bare "$bare_dir" || return 1
	git remote add origin "$bare_dir" || return 1
	git push -q origin HEAD:main 2>/dev/null || return 1
}

# Write a changelog file with the given content
write_changelog() {
	local content="$1"
	printf '%s' "$content" >"${MOCK_GIT_REPO}/CHANGELOG.md"
}

# Run update-changelog.sh with the given version and body
run_update_changelog() {
	local version="${1:-1.0.0}"
	local body="${2:-}"
	local changelog_file="${MOCK_GIT_REPO}/CHANGELOG.md"

	# Write body to a temp file to avoid single-quote escaping issues
	local body_file
	body_file=$(mktemp "${BATS_TEST_TMPDIR}/changelog-body.XXXXXX") || {
		echo "mktemp failed for changelog body file" >&2
		return 1
	}
	if [[ -z "$body_file" || ! -e "$body_file" ]]; then
		echo "body_file is empty or does not exist: '$body_file'" >&2
		rm -f "$body_file"
		return 1
	fi
	printf '%s' "$body" >"$body_file"

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export VERSION='$version'
		export CHANGELOG_BODY=\"\$(cat '$body_file')\"
		export CHANGELOG_FILE='$changelog_file'
		export TAG_PREFIX='v'
		export REPO_URL='https://github.com/test-org/test-repo'
		export PUSH='false'
		'$PROJECT_ROOT/scripts/ci/release/update-changelog.sh' 2>&1
	"
	rm -f "$body_file"
}

# =============================================================================
# Tests: duplicate header prevention
# =============================================================================

@test "update-changelog: does not produce duplicate version headers" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD'

	run_update_changelog "1.0.0" "### Features

- add new feature (abc1234)"
	assert_success

	# Count occurrences of the version header
	local count
	count=$(grep -c '## \[1\.0\.0\]' "${MOCK_GIT_REPO}/CHANGELOG.md")
	[[ "$count" -eq 1 ]] || {
		echo "Expected exactly 1 version header, found $count" >&2
		cat "${MOCK_GIT_REPO}/CHANGELOG.md" >&2
		return 1
	}
}

# =============================================================================
# Tests: preserve existing unreleased entries
# =============================================================================

@test "update-changelog: preserves hand-curated unreleased entries" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

- Existing feature one ([#1])
- Existing feature two ([#2])

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD
[#1]: https://github.com/test-org/test-repo/pull/1
[#2]: https://github.com/test-org/test-repo/pull/2'

	run_update_changelog "1.0.0" "### Features

- new auto-generated entry (def5678)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# Existing entries should be present in the versioned section
	echo "$changelog" | grep -q 'Existing feature one' || fail "'Existing feature one' not found in changelog"
	echo "$changelog" | grep -q 'Existing feature two' || fail "'Existing feature two' not found in changelog"

	# Auto-generated entry should also be present
	echo "$changelog" | grep -q 'new auto-generated entry' || fail "'new auto-generated entry' not found in changelog"
}

@test "update-changelog: preserves unreleased entries even without generated content" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

- Manual entry ([#5])

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD
[#5]: https://github.com/test-org/test-repo/pull/5'

	# Empty generated body — existing entries should still appear
	run_update_changelog "1.0.0" ""
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")
	echo "$changelog" | grep -q 'Manual entry' || fail "'Manual entry' not found in changelog"
}

# =============================================================================
# Tests: preserve reference links
# =============================================================================

@test "update-changelog: preserves PR reference links" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

- Feature A ([#10])
- Feature B ([#20])

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD
[#10]: https://github.com/test-org/test-repo/pull/10
[#20]: https://github.com/test-org/test-repo/pull/20'

	run_update_changelog "1.0.0" "### Features

- auto feature (aaa1111)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# PR reference links must be preserved
	echo "$changelog" | grep -q '\[#10\]: https://github.com/test-org/test-repo/pull/10' || {
		echo "Missing [#10] reference link" >&2
		echo "$changelog" >&2
		return 1
	}
	echo "$changelog" | grep -q '\[#20\]: https://github.com/test-org/test-repo/pull/20' || {
		echo "Missing [#20] reference link" >&2
		echo "$changelog" >&2
		return 1
	}
}

@test "update-changelog: updates Unreleased comparison link" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD'

	run_update_changelog "1.0.0" "### Features

- a feature (abc1234)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# Unreleased link should point to the new tag
	echo "$changelog" | grep -q '\[Unreleased\]: https://github.com/test-org/test-repo/compare/v1.0.0...HEAD' || {
		echo "Unreleased link not updated correctly" >&2
		echo "$changelog" >&2
		return 1
	}

	# Version comparison link should exist
	echo "$changelog" | grep -q '\[1\.0\.0\]:' || {
		echo "Missing version comparison link" >&2
		echo "$changelog" >&2
		return 1
	}
}

# =============================================================================
# Tests: first release (no prior tags)
# =============================================================================

@test "update-changelog: handles first release from v0.0.0" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

- Initial feature ([#1])

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD
[#1]: https://github.com/test-org/test-repo/pull/1'

	run_update_changelog "0.1.0" "### Features

- auto feature (bbb2222)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# Should have a clean [Unreleased] section
	echo "$changelog" | grep -q '## \[Unreleased\]' || fail "'## [Unreleased]' not found in changelog"

	# Should have the versioned section
	echo "$changelog" | grep -q '## \[0\.1\.0\]' || fail "'## [0.1.0]' not found in changelog"

	# Hand-curated entry should be preserved
	echo "$changelog" | grep -q 'Initial feature' || fail "'Initial feature' not found in changelog"

	# Auto-generated entry should be present
	echo "$changelog" | grep -q 'auto feature' || fail "'auto feature' not found in changelog"

	# Reference link for [#1] should be preserved
	echo "$changelog" | grep -q '\[#1\]: https://github.com/test-org/test-repo/pull/1' || fail "'[#1]' reference link not found in changelog"
}

# =============================================================================
# Tests: empty unreleased section
# =============================================================================

@test "update-changelog: works with empty unreleased section" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.0.0...HEAD'

	run_update_changelog "1.0.0" "### Features

- new feature (ccc3333)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# Should not have "Previously Unreleased" section when there are no existing entries
	if echo "$changelog" | grep -q 'Previously Unreleased'; then
		echo "Should not have Previously Unreleased when unreleased section was empty" >&2
		echo "$changelog" >&2
		return 1
	fi

	# Should have the feature from generated body
	echo "$changelog" | grep -q 'new feature' || fail "'new feature' not found in changelog"
}

# =============================================================================
# Tests: existing versioned sections preserved
# =============================================================================

@test "update-changelog: preserves existing versioned sections" {
	setup_changelog_repo

	write_changelog '# Changelog

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.0] - 2026-01-01

### Features

- old feature (aaa1111)

[Unreleased]: https://github.com/test-org/test-repo/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/test-org/test-repo/releases/tag/v0.1.0'

	(cd "$MOCK_GIT_REPO" && git tag v0.1.0)

	run_update_changelog "0.2.0" "### Features

- newer feature (ddd4444)"
	assert_success

	local changelog
	changelog=$(cat "${MOCK_GIT_REPO}/CHANGELOG.md")

	# Both versions should exist
	echo "$changelog" | grep -q '## \[0\.2\.0\]' || fail "'## [0.2.0]' not found in changelog"
	echo "$changelog" | grep -q '## \[0\.1\.0\]' || fail "'## [0.1.0]' not found in changelog"

	# Old feature preserved
	echo "$changelog" | grep -q 'old feature' || fail "'old feature' not found in changelog"

	# New feature present
	echo "$changelog" | grep -q 'newer feature' || fail "'newer feature' not found in changelog"

	# Old version link preserved
	echo "$changelog" | grep -q '\[0\.1\.0\]: https://github.com/test-org/test-repo/' || {
		echo "Missing [0.1.0] comparison link" >&2
		echo "$changelog" >&2
		return 1
	}
}
