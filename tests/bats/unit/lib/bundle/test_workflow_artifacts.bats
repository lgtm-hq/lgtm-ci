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
workflow=""
for ((i = 1; i <= \$#; i++)); do
	case "\${!i}" in
	repos/*) url="\${!i}" ;;
	--arg)
		next=\$((i + 1))
		if [[ "\${!next}" == "wf" ]]; then
			wf_index=\$((i + 2))
			workflow="\${!wf_index}"
		fi
		;;
	esac
done

case "\$url" in
*actions/runs?head_sha=abc123*)
	if [[ "\$workflow" == "missing-workflow" ]]; then
		echo ""
	else
		echo "${run_id}"
	fi
	;;
*actions/runs?branch=main*)
	echo "${run_id}"
	;;
*actions/runs/${run_id}/artifacts*)
	echo "${artifact_id}"
	;;
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
