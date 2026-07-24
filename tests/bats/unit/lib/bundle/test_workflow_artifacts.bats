#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for bundle workflow artifact library

load "../../../../helpers/common"
load "../../../../helpers/github_env"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	setup_github_env
	export GITHUB_REPOSITORY="lgtm-hq/turbo-themes"
	export COMMIT_SHA="abc123deadbeef"
	export SITE_ROOT="${BATS_TEST_TMPDIR}/site"
	mkdir -p "$SITE_ROOT"
	# shellcheck source=../../../../../scripts/ci/lib/actions.sh
	source "${PROJECT_ROOT}/scripts/ci/lib/actions.sh"
	# shellcheck source=../../../../../scripts/ci/lib/bundle/workflow_artifacts.sh
	source "${PROJECT_ROOT}/scripts/ci/lib/bundle/workflow_artifacts.sh"
}

teardown() {
	teardown_temp_dir
}

_create_traversal_artifact_zip() {
	local zip_path="${BATS_TEST_TMPDIR}/traversal.zip"
	python3 - "$zip_path" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("../../outside.txt", "pwned")
PY
	echo "$zip_path"
}

_create_absolute_artifact_zip() {
	local zip_path="${BATS_TEST_TMPDIR}/absolute.zip"
	python3 - "$zip_path" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("/etc/passwd", "pwned")
PY
	echo "$zip_path"
}

_create_symlink_artifact_zip() {
	local zip_path="${BATS_TEST_TMPDIR}/symlink.zip"
	python3 - "$zip_path" <<'PY'
import sys
import zipfile

info = zipfile.ZipInfo("link")
info.external_attr = (0o120777 << 16)
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr(info, "target")
PY
	echo "$zip_path"
}

_setup_artifact_zip_gh_mock() {
	local zip_path="$1"
	local artifact_id="${2:-99}"

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
url=""
for ((i = 1; i <= \$#; i++)); do
	case "\${!i}" in
	repos/*) url="\${!i}" ;;
	esac
done

case "\$url" in
*actions/artifacts/${artifact_id}/zip*)
	cat "${zip_path}"
	;;
*)
	echo ""
	;;
esac
exit 0
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

_create_artifact_zip() {
	local zip_path="${BATS_TEST_TMPDIR}/artifact.zip"
	local root="${BATS_TEST_TMPDIR}/artifact-root"
	mkdir -p "$root"
	echo '<html>report</html>' >"${root}/index.html"
	(
		cd "$root" || exit 1
		zip -q "$zip_path" index.html
	)
	echo "$zip_path"
}

_setup_bundle_gh_mock() {
	local run_id="${1:-42}"
	local artifact_id="${2:-99}"
	local zip_path
	zip_path=$(_create_artifact_zip)

	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
url=""
for ((i = 1; i <= \$#; i++)); do
	case "\${!i}" in
	repos/*) url="\${!i}" ;;
	esac
done

case "\$url" in
*actions/runs?head_sha=abc123*)
	cat <<'JSON'
{"workflow_runs":[
  {"id":${run_id},"name":"quality-ci-main","path":".github/workflows/quality-ci-main.yml","conclusion":"success","head_branch":"main"},
  {"id":${run_id},"name":"coverage-reports","path":".github/workflows/coverage-reports.yml","conclusion":"success","head_branch":"main"}
]}
JSON
	;;
*actions/workflows/*/runs?branch=main*)
	cat <<'JSON'
{"workflow_runs":[
  {"id":${run_id},"conclusion":"success","head_branch":"main"}
]}
JSON
	;;
*actions/workflows?*)
	cat <<'JSON'
{"workflows":[
  {"id":7,"name":"quality-ci-main","path":".github/workflows/quality-ci-main.yml"},
  {"id":8,"name":"coverage-reports","path":".github/workflows/coverage-reports.yml"}
]}
JSON
	;;
*actions/runs/${run_id}/artifacts*)
	cat <<'JSON'
{"artifacts":[
  {"id":${artifact_id},"name":"coverage-html"},
  {"id":${artifact_id},"name":"rust-coverage-html"}
]}
JSON
	;;
