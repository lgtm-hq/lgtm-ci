#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/recover/* (#966)

load "../../../../helpers/common"
load "../../../../helpers/mocks"

RESOLVE="${PROJECT_ROOT}/scripts/ci/release/recover/resolve-tag.sh"
DETECT="${PROJECT_ROOT}/scripts/ci/release/recover/detect-channels.sh"
VERIFY="${PROJECT_ROOT}/scripts/ci/release/recover/verify-recovery-artifacts.sh"
RECORD="${PROJECT_ROOT}/scripts/ci/release/recover/record-recovery.sh"
DOWNLOAD="${PROJECT_ROOT}/scripts/ci/release/recover/download-artifacts.sh"
REDISPATCH="${PROJECT_ROOT}/scripts/ci/release/recover/redispatch-homebrew.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GH_TOKEN=test-token
	export GITHUB_SERVER_URL=https://github.com
	export GITHUB_RUN_ID=999
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# resolve-tag.sh
# =============================================================================

@test "resolve-tag: passes bash syntax check" {
	run bash -n "$RESOLVE"
	assert_success
}

@test "resolve-tag: refuses prerelease tags with tier-three guidance" {
	export TAG=v1.2.3-rc1
	export EXPECTED_SHA=abc123
	mock_command_multi "gh" '*) exit 1;;'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "refusing to recover prerelease tag"
	assert_output --partial "cut a new prerelease version"
}

@test "resolve-tag: refuses a missing tag" {
	export TAG=v9.9.9
	export EXPECTED_SHA=abc123
	mock_command_multi "gh" '
		*commits*v9.9.9*) echo "Not Found" >&2; exit 1;;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "not found"
}

@test "resolve-tag: refuses a tag that moved off the original commit" {
	export TAG=v1.2.3
	export EXPECTED_SHA=aaa111
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "{\"sha\":\"bbb222\"}";;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "the tag moved"
	assert_output --partial "tier three"
}

@test "resolve-tag: accepts a tag pinned to the original run's commit" {
	export TAG=v1.2.3
	export EXPECTED_SHA=abc123def
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "abc123def";;
	'

	run bash "$RESOLVE"
	assert_success
	assert_output --partial "matches the original run"
}

# =============================================================================
# detect-channels.sh
# =============================================================================

detect_env() {
	export TAG=v1.2.3
	export PYPI_PACKAGE=""
	export NPM_PACKAGE=""
	export DOCKER_IMAGE=""
	export TAP_REPO=""
	export TAP_FORMULA=""
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	: >"$GITHUB_STEP_SUMMARY"
}

@test "detect-channels: passes bash syntax check" {
	run bash -n "$DETECT"
	assert_success
}

@test "detect-channels: unconfigured channels are not applicable and nothing is missing" {
	detect_env
	mock_command_multi "gh" '
		*release*view*--jq*) echo "2";;
		*release*view*) echo "{}";;
	'

	run bash "$DETECT"
	assert_success
	assert_output --partial "Missing channels: []"
	run grep -cF "NOT-APPLICABLE" "$GITHUB_STEP_SUMMARY"
	assert_output 4
}

@test "detect-channels: npm missing lands in the missing set; pypi missing is terminal" {
	detect_env
	export NPM_PACKAGE=@lgtm-hq/pkg
	export PYPI_PACKAGE=pkg
	mock_command_multi "npm" '*view*) exit 1;;'
	mock_command_multi "curl" '*pypi.org*pkg*1.2.3*) printf "404"; exit 0;;'
	mock_command_multi "gh" '
		*release*view*--jq*) echo "0";;
		*release*view*) echo "{}";;
	'

	local output_file="${BATS_TEST_TMPDIR}/out"
	export GITHUB_OUTPUT="$output_file"
	run bash "$DETECT"
	assert_success
	run grep -F "missing=[\"npm\",\"github-release\"]" "$output_file"
	assert_success
	run grep -F "burned on first upload" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "detect-channels: done channels are excluded from the missing set" {
	detect_env
	export NPM_PACKAGE=@lgtm-hq/pkg
	mock_command_multi "npm" '*view*) echo "1.2.3";;'
	mock_command_multi "gh" '
		*release*view*--jq*) echo "2";;
	'

	run bash "$DETECT"
	assert_success
	assert_output --partial "Missing channels: []"
}

