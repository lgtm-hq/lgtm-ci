#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/write-release-metadata.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/write-release-metadata.sh"

setup() {
	setup_temp_dir
	save_path
	OUT="${BATS_TEST_TMPDIR}/meta/release-metadata.json"
	RELEASE_JSON='{"tag_name":"v1.2.2","published_at":"2026-10-01T00:00:00Z","html_url":"https://github.com/acme/widget/releases/tag/v1.2.2"}'
	# Newest first, as the API returns; sha-/ci- tags must be ignored and the
	# highest release tag wins even when it is not the first record.
	PACKAGE_JSON='[
	  {"name":"sha256:aaaa","metadata":{"container":{"tags":["sha-abc123","latest"]}}},
	  {"name":"sha256:bbbb","metadata":{"container":{"tags":["1.2.1"]}}},
	  {"name":"sha256:cccc","metadata":{"container":{"tags":["1.2.2"]}}},
	  {"name":"sha256:dddd","metadata":{"container":{"tags":["1.10.0"]}}},
	  {"name":"not-a-digest","metadata":{"container":{"tags":["9.9.9"]}}}
	]'
}

teardown() {
	restore_path
	teardown_temp_dir
}

# gh mock keyed on the API path: $1 = release body or exit code, $2 = package body or exit code.
mock_gh() {
	local release="$1" package="$2"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '%s\n' "$release" >"${mock_bin}/.release"
	printf '%s\n' "$package" >"${mock_bin}/.package"
	printf '%s\n' "${3:-[]}" >"${mock_bin}/.package2"
	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>'${BATS_TEST_TMPDIR}/gh_calls'
case "\$*" in
*releases/latest*) body='${mock_bin}/.release' ;;
*packages/container/*\&page=1) body='${mock_bin}/.package' ;;
*packages/container/*) body='${mock_bin}/.package2' ;;
*) echo "unexpected: \$*" >&2; exit 1 ;;
esac
content="\$(cat "\$body")"
if [[ "\$content" =~ ^exit:([0-9]+)$ ]]; then exit "\${BASH_REMATCH[1]}"; fi
printf '%s\n' "\$content"
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

run_writer() {
	run env GH_TOKEN=fake REPO=acme/widget OWNER=acme OWNER_TYPE=Organization \
		NEXT_VERSION=1.3.0 TAG_PREFIX=v OUTPUT_PATH="$OUT" "$@" bash "$SCRIPT"
}

@test "write-release-metadata: fails without GH_TOKEN" {
	run env -u GH_TOKEN REPO=a/b OWNER=a NEXT_VERSION=1 OUTPUT_PATH="$OUT" bash "$SCRIPT"
	assert_failure
	assert_output --partial "GH_TOKEN is required"
}

@test "write-release-metadata: records the latest release and skips the container lookup by default" {
	mock_gh "$RELEASE_JSON" "exit:1"
	run_writer
	assert_success
	assert_file_exists "$OUT"
	run jq -r '.schema, .repository, .next_version, .tag_prefix, .latest_release.tag, .latest_release.version, .container' "$OUT"
	assert_output "1
acme/widget
1.3.0
v
v1.2.2
1.2.2
null"
	run grep -c "packages/container" "${BATS_TEST_TMPDIR}/gh_calls"
	assert_output "0"
}

@test "write-release-metadata: a repository without releases yields latest_release null" {
	mock_gh "exit:1" "exit:1"
	run_writer
	assert_success
	assert_output --partial "no latest release"
	run jq -c '.latest_release' "$OUT"
	assert_output "null"
}

@test "write-release-metadata: resolves the newest release-tagged container digest" {
	mock_gh "$RELEASE_JSON" "$PACKAGE_JSON"
	run_writer CONTAINER_PACKAGE=widget
	assert_success
	run jq -r '.container.package, .container.version, .container.digest' "$OUT"
	assert_output "widget
1.10.0
sha256:dddd"
	run grep -F "orgs/acme/packages/container/widget/versions" "${BATS_TEST_TMPDIR}/gh_calls"
	assert_success
}

@test "write-release-metadata: user-owned packages use the users endpoint" {
	mock_gh "$RELEASE_JSON" "$PACKAGE_JSON"
	run_writer CONTAINER_PACKAGE=widget OWNER_TYPE=User
	assert_success
	run grep -F "users/acme/packages/container/widget/versions" "${BATS_TEST_TMPDIR}/gh_calls"
	assert_success
}

@test "write-release-metadata: an unreadable package yields container null and a warning" {
	mock_gh "$RELEASE_JSON" "exit:1"
	run_writer CONTAINER_PACKAGE=widget
	assert_success
	assert_output --partial "Packages: read"
	run jq -c '.container' "$OUT"
	assert_output "null"
}

@test "write-release-metadata: a package with no release tags yields container null" {
	mock_gh "$RELEASE_JSON" '[{"name":"sha256:aaaa","metadata":{"container":{"tags":["sha-abc"]}}}]'
	run_writer CONTAINER_PACKAGE=widget
	assert_success
	run jq -c '.container' "$OUT"
	assert_output "null"
}

@test "write-release-metadata: walks every page so a newer release behind a recent backport is found" {
	# Page 1 is full (100 records, newest first) and carries only a backport;
	# the higher release sits on page 2.
	local page1 page2
	page1="$(jq -c -n '[range(100) | {name: ("sha256:" + (. | tostring)), metadata: {container: {tags: [(if . == 0 then "1.2.4" else ("sha-" + (. | tostring)) end)]}}}]')"
	page2='[{"name":"sha256:newer","metadata":{"container":{"tags":["1.10.0"]}}}]'
	mock_gh "$RELEASE_JSON" "$page1" "$page2"
	run_writer CONTAINER_PACKAGE=widget
	assert_success
	run jq -r '.container.version, .container.digest' "$OUT"
	assert_output "1.10.0
sha256:newer"
	run grep -c "packages/container/widget/versions" "${BATS_TEST_TMPDIR}/gh_calls"
	assert_output "2"
}
