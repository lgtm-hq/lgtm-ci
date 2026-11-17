#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-release-version-pr and lgtm-ci caller

load "../../helpers/common"

@test "release-version-pr caller: delegates to same-repo reusable workflow" {
	local workflow="${PROJECT_ROOT}/.github/workflows/release-version-pr.yml"

	run grep -F "uses: ./.github/workflows/reusable-release-version-pr.yml" "$workflow"
	assert_success
}

@test "release-version-pr caller: is CHANGELOG-only (no ecosystems or update script)" {
	local workflow="${PROJECT_ROOT}/.github/workflows/release-version-pr.yml"

	run grep -E '^\s+ecosystems:' "$workflow"
	assert_failure
	run grep -E '^\s+version-update-script:' "$workflow"
	assert_failure
}

@test "release-version-pr caller: passes release app secrets" {
	local workflow="${PROJECT_ROOT}/.github/workflows/release-version-pr.yml"

	run grep -F "RELEASE_APP_ID: \${{ secrets.RELEASE_APP_ID }}" "$workflow"
	assert_success
	run grep -F "RELEASE_APP_PRIVATE_KEY: \${{ secrets.RELEASE_APP_PRIVATE_KEY }}" "$workflow"
	assert_success
}

@test "reusable-release-version-pr: defines workflow_call inputs and secrets" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F "workflow_call:" "$workflow"
	assert_success
	run grep -F "ecosystems:" "$workflow"
	assert_success
	run grep -F "ecosystem-config:" "$workflow"
	assert_success
	run awk '
		/^      RELEASE_APP_ID:/ {
			while ((getline line) > 0) {
				if (line ~ /^      [A-Za-z_][A-Za-z0-9_-]+:/) {
					break
				}
				if (line ~ /^        required: false$/) {
					found_app_id = 1
					break
				}
			}
		}
		END { exit !found_app_id }
	' "$workflow"
	assert_success
	run awk '
		/^      RELEASE_APP_PRIVATE_KEY:/ {
			while ((getline line) > 0) {
				if (line ~ /^      [A-Za-z_][A-Za-z0-9_-]+:/) {
					break
				}
				if (line ~ /^        required: true$/) {
					found_private_key = 1
					break
				}
			}
		}
		END { exit !found_private_key }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: creates GitHub App token before authenticated checkout" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		# First mint and first authenticated checkout; prepare and version-pr
		# each mint their own token (#849).
		/- name: Create GitHub App installation token/ && !token_line { token_line = NR; after_token = 1 }
		after_token && !checkout_line && /^      - name: Checkout repository/ {
			in_auth_checkout = 1
		}
		in_auth_checkout && /fetch-depth: 0/ { checkout_line = NR }
		in_auth_checkout && /^      - name:/ && $0 !~ /Checkout repository/ {
			in_auth_checkout = 0
		}
		END { exit !(token_line && checkout_line && token_line < checkout_line) }
	' "$workflow"
	assert_success
	run grep -F "actions/create-github-app-token" "$workflow"
	assert_success
}

@test "reusable-release-version-pr: uses App token for create-pull-request" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		/- name: Create or update version PR/ { in_step = 1 }
		in_step && /peter-evans\/create-pull-request/ { saw_cpr = 1 }
		in_step && /token: \$\{\{ steps\.app-token\.outputs\.token \}\}/ { saw_token = 1 }
		in_step && /^      - name:/ && $0 !~ /Create or update version PR/ { in_step = 0 }
		END { exit !(saw_cpr && saw_token) }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: gates create-pull-request on merge-queue skip" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F "check-version-pr-merge-queue.sh" "$workflow"
	assert_success
	run awk '
		/- name: Create or update version PR/ { in_step = 1 }
		in_step && /skip-branch-update != '\''true'\''/ { found = 1; exit }
		in_step && /^      - name:/ && $0 !~ /Create or update version PR/ { in_step = 0 }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: wires CHANGELOG-only expect flag when ecosystems empty" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F "EXPECT_VERSION_FILES:" "$workflow"
	assert_success
	run grep -F "inputs.ecosystems != ''" "$workflow"
	assert_success
	run grep -F "inputs.version-update-script != ''" "$workflow"
	assert_success
}

@test "reusable-release-version-pr: uses version-specific release branch prefix" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F "release-branch-prefix:" "$workflow"
	assert_success
	run grep -F "steps.version.outputs.next-version" "$workflow"
	assert_success
}

@test "reusable-release-version-pr: serializes with cancel-in-progress false" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		/^  version-pr:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /version-pr:/ { in_job = 0 }
		in_job && /cancel-in-progress: false/ { found_cancel = 1 }
		in_job && /group: reusable-release-version-pr-/ { found_group = 1 }
		END { exit !(found_cancel && found_group) }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: enforces caller-tunable job timeout" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run grep -F 'default: 20' "$workflow"
	assert_success
	run awk '
		/^  version-pr:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /version-pr:/ { in_job = 0 }
		in_job && /timeout-minutes: \$\{\{ inputs\.timeout-minutes \}\}/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: runs guard before version calculation" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"

	run awk '
		/- name: Guard release commit/ { saw_guard = 1 }
		saw_guard && /- name: Calculate next version/ { saw_calc = 1; exit }
		END { exit !saw_calc }
	' "$workflow"
	assert_success
}

@test "reusable-release-version-pr: moves the tooling out before PR creation and back after it" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	require_python_yaml

	# One tooling checkout and one tooling App mint in the job (#1622): the
	# tooling is packed under runner.temp before the PR and restored from that
	# tarball after it, never fetched a second time.
	run "$PY" - "$workflow" <<'PY'
import sys
import yaml

steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["version-pr"]["steps"]
names = [step.get("name") for step in steps]
stash = names.index("Move tooling checkout out of the workspace before PR creation")
create = names.index("Create or update version PR")
restore = names.index("Restore tooling for post-PR steps")
assert stash < create < restore, (stash, create, restore)
assert steps[stash]["id"] == "stash-tooling"
assert steps[stash]["run"] == (
    ".lgtm-ci-tooling/scripts/ci/release/stash-tooling-checkout.sh"
)
# Whenever the tooling was moved out, even after a failed step.
assert steps[restore]["if"] == (
    "always() && steps.stash-tooling.outputs.digest != ''"
), steps[restore]["if"]
assert "uses" not in steps[restore]
assert steps[restore]["env"] == {
    "TARBALL": "${{ runner.temp }}/tooling-stash/tooling.tar.gz",
    "EXPECTED_DIGEST": "${{ steps.stash-tooling.outputs.digest }}",
}
assert "# lgtm-ci-inline:begin verify-extract-hook-tooling" in steps[restore]["run"]
checkouts = [
    i
    for i, step in enumerate(steps)
    if (step.get("with") or {}).get("path") == ".lgtm-ci-tooling"
]
assert len(checkouts) == 1 and checkouts[0] < stash, checkouts
mints = [i for i, step in enumerate(steps) if step.get("id") == "tooling-app-token"]
assert mints == [checkouts[0] - 1], mints
# Every post-PR step that runs the tooling comes after the restore.
for index, step in enumerate(steps):
    if ".lgtm-ci-tooling/" in str(step.get("run", "")) and index > create:
        assert index > restore, step.get("name")
PY
	assert_success
}