@test "detect-channels: channel restriction limits probing" {
	detect_env
	export NPM_PACKAGE=@lgtm-hq/pkg
	export CHANNELS='["npm"]'
	# gh must NOT be called: github-release is not selected.
	mock_command_multi "npm" '*view*) exit 1;;'
	mock_command_multi "gh" '*) echo "must not be called" >&2; exit 99;;'

	run bash "$DETECT"
	assert_success
	run grep -c "github-release" "$GITHUB_STEP_SUMMARY"
	assert_output 0
}

# =============================================================================
# verify-recovery-artifacts.sh
# =============================================================================

# Same preference order as the scripts: GNU coreutils first, shasum fallback.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

verify_env() {
	export ARTIFACTS_DIR="${BATS_TEST_TMPDIR}/artifacts"
	mkdir -p "$ARTIFACTS_DIR"
	echo "artifact-bytes" >"$ARTIFACTS_DIR/tool-linux-x64"
	h="$(sha256_of "$ARTIFACTS_DIR/tool-linux-x64")"
	printf '%s  tool-linux-x64\n' "$h" >"$ARTIFACTS_DIR/SHA256SUMS"
	export CHECKSUMS_FILE="SHA256SUMS"
	export SIGNER_REPO=lgtm-hq/lgtm-ci
	export SIGNER_WORKFLOW=.github/workflows/publish.yml
	export RELEASE_ASSET_DIGESTS=""
}

attest_mock() {
	mock_command_multi "gh" "
		*attestation*verify*) exit $1;;
		*) exit 0;;
	"
}

@test "verify-recovery-artifacts: passes bash syntax check" {
	run bash -n "$VERIFY"
	assert_success
}

@test "verify-recovery-artifacts: passes clean artifacts" {
	verify_env
	attest_mock 0

	run bash "$VERIFY"
	assert_success
	assert_output --partial "Recovery artifacts verified"
}

@test "verify-recovery-artifacts: fails a swapped artifact before any resume" {
	verify_env
	echo "different-bytes" >"$ARTIFACTS_DIR/tool-linux-x64"
	attest_mock 0

	run bash "$VERIFY"
	assert_failure
	assert_output --partial "sha256 mismatch"
	assert_output --partial "nothing was resumed"
}

@test "verify-recovery-artifacts: tier-three stop when the published asset differs from the artifact" {
	verify_env
	local h
	h="$(shasum -a 256 "$ARTIFACTS_DIR/tool-linux-x64" | awk '{print $1}')"
	export RELEASE_ASSET_DIGESTS="{\"tool-linux-x64\":\"sha256:deadbeef\"}"
	attest_mock 0

	run bash "$VERIFY"
	assert_failure
	assert_output --partial "same version, different bytes"
	assert_output --partial "tier three"
}

@test "verify-recovery-artifacts: reads published asset digests from the release when RELEASE_TAG is set" {
	verify_env
	export RELEASE_TAG=v1.2.3
	# The published asset differs from the attested artifact: tier three.
	mock_command_multi "gh" '
		*attestation*verify*) exit 0;;
		*release*view*) echo "{\"tool-linux-x64\":\"sha256:deadbeef\"}";;
		*) exit 0;;
	'
	run bash "$VERIFY"
	assert_failure
	assert_output --partial "Published assets under v1.2.3: 1 with digests"
	assert_output --partial "same version, different bytes"

	# Same bytes already published: equality holds and verification passes.
	local h
	h="$(sha256_of "$ARTIFACTS_DIR/tool-linux-x64")"
	mock_command_multi "gh" "
		*attestation*verify*) exit 0;;
		*release*view*) echo '{\"tool-linux-x64\":\"sha256:${h}\"}';;
		*) exit 0;;
	"
	run bash "$VERIFY"
	assert_success

	# No release yet: nothing to compare, verification still passes.
	mock_command_multi "gh" '
		*attestation*verify*) exit 0;;
		*release*view*) echo "release not found" >&2; exit 1;;
		*) exit 0;;
	'
	run bash "$VERIFY"
	assert_success
	assert_output --partial "No published release under v1.2.3 yet"
}

