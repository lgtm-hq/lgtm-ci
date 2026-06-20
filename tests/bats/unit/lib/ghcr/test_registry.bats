#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ghcr/registry.sh

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
# ghcr_exchange_registry_token
# =============================================================================

@test "ghcr_exchange_registry_token: exchanges token field from registry" {
	mock_command_multi "curl" '
		*ghcr.io/token*) printf "%s" "{\"token\":\"registry-bearer\"}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_exchange_registry_token "test-org" "pkg" "github-token"
	'
	assert_success
	assert_output "registry-bearer"
}

@test "ghcr_exchange_registry_token: accepts access_token field" {
	mock_command_multi "curl" '
		*ghcr.io/token*) printf "%s" "{\"access_token\":\"alt-bearer\"}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_exchange_registry_token "test-org" "pkg" "github-token"
	'
	assert_success
	assert_output "alt-bearer"
}

@test "ghcr_exchange_registry_token: fails when curl fails" {
	mock_command_multi "curl" '
		*ghcr.io/token*) exit 22;;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_exchange_registry_token "test-org" "pkg" "github-token"
	'
	assert_failure
}

@test "ghcr_exchange_registry_token: fails when response has no token" {
	mock_command_multi "curl" '
		*ghcr.io/token*) printf "%s" "{}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_exchange_registry_token "test-org" "pkg" "github-token"
	'
	assert_failure
}

# =============================================================================
# ghcr_fetch_manifest
# =============================================================================

@test "ghcr_fetch_manifest: returns 404 marker for missing manifest" {
	mock_command_multi "curl" '
		*manifests/sha256:missing*) printf "%s\n404\n" "{}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_manifest "test-org" "pkg" "sha256:missing" "bearer"
	'
	assert_success
	assert_output "404"
}

@test "ghcr_fetch_manifest: returns manifest JSON on success" {
	mock_command_multi "curl" '
		*manifests/sha256:index*) printf "%s\n200\n" "{\"manifests\":[{\"digest\":\"sha256:child\"}]}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_manifest "test-org" "pkg" "sha256:index" "bearer"
	'
	assert_success
	assert_output --partial "sha256:child"
}

@test "ghcr_fetch_manifest: returns ERROR for server failure" {
	mock_command_multi "curl" '
		*manifests/sha256:broken*) printf "%s\n500\n" "internal error";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_manifest "test-org" "pkg" "sha256:broken" "bearer"
	'
	assert_failure
	assert_output "ERROR"
}