*actions/artifacts/${artifact_id}/zip*)
	cat "${zip_path}"
	;;
*)
	echo '{"workflow_runs":[],"artifacts":[]}'
	;;
esac
exit 0
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
}

@test "bundle_run_manifest: ignores malicious bundle id in staging paths" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"../../outside","workflow":"quality-ci-main","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_success
	assert_file_exists "${SITE_ROOT}/coverage/index.html"
	run test ! -e "${BATS_TEST_TMPDIR}/outside"
	assert_success
}

@test "bundle_validate_zip_members: rejects absolute zip entries" {
	local zip_path
	zip_path=$(_create_absolute_artifact_zip)

	run bundle_validate_zip_members "$zip_path" 42
	assert_failure
	assert_output --partial "Zip entry is absolute"
}

@test "bundle_validate_zip_members: rejects path traversal entries" {
	local zip_path
	zip_path=$(_create_traversal_artifact_zip)

	run bundle_validate_zip_members "$zip_path" 42
	assert_failure
	assert_output --partial "path traversal"
}

@test "bundle_validate_zip_members: allows double dots in filenames" {
	local zip_path="${BATS_TEST_TMPDIR}/double-dot.zip"
	python3 - "$zip_path" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("report..2024.html", "ok")
PY

	run bundle_validate_zip_members "$zip_path" 42
	assert_success
}

@test "bundle_validate_zip_members: rejects symlink entries" {
	local zip_path
	zip_path=$(_create_symlink_artifact_zip)

	run bundle_validate_zip_members "$zip_path" 42
	assert_failure
	assert_output --partial "symlink"
}

@test "bundle_download_artifact: rejects zip slip before extraction" {
	local zip_path dest_dir
	zip_path=$(_create_traversal_artifact_zip)
	dest_dir="${BATS_TEST_TMPDIR}/dest"
	_setup_artifact_zip_gh_mock "$zip_path"

	run bundle_download_artifact 99 "$dest_dir"
	assert_failure
	assert_output --partial "path traversal"
	run test ! -e "${BATS_TEST_TMPDIR}/outside.txt"
	assert_success
}

