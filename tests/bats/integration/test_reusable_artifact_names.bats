#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-workflow artifact names (#726).
#
# actions/upload-artifact v4+ rejects a second upload of an existing name with
# 409 Conflict. Two collision classes are reachable: sibling reusables a caller
# runs in one workflow run sharing a default name, and one reusable invoked
# twice in a run re-uploading its own name.

load "../../helpers/common"

WORKFLOW_DIR="${PROJECT_ROOT}/.github/workflows"

# reusable-quality-lint.yml is asserted by
# test_reusable_quality_lint_workflow.bats instead (#717/#724 own that upload).
_reusable_workflows() {
	local wf
	for wf in "${WORKFLOW_DIR}"/reusable-*.yml; do
		if [[ "$(basename "$wf")" != "reusable-quality-lint.yml" ]]; then
			printf '%s\n' "$wf"
		fi
	done
}

# Emits "<file><TAB><raw name value>" for every upload-artifact step. The
# artifact name is always the first `with:` key on these steps.
_upload_names() {
	local wf
	while read -r wf; do
		awk -v file="$(basename "$wf")" '
			/uses: actions\/upload-artifact@/ { in_block = 1; next }
			in_block && /^ *name: / {
				line = $0
				sub(/^ *name: /, "", line)
				print file "\t" line
				in_block = 0
			}
			in_block && /^      - name: / { in_block = 0 }
		' "$wf"
	done < <(_reusable_workflows)
}

# Emits "<file>:<line>" for every upload-artifact step missing overwrite: true.
_uploads_missing_overwrite() {
	local wf
	while read -r wf; do
		awk -v file="$(basename "$wf")" '
			/uses: actions\/upload-artifact@/ {
				in_block = 1
				start = NR
				overwritten = 0
				next
			}
			in_block && /^ *overwrite: true$/ { overwritten = 1 }
			in_block && (/^      - name: / || /^  [a-zA-Z0-9_-]+:/) {
				if (!overwritten) { print file ":" start }
				in_block = 0
			}
			END { if (in_block && !overwritten) print file ":" start }
		' "$wf"
	done < <(_reusable_workflows)
}

# A caller may invoke the same reusable twice in one run (a bounded retry, or
# two fan-out legs). Without overwrite the second upload 409s; the later
# attempt is the authoritative one.
@test "reusable workflows: every artifact upload sets overwrite: true" {
	run _uploads_missing_overwrite
	assert_success
	assert_output ""
}

