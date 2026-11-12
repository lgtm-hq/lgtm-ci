#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the version-update-hook trust split (#849).
#
# The caller's version-update-script must run in a job that holds no App
# token and no secrets, hand its edits over as a diff, and never be executed
# by the job that mints the token. The App token must be scoped to the
# calling repository. Both release version-PR reusables share the shape.

load "../../helpers/common"

VERSION_PR="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
MULTI_ECO="${PROJECT_ROOT}/.github/workflows/reusable-release-multi-ecosystem.yml"
AUTO_TAG="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

# Print one top-level job block (from `  <id>:` to the next job key).
_job_block() {
	local workflow="$1" job="$2"
	awk -v job="$job" '
		$0 == "  " job ":" { in_job = 1; print; next }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { in_job = 0 }
		in_job { print }
	' "$workflow"
}

_assert_hook_job_isolated() {
	local workflow="$1"
	local block
	block="$(_job_block "$workflow" "version-update-hook")"
	[[ -n "$block" ]] || {
		echo "no version-update-hook job in ${workflow}" >&2
		return 1
	}

	# Exactly one permission scope, read-only.
	local perms
	perms="$(printf '%s\n' "$block" | awk '
		/^    permissions:/ { in_perms = 1; next }
		in_perms && /^      [a-z-]+: / { print $1 $2; next }
		in_perms && !/^      #/ { in_perms = 0 }
	')"
	[[ "$perms" == "contents:read" ]] || {
		echo "hook job permissions must be exactly contents: read, got: ${perms}" >&2
		return 1
	}

	# No secret, token or App-token reference of any spelling.
	local forbidden
	for forbidden in 'secrets\.' 'GH_TOKEN' 'GITHUB_TOKEN' 'github\.token' \
		'app-token' 'create-github-app-token' 'token:'; do
		if printf '%s\n' "$block" | grep -Eq "$forbidden"; then
			echo "hook job references '${forbidden}'" >&2
			return 1
		fi
	done

	# Runs the hook through the sandboxing script and ships the diff.
	printf '%s\n' "$block" | grep -Fq 'run-version-update-hook.sh' || return 1
	printf '%s\n' "$block" | grep -Fq 'RELEASE_METADATA_PATH:' || return 1
	printf '%s\n' "$block" | grep -Eq 'name: release-[a-z-]+-hook-changes-\$\{\{ needs\.prepare\.outputs\.artifact-key \}\}' || return 1
	printf '%s\n' "$block" | grep -Fq 'if-no-files-found: error' || return 1
}

