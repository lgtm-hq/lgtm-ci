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

# The source run as the API reports it: repository, workflow path, head SHA.
resolve_env() {
	export TAG=v1.2.3
	export SOURCE_RUN_ID=12345
	export SOURCE_WORKFLOW=.github/workflows/publish-pypi-on-tag.yml
}

@test "resolve-tag: refuses prerelease tags with tier-three guidance" {
	resolve_env
	export TAG=v1.2.3-rc1
	mock_command_multi "gh" '*) exit 1;;'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "refusing to recover prerelease tag"
	assert_output --partial "cut a new prerelease version"
}

@test "resolve-tag: refuses PEP 440 and SemVer prerelease spellings, accepts final versions" {
	resolve_env
	mock_command_multi "gh" '*) echo "must not be called" >&2; exit 99;;'
	local tag
	for tag in v1.2.3rc1 v1.2.3a1 v1.2.3b2 v1.2.3-rc.1 v1.2.3-beta.1 v1.2.3-alpha1 v1.2.3.dev4 v1.2.3-pre; do
		export TAG="$tag"
		run bash "$RESOLVE"
		assert_failure
		assert_output --partial "refusing to recover prerelease tag '${tag}'"
	done
	# Final versions reach the tag lookup (the mock then refuses, proving the
	# gate let them through).
	for tag in v1.2.3 v1.2.30 v10.0.0; do
		export TAG="$tag"
		run bash "$RESOLVE"
		assert_failure
		refute_output --partial "prerelease"
		assert_output --partial "not found"
	done
}

@test "resolve-tag: refuses a missing tag" {
	resolve_env
	export TAG=v9.9.9
	mock_command_multi "gh" '
		*commits*v9.9.9*) echo "Not Found" >&2; exit 1;;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "not found"
}

@test "resolve-tag: refuses a tag that moved off the source run's commit" {
	resolve_env
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "bbb222";;
		*actions/runs/12345*) printf "lgtm-hq/lgtm-ci\t.github/workflows/publish-pypi-on-tag.yml\taaa111\n";;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "source run 12345 built aaa111"
	assert_output --partial "tier three"
}

@test "resolve-tag: refuses a source run that is not found" {
	resolve_env
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "abc123def";;
		*actions/runs/12345*) echo "Not Found" >&2; exit 1;;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "source run 12345 not found"
}

@test "resolve-tag: refuses a source run from another repository" {
	resolve_env
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "abc123def";;
		*actions/runs/12345*) printf "someone-else/fork\t.github/workflows/publish-pypi-on-tag.yml\tabc123def\n";;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "belongs to 'someone-else/fork', not lgtm-hq/lgtm-ci"
}

@test "resolve-tag: refuses a source run of a different workflow even at the tag's commit" {
	resolve_env
	# Same commit, but a CI run (not the publish workflow): its artifacts are
	# not the release's.
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "abc123def";;
		*actions/runs/12345*) printf "lgtm-hq/lgtm-ci\t.github/workflows/ci.yml\tabc123def\n";;
	'

	run bash "$RESOLVE"
	assert_failure
	assert_output --partial "is a run of '.github/workflows/ci.yml', not the publish workflow '.github/workflows/publish-pypi-on-tag.yml'"
}

@test "resolve-tag: accepts a publish-workflow run that built the tag's commit" {
	resolve_env
	local output_file="${BATS_TEST_TMPDIR}/out"
	export GITHUB_OUTPUT="$output_file"
	mock_command_multi "gh" '
		*commits*v1.2.3*) echo "abc123def";;
		*actions/runs/12345*) printf "lgtm-hq/lgtm-ci\t.github/workflows/publish-pypi-on-tag.yml\tabc123def\n";;
	'

	run bash "$RESOLVE"
	assert_success
	assert_output --partial "source run 12345 (.github/workflows/publish-pypi-on-tag.yml) built the same commit"
	run grep -F "head_sha=abc123def" "$output_file"
	assert_success
}

