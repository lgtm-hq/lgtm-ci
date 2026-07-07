#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for SHA-to-tag verification in validate-action-pinning

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-action-pinning.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

create_workflow() {
	local dir="$1"
	local filename="$2"
	local content="$3"
	mkdir -p "$dir"
	printf '%s\n' "$content" >"${dir}/${filename}"
}

@test "validate-action-pinning: verify-tags reuses tag resolution cache across duplicate pins" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
'

	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
case "\$*" in
	*repos/actions/checkout/commits/v4*)
		echo "a5ac7e51b41094c92402da3b24376905380afc29"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_VERIFY_TAGS=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run bash -c 'grep -c "repos/actions/checkout/commits/v4" "'"${BATS_TEST_TMPDIR}"'/mock_calls_gh" || true'
	assert_output "1"
}

@test "validate-action-pinning: verify-tags passes when comment tag resolves to pinned SHA" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
'

	mock_command_multi "gh" '
		*repos/actions/checkout/commits/v4*) echo "a5ac7e51b41094c92402da3b24376905380afc29";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_VERIFY_TAGS=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Verifying 1 Renovate version comment"
}

@test "validate-action-pinning: verify-tags warns when tag resolution returns null SHA" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4
'

	mock_command_multi "gh" '
		*repos/actions/checkout/commits/v4*) echo "null";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_VERIFY_TAGS=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "could not resolve v4 via GitHub API"
	assert_output --partial "verification warning"
	refute_output --partial "All action references follow SHA pinning"
	refute_output --partial "action pinning violation"
	assert_github_output "warnings" "1"
}

@test "validate-action-pinning: verify-tags fails when pinned SHA mismatches comment tag" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000001 # v4
'

	mock_command_multi "gh" '
		*repos/actions/checkout/commits/v4*) echo "a5ac7e51b41094c92402da3b24376905380afc29";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_VERIFY_TAGS=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "pinned SHA does not match v4"
}

@test "validate-action-pinning: verify-tags resolves pre-release version comments" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4.2.2-rc.1
'

	mock_command_multi "gh" '
		*repos/actions/checkout/commits/v4.2.2-rc.1*) echo "a5ac7e51b41094c92402da3b24376905380afc29";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_VERIFY_TAGS=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Verifying 1 Renovate version comment"
}

@test "validate-action-pinning: audit-transitive skips reusable workflow refs" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-quality-lint.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v4
'

	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "unexpected gh call: \$*" >&2
exit 1
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_AUDIT_TRANSITIVE=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	refute_output --partial "could not fetch composite action manifest"
	refute_output --partial "unexpected gh call"
	assert_github_output "warnings" "0"
}

@test "validate-action-pinning: audit-transitive skips when action content is unavailable" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: example/composite-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
'

	mock_command_multi "gh" '
		*repos/example/composite-action/contents/action.yml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) echo "null";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_AUDIT_TRANSITIVE=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "could not fetch composite action manifest for transitive audit"
}

@test "validate-action-pinning: audit-transitive falls back to action.yaml manifests" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: example/composite-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
'

	local encoded
	encoded="$(printf '%s' '---
runs:
  using: composite
  steps:
    - uses: aquasecurity/setup-trivy@v0.2.2
' | base64 | tr -d '\n')"

	mock_command_multi "gh" "
		*repos/example/composite-action/contents/action.yml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) exit 1;;
		*repos/example/composite-action/contents/action.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) echo '${encoded}';;
		*) exit 1;;
	"

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_AUDIT_TRANSITIVE=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "verification warning"
}

@test "validate-action-pinning: prints warnings before enforce exit when offenders exist" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: example/composite-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
'

	local encoded
	encoded="$(printf '%s' '---
runs:
  using: composite
  steps:
    - uses: aquasecurity/setup-trivy@v0.2.2
' | base64 | tr -d '\n')"

	mock_command_multi "gh" "
		*repos/example/composite-action/contents/action.yml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) echo '${encoded}';;
		*) exit 1;;
	"

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_AUDIT_TRANSITIVE=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "action pinning violation"
	assert_output --partial "verification warning"
	assert_output --partial "aquasecurity/setup-trivy@v0.2.2"
	assert_github_output "offenders" "1"
	assert_github_output "warnings" "1"
}

@test "validate-action-pinning: audit-transitive warns on nested mutable tag refs" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: example/composite-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
'

	local encoded
	encoded="$(printf '%s' '---
runs:
  using: composite
  steps:
    - uses: aquasecurity/setup-trivy@v0.2.2
' | base64 | tr -d '\n')"

	mock_command_multi "gh" "
		*repos/example/composite-action/contents/action.yml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) echo '${encoded}';;
		*) exit 1;;
	"

	run bash -c '
		export PATH="'"$PATH"'"
		export INPUT_ENFORCE=true
		export INPUT_AUDIT_TRANSITIVE=true
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "verification warning"
	assert_output --partial "aquasecurity/setup-trivy@v0.2.2"
}