# The hook job holds no credential, so it cannot check out the tooling
# (#1451): prepare packs it, and the hook downloads, verifies and extracts it
# before anything reads or runs the caller's code.
_assert_hook_job_receives_packed_tooling() {
	local workflow="$1"
	local block
	block="$(_job_block "$workflow" "version-update-hook")"
	[[ -n "$block" ]] || return 1

	# No tooling checkout of any spelling.
	local forbidden
	for forbidden in 'path: .lgtm-ci-tooling' 'workflow_repository' \
		'check-tooling-ref-divergence'; do
		if printf '%s\n' "$block" | grep -Fq "$forbidden"; then
			echo "hook job still checks out tooling ('${forbidden}')" >&2
			return 1
		fi
	done

	printf '%s\n' "$block" | awk '
		function fail(msg) { print msg > "/dev/stderr"; bad = 1; exit }
		/uses: actions\/download-artifact@/ { dl_uses = NR }
		/name: release-[a-z-]+-tooling-\$\{\{ needs\.prepare\.outputs\.artifact-key \}\}/ {
			if (dl_uses == 0 || NR != dl_uses + 2) fail("tooling artifact is not a download-artifact step")
			download = NR
		}
		download && !dl_path && /path: / {
			dl_path = NR
			if ($0 !~ /path: \$\{\{ runner\.temp \}\}\/hook-tooling$/) fail("tooling download must go to runner.temp/hook-tooling")
		}
		/EXPECTED_DIGEST: \$\{\{ needs\.prepare\.outputs\.tooling-digest \}\}/ { digest_env = NR }
		/shasum -a 256 -c -/ { verify = NR }
		/tar -xzf .*--no-same-owner -C \.lgtm-ci-tooling/ { extract = NR }
		/\.lgtm-ci-tooling\/scripts\// && !first_tool { first_tool = NR }
		/name: Download release metadata/ { metadata = NR }
		/run-version-update-hook\.sh/ { hook = NR }
		END {
			if (bad) exit 1
			if (!download) { print "no tooling download" > "/dev/stderr"; exit 1 }
			if (!(download < digest_env && digest_env < verify && verify < extract)) {
				print "tooling must be downloaded, then digest-checked, then extracted" > "/dev/stderr"; exit 1
			}
			if (!(extract < metadata && extract < first_tool && extract < hook)) {
				print "tooling must be in place before any caller-code step" > "/dev/stderr"; exit 1
			}
		}
	' || return 1

	# Values reach the inline step through env:, never ${{ }} in run:.
	if printf '%s\n' "$block" | grep -E '^\s+(run:|\[\[|printf|mkdir|tar) ' | grep -Fq '${{'; then
		echo "hook job interpolates an expression into run:" >&2
		return 1
	fi

	# prepare packs the guarded checkout and exposes the digest.
	local prepare
	prepare="$(_job_block "$workflow" "prepare")"
	printf '%s\n' "$prepare" | grep -Fq 'tooling-digest: ${{ steps.pack-tooling.outputs.digest }}' || return 1
	printf '%s\n' "$prepare" | grep -Fq '.lgtm-ci-tooling/scripts/ci/release/pack-hook-tooling.sh' || return 1
	printf '%s\n' "$prepare" | grep -Eq 'name: release-[a-z-]+-tooling-\$\{\{ steps\.artifact-key\.outputs\.key \}\}' || return 1
	printf '%s\n' "$prepare" | awk '
		/name: Refuse a diverging tooling-ref/ { guard = NR }
		/pack-hook-tooling\.sh/ { pack = NR }
		END { exit !(guard && pack && guard < pack) }
	' || {
		echo "prepare must pack the tooling after its divergence guard" >&2
		return 1
	}

	# Only the hook job consumes the artifact.
	local job
	for job in version-pr report-release-failure; do
		if _job_block "$workflow" "$job" | grep -Eq 'release-[a-z-]+-tooling-'; then
			echo "${job} consumes the hook tooling artifact" >&2
			return 1
		fi
	done
}

_assert_privileged_job_runs_no_caller_code() {
	local workflow="$1"
	local block
	block="$(_job_block "$workflow" "version-pr")"
	[[ -n "$block" ]] || return 1

	# Every run: step executes lgtm-ci tooling or a fixed inline command;
	# nothing resolves a caller-supplied path.
	local forbidden
	for forbidden in 'SCRIPT_PATH' 'validate-version-update-script.sh' \
		'run-version-update-hook.sh' 'run-version-update-script.sh' \
		'steps.validate-script'; do
		if printf '%s\n' "$block" | grep -Fq "$forbidden"; then
			echo "privileged job still references '${forbidden}'" >&2
			return 1
		fi
	done
	if printf '%s\n' "$block" | grep -E '^\s+run:' | grep -Eq 'version-update-script|inputs\.'; then
		echo "privileged job has a run: line built from caller input" >&2
		return 1
	fi

	# The hook's output enters only as a downloaded diff that is applied by
	# fixed code, after the download.
	printf '%s\n' "$block" | awk '
		/name: release-[a-z-]+-hook-changes-/ { saw_download = 1 }
		saw_download && /apply-version-update-changes.sh/ { saw_apply = 1; exit }
		END { exit !(saw_download && saw_apply) }
	' || return 1

	# Depends on the hook job and refuses to run after a hook failure.
	printf '%s\n' "$block" | grep -Fq 'needs: [prepare, version-update-hook]' || return 1
	printf '%s\n' "$block" | grep -Fq "needs.version-update-hook.result == 'success' || needs.version-update-hook.result == 'skipped'" || return 1
	printf '%s\n' "$block" | grep -Fq "needs.prepare.result == 'success' || needs.prepare.result == 'skipped'" || return 1
	# The diff is refused when prepare and version-pr resolved different versions.
	printf '%s\n' "$block" | grep -Fq 'EXPECTED_NEXT_VERSION: ${{ needs.prepare.outputs.next-version }}' || return 1
}