# =============================================================================
# detect-channels.sh
# =============================================================================

detect_env() {
	export TAG=v1.2.3
	export PYPI_PACKAGE=""
	export NPM_PACKAGE=""
	export RELEASE_MANIFEST=""
	export DOCKER_IMAGE=""
	export TAP_REPO=""
	export TAP_FORMULA=""
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	: >"$GITHUB_STEP_SUMMARY"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/detect-out"
	: >"$GITHUB_OUTPUT"
}

# A verified release manifest with two assets; returns nothing, sets
# RELEASE_MANIFEST and the digests H1/H2.
release_manifest_env() {
	local dir="${BATS_TEST_TMPDIR}/release"
	mkdir -p "$dir"
	echo "wheel-bytes" >"$dir/pkg-1.2.3-py3-none-any.whl"
	echo "sdist-bytes" >"$dir/pkg-1.2.3.tar.gz"
	H1="$(sha256_of "$dir/pkg-1.2.3-py3-none-any.whl")"
	H2="$(sha256_of "$dir/pkg-1.2.3.tar.gz")"
	printf '%s  pkg-1.2.3-py3-none-any.whl\n%s  pkg-1.2.3.tar.gz\n' "$H1" "$H2" >"$dir/SHA256SUMS"
	export RELEASE_MANIFEST="$dir/SHA256SUMS"
}

@test "detect-channels: passes bash syntax check" {
	run bash -n "$DETECT"
	assert_success
}

@test "detect-channels: unconfigured channels are not applicable and nothing is missing" {
	detect_env
	mock_command_multi "gh" '*) echo "must not be called" >&2; exit 99;;'

	run bash "$DETECT"
	assert_success
	assert_output --partial "Missing channels: []"
	assert_output --partial "Unresumable channels: []"
	run grep -cF "NOT-APPLICABLE" "$GITHUB_STEP_SUMMARY"
	assert_output 5
}

@test "detect-channels: npm missing lands in the missing set; pypi missing is terminal and unresumable" {
	detect_env
	export NPM_PACKAGE=@lgtm-hq/pkg
	export PYPI_PACKAGE=pkg
	mock_command_multi "npm" '*view*) exit 1;;'
	mock_command_multi "curl" '*pypi.org*pkg*1.2.3*) printf "404"; exit 0;;'

	run bash "$DETECT"
	assert_success
	run grep -F 'missing=["npm"]' "$GITHUB_OUTPUT"
	assert_success
	run grep -F 'unresumable=["pypi"]' "$GITHUB_OUTPUT"
	assert_success
	run grep -F "burned on first upload" "$GITHUB_STEP_SUMMARY"
	assert_success
}

@test "detect-channels: done channels are excluded from the missing set" {
	detect_env
	export NPM_PACKAGE=@lgtm-hq/pkg
	release_manifest_env
	mock_command_multi "npm" '*view*) echo "1.2.3";;'
	mock_command_multi "gh" "
		*release*view*) printf 'pkg-1.2.3-py3-none-any.whl\tsha256:${H1}\npkg-1.2.3.tar.gz\tsha256:${H2}\nSHA256SUMS\tsha256:abc\n';;
	"

	run bash "$DETECT"
	assert_success
	assert_output --partial "Missing channels: []"
	assert_output --partial "all 2 manifest assets published with matching digests"
}

@test "detect-channels: a release with some manifest assets is partial and resumed" {
	detect_env
	release_manifest_env
	mock_command_multi "gh" "
		*release*view*) printf 'pkg-1.2.3-py3-none-any.whl\tsha256:${H1}\n';;
	"

	run bash "$DETECT"
	assert_success
	assert_output --partial "1/2 manifest assets published; absent: pkg-1.2.3.tar.gz"
	run grep -F 'missing=["github-release"]' "$GITHUB_OUTPUT"
	assert_success
}

