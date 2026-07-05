#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Verify library aggregators fail explicitly when a required
#          sub-module is missing (issue #30). Each test copies the lib tree
#          into a temp dir, removes one module, and asserts sourcing fails
#          with a clear error naming the missing file.

load "../../../helpers/common"

setup() {
	setup_temp_dir
	TMP_LIB_DIR="$BATS_TEST_TMPDIR/lib"
	cp -R "$PROJECT_ROOT/scripts/ci/lib" "$TMP_LIB_DIR"
	export TMP_LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# Helper: source an aggregator from the temp lib copy and capture rc/output
_source_tmp_lib() {
	local file="$1"
	bash -c 'source "$1"' _ "$TMP_LIB_DIR/$file"
}

@test "github.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/github/summary.sh"
	run _source_tmp_lib "github.sh"
	assert_failure
	assert_output --partial "missing required module summary.sh"
}

@test "github.sh: fails loudly when modules directory is missing" {
	rm -rf "$TMP_LIB_DIR/github"
	run _source_tmp_lib "github.sh"
	assert_failure
	assert_output --partial "cannot resolve github modules directory"
}

@test "network.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/network/checksum.sh"
	run _source_tmp_lib "network.sh"
	assert_failure
	assert_output --partial "missing required module checksum.sh"
}

@test "sbom.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/sbom/severity.sh"
	run _source_tmp_lib "sbom.sh"
	assert_failure
	assert_output --partial "missing required module severity.sh"
}

@test "installer.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/installer/core.sh"
	run _source_tmp_lib "installer.sh"
	assert_failure
	assert_output --partial "missing required module core.sh"
}

@test "publish.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/publish/registry.sh"
	run _source_tmp_lib "publish.sh"
	assert_failure
	assert_output --partial "missing required module publish/registry.sh"
}

@test "docker.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/docker/tags.sh"
	run _source_tmp_lib "docker.sh"
	assert_failure
	assert_output --partial "missing required module docker/tags.sh"
}

@test "testing.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/testing/parse.sh"
	run _source_tmp_lib "testing.sh"
	assert_failure
	assert_output --partial "missing required module testing/parse.sh"
}

@test "release.sh: fails loudly when a required module is missing" {
	rm "$TMP_LIB_DIR/release/changelog.sh"
	run _source_tmp_lib "release.sh"
	assert_failure
	assert_output --partial "missing required module release/changelog.sh"
}

@test "actions.sh: fails loudly when a required library is missing" {
	rm "$TMP_LIB_DIR/sbom.sh"
	run _source_tmp_lib "actions.sh"
	assert_failure
	assert_output --partial "missing required library sbom.sh"
}

@test "actions.sh: propagates failure from nested aggregator" {
	rm "$TMP_LIB_DIR/github/output.sh"
	run _source_tmp_lib "actions.sh"
	assert_failure
	assert_output --partial "missing required module output.sh"
}

@test "coverage/merge.sh: fails loudly when detect.sh is missing" {
	rm "$TMP_LIB_DIR/testing/detect.sh"
	run _source_tmp_lib "testing/coverage/merge.sh"
	assert_failure
	assert_output --partial "missing required module detect.sh"
}

# Runs from a script file (not bash -c) so BASH_SOURCE is bound: kcov's
# bash instrumentation references BASH_SOURCE in a DEBUG trap and aborts
# under set -u inside a bash -c script. Paths are passed via the exported
# TMP_LIB_DIR, never interpolated into shell syntax.
@test "aggregators: all load successfully when modules are present" {
	local smoke="$BATS_TEST_TMPDIR/aggregator_smoke.sh"
	cat >"$smoke" <<'SMOKE'
set -euo pipefail
for lib in actions testing release docker publish network egress; do
	source "$TMP_LIB_DIR/$lib.sh"
done
echo loaded
SMOKE
	run bash "$smoke"
	assert_success
	assert_output --partial "loaded"
}

@test "aggregators: sourcing twice is still a no-op" {
	run bash -c 'source "$1" && source "$1" && echo ok' _ "$TMP_LIB_DIR/github.sh"
	assert_success
	assert_output --partial "ok"
}

# =============================================================================
# Exhaustive per-module coverage: every required-module error path fires
# =============================================================================

# Re-create the temp lib copy (used between iterations of the loops below).
_reset_tmp_lib() {
	rm -rf "$TMP_LIB_DIR"
	cp -R "$PROJECT_ROOT/scripts/ci/lib" "$TMP_LIB_DIR"
}

# Resolve a "missing required module" token from an aggregator to the path
# (relative to the lib root) that must be removed to trigger it.
_module_removal_path() {
	local agg_dir="$1" token="$2"
	if [[ "$token" == */* ]]; then
		echo "$token"
	elif [[ -f "$TMP_LIB_DIR/$agg_dir/$token" ]]; then
		echo "$agg_dir/$token"
	else
		echo "$token"
	fi
}

# For the given aggregator, remove each required module in turn and assert
# sourcing fails with the "missing required module" error.
_assert_all_modules_required() {
	local agg="$1"
	local agg_dir="${agg%.sh}"
	local token path
	while IFS= read -r token; do
		[[ -n "$token" ]] || continue
		_reset_tmp_lib
		path="$(_module_removal_path "$agg_dir" "$token")"
		rm "$TMP_LIB_DIR/$path"
		run _source_tmp_lib "$agg"
		assert_failure
		assert_output --partial "missing required module"
	done < <(grep -oE 'missing required module [A-Za-z0-9/_.-]+' \
		"$PROJECT_ROOT/scripts/ci/lib/$agg" | awk '{print $4}' | sort -u)
}

@test "github.sh: every required module is enforced" {
	_assert_all_modules_required "github.sh"
}

@test "network.sh: every required module is enforced" {
	_assert_all_modules_required "network.sh"
}

@test "sbom.sh: every required module is enforced" {
	_assert_all_modules_required "sbom.sh"
}

@test "installer.sh: every required module is enforced" {
	_assert_all_modules_required "installer.sh"
}

@test "publish.sh: every required module is enforced" {
	_assert_all_modules_required "publish.sh"
}

@test "docker.sh: every required module is enforced" {
	_assert_all_modules_required "docker.sh"
}

@test "testing.sh: every required module is enforced" {
	_assert_all_modules_required "testing.sh"
}

@test "release.sh: every required module is enforced" {
	_assert_all_modules_required "release.sh"
}

@test "actions.sh: every required library is enforced" {
	local token
	while IFS= read -r token; do
		[[ -n "$token" ]] || continue
		_reset_tmp_lib
		rm "$TMP_LIB_DIR/$token"
		run _source_tmp_lib "actions.sh"
		assert_failure
		assert_output --partial "missing required library"
	done < <(grep -oE 'missing required library [A-Za-z0-9/_.-]+' \
		"$PROJECT_ROOT/scripts/ci/lib/actions.sh" | awk '{print $4}' | sort -u)
}
