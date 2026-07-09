#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-site-quality workflow inputs and job shape

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-site-quality.yml"

@test "reusable-site-quality: requires build-command input" {
	run grep -E '^      build-command:$' "$WORKFLOW"
	assert_success
	run awk '
		/^      build-command:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      build-command:/ { in_input = 0 }
		in_input && /required: true/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: requires test-command input" {
	run grep -E '^      test-command:$' "$WORKFLOW"
	assert_success
	run awk '
		/^      test-command:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      test-command:/ { in_input = 0 }
		in_input && /required: true/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: build job checkout order preserves tooling" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "site-build-link"
	assert_success
}

@test "reusable-site-quality: test job checkout order preserves tooling" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "site-test"
	assert_success
}

@test "reusable-site-quality: no pull-requests permission on work jobs" {
	run awk '
		/^  site-build-link:/ { in_job = 1 }
		/^  site-test:/ { in_job = 1 }
		/^  publish-test-summary:/ { in_job = 0 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-build-link:/ && !/^  site-test:/ { in_job = 0 }
		in_job && /pull-requests:/ { found = 1; exit }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: uses prepare-lychee-action-args tooling script" {
	run grep -F 'scripts/ci/actions/prepare-lychee-action-args.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: uses build-lychee-args tooling script" {
	run grep -F 'scripts/ci/actions/build-lychee-args.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: lychee-action uses pinned SHA" {
	run grep -F 'lycheeverse/lychee-action@e7477775783ea5526144ba13e8db5eec57747ce8 # v2.9.0' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: upload-artifact uses upload repo v7 SHA" {
	run grep -F 'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: publish job delegates to reusable-publish-test-summary" {
	run grep -F './.github/workflows/reusable-publish-test-summary.yml' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: publish job declares pull-requests write" {
	run awk '
		/^  publish-test-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_job = 0 }
		in_job && /pull-requests: write/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: aggregate passed output combines both jobs" {
	run awk '
		/^on:/ { in_on = 1 }
		/^jobs:/ { in_on = 0 }
		in_on && /^    outputs:/ { in_outputs = 1 }
		in_on && /^    [a-zA-Z0-9_-]+:/ && !/^    outputs:/ { in_outputs = 0 }
		in_outputs && /^      passed:/ { has_passed_key = 1 }
		in_outputs && /jobs\.site-build-link\.outputs\.passed/ { has_build = 1 }
		in_outputs && /jobs\.site-test\.outputs\.passed/ { has_test = 1 }
		END { exit !(has_passed_key && has_build && has_test) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: scopes pnpm setup to site-working-directory" {
	run awk '
		/^  site-build-link:/ { in_build = 1; in_test = 0 }
		/^  site-test:/ { in_build = 0; in_test = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-build-link:/ && !/^  site-test:/ {
			in_build = 0
			in_test = 0
		}
		(in_build || in_test) && /- name: Setup pnpm/ { in_pnpm = 1 }
		(in_build || in_test) && in_pnpm && /package_json_file:/ { has_key = 1 }
		(in_build || in_test) && in_pnpm && /inputs\.site-working-directory/ {
			has_site_dir = 1
		}
		(in_build || in_test) && in_pnpm && /^      - name:/ && !/- name: Setup pnpm/ {
			if (has_key && has_site_dir) { count += 1 }
			in_pnpm = 0
			has_key = 0
			has_site_dir = 0
		}
		END {
			if (in_pnpm && has_key && has_site_dir) { count += 1 }
			exit count < 2
		}
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: forwards package-manager to install step" {
	run awk '
		/^  site-build-link:/ { in_build = 1; in_test = 0 }
		/^  site-test:/ { in_build = 0; in_test = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-build-link:/ && !/^  site-test:/ {
			in_build = 0
			in_test = 0
		}
		(in_build || in_test) && /PACKAGE_MANAGER: \$\{\{ inputs\.package-manager \}\}/ {
			count += 1
		}
		END { exit count < 2 }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: resolves site artifact path via tooling script" {
	run grep -F 'scripts/ci/actions/resolve-site-artifact-path.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: optional Python setup when python-version is set" {
	run awk '
		/^  site-test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-test:/ { in_job = 0 }
		in_job && /inputs\.python-version != '\'''\''/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: vitest-json-path wires run-vitest parse step" {
	run grep -F 'scripts/ci/actions/run-vitest.sh' "$WORKFLOW"
	assert_success
	run grep -F 'inputs.vitest-json-path' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: apply-build-env uses tooling script" {
	run grep -F 'scripts/ci/actions/apply-build-env.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: uploads lychee report when markdown exists" {
	run awk '
		/^  site-build-link:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-build-link:/ { in_job = 0 }
		in_job && /- name: Upload lychee report/ { upload = 1 }
		upload && /hashFiles\('\''lychee-report\.md'\''\)/ { found = 1; exit }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-site-quality: fail step follows always vitest parse" {
	run awk '
		/^  site-test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  site-test:/ { in_job = 0 }
		in_job && /- name: Parse Vitest JSON results/ { parse = 1 }
		in_job && parse && /if: always\(\)/ { parse_always = 1 }
		in_job && /- name: Fail on site test errors/ { fail = 1 }
		in_job && fail && /steps\.test-run\.outcome == '\''failure'\''/ { found = 1 }
		END { exit !(parse_always && found) }
	' "$WORKFLOW"
	assert_success
}