@test "detect-channels: a release that does not exist is missing" {
	detect_env
	release_manifest_env
	mock_command_multi "gh" '
		*release*view*) echo "release not found" >&2; exit 1;;
	'

	run bash "$DETECT"
	assert_success
	assert_output --partial "release does not exist"
	run grep -F 'missing=["github-release"]' "$GITHUB_OUTPUT"
	assert_success
}

@test "detect-channels: a published asset with a different digest is tier three and fails detection" {
	detect_env
	release_manifest_env
	mock_command_multi "gh" "
		*release*view*) printf 'pkg-1.2.3-py3-none-any.whl\tsha256:deadbeef\npkg-1.2.3.tar.gz\tsha256:${H2}\n';;
	"

	run bash "$DETECT"
	assert_failure
	assert_output --partial "MISMATCH"
	assert_output --partial "pkg-1.2.3-py3-none-any.whl (published sha256:deadbeef"
	assert_output --partial "tier three"
	# Never offered for resume: a resume would overwrite different bytes.
	run grep -F 'missing=[]' "$GITHUB_OUTPUT"
	assert_success
	run grep -F 'unresumable=["github-release"]' "$GITHUB_OUTPUT"
	assert_success
}

@test "detect-channels: a published asset without a digest cannot be proven identical" {
	detect_env
	release_manifest_env
	mock_command_multi "gh" "
		*release*view*) printf 'pkg-1.2.3-py3-none-any.whl\t\npkg-1.2.3.tar.gz\tsha256:${H2}\n';;
	"

	run bash "$DETECT"
	assert_failure
	assert_output --partial "published no digest"
}

@test "detect-channels: a missing Docker image is unresumable, not a resume target" {
	detect_env
	export DOCKER_IMAGE=ghcr.io/lgtm-hq/tool
	mock_command_multi "crane" '*digest*) exit 1;;'

	run bash "$DETECT"
	assert_success
	run grep -F 'missing=[]' "$GITHUB_OUTPUT"
	assert_success
	run grep -F 'unresumable=["docker"]' "$GITHUB_OUTPUT"
	assert_success
}

@test "detect-channels: homebrew compares the formula version string exactly" {
	detect_env
	export TAP_REPO=lgtm-hq/homebrew-tap
	export TAP_FORMULA=tool
	# gh returns the base64 content of a formula; the version is 1.2.30, a
	# superstring of 1.2.3 that a loose match would accept.
	local formula
	formula="$(printf 'class Tool < Formula\n  url "https://example/1.2.30.tar.gz"\n  version "1.2.30"\nend\n' | base64)"
	mock_command_multi "gh" "
		*contents/Formula/tool.rb*) echo '${formula}';;
	"
	run bash "$DETECT"
	assert_success
	assert_output --partial "formula version is 1.2.30, expected 1.2.3"
	run grep -F 'missing=["homebrew"]' "$GITHUB_OUTPUT"
	assert_success

	formula="$(printf 'class Tool < Formula\n  version "1.2.3"\nend\n' | base64)"
	mock_command_multi "gh" "
		*contents/Formula/tool.rb*) echo '${formula}';;
	"
	run bash "$DETECT"
	assert_success
	assert_output --partial "formula version 1.2.3 matches"
	assert_output --partial "Missing channels: []"

	# No version string at all (or a missing formula) is missing.
	formula="$(printf 'class Tool < Formula\n  url "https://example/1.2.3.tar.gz"\nend\n' | base64)"
	mock_command_multi "gh" "
		*contents/Formula/tool.rb*) echo '${formula}';;
	"
	run bash "$DETECT"
	assert_success
	assert_output --partial "has no version string"
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

