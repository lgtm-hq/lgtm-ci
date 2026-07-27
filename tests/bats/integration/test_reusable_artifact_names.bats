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
E2E_MATRIX="${WORKFLOW_DIR}/reusable-test-e2e-matrix.yml"
PREFIX_VALIDATOR="${PROJECT_ROOT}/scripts/ci/actions/validate-artifact-prefix.sh"

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

# Upload and the summary publisher must both resolve the same name, or an
# override splits the handoff. Asserted per step block, not by file-wide grep: a
# hardcoded name inside the real step would otherwise hide behind matching text
# elsewhere in the file.
#
# The third consumer, the Pages publisher's download, moved out of this file in
# #770 and is asserted in test_reusable_publish_split.bats — it now takes the
# name as its own `artifact-name` input, which the caller wires up.
@test "reusable-coverage: every consumer of the artifact reuses the input" {
	local step
	for step in "Upload coverage report"; do
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

# --- reusable-test-e2e-matrix artifact namespacing (#739) -------------------
#
# The merge job collects shards with a glob. Before #739 every site was the
# literal `playwright`, so two calls of this reusable in one run shared one
# namespace and the second call's merge swallowed the first call's shards.

# Raw value of `key` under the `with:` block of the named step, read out of the
# real YAML so the assertions below cannot drift from the workflow.
#
# Fails loudly when the step or key is absent: returning an empty string with
# status 0 would let the comparisons below pass vacuously against '' == '' the
# moment a step is renamed or its indentation drifts.
_e2e_matrix_with_value() {
	local step_name="$1" with_key="$2" value
	value="$(awk -v step="      - name: ${step_name}" -v key="          ${with_key}: " '
		$0 == step { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && index($0, key) == 1 { print substr($0, length(key) + 1); exit }
	' "$E2E_MATRIX")"
	if [[ -z "$value" ]]; then
		echo "no '${with_key}:' under step '${step_name}' in ${E2E_MATRIX}" >&2
		return 1
	fi
	printf '%s' "$value"
}

# Substitutes a candidate prefix (and a representative matrix leg) into one of
# those templates.
_e2e_matrix_render() {
	local template="$1" prefix="$2"
	template="${template//'${{ inputs.artifact-prefix }}'/$prefix}"
	template="${template//'${{ matrix.suite }}'/smoke}"
	template="${template//'${{ matrix.browser }}'/chromium}"
	template="${template//'${{ matrix.shard }}'/1}"
	printf '%s' "$template"
}

@test "reusable-test-e2e-matrix: artifact-prefix defaults to playwright" {
	run awk '/^      artifact-prefix:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$E2E_MATRIX"
	assert_success
	assert_output --partial 'default: "playwright"'
	assert_output --partial "type: string"
	assert_output --partial "required: false"
}

# A caller that passes nothing must keep today's names byte-for-byte: this is a
# backwards-compatible input addition, not an interface break.
@test "reusable-test-e2e-matrix: the default prefix reproduces today's names" {
	local shard merged pattern published
	shard="$(_e2e_matrix_render "$(_e2e_matrix_with_value "Upload report" name)" playwright)"
	merged="$(_e2e_matrix_render "$(_e2e_matrix_with_value "Upload merged report" name)" playwright)"
	pattern="$(_e2e_matrix_render "$(_e2e_matrix_with_value "Download all reports" pattern)" playwright)"
	published="$(_e2e_matrix_render "$(_e2e_matrix_with_value "Download merged report" name)" playwright)"

	[ "$shard" = "playwright-smoke-chromium-1" ] || {
		echo "shard upload name changed: ${shard}" >&2
		return 1
	}
	[ "$merged" = "playwright-merged-report" ] || {
		echo "merged report name changed: ${merged}" >&2
		return 1
	}
	[ "$pattern" = "playwright-*" ] || {
		echo "download pattern changed: ${pattern}" >&2
		return 1
	}
	# Since #770 the Pages deploy lives in a separate workflow the caller wires
	# up by name, so the name this merge uploads is a published contract: it is
	# what docs tell a migrating caller to pass as the publisher's
	# artifact-name. A drift here strands every migrated deploy.
	run grep -qF "artifact-name: playwright-merged-report" \
		"${PROJECT_ROOT}/docs/pages-publishing.md"
	assert_success
	[ "$merged" = "playwright-merged-report" ]
}

# All three sites must be parameterised together. Threading only the uploads
# leaves the merge globbing the whole run; threading only the pattern leaves it
# globbing nothing.
@test "reusable-test-e2e-matrix: every artifact site is built from the input" {
	local entry step key value
	for entry in \
		"Upload report:name" \
		"Upload merged report:name" \
		"Download all reports:pattern"; do
		step="${entry%:*}"
		key="${entry##*:}"
		value="$(_e2e_matrix_with_value "$step" "$key")"
		case "$value" in
		'${{ inputs.artifact-prefix }}'*) ;;
		*)
			echo "${step} / ${key} is not prefixed by the input: ${value}" >&2
			return 1
			;;
		esac
	done
}