@test "verify-recovery-artifacts: manifest lookup is an exact path match" {
	verify_env
	echo "plus-bytes" >"$ARTIFACTS_DIR/tool+x64"
	printf '%s  tool+x64\n' "$(sha256_of "$ARTIFACTS_DIR/tool+x64")" >>"$ARTIFACTS_DIR/SHA256SUMS"
	attest_mock 0

	run bash "$VERIFY"
	assert_success
	assert_output --partial "Verifying tool+x64"
}

@test "verify-recovery-artifacts: missing manifest entry is a failure, not a crash" {
	verify_env
	echo "stray" >"$ARTIFACTS_DIR/stray"
	h="$(shasum -a 256 "$ARTIFACTS_DIR/stray" | awk '{print $1}')"
	# A manifest entry pointing at a file that was never downloaded:
	printf '%s  not-downloaded\n' "$h" >>"$ARTIFACTS_DIR/SHA256SUMS"
	attest_mock 0

	run bash "$VERIFY"
	assert_failure
	assert_output --partial "missing from the downloaded artifacts"
}

# =============================================================================
# record-recovery.sh
# =============================================================================

record_env() {
	export TAG=v1.2.3
	export WORKFLOW_KEY=release-publish
	export RECOVERY_SUMMARY="| Channel resume | Result |
| --- | --- |
| npm | success |"
}

@test "record-recovery: passes bash syntax check" {
	run bash -n "$RECORD"
	assert_success
}

@test "record-recovery: comments and closes the issue on success" {
	record_env
	export RECOVERY_STATUS=success
	mock_command_multi "gh" '
		*issue*list*) echo "77";;
		*issue*comment*) echo "ok";;
		*issue*close*) echo "closed";;
	'

	run bash "$RECORD"
	assert_success
	assert_output --partial "Recorded recovery outcome on issue #77"
	assert_output --partial "Closed release-failure issue #77"
}

@test "record-recovery: comments without closing on failure" {
	record_env
	export RECOVERY_STATUS=failure
	mock_command_multi "gh" '
		*issue*list*) echo "77";;
		*issue*comment*) echo "ok";;
		*issue*close*) echo "must not close" >&2; exit 99;;
	'

	run bash "$RECORD"
	assert_success
	assert_output --partial "Recorded recovery outcome on issue #77"
	refute_output --partial "Closed"
}

@test "record-recovery: nothing to record without an open issue" {
	record_env
	export RECOVERY_STATUS=success
	mock_command_multi "gh" '
		*issue*list*) echo "";;
	'

	run bash "$RECORD"
	assert_success
	assert_output --partial "No open release-failure issue"
}

@test "record-recovery: survives a search API outage" {
	record_env
	export RECOVERY_STATUS=success
	mock_command_multi "gh" '
		*issue*list*) echo "rate limited" >&2; exit 1;;
	'

	run bash "$RECORD"
	assert_success
	assert_output --partial "leaving it untouched"
}

@test "record-recovery: rejects an invalid RECOVERY_STATUS" {
	record_env
	export RECOVERY_STATUS=maybe

	run bash "$RECORD"
	assert_failure
	assert_output --partial "RECOVERY_STATUS must be"
}

@test "record-recovery: derives the outcome from the per-job results" {
	export TAG=v1.2.3
	export WORKFLOW_KEY=release-publish
	unset RECOVERY_STATUS RECOVERY_SUMMARY
	export RESOLVE_RESULT=success
	export NPM_RESULT=success
	export RELEASE_RESULT=skipped
	export HOMEBREW_RESULT=skipped
	export MISSING_SET='["npm"]'
	local body="${BATS_TEST_TMPDIR}/comment-body"
	mock_command_multi "gh" "
		*issue*list*) echo 77;;
		*issue*comment*)
			for a in \"\$@\"; do case \"\$a\" in /*) cp \"\$a\" '${body}';; esac; done
			echo ok;;
		*issue*close*) echo closed;;
	"

	run bash "$RECORD"
	assert_success
	assert_output --partial "Closed release-failure issue #77"
	run cat "$body"
	assert_output --partial "| npm | success |"
	assert_output --partial "| GitHub Release | skipped |"
	assert_output --partial 'Missing set at detection: `["npm"]`'

	# A failed (or cancelled) resume, or a failed resolve, is a failed recovery.
	export NPM_RESULT=failure
	mock_command_multi "gh" '
		*issue*list*) echo 77;;
		*issue*comment*) echo ok;;
		*issue*close*) echo "must not close" >&2; exit 99;;
	'
	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"

	export NPM_RESULT=success
	export RESOLVE_RESULT=failure
	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"
}

