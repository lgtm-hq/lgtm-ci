#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/generate-file-breakdown.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="scripts/ci/actions/generate-file-breakdown.sh"

setup() {
	setup_temp_dir
	export GITHUB_SERVER_URL="https://github.com"
	export GITHUB_REPOSITORY="lgtm-hq/lgtm-ci"
	export GITHUB_RUN_ID="12345"
}

teardown() {
	teardown_temp_dir
}

write_mixed_fixture() {
	local file="$1"
	install_fixture "file-breakdown/files-mixed.json" "$file"
}

write_all_categories_fixture() {
	local file="$1"
	install_fixture "file-breakdown/files-all-categories.json" "$file"
}

# =============================================================================
# STEP=generate - validation
# =============================================================================

@test "generate-file-breakdown: fails when PR_FILES_JSON is unset" {
	run env STEP="generate" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "PR_FILES_JSON"
}

@test "generate-file-breakdown: fails when payload file is missing" {
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/missing.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "not found"
}

@test "generate-file-breakdown: fails on invalid JSON payload" {
	printf 'not json' >"${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "not a JSON array"
}

@test "generate-file-breakdown: fails on non-array JSON payload" {
	printf '{"filename": "a"}' >"${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "not a JSON array"
}

@test "generate-file-breakdown: fails on unknown STEP" {
	run env STEP="bogus" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown STEP"
}

# =============================================================================
# STEP=generate - rendering
# =============================================================================

@test "generate-file-breakdown: empty payload renders no-files message" {
	printf '[]' >"${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "No files changed."
	assert_output --partial "PR File Breakdown"
}

@test "generate-file-breakdown: classifies files into semantic categories" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| Implementation | 2 | +40 | -2 |'
	assert_output --partial '| Docs | 2 | +5 | -45 |'
	refute_output --partial '| `scripts/` |'
}

@test "generate-file-breakdown: reports totals and status counts" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "**4 file(s) changed** (+45 / -47)"
	assert_output --partial "1 added"
	assert_output --partial "2 modified"
	assert_output --partial "1 removed"
}

@test "generate-file-breakdown: renders per-file detail rows in details block" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "<details>"
	assert_output --partial '| `scripts/ci/lib/bar.sh` | added | +30 | -0 |'
	assert_output --partial '| `README.md` | removed | +0 | -40 |'
}

@test "generate-file-breakdown: caps detail rows and summarizes the rest" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		MAX_ROWS="2" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Changed files (first 2 of 4)"
	assert_output --partial "…and 2 more file(s) not shown."
	refute_output --partial '| `README.md` |'
}

@test "generate-file-breakdown: byte-caps body for many long-path files" {
	# Worst case: 500 files under a long monorepo path. The 500-row cap alone
	# would render a body past GitHub's ~65,536-char limit, so the byte budget
	# must drop rows and note that they were dropped for size.
	local prefix="services/platform/backend/internal/very/deeply/nested/module"
	jq -n --arg p "$prefix" '
		[range(0; 500) | {
			filename: ($p + "/component-\(.)/handler_implementation_file_\(.).go"),
			status: "modified",
			additions: 12,
			deletions: 7
		}]
	' >"${BATS_TEST_TMPDIR}/files.json"

	run env \
		STEP="generate" \
		MAX_ROWS="500" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	# Rendered body must stay under GitHub's comment-body limit.
	local size
	size=$(wc -c <"${BATS_TEST_TMPDIR}/comment.md")
	assert [ "$size" -lt 65536 ]

	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" "500 file(s) changed"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" \
		"dropped to keep this comment within GitHub's size limit"
	# Fixed sections must survive the truncation.
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" "| Category | Files |"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" "View full build details"
}

@test "generate-file-breakdown: byte-caps category rows when details are already hidden" {
	# Requires python3 + PyYAML — config with many categories triggers
	# the category-row byte-cap path.
	python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module not available"

	# Generate config with 5000 unique categories
	python3 -c '
import sys
sys.stdout.write("categories:\n")
for i in range(5000):
    name = "service-component-with-a-very-long-unique-category-name-" + str(i)
    sys.stdout.write("  " + name + ":\n")
    sys.stdout.write("    - \"^unique-svc-dir-" + str(i) + "/\"\n")
sys.stdout.write("  Uncategorized:\n")
sys.stdout.write("    - \".\"\n")
' >"${BATS_TEST_TMPDIR}/config.yml"

	jq -n '
		[range(0; 5000) | {
			filename: ("unique-svc-dir-\(.)/handler.go"),
			status: "modified",
			additions: 1,
			deletions: 1
		}]
	' >"${BATS_TEST_TMPDIR}/files.json"

	run env \
		STEP="generate" \
		MAX_ROWS="500" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/config.yml" \
		COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	local size
	size=$(wc -c <"${BATS_TEST_TMPDIR}/comment.md")
	assert [ "$size" -lt 65536 ]

	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" "5000 file(s) changed"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" \
		"category(ies) dropped to keep this comment within GitHub's size limit"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/comment.md" \
		"5000 more file(s) not shown (dropped to keep this comment within GitHub's size limit)."
}

@test "generate-file-breakdown: escapes pipes and strips backticks in paths" {
	install_fixture "file-breakdown/files-pipe-backtick.json" "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial 'weird\|namex.txt'
}

@test "generate-file-breakdown: normalizes leading-zero MAX_ROWS" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		MAX_ROWS="02" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Changed files (first 2 of 4)"
}