# Two calls with distinct prefixes must not see each other's artifacts: neither
# download pattern may match the other call's upload names.
@test "reusable-test-e2e-matrix: distinct prefixes are mutually invisible" {
	local shard_tpl pattern_tpl a_shard b_shard a_pattern b_pattern
	shard_tpl="$(_e2e_matrix_with_value "Upload report" name)"
	pattern_tpl="$(_e2e_matrix_with_value "Download all reports" pattern)"

	a_shard="$(_e2e_matrix_render "$shard_tpl" playwright)"
	b_shard="$(_e2e_matrix_render "$shard_tpl" e2e)"
	a_pattern="$(_e2e_matrix_render "$pattern_tpl" playwright)"
	b_pattern="$(_e2e_matrix_render "$pattern_tpl" e2e)"

	[ "$a_shard" != "$b_shard" ] || {
		echo "distinct prefixes produced the same upload name: ${a_shard}" >&2
		return 1
	}
	# shellcheck disable=SC2053 # deliberate glob match, pattern must stay unquoted
	[[ $a_shard == $a_pattern ]] || {
		echo "${a_pattern} does not collect its own shard ${a_shard}" >&2
		return 1
	}
	# shellcheck disable=SC2053
	[[ $b_shard == $b_pattern ]] || {
		echo "${b_pattern} does not collect its own shard ${b_shard}" >&2
		return 1
	}
	# shellcheck disable=SC2053
	if [[ $b_shard == $a_pattern ]]; then
		echo "${a_pattern} also matches the other call's shard ${b_shard}" >&2
		return 1
	fi
	# shellcheck disable=SC2053
	if [[ $a_shard == $b_pattern ]]; then
		echo "${b_pattern} also matches the other call's shard ${a_shard}" >&2
		return 1
	fi
}

# The substring case: `e2e-*` would match `e2e-nightly-smoke-chromium-1`, so a
# glob on a hyphenated prefix cannot isolate the two calls. The workflow keeps
# the guarantee by rejecting the hyphen up front rather than by hoping callers
# pick non-overlapping names.
@test "reusable-test-e2e-matrix: a substring prefix pair cannot be configured" {
	local shard_tpl pattern_tpl outer_pattern inner_shard
	shard_tpl="$(_e2e_matrix_with_value "Upload report" name)"
	pattern_tpl="$(_e2e_matrix_with_value "Download all reports" pattern)"
	outer_pattern="$(_e2e_matrix_render "$pattern_tpl" e2e)"
	inner_shard="$(_e2e_matrix_render "$shard_tpl" e2e-nightly)"

	# Demonstrate the overlap the guard exists to prevent.
	# shellcheck disable=SC2053
	[[ $inner_shard == $outer_pattern ]] || {
		echo "expected ${outer_pattern} to swallow ${inner_shard}" >&2
		return 1
	}

	run env ARTIFACT_PREFIX="e2e-nightly" bash "$PREFIX_VALIDATOR"
	assert_failure
	assert_output --partial "artifact-prefix must match"

	run env ARTIFACT_PREFIX="e2e" bash "$PREFIX_VALIDATOR"
	assert_success
	run env ARTIFACT_PREFIX="e2e_nightly" bash "$PREFIX_VALIDATOR"
	assert_success
}

# The guard only helps if the workflow actually runs it, and it must run in the
# job every other job depends on so an invalid prefix fails before any upload.
@test "reusable-test-e2e-matrix: the setup job validates the prefix" {
	# Both facts must hold for the *same* step: tracked independently, a
	# validator step with no env plus an unrelated step carrying the env would
	# satisfy the assertion while the script ran with an empty prefix.
	run awk '
		/^  setup:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  setup:$/ { exit }
		in_job && /^      - name: / { step_script = 0; step_wired = 0 }
		in_job && /validate-artifact-prefix\.sh$/ { step_script = 1 }
		in_job && /ARTIFACT_PREFIX: \$\{\{ inputs\.artifact-prefix \}\}$/ { step_wired = 1 }
		step_script && step_wired { ok = 1 }
		END { exit !ok }
	' "$E2E_MATRIX"
	assert_success
}

# always() on the merge job would otherwise run it after setup failed, i.e.
# after the prefix was rejected — globbing with the very value the validator
# refused. The test dependency stays loose so a report is still merged when
# tests fail; only setup is required to have succeeded.
@test "reusable-test-e2e-matrix: a failed setup blocks the merge job" {
	run awk '
		/^  merge:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  merge:$/ { exit }
		in_job && /^    needs: / && /setup/ && /test/ { needs_setup = 1 }
		in_job && /^    if: / && /always\(\)/ &&
			/needs\.setup\.result == .success./ { gated = 1 }
		END { exit !(needs_setup && gated) }
	' "$E2E_MATRIX"
	assert_success
}

# The publish job used to guard `needs.merge.result == 'success'`, because
# !cancelled() alone also passes when merge was skipped or failed and publish
# then dies downloading a merged report that was never produced. #770 moved the
# deploy into a workflow the caller invokes, so the workflow can no longer
# enforce that ordering for the caller — the documented snippets have to, and a
# snippet without `needs:` would reproduce exactly that failure for everyone who
# copies it.
@test "docs: the publisher snippets order the deploy after its producer" {
	local doc
	for doc in docs/pages-publishing.md docs/reusable-workflows.md \
		docs/workflows/testing.md; do
		# Every documented publisher call must be preceded, inside its own job
		# block, by a `needs:` on the job that produced the artifact.
		run awk '
			/^[[:space:]]*[a-z0-9-]+:[[:space:]]*$/ { pending = 0 }
			/^[[:space:]]+needs: / { pending = 1 }
			/reusable-publish-test-results-pages\.yml@/ {
				calls += 1
				if (pending) { ordered += 1 }
			}
			END { exit !(calls > 0 && calls == ordered) }
		' "${PROJECT_ROOT}/${doc}"
		assert_success
	done
}