# =============================================================================
# download-artifacts.sh
# =============================================================================

@test "download-artifacts: passes bash syntax check" {
	run bash -n "$DOWNLOAD"
	assert_success
}

@test "download-artifacts: downloads each configured artifact into its own directory" {
	export SOURCE_RUN_ID=12345
	export NPM_ARTIFACT=npm-dist
	export RELEASE_ARTIFACT=python-dist
	export TARGET_DIR="${BATS_TEST_TMPDIR}/recovery-artifacts"
	local calls="${BATS_TEST_TMPDIR}/gh-calls"
	mock_command_multi "gh" "
		*run*download*)
			echo \"\$*\" >> '${calls}'
			for a in \"\$@\"; do case \"\$a\" in ${BATS_TEST_TMPDIR}/*) mkdir -p \"\$a\"; echo x > \"\$a/file\";; esac; done
			exit 0;;
	"

	run bash "$DOWNLOAD"
	assert_success
	assert_output --partial "Downloading artifact 'npm-dist' from run 12345"
	assert_output --partial "Downloading artifact 'python-dist' from run 12345"
	run grep -c "run download 12345 --repo lgtm-hq/lgtm-ci --name" "$calls"
	assert_output 2
	[[ -f "$TARGET_DIR/npm/file" && -f "$TARGET_DIR/release/file" ]]
}

@test "download-artifacts: an expired or missing artifact fails with tier-three guidance" {
	export SOURCE_RUN_ID=12345
	export NPM_ARTIFACT=npm-dist
	export TARGET_DIR="${BATS_TEST_TMPDIR}/recovery-artifacts"
	mock_command_multi "gh" '
		*run*download*) echo "no artifact matches any of the names or patterns provided" >&2; exit 1;;
	'

	run bash "$DOWNLOAD"
	assert_failure
	assert_output --partial "could not download artifact 'npm-dist'"
	assert_output --partial "90-day retention"
	assert_output --partial "tier three"
}

@test "download-artifacts: an empty artifact is refused" {
	export SOURCE_RUN_ID=12345
	export RELEASE_ARTIFACT=python-dist
	export TARGET_DIR="${BATS_TEST_TMPDIR}/recovery-artifacts"
	mock_command_multi "gh" '
		*run*download*) exit 0;;
	'

	run bash "$DOWNLOAD"
	assert_failure
	assert_output --partial "downloaded no files"
}

@test "download-artifacts: nothing configured is a no-op" {
	export SOURCE_RUN_ID=12345
	run bash "$DOWNLOAD"
	assert_success
	assert_output --partial "nothing to download"
}

# =============================================================================
# redispatch-homebrew.sh
# =============================================================================

@test "redispatch-homebrew: passes bash syntax check" {
	run bash -n "$REDISPATCH"
	assert_success
}

@test "redispatch-homebrew: runs the tap workflow on the given ref with the tag input" {
	export REPO=lgtm-hq/homebrew-tap
	export WORKFLOW=dispatch-homebrew.yml
	export REF=main
	export TAG=v1.2.3
	local calls="${BATS_TEST_TMPDIR}/gh-calls"
	mock_command_multi "gh" "
		*workflow*run*) echo \"\$*\" >> '${calls}'; exit 0;;
	"

	run bash "$REDISPATCH"
	assert_success
	assert_output --partial "Dispatched dispatch-homebrew.yml@main on lgtm-hq/homebrew-tap for v1.2.3"
	run cat "$calls"
	assert_output "workflow run dispatch-homebrew.yml --repo lgtm-hq/homebrew-tap --ref main -f tag=v1.2.3"
}

@test "redispatch-homebrew: a rejected dispatch fails the job" {
	export REPO=lgtm-hq/homebrew-tap
	export WORKFLOW=dispatch-homebrew.yml
	export REF=main
	export TAG=v1.2.3
	mock_command_multi "gh" '
		*workflow*run*) echo "HTTP 404" >&2; exit 1;;
	'

	run bash "$REDISPATCH"
	assert_failure
}
