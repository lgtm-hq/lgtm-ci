#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for the build-* staging-tag pruner.
#          Guards the #433 safety gate: a staging manifest that a live index
#          still points at must never be deleted.

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/prune-build-staging-tags.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT

	export PACKAGE_NAME="test-package"
	export GITHUB_ORG="test-org"
	export THRESHOLD_DAYS="30"
	export KEEP_RECENT="0"
	export PROTECT_REFERENCED="true"
	export DRY_RUN="false"
	export GH_TOKEN="test-token"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Mock gh: serve versions JSON for list calls, record DELETEs to a file.
mock_gh_versions() {
	local versions_json="$1"
	local delete_exit="${2:-0}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local versions_file="${mock_bin}/.gh_versions"
	printf '%s' "$versions_json" >"$versions_file"
	: >"${mock_bin}/.gh_deletes"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
	*--method\ DELETE*)
		printf '%s\n' "\$*" >>"${mock_bin}/.gh_deletes"
		exit $delete_exit
		;;
	*packages/container*) cat '$versions_file';;
	*) exit 1;;
esac
EOF
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# A release index tagged v1.0.0 whose single child is sha256:child-referenced.
mock_registry_release_index() {
	mock_command_multi "curl" '
		*ghcr.io/token*) printf "%s" "{\"token\":\"registry-bearer\"}";;
		*manifests/sha256:release-index*) printf "%s\n200\n" "{\"manifests\":[{\"digest\":\"sha256:child-referenced\"}]}";;
		*referrers/sha256:release-index*) printf "%s\n200\n" "{\"manifests\":[]}";;
		*) printf "%s\n404\n" "{}";;
	'
}

# Minimum size, in bytes, the serialised reference set must reach for the #793
# regression test to be meaningful. It must exceed the argument-list limit on
# every supported platform: macOS caps a whole execve argument list at 1 MiB
# (ARG_MAX), and Linux caps any SINGLE argument at 128 KiB (MAX_ARG_STRLEN).
# 1.5 MiB clears both with margin.
REFS_MIN_BYTES=1572864

# Emit an OCI index manifest with $1 synthetic 64-hex child digests, plus the
# digest given in $2 as one more child, into the file named by $3.
write_large_index_manifest() {
	local count="$1" extra_digest="$2" out_file="$3"

	jq -n --argjson n "$count" --arg extra "$extra_digest" '
		{
			manifests: (
				[ range($n)
				  | { digest: ("sha256:" + ("a" * 59) + (("0000" + (. | tostring)) | .[-5:])) }
				]
				+ [ { digest: $extra } ]
			)
		}
	' >"$out_file"
}

# =============================================================================
# Required env var validation
# =============================================================================

@test "prune-staging: fails when PACKAGE_NAME is not set" {
	run bash -c 'unset PACKAGE_NAME; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "PACKAGE_NAME is required"
}

@test "prune-staging: fails when GITHUB_ORG is not set" {
	run bash -c 'unset GITHUB_ORG; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "GITHUB_ORG is required"
}

@test "prune-staging: fails when THRESHOLD_DAYS is not an integer" {
	run bash -c 'export THRESHOLD_DAYS=abc; bash "$SCRIPT" 2>&1'
	assert_failure
	assert_output --partial "THRESHOLD_DAYS must be a non-negative integer"
}

# =============================================================================
# Core behaviour
# =============================================================================

@test "prune-staging: no-op when package has no build-* staging tags" {
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No build-* staging tags to prune"
}

@test "prune-staging: deletes an old, UNreferenced build-* staging tag" {
	mock_registry_release_index
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Pruned staging version 111"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	assert_output --partial "versions/111"
}

@test "prune-staging: SKIPS a staging tag whose digest is still an index child (#433 guard)" {
	mock_registry_release_index
	# The staging version's digest IS the release index's child digest.
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":333,"name":"sha256:child-referenced","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "still referenced by a live release"
	refute_output --partial "Pruned staging version"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	refute_output --partial "versions/333"
}

@test "prune-staging: mixed set prunes only the unreferenced staging tag" {
	mock_registry_release_index
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":333,"name":"sha256:child-referenced","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-arm64"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Pruned staging version 111"
	assert_output --partial "still referenced by a live release"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	assert_output --partial "versions/111"
	refute_output --partial "versions/333"
}

# =============================================================================
# Age and keep-recent guards
# =============================================================================