# Literal (non-expression) names are the ones a caller cannot disambiguate, so
# two reusables must never share one. Expression-valued names are covered by the
# per-workflow default assertions below.
@test "reusable workflows: no literal artifact name is uploaded by two workflows" {
	local shared
	shared="$(_upload_names | awk -F'\t' '
		$2 ~ /\$\{\{/ { next }
		$2 == ">-" || $2 == "|" || $2 == "" { next }
		{ print $2 "\t" $1 }
	' | sort -u | cut -f1 | uniq -d)"
	[ -z "$shared" ] || {
		echo "artifact names shared by two reusable workflows: ${shared}" >&2
		return 1
	}
}

@test "reusable-link-check: link report artifact name defaults to lychee-report" {
	run awk '/^      link-report-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"${WORKFLOW_DIR}/reusable-link-check.yml"
	assert_success
	assert_output --partial 'default: "lychee-report"'
}

# Distinct from reusable-link-check.yml's default: a caller can run both in one
# run, and before #726 both uploaded `lychee-report` — the second 409'd.
@test "reusable-site-quality: link report artifact name defaults to site-lychee-report" {
	run awk '/^      link-report-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"${WORKFLOW_DIR}/reusable-site-quality.yml"
	assert_success
	assert_output --partial 'default: "site-lychee-report"'
}

@test "reusable-test-node: coverage artifact name defaults to node-coverage" {
	run awk '/^      coverage-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"${WORKFLOW_DIR}/reusable-test-node.yml"
	assert_success
	assert_output --partial 'default: "node-coverage"'
}

# Distinct from reusable-test-node.yml's default for the same reason.
@test "reusable-test-node-custom: coverage artifact name defaults to node-custom-coverage" {
	run awk '/^      coverage-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"${WORKFLOW_DIR}/reusable-test-node-custom.yml"
	assert_success
	assert_output --partial 'default: "node-custom-coverage"'
}

# reusable-coverage.yml's handoff has no tolerance guard, so a caller invoking
# it twice in one run (per working directory, say) must be able to keep the two
# uploads apart instead of having overwrite silently pick one.
@test "reusable-coverage: coverage artifact name defaults to coverage-report" {
	run awk '/^      coverage-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"${WORKFLOW_DIR}/reusable-coverage.yml"
	assert_success
	assert_output --partial 'default: "coverage-report"'
}

# Upload, publish-job download and the summary publisher must all resolve the
# same name, or an override splits the handoff. Asserted per step block, not by
# file-wide grep: a hardcoded name inside the real step would otherwise hide
# behind matching text elsewhere in the file.
@test "reusable-coverage: every consumer of the artifact reuses the input" {
	local step
	for step in "Upload coverage report" "Download coverage report"; do
		run awk -v step="      - name: ${step}" '
			$0 == step { seen = 1; in_step = 1; next }
			in_step && /^      - name: / { exit }
			in_step && /^          name: / {
				line = $0
				sub(/^          name: /, "", line)
				resolved = (line == "${{ inputs.coverage-artifact-name }}")
				exit
			}
			END { exit !(seen && resolved) }
		' "${WORKFLOW_DIR}/reusable-coverage.yml"
		assert_success
	done
	# The publish-test-summary caller job passes the same input through.
	run awk '
		/^  publish-test-summary:$/ { seen = 1; in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:$/ { exit }
		in_job && /^      coverage-artifact-name: / {
			line = $0
			sub(/^      coverage-artifact-name: /, "", line)
			resolved = (line == "${{ inputs.coverage-artifact-name }}")
			exit
		}
		END { exit !(seen && resolved) }
	' "${WORKFLOW_DIR}/reusable-coverage.yml"
	assert_success
}

# The summary publisher must read the same name the test job uploaded, or the
# rich coverage comment silently degrades to pass/fail totals.
@test "reusable-test-node variants: summary publisher reuses coverage-artifact-name" {
	local wf
	for wf in reusable-test-node.yml reusable-test-node-custom.yml; do
		run grep -F 'inputs.coverage && inputs.coverage-artifact-name' \
			"${WORKFLOW_DIR}/${wf}"
		assert_success
	done
	run grep -rF "coverage-artifact-name: \${{ inputs.coverage && 'node-coverage' || '' }}" \
		"${WORKFLOW_DIR}/reusable-test-node.yml" \
		"${WORKFLOW_DIR}/reusable-test-node-custom.yml"
	assert_failure
}

@test "reusable-link-check: report publisher reuses link-report-artifact-name" {
	run grep -F 'artifact-name: ${{ inputs.link-report-artifact-name }}' \
		"${WORKFLOW_DIR}/reusable-link-check.yml"
	assert_success
}

# github.run_id is stable across a rerun, so the two Playwright reusables shared
# one name for any caller running both.
@test "reusable-test-e2e-playwright: report name falls back to playwright-report-<run_id>" {
	run grep -F "format('playwright-report-{0}', github.run_id)" \
		"${WORKFLOW_DIR}/reusable-test-e2e-playwright.yml"
	assert_success
}

@test "reusable-test-e2e: report name falls back to e2e-report-<run_id>" {
	run grep -F "format('e2e-report-{0}', github.run_id)" \
		"${WORKFLOW_DIR}/reusable-test-e2e.yml"
	assert_success
	run grep -F 'playwright-report-${{ github.run_id }}' \
		"${WORKFLOW_DIR}/reusable-test-e2e.yml"
	assert_failure
}

# Convenience/report payloads only: their verdict lives in a separate step, and
# every in-repo consumer already tolerates a missing artifact. A storage hiccup
# must not redden an otherwise green job (#696 pattern).
@test "reusable workflows: convenience report uploads are non-fatal and warn" {
	local entry wf step
	for entry in \
		"reusable-link-check.yml:Upload link report" \
		"reusable-site-quality.yml:Upload lychee report" \
		"reusable-security-audit.yml:Upload comment artifact" \
		"reusable-validate.yml:Upload validation report" \
		"reusable-test-shell.yml:Upload test results" \
		"reusable-test-shell.yml:Upload coverage report" \
		"reusable-test-node.yml:Upload coverage for test summary" \
		"reusable-test-node-custom.yml:Upload coverage for test summary" \
		"reusable-rust-test.yml:Upload LCOV for test summary" \
		"reusable-test-e2e.yml:Upload report" \
		"reusable-test-e2e-playwright.yml:Upload Playwright report"; do
		wf="${entry%%:*}"
		step="${entry#*:}"
		run awk -v step="      - name: ${step}" '
			$0 == step { in_step = 1; next }
			in_step && /^      - name: / { exit }
			in_step && /^        continue-on-error: true$/ { found = 1 }
			END { exit !found }
		' "${WORKFLOW_DIR}/${wf}"
		assert_success
		# The warn step directly follows the upload it reports on.
		run awk -v step="      - name: ${step}" '
			$0 == step { in_step = 1; next }
			in_step && /^      - name: Warn on/ { found = 1; exit }
			in_step && /^      - name: / { exit }
			END { exit !found }
		' "${WORKFLOW_DIR}/${wf}"
		assert_success
	done
}

# The uploads these warnings report on are always()-gated, so the warning must be
# too: without it the implicit success() check skips the warning on exactly the
# runs where the tests failed — the storage hiccup would then go unreported.
@test "reusable workflows: upload warnings survive a failed job" {
	local wf missing=""
	while read -r wf; do
		# Warnings that report on an upload step's outcome only. Publisher-job
		# download warnings are excluded: nothing runs before their download, so
		# the job cannot already be failing when they are evaluated.
		if ! awk '
			/^      - name: Warn on/ { in_step = 1; next }
			in_step && /^        if: .*steps\.upload-[A-Za-z0-9_-]*\.outcome/ {
				if ($0 !~ /if: always\(\)/) { bad = 1 }
				in_step = 0
			}
			in_step && /^      - name: / { in_step = 0 }
			END { exit bad }
		' "$wf"; then
			missing+=" $(basename "$wf")"
		fi
	done < <(_reusable_workflows)
	[ -z "$missing" ] || {
		echo "warn steps missing always():${missing}" >&2
		return 1
	}
}

# The inverse guard: these artifacts are a job's verdict or a downstream job's
# required input, so continue-on-error would turn a real failure green.
@test "reusable workflows: verdict uploads stay fatal" {
	local entry wf step
	for entry in \
		"reusable-build-artifact.yml:Upload build artifact" \
		"reusable-build-python-dist.yml:Upload Python distribution" \
		"reusable-build-rust-binaries.yml:Upload binaries" \
		"reusable-coverage.yml:Upload coverage report" \
		"reusable-docker-multiplatform.yml:Upload staging digest" \
		"reusable-site-quality.yml:Upload site artifact" \
		"reusable-test-e2e-matrix.yml:Upload merged report" \
		"reusable-test-node.yml:Upload build artifact" \
		"reusable-test-node.yml:Upload matrix test summary" \
		"reusable-test-python.yml:Upload matrix test summary" \
		"reusable-rust-test.yml:Upload matrix test summary"; do
		wf="${entry%%:*}"
		step="${entry#*:}"
		run awk -v step="      - name: ${step}" '
			$0 == step { seen = 1; in_step = 1; next }
			in_step && /^      - name: / { exit }
			in_step && /^        continue-on-error: true$/ { bad = 1; exit }
			END { exit (!seen || bad) }
		' "${WORKFLOW_DIR}/${wf}"
		assert_success
	done
}
