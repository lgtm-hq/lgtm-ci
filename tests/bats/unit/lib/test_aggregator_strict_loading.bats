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