@test "verify-recovery-artifacts: fails when attestation verification fails" {
	verify_env
	attest_mock 1

	run bash "$VERIFY"
	assert_failure
	assert_output --partial "attestation verification failed for 'tool-linux-x64'"
	assert_output --partial "nothing was resumed"
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

@test "verify-recovery-artifacts: qualifies a bare signer-workflow with the signer repo for gh" {
	verify_env
	local calls="${BATS_TEST_TMPDIR}/gh-calls"
	mock_command_multi "gh" "
		*attestation*verify*) echo \"\$*\" >> '${calls}'; exit 0;;
		*) exit 0;;
	"

	run bash "$VERIFY"
	assert_success
	run grep -F -- "--signer-workflow lgtm-hq/lgtm-ci/.github/workflows/publish.yml" "$calls"
	assert_success

	# Already qualified: passed through unchanged.
	: >"$calls"
	export SIGNER_WORKFLOW=other-org/builder/.github/workflows/build.yml
	run bash "$VERIFY"
	assert_success
	run grep -F -- "--signer-workflow other-org/builder/.github/workflows/build.yml" "$calls"
	assert_success
	run grep -F -- "lgtm-hq/lgtm-ci/other-org" "$calls"
	assert_failure
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

# Per-job results for the derived-outcome tests; the mock refuses to close.
derived_env() {
	export TAG=v1.2.3
	export WORKFLOW_KEY=release-publish
	unset RECOVERY_STATUS RECOVERY_SUMMARY
	export RESOLVE_RESULT=success
	export NPM_RESULT=skipped
	export RELEASE_RESULT=skipped
	export HOMEBREW_RESULT=skipped
	export MISSING_SET='[]'
	export UNRESUMABLE_SET='[]'
	export DRY_RUN=0
	export BODY_FILE="${BATS_TEST_TMPDIR}/comment-body"
	mock_command_multi "gh" "
		*issue*list*) echo 77;;
		*issue*comment*)
			for a in \"\$@\"; do case \"\$a\" in /*) cp \"\$a\" '${BODY_FILE}';; esac; done
			echo ok;;
		*issue*close*) echo \"must not close\" >&2; exit 99;;
	"
}

@test "record-recovery: a dry run records the table and leaves the issue open" {
	derived_env
	export DRY_RUN=1
	export MISSING_SET='["npm"]'

	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"
	run cat "$BODY_FILE"
	assert_output --partial "Release recovery run — dry-run"
	assert_output --partial "this issue stays open"
}

@test "record-recovery: an unresumable missing channel (PyPI, Docker) keeps the issue open" {
	derived_env
	export UNRESUMABLE_SET='["pypi"]'
	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"
	run cat "$BODY_FILE"
	assert_output --partial "pypi is missing and cannot be resumed by this workflow"

	export UNRESUMABLE_SET='["docker"]'
	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"
}

@test "record-recovery: a detected-missing channel whose resume did not run keeps the issue open" {
	derived_env
	# npm was missing but its resume job was skipped (gate not met).
	export MISSING_SET='["npm"]'
	run bash "$RECORD"
	assert_success
	refute_output --partial "Closed"
	run cat "$BODY_FILE"
	assert_output --partial "npm still missing (resume result: skipped)"
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
	export UNRESUMABLE_SET='[]'
	export DRY_RUN=0
	local body="${BATS_TEST_TMPDIR}/comment-body"
	mock_command_multi "gh" "
		*issue*list*) echo 77;;
		*issue*comment*)
			for a in \"\$@\"; do case \"\$a\" in /*) cp \"\$a\" '${body}';; esac; done
			echo ok;;
		*issue*close*) echo closed;;
	"

	# Live run, resolve succeeded, the one missing channel resumed: close.
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

@test "redispatch-homebrew: refuses to run without the cross-repo token" {
	export REPO=lgtm-hq/homebrew-tap
	export WORKFLOW=dispatch-homebrew.yml
	export REF=main
	export TAG=v1.2.3
	export GH_TOKEN=""
	mock_command_multi "gh" '*) echo "must not be called" >&2; exit 99;;'

	run bash "$REDISPATCH"
	assert_failure
	assert_output --partial "needs the homebrew-dispatch-token secret"
	assert_output --partial "Nothing was dispatched"
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