@test "ghcr_fetch_manifest: returns ERROR when curl fails" {
	mock_command_multi "curl" '
		*manifests/*) exit 1;;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_manifest "test-org" "pkg" "sha256:down" "bearer"
	'
	assert_failure
	assert_output "ERROR"
}

@test "ghcr_fetch_manifest: returns ERROR for non-object JSON body" {
	mock_command_multi "curl" '
		*manifests/sha256:badjson*) printf "%s\n200\n" "[]";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_manifest "test-org" "pkg" "sha256:badjson" "bearer"
	'
	assert_failure
	assert_output "ERROR"
}

# =============================================================================
# ghcr_fetch_referrers
# =============================================================================

@test "ghcr_fetch_referrers: returns empty array on 404" {
	mock_command_multi "curl" '
		*referrers/sha256:missing*) printf "%s\n404\n" "{}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_referrers "test-org" "pkg" "sha256:missing" "bearer"
	'
	assert_success
	assert_output "[]"
}

@test "ghcr_fetch_referrers: returns manifest descriptors on success" {
	mock_command_multi "curl" '
		*referrers/sha256:root*) printf "%s\n200\n" "{\"manifests\":[{\"digest\":\"sha256:attest\"}]}";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_referrers "test-org" "pkg" "sha256:root" "bearer"
	'
	assert_success
	assert_output --partial "sha256:attest"
}

@test "ghcr_fetch_referrers: returns ERROR for server failure" {
	mock_command_multi "curl" '
		*referrers/sha256:broken*) printf "%s\n503\n" "unavailable";;
		*) exit 1;;
	'

	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_fetch_referrers "test-org" "pkg" "sha256:broken" "bearer"
	'
	assert_failure
	assert_output "ERROR"
}

# =============================================================================
# ghcr_collect_referenced_digests
# =============================================================================

@test "ghcr_collect_referenced_digests: collects root, child, subject, and referrer digests" {
	mock_command_multi "curl" '
		*manifests/sha256:root*) printf "%s\n200\n" "{\"manifests\":[{\"digest\":\"sha256:child\"}],\"subject\":{\"digest\":\"sha256:subject\"}}";;
		*referrers/sha256:root*) printf "%s\n200\n" "{\"manifests\":[{\"digest\":\"sha256:referrer\"}]}";;
		*) exit 1;;
	'

	local versions='[
		{"name":"sha256:root","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"name":"sha256:untagged","metadata":{"container":{"tags":[]}}}
	]'

	run bash -c "
		source \"\$LIB_DIR/ghcr/registry.sh\"
		ghcr_collect_referenced_digests \
			'test-org' \
			'pkg' \
			'$versions' \
			'bearer' \
			referenced_complete \
			referenced_digests
		printf 'complete=%s\n' \"\$referenced_complete\"
		printf '%s\n' \"\$referenced_digests\"
	"
	assert_success
	assert_output --partial "complete=true"
	assert_output --partial "sha256:root"
	assert_output --partial "sha256:child"
	assert_output --partial "sha256:subject"
	assert_output --partial "sha256:referrer"
	refute_output --partial "sha256:untagged"
}

@test "ghcr_collect_referenced_digests: marks collection incomplete on manifest error" {
	mock_command_multi "curl" '
		*manifests/sha256:root*) printf "%s\n500\n" "error";;
		*referrers/sha256:root*) printf "%s\n200\n" "{\"manifests\":[]}";;
		*) exit 1;;
	'

	local versions='[{"name":"sha256:root","metadata":{"container":{"tags":["v1.0.0"]}}}]'

	run bash -c "
		source \"\$LIB_DIR/ghcr/registry.sh\"
		ghcr_collect_referenced_digests \
			'test-org' \
			'pkg' \
			'$versions' \
			'bearer' \
			referenced_complete \
			referenced_digests
		printf 'complete=%s\n' \"\$referenced_complete\"
	"
	assert_success
	assert_output --partial "complete=false"
}

@test "ghcr_collect_referenced_digests: marks collection incomplete on referrers error" {
	mock_command_multi "curl" '
		*manifests/sha256:root*) printf "%s\n404\n" "{}";;
		*referrers/sha256:root*) printf "%s\n500\n" "error";;
		*) exit 1;;
	'

	local versions='[{"name":"sha256:root","metadata":{"container":{"tags":["v1.0.0"]}}}]'

	run bash -c "
		source \"\$LIB_DIR/ghcr/registry.sh\"
		ghcr_collect_referenced_digests \
			'test-org' \
			'pkg' \
			'$versions' \
			'bearer' \
			referenced_complete \
			referenced_digests
		printf 'complete=%s\n' \"\$referenced_complete\"
	"
	assert_success
	assert_output --partial "complete=false"
}

@test "ghcr_collect_referenced_digests: returns empty digests for untagged-only versions" {
	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		ghcr_collect_referenced_digests \
			"test-org" \
			"pkg" \
			"[{\"name\":\"sha256:orphan\",\"metadata\":{\"container\":{\"tags\":[]}}}]" \
			"bearer" \
			referenced_complete \
			referenced_digests
		printf "complete=%s\n" "$referenced_complete"
		printf "digests=%s\n" "$referenced_digests"
	'
	assert_success
	assert_output --partial "complete=true"
	assert_output --partial "digests="
}

@test "ghcr/registry.sh: second source is a no-op when already loaded" {
	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		source "$LIB_DIR/ghcr/registry.sh"
		declare -F ghcr_exchange_registry_token >/dev/null && echo loaded
	'
	assert_success
	assert_output "loaded"
}