@test "prune-staging: keeps staging tags newer than THRESHOLD_DAYS" {
	local recent
	recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	mock_registry_release_index
	mock_gh_versions "[
		{\"id\":222,\"name\":\"sha256:release-index\",\"updated_at\":\"2024-01-01T00:00:00Z\",\"metadata\":{\"container\":{\"tags\":[\"v1.0.0\"]}}},
		{\"id\":111,\"name\":\"sha256:staging-new\",\"updated_at\":\"${recent}\",\"metadata\":{\"container\":{\"tags\":[\"build-999-linux-amd64\"]}}}
	]"

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "Pruned staging version 111"
}

@test "prune-staging: KEEP_RECENT protects the newest staging tags regardless of age" {
	export KEEP_RECENT="1"
	mock_registry_release_index
	# Two aged, unreferenced staging tags; the newest is kept.
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-older","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}},
		{"id":112,"name":"sha256:staging-newer","updated_at":"2021-01-01T00:00:00Z","metadata":{"container":{"tags":["build-200-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Pruned staging version 111"
	refute_output --partial "Pruned staging version 112"
}

# =============================================================================
# Fail-closed safety
# =============================================================================

@test "prune-staging: skips all deletion when referenced-digest collection is incomplete" {
	# Manifest fetch returns a server error -> collection incomplete -> fail closed.
	mock_command_multi "curl" '
		*ghcr.io/token*) printf "%s" "{\"token\":\"registry-bearer\"}";;
		*manifests/sha256:release-index*) printf "%s\n500\n" "error";;
		*referrers/sha256:release-index*) printf "%s\n200\n" "{\"manifests\":[]}";;
		*) printf "%s\n404\n" "{}";;
	'
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "incomplete"
	refute_output --partial "Pruned staging version"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	refute_output --partial "versions/111"
}

@test "prune-staging: skips prune when registry auth fails" {
	mock_command_multi "curl" '
		*ghcr.io/token*) exit 22;;
		*) exit 1;;
	'
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "registry auth failed"
	refute_output --partial "Pruned staging version"
}

# =============================================================================
# Dry-run
# =============================================================================

@test "prune-staging: dry-run reports but does not delete" {
	export DRY_RUN="true"
	mock_registry_release_index
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "[dry-run] Would prune staging version 111"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	refute_output --partial "versions/111"
}

# =============================================================================
# Large reference set (#793)
# =============================================================================

@test "prune-staging: reference set larger than ARG_MAX still prunes and protects (#793)" {
	local manifest_file="${BATS_TEST_TMPDIR}/large-index.json"
	local protected_digest="sha256:$(printf 'a%.0s' {1..59})00007"

	write_large_index_manifest 24000 "sha256:child-referenced" "$manifest_file"

	# Guard the guard: if the payload ever shrinks below the argument-list limit
	# this test stops reproducing #793 and must fail loudly rather than pass.
	local refs_bytes
	refs_bytes=$(jq -r '.manifests[].digest' "$manifest_file" | jq -R . | jq -s . | wc -c)
	((refs_bytes >= REFS_MIN_BYTES)) ||
		fail "reference payload is ${refs_bytes} bytes, need >= ${REFS_MIN_BYTES} to reproduce #793"

	mock_command_multi "curl" "
		*ghcr.io/token*) printf '%s' '{\"token\":\"registry-bearer\"}';;
		*manifests/sha256:release-index*) cat '${manifest_file}'; printf '200\n';;
		*referrers/sha256:release-index*) printf '%s\n200\n' '{\"manifests\":[]}';;
		*) printf '%s\n404\n' '{}';;
	"
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":333,"name":"'"$protected_digest"'","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-arm64"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	refute_output --partial "Argument list too long"
	assert_output --partial "Collected 24002 referenced digest(s)"

	# Protection semantics survive the large-set path: the referenced staging
	# digest is skipped, the unreferenced one is pruned.
	assert_output --partial "Pruned staging version 111"
	assert_output --partial "still referenced by a live release"
	refute_output --partial "Pruned staging version 333"

	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	assert_output --partial "versions/111"
	refute_output --partial "versions/333"
}

@test "prune-staging: large reference set honours DRY_RUN" {
	export DRY_RUN="true"
	local manifest_file="${BATS_TEST_TMPDIR}/large-index.json"
	local protected_digest="sha256:$(printf 'a%.0s' {1..59})00007"

	write_large_index_manifest 24000 "sha256:child-referenced" "$manifest_file"

	mock_command_multi "curl" "
		*ghcr.io/token*) printf '%s' '{\"token\":\"registry-bearer\"}';;
		*manifests/sha256:release-index*) cat '${manifest_file}'; printf '200\n';;
		*referrers/sha256:release-index*) printf '%s\n200\n' '{\"manifests\":[]}';;
		*) printf '%s\n404\n' '{}';;
	"
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":333,"name":"'"$protected_digest"'","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-arm64"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "[dry-run] Would prune staging version 111"
	refute_output --partial "Would prune staging version 333"

	# DRY_RUN must issue no DELETE at all, not merely spare version 111.
	run cat "${BATS_TEST_TMPDIR}/bin/.gh_deletes"
	assert_output ""
}

@test "prune-staging: removes its referenced-digest temp file on exit" {
	local tmp_home="${BATS_TEST_TMPDIR}/scratch"
	mkdir -p "$tmp_home"
	mock_registry_release_index
	mock_gh_versions '[
		{"id":222,"name":"sha256:release-index","updated_at":"2024-01-01T00:00:00Z","metadata":{"container":{"tags":["v1.0.0"]}}},
		{"id":111,"name":"sha256:staging-old","updated_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["build-100-linux-amd64"]}}}
	]'

	TMPDIR="$tmp_home" run bash "$SCRIPT"
	assert_success

	run find "$tmp_home" -name 'prune-staging-refs.*'
	assert_output ""
}
