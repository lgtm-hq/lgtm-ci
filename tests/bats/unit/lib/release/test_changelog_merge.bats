#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/changelog_merge.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# normalize_kac_section
# =============================================================================

@test "normalize_kac_section: maps Added and Features to Added" {
	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Added"'
	assert_success
	assert_output "Added"

	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Features"'
	assert_success
	assert_output "Added"
}

@test "normalize_kac_section: maps Changed aliases to Changed" {
	local aliases=(
		"Changed"
		"Breaking Changes"
		"Documentation"
		"Other Changes"
	)

	for alias in "${aliases[@]}"; do
		run bash -c "source \"\$LIB_DIR/release/changelog_merge.sh\" && normalize_kac_section \"$alias\""
		assert_success
		assert_output "Changed"
	done
}

@test "normalize_kac_section: maps remaining KaC and legacy headings" {
	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Deprecated"'
	assert_output "Deprecated"

	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Removed"'
	assert_output "Removed"

	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Fixed"'
	assert_output "Fixed"

	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Bug Fixes"'
	assert_output "Fixed"

	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Security"'
	assert_output "Security"
}

@test "normalize_kac_section: returns empty for unknown headings" {
	run bash -c 'source "$LIB_DIR/release/changelog_merge.sh" && normalize_kac_section "Performance"'
	assert_success
	assert_output ""
}

# =============================================================================
# parse_changelog_body
# =============================================================================

@test "parse_changelog_body: captures prose and ignores reference links" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "Target release: v1.0.0

### Added

- new item

[Unreleased]: https://example.com/compare/v0.9.0...HEAD"
		echo "prose=${_MERGE_PROSE}"
		echo "added=${_MERGE_SECTION_Added}"
	'
	assert_success
	assert_output --partial "prose=Target release: v1.0.0"
	assert_output --partial "added=- new item"
}

@test "parse_changelog_body: captures breaking changes block" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "### Breaking Changes

| Removed | Use instead |
| --- | --- |
| old.yml | new.yml"
		echo "breaking=${_MERGE_BREAKING}"
	'
	assert_success
	assert_output --partial "breaking=| Removed | Use instead |"
}

@test "parse_changelog_body: maps Previously Unreleased bullets to Changed" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "### Previously Unreleased

- legacy curated entry"
		echo "changed=${_MERGE_SECTION_Changed}"
	'
	assert_success
	assert_output --partial "changed=- legacy curated entry"
}

@test "parse_changelog_body: preserves bare bullets under Changed" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "- flat unreleased entry"
		echo "changed=${_MERGE_SECTION_Changed}"
	'
	assert_success
	assert_output --partial "changed=- flat unreleased entry"
}

@test "parse_changelog_body: treats asterisk and plus list markers as bullets" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "* asterisk entry
+ plus entry"
		echo "changed=${_MERGE_SECTION_Changed}"
	'
	assert_success
	assert_output --partial "changed=* asterisk entry"
	assert_output --partial "+ plus entry"
}

@test "parse_changelog_body: preserves markdown links while skipping reference definitions" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "### Breaking changes

See [migration guide](docs/migration.md).

[Unreleased]: https://example.com/compare/v0.9.0...HEAD"
		echo "breaking=${_MERGE_BREAKING}"
	'
	assert_success
	assert_output --partial "breaking=See [migration guide](docs/migration.md)."
	refute_output --partial "[Unreleased]:"
}

@test "parse_changelog_body: skips link definitions inside breaking block" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "### Breaking changes

| old | new |
| --- | --- |

[Unreleased]: https://example.com/compare/v0.9.0...HEAD"
		echo "breaking=${_MERGE_BREAKING}"
	'
	assert_success
	assert_output --partial "breaking=| old | new |"
	refute_output --partial "[Unreleased]:"
}

@test "parse_changelog_body: routes each Keep a Changelog section" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "### Added
- added

### Changed
- changed

### Deprecated
- deprecated

### Removed
- removed

### Fixed
- fixed

### Security
- security"
		for section in Added Changed Deprecated Removed Fixed Security; do
			eval "value=\${_MERGE_SECTION_${section}}"
			echo "${section}=${value}"
		done
	'
	assert_success
	assert_output --partial "Added=- added"
	assert_output --partial "Changed=- changed"
	assert_output --partial "Deprecated=- deprecated"
	assert_output --partial "Removed=- removed"
	assert_output --partial "Fixed=- fixed"
	assert_output --partial "Security=- security"
}

@test "parse_changelog_body: treats non-list lines before sections as prose" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		parse_changelog_body "Release notes preamble

### Added
- item"
		echo "prose=${_MERGE_PROSE}"
	'
	assert_success
	assert_output --partial "prose=Release notes preamble"
}

# =============================================================================
# merge_changelog_sections
# =============================================================================

@test "merge_changelog_sections: returns nothing when both bodies are empty" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "" ""
	'
	assert_success
	assert_output ""
}

@test "merge_changelog_sections: returns existing body when generated is empty" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "" "### Fixed

- existing fix"
	'
	assert_success
	assert_output --partial "### Fixed"
	assert_output --partial "existing fix"
}

@test "merge_changelog_sections: returns generated body when existing is empty" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "### Added

- generated entry" ""
	'
	assert_success
	assert_output --partial "### Added"
	assert_output --partial "generated entry"
}

@test "merge_changelog_sections: places generated bullets before existing bullets" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "### Added

- generated entry" "### Added

- existing entry"
	'
	assert_success
	assert_output --partial "### Added"
	assert_output --partial $'- generated entry
- existing entry'
}

@test "merge_changelog_sections: concatenates prose and breaking blocks" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "Generated prose

### Breaking changes

generated-table" "Existing prose

### Breaking changes

existing-table"
	'
	assert_success
	assert_output --partial "Generated prose"
	assert_output --partial "Existing prose"
	assert_output --partial "generated-table"
	assert_output --partial "existing-table"
}

@test "merge_changelog_sections: routes title-case Breaking Changes into breaking block" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "### Breaking Changes

- removed old workflow" ""
	'
	assert_success
	assert_output --partial "### Breaking changes"
	assert_output --partial "- removed old workflow"
}

@test "merge_changelog_sections: keeps bullets under unrecognized headings" {
	run bash -c '
		source "$LIB_DIR/release/changelog_merge.sh"
		merge_changelog_sections "" "### Performance

- faster runner selection"
	'
	assert_success
	assert_output --partial "### Changed"
	assert_output --partial "faster runner selection"
}