_assert_prepare_job_shape() {
	local workflow="$1"
	local block
	block="$(_job_block "$workflow" "prepare")"
	[[ -n "$block" ]] || return 1
	printf '%s\n' "$block" | grep -Fq "if: inputs.version-update-script != ''" || return 1
	printf '%s\n' "$block" | grep -Fq 'contents: read' || return 1
	printf '%s\n' "$block" | grep -Fq 'pull-requests: read' || return 1
	if printf '%s\n' "$block" | grep -Eq 'contents: write|pull-requests: write'; then
		return 1
	fi
	# Metadata is fetched by fixed code with the token and shipped read-only.
	printf '%s\n' "$block" | grep -Fq 'write-release-metadata.sh' || return 1
	printf '%s\n' "$block" | grep -Eq 'name: release-[a-z-]+-metadata-\$\{\{ steps\.artifact-key\.outputs\.key \}\}' || return 1
	# The hook job is gated on prepare's verdict, never on caller input alone.
	_job_block "$workflow" "version-update-hook" |
		grep -Fq "if: needs.prepare.outputs.hook-needed == 'true'" || return 1
}

_assert_token_scoped() {
	local workflow="$1"
	local mints scoped
	mints="$(grep -c 'uses: actions/create-github-app-token@' "$workflow")"
	scoped="$(grep -c 'repositories: ${{ github.event.repository.name }}' "$workflow")"
	[[ "$mints" -gt 0 && "$mints" -eq "$scoped" ]] || {
		echo "${workflow}: ${mints} App token mint(s), ${scoped} scoped with repositories:" >&2
		return 1
	}
}

_assert_failure_report_covers_all_jobs() {
	local workflow="$1"
	local block
	block="$(_job_block "$workflow" "report-release-failure")"
	printf '%s\n' "$block" | grep -Fq 'needs: [prepare, version-update-hook, version-pr]' || return 1
	printf '%s\n' "$block" | grep -Fq "needs.version-update-hook.result == 'failure'" || return 1
	printf '%s\n' "$block" | grep -Fq "needs.prepare.result == 'failure'" || return 1
}

@test "reusable-release-version-pr: hook job declares no secrets and no token" {
	run _assert_hook_job_isolated "$VERSION_PR"
	assert_success
}

@test "reusable-release-multi-ecosystem: hook job declares no secrets and no token" {
	run _assert_hook_job_isolated "$MULTI_ECO"
	assert_success
}

@test "reusable-release-version-pr: hook job receives the tooling as a digest-checked artifact" {
	run _assert_hook_job_receives_packed_tooling "$VERSION_PR"
	assert_success
}

@test "reusable-release-multi-ecosystem: hook job receives the tooling as a digest-checked artifact" {
	run _assert_hook_job_receives_packed_tooling "$MULTI_ECO"
	assert_success
}

@test "reusable-release-version-pr: privileged job never executes a caller path" {
	run _assert_privileged_job_runs_no_caller_code "$VERSION_PR"
	assert_success
}

@test "reusable-release-multi-ecosystem: privileged job never executes a caller path" {
	run _assert_privileged_job_runs_no_caller_code "$MULTI_ECO"
	assert_success
}

@test "reusable-release-version-pr: prepare job fetches metadata with read-only permissions" {
	run _assert_prepare_job_shape "$VERSION_PR"
	assert_success
}

@test "reusable-release-multi-ecosystem: prepare job fetches metadata with read-only permissions" {
	run _assert_prepare_job_shape "$MULTI_ECO"
	assert_success
}

@test "release reusables: every App token mint is scoped to the calling repository" {
	run _assert_token_scoped "$VERSION_PR"
	assert_success
	run _assert_token_scoped "$MULTI_ECO"
	assert_success
	run _assert_token_scoped "$AUTO_TAG"
	assert_success
}

@test "release reusables: failure report covers the hook and prepare jobs" {
	run _assert_failure_report_covers_all_jobs "$VERSION_PR"
	assert_success
	run _assert_failure_report_covers_all_jobs "$MULTI_ECO"
	assert_success
}

@test "release reusables: version-update-script input documents the sandbox" {
	run grep -F "RELEASE_METADATA_PATH" "$VERSION_PR"
	assert_success
	run grep -F "RELEASE_METADATA_PATH" "$MULTI_ECO"
	assert_success
	run grep -F "release-metadata-container-package:" "$VERSION_PR"
	assert_success
	run grep -F "release-metadata-container-package:" "$MULTI_ECO"
	assert_success
}