@test "generate-file-breakdown: clamps MAX_ROWS to the hard cap" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		MAX_ROWS="999999" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "4 file(s) changed"
}

@test "generate-file-breakdown: neutralizes newlines in filenames" {
	install_fixture "file-breakdown/files-newline-name.json" "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| `line1 line2.txt` | added | +1 | -0 |'
}

@test "generate-file-breakdown: includes build details link" {
	printf '[]' >"${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "https://github.com/lgtm-hq/lgtm-ci/actions/runs/12345"
}

@test "generate-file-breakdown: writes comment to COMMENT_OUTPUT when set" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		COMMENT_OUTPUT="${BATS_TEST_TMPDIR}/comment.md" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_file_contains "${BATS_TEST_TMPDIR}/comment.md" "PR File Breakdown"
}

@test "generate-file-breakdown: invalid MAX_ROWS falls back to default" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		MAX_ROWS="banana" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "<summary>Changed files</summary>"
}

# =============================================================================
# STEP=generate - category classification
# =============================================================================

@test "generate-file-breakdown: classifies all six default categories" {
	write_all_categories_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| CI-CD | 1 |'
	assert_output --partial '| Implementation | 1 |'
	assert_output --partial '| Tests | 1 |'
	assert_output --partial '| Docs | 1 |'
	assert_output --partial '| Images | 1 |'
	assert_output --partial '| Config | 1 |'
}

@test "generate-file-breakdown: CI-CD category takes priority over Config for .github files" {
	install_fixture "file-breakdown/files-cicd-vs-config.json" "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| CI-CD | 1 |'
	assert_output --partial '| Config | 1 |'
}

@test "generate-file-breakdown: test patterns match various conventions" {
	install_fixture "file-breakdown/files-test-patterns.json" "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| Tests | 4 |'
	refute_output --partial '| Implementation |'
}

# =============================================================================
# STEP=generate - distribution bar
# =============================================================================

@test "generate-file-breakdown: renders distribution bar per category" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| Distribution |'
	# Both categories have 2/4 files = 50% → 10 full blocks + 10 empty blocks
	assert_output --partial '██████████░░░░░░░░░░ 50%'
}

@test "generate-file-breakdown: bar shows 100% for single category" {
	install_fixture "file-breakdown/files-single-category.json" "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '████████████████████ 100%'
}

# =============================================================================
# STEP=generate - config override
# =============================================================================

@test "generate-file-breakdown: extends categories via config file" {
	python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module not available"

	install_fixture "file-breakdown/config-shell-scripts.yml" "${BATS_TEST_TMPDIR}/config.yml"

	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/config.yml" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	# .sh files now match Shell-Scripts (inserted before catch-all)
	assert_output --partial '| Shell-Scripts | 2 |'
	assert_output --partial '| Docs | 2 |'
	refute_output --partial '| Implementation |'
}

@test "generate-file-breakdown: overrides default category patterns via config" {
	python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module not available"

	# Override Docs to only match .rst files
	install_fixture "file-breakdown/config-docs-rst.yml" "${BATS_TEST_TMPDIR}/config.yml"

	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/config.yml" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	# No .rst files → Docs category absent; .md files fall to Implementation
	refute_output --partial '| Docs |'
	assert_output --partial '| Implementation | 4 |'
}

@test "generate-file-breakdown: coerces non-string YAML category keys" {
	python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module not available"

	# Unquoted true: becomes bool True under yaml.safe_load — must still render.
	install_fixture "file-breakdown/config-bool-key.yml" "${BATS_TEST_TMPDIR}/config.yml"

	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/config.yml" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| True | 2 |'
}

@test "generate-file-breakdown: falls back to defaults when config is absent" {
	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/nonexistent.yml" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| Implementation | 2 |'
	assert_output --partial '| Docs | 2 |'
}

@test "generate-file-breakdown: falls back to defaults on invalid config" {
	printf 'not: [valid: yaml: {{' >"${BATS_TEST_TMPDIR}/bad.yml"

	write_mixed_fixture "${BATS_TEST_TMPDIR}/files.json"
	run env \
		STEP="generate" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		FILE_BREAKDOWN_CONFIG="${BATS_TEST_TMPDIR}/bad.yml" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial '| Implementation | 2 |'
	assert_output --partial '| Docs | 2 |'
}

# =============================================================================
# STEP=fetch
# =============================================================================

@test "generate-file-breakdown: fetch fails without PR_NUMBER" {
	run env \
		STEP="fetch" \
		GH_TOKEN="token" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "PR_NUMBER"
}

@test "generate-file-breakdown: fetch rejects non-numeric PR_NUMBER" {
	run env \
		STEP="fetch" \
		GH_TOKEN="token" \
		PR_NUMBER="42; rm -rf /" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "must be numeric"
}

@test "generate-file-breakdown: fetch merges paginated arrays into one payload" {
	mock_command "gh" '[{"filename": "a.txt", "status": "added", "additions": 1, "deletions": 0}]
[{"filename": "b.txt", "status": "modified", "additions": 2, "deletions": 1}]'
	run env \
		STEP="fetch" \
		GH_TOKEN="token" \
		PR_NUMBER="42" \
		PR_FILES_JSON="${BATS_TEST_TMPDIR}/files.json" \
		bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Fetched 2 changed files for PR #42"
	run jq -r '.[1].filename' "${BATS_TEST_TMPDIR}/files.json"
	assert_output "b.txt"
}