@test "bundle_find_workflow_run_on_ref: finds run even when branch run listing is dominated by other workflows" {
	# Regression for #663: the old implementation scanned one page of ALL
	# branch runs client-side, so a workflow whose latest run was older than
	# the newest page of runs was reported missing. The generic branch runs
	# endpoint deliberately returns only unrelated workflows here.
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
url=""
for ((i = 1; i <= $#; i++)); do
	case "${!i}" in
	repos/*) url="${!i}" ;;
	esac
done

case "$url" in
*actions/workflows/8/runs?branch=main*)
	echo '{"workflow_runs":[{"id":4242,"conclusion":"success","head_branch":"main"}]}'
	;;
*actions/workflows?*)
	echo '{"workflows":[{"id":8,"name":"coverage-reports","path":".github/workflows/coverage-reports.yml"}]}'
	;;
*actions/runs?branch=main*)
	echo '{"workflow_runs":[{"id":1,"name":"other","path":".github/workflows/other.yml","conclusion":"success","head_branch":"main"}]}'
	;;
*)
	echo '{"workflow_runs":[],"workflows":[],"artifacts":[]}'
	;;
esac
exit 0
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"

	run bundle_find_workflow_run_on_ref "coverage-reports" "main" "true"
	[ "$status" -eq 0 ]
	[ "$output" = "4242" ]
}

@test "bundle_find_workflow_run_on_ref: returns empty when workflow is unknown" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"workflow_runs":[],"workflows":[],"artifacts":[]}'
exit 0
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"

	run bundle_find_workflow_run_on_ref "no-such-workflow" "main" "true"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "bundle_run_manifest: does not claim fallback when lookup fails" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"workflow_runs":[],"artifacts":[]}'
exit 0
EOF
	chmod +x "${mock_bin}/gh"
	export PATH="${mock_bin}:$PATH"
	export FALLBACK_REF="main"
	bundle_load_manifest '{"bundles":[{"id":"missing","workflow":"missing-workflow","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_success
	assert_output --partial "no workflow run found"
	refute_output --partial "using fallback run"
}

@test "bundle_load_manifest: loads inline JSON" {
	bundle_load_manifest '{"bundles":[{"workflow":"ci","artifact":"html","dest":"coverage"}]}'
	run jq -e '.bundles[0].workflow == "ci"' <<<"$BUNDLE_MANIFEST_JSON"
	assert_success
}

@test "bundle_load_manifest: loads JSON file" {
	local manifest="${BATS_TEST_TMPDIR}/manifest.json"
	cat >"$manifest" <<'EOF'
{"bundles":[{"workflow":"ci","artifact":"html","dest":"coverage"}]}
EOF
	bundle_load_manifest "$manifest"
	run jq -e '.bundles[0].artifact == "html"' <<<"$BUNDLE_MANIFEST_JSON"
	assert_success
}

@test "bundle_load_manifest: rejects invalid JSON" {
	run bundle_load_manifest "not-json"
	assert_failure
}

@test "bundle_run_manifest: copies artifact into site root" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"coverage","workflow":"quality-ci-main","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_success
	assert_file_exists "${SITE_ROOT}/coverage/index.html"
	run grep -q 'report' "${SITE_ROOT}/coverage/index.html"
	assert_success
}

@test "bundle_run_manifest: copies rust-coverage-html artifact into site root" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"rust-coverage","workflow":"coverage-reports","artifact":"rust-coverage-html","dest":"coverage-rust"}]}'

	run bundle_run_manifest
	assert_success
	assert_file_exists "${SITE_ROOT}/coverage-rust/index.html"
	run grep -q 'report' "${SITE_ROOT}/coverage-rust/index.html"
	assert_success
}

@test "bundle_run_manifest: records github outputs" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"coverage","workflow":"quality-ci-main","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_success
	grep -q '^files-bundled=1$' "$GITHUB_OUTPUT"
	grep -q '^bundles-applied=1$' "$GITHUB_OUTPUT"
	grep -q '^bundle-warnings=0$' "$GITHUB_OUTPUT"
}

@test "bundle_run_manifest: warns on missing workflow when not strict" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"missing","workflow":"missing-workflow","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_success
	assert_output --partial "no workflow run found"
	grep -q '^bundles-applied=0$' "$GITHUB_OUTPUT"
	grep -q '^bundle-warnings=1$' "$GITHUB_OUTPUT"
}

@test "bundle_run_manifest: fails in strict mode for missing workflow" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"strict":true,"bundles":[{"id":"missing","workflow":"missing-workflow","artifact":"coverage-html","dest":"coverage"}]}'

	run bundle_run_manifest
	assert_failure
}

@test "bundle_run_manifest: rejects dest path traversal" {
	_setup_bundle_gh_mock
	bundle_load_manifest '{"bundles":[{"id":"escape","workflow":"quality-ci-main","artifact":"coverage-html","dest":"../outside"}]}'

	run bundle_run_manifest
	assert_success
	assert_output --partial "must not contain .. segments"
	run test ! -e "${BATS_TEST_TMPDIR}/outside"
	assert_success
}

@test "workflow_artifacts.sh: does not pass jq --arg to gh api" {
	local script="${PROJECT_ROOT}/scripts/ci/lib/bundle/workflow_artifacts.sh"

	run bash -c 'grep "gh api" "$1" | grep -q -- "--arg"' _ "$script"
	assert_failure
	run grep -q 'jq -r --arg' "$script"
	assert_success
}

@test "bundle-workflow-artifacts action script: runs end-to-end" {
	_setup_bundle_gh_mock
	local manifest="${BATS_TEST_TMPDIR}/manifest.json"
	cat >"$manifest" <<'EOF'
{"bundles":[{"id":"coverage","workflow":"quality-ci-main","artifact":"coverage-html","dest":"coverage"}]}
EOF
	export BUNDLE_MANIFEST="$manifest"

	run bash "${PROJECT_ROOT}/scripts/ci/actions/bundle-workflow-artifacts.sh"
	assert_success
	assert_file_exists "${SITE_ROOT}/coverage/index.html"
}
