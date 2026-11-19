#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/maintenance/attestation-store-drift.sh (#1644)
#
# gh is the stub in tests/helpers/gh_issue_stub.bash: the release and
# attestations answers come from STUB_API_DIR, the issue calls are logged.

load "../../helpers/common"
load "../../helpers/fake_python"
load "../../helpers/gh_issue_stub"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/attestation-store-drift.sh"
FIXTURES="${PROJECT_ROOT}/tests/fixtures/attestation-store"
MARKER="<!-- lgtm-ci:attestation-store-host -->"
BOT="github-actions[bot]"
DIGEST_A="sha256:79e7ab5db738c48777b696e374f8b428f0647debfb424f44d2f426370407fe2f"
DIGEST_B="sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup() {
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GITHUB_RUN_ID=12345
	export STUB_API_DIR="${BATS_TEST_TMPDIR}/api"
	mkdir -p "$STUB_API_DIR"
	install_gh_issue_stub
	cp "$FIXTURES/release.json" "$STUB_API_DIR/repos_cli_cli_releases_latest.json"
	answer "$DIGEST_A" "$FIXTURES/attestations.json"
	answer "$DIGEST_B" "$FIXTURES/attestations.json"
}

# answer <digest> <file>: the stub's attestations answer for one digest.
answer() {
	cp "$2" "$STUB_API_DIR/repos_cli_cli_attestations_$1.json"
}

# moved_answer <digest>: an answer whose bundle_url is on another host.
moved_answer() {
	jq '.attestations[0].bundle_url = "https://elsewhere.blob.core.windows.net/a.json?sig=x"' \
		"$FIXTURES/attestations.json" >"${BATS_TEST_TMPDIR}/moved.json"
	answer "$1" "${BATS_TEST_TMPDIR}/moved.json"
}

@test "attestation-store-drift.sh: match with no open issue changes nothing" {
	add_issue 7 "$BOT" Bot "<!-- lgtm-ci:results-hosts-drift --> other tracker"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "no tracking issue to close"
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
	# Both digests, sorted by asset name (checksums first), and only those.
	run grep -c '^api repos/cli/cli/attestations/' "$GH_CALLS"
	assert_output "2"
}

@test "attestation-store-drift.sh: match closes the tracking issue" {
	add_issue 42 "$BOT" Bot "$MARKER older"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Closed tracking issue #42"
	run grep -E '^issue close 42 .*--reason completed' "$GH_CALLS"
	assert_success
}

@test "attestation-store-drift.sh: a moved host opens one issue and fails the run" {
	moved_answer "$DIGEST_B"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "elsewhere.blob.core.windows.net"
	refute_output --partial "sig=x"
	assert_new_issue_only
	run grep -F 'fix(egress): attestation bundle host differs from the release-recover preset' "$GH_CALLS"
	assert_success
}

@test "attestation-store-drift.sh: MAX_SUBJECTS bounds the attestation calls" {
	export MAX_SUBJECTS=1
	run bash "$SCRIPT"
	assert_success
	run grep '^api repos/cli/cli/attestations/' "$GH_CALLS"
	assert_output "api repos/cli/cli/attestations/${DIGEST_B}"
}

@test "attestation-store-drift.sh: a failed attestations call fails closed" {
	rm "$STUB_API_DIR/repos_cli_cli_attestations_${DIGEST_A}.json"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not fetch the attestations"
	run grep -E '^issue' "$GH_CALLS"
	assert_failure
}

@test "attestation-store-drift.sh: a release without digests fails closed" {
	jq '.assets |= map(.digest = null)' "$FIXTURES/release.json" \
		>"$STUB_API_DIR/repos_cli_cli_releases_latest.json"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "no asset with a sha256 digest"
	run grep -E '^issue' "$GH_CALLS"
	assert_failure
}

@test "attestation-store-drift.sh: a malformed digest fails closed" {
	jq '.assets[0].digest = "sha256:../../issues"' "$FIXTURES/release.json" \
		>"$STUB_API_DIR/repos_cli_cli_releases_latest.json"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Unexpected asset digest"
}

@test "attestation-store-drift.sh: a rejected SUBJECT_REPO fails before any call" {
	export SUBJECT_REPO='cli/cli/../x'
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "SUBJECT_REPO is not owner/name"
	[[ ! -s "$GH_CALLS" ]]
}

@test "attestation-store-drift.sh: Python older than 3.11 is an error, never a mismatch" {
	write_fake_python "${BATS_TEST_TMPDIR}/fake-python" "exit 1" 3.10.12
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
}

@test "attestation-store-drift.sh: requires GH_TOKEN" {
	unset GH_TOKEN
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "GH_TOKEN is required"
}

@test "attestation-store-drift.sh: an attestation with no bundle data fails closed" {
	echo '{"attestations":[{}]}' >"${BATS_TEST_TMPDIR}/empty.json"
	answer "$DIGEST_B" "${BATS_TEST_TMPDIR}/empty.json"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "neither bundle_url nor bundle"
	run grep -E '^issue' "$GH_CALLS"
	assert_failure
}

@test "attestation-store-drift.sh: an inline bundle beside on-host URLs is a match" {
	jq '.attestations[0] |= (.bundle_url = null
		| .bundle = {mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json"})' \
		"$FIXTURES/attestations.json" >"${BATS_TEST_TMPDIR}/mixed.json"
	answer "$DIGEST_B" "${BATS_TEST_TMPDIR}/mixed.json"
	run bash "$SCRIPT"
	assert_success
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
}

# Each failed issue write is an error (2), never the mismatch status (1).
@test "attestation-store-drift.sh: a failed close on a match exits 2" {
	add_issue 42 "$BOT" Bot "$MARKER older"
	export STUB_CLOSE_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not close tracking issue #42"
}

@test "attestation-store-drift.sh: a failed create on a mismatch exits 2" {
	moved_answer "$DIGEST_B"
	export STUB_CREATE_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not open the attestation store host tracking issue"
}

@test "attestation-store-drift.sh: a failed edit on a changed mismatch exits 2" {
	moved_answer "$DIGEST_B"
	add_issue 42 "$BOT" Bot "$MARKER older mismatch"
	export STUB_EDIT_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "its body is unchanged"
	run grep -E '^issue comment' "$GH_CALLS"
	assert_failure
}

@test "attestation-store-drift.sh: a failed comment after an edit exits 2 and says so" {
	moved_answer "$DIGEST_B"
	add_issue 42 "$BOT" Bot "$MARKER older mismatch"
	export STUB_COMMENT_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Updated the body of tracking issue #42, but could not comment"
}
