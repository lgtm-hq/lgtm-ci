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

# Since #1091 the per-call coverage name comes from artifact-prefix. The
# override input stays for callers that want a name outside that scheme and
# defaults to empty, which the upload resolves to <artifact-prefix>-coverage:
# node-coverage for reusable-test-node.yml (unchanged) and node_custom-coverage
# for the custom variant (was node-custom-coverage; '-' is the reserved
# separator). The two defaults stay distinct so a caller running both in one
# run does not collide.
@test "reusable-test-node variants: coverage-artifact-name defaults to empty and resolves from the prefix" {
	local entry wf job prefix tpl resolved_node="" resolved_custom=""
	for entry in \
		"reusable-test-node.yml:test-vitest:node" \
		"reusable-test-node-custom.yml:test:node_custom"; do
		IFS=: read -r wf job prefix <<<"$entry"
		run awk '/^      coverage-artifact-name:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
			"${WORKFLOW_DIR}/${wf}"
		assert_success
		assert_output --partial 'default: ""'
		tpl="$(_lang_with_value "$wf" "$job" "Upload coverage for test summary" name)"
		run _lang_render_coverage_name "$tpl" "$prefix" ""
		assert_success
		assert_output "${prefix}-coverage"
		run _lang_render_coverage_name "$tpl" "$prefix" "my-cov"
		assert_success
		assert_output "my-cov"
		if [[ "$wf" == "reusable-test-node.yml" ]]; then
			resolved_node="$(_lang_render_coverage_name "$tpl" "$prefix" "")"
		else
			resolved_custom="$(_lang_render_coverage_name "$tpl" "$prefix" "")"
		fi
	done
	[ "$resolved_node" = "node-coverage" ]
	[ "$resolved_custom" = "node_custom-coverage" ]
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
# rich coverage comment silently degrades to pass/fail totals. Both sites must
# spell out the identical resolution (override, else <artifact-prefix>-coverage);
# a literal on either side would split the handoff for every non-default prefix.
@test "reusable-test-node variants: summary publisher resolves coverage-artifact-name like the upload" {
	local wf expected
	expected="\${{ inputs.coverage && (inputs.coverage-artifact-name != '' && inputs.coverage-artifact-name || format('{0}-coverage', inputs.artifact-prefix)) || '' }}"
	for wf in reusable-test-node.yml reusable-test-node-custom.yml; do
		run _lang_publish_coverage_name "$wf"
		assert_success
		assert_output "$expected"
	done
	run grep -rF "'node-coverage'" \
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
	# The producer job names the snippets use. Asserting membership rather than
	# mere presence of a `needs:` is the point: a snippet depending on some
	# unrelated job would satisfy "has a needs" while still racing the report
	# upload, which is the exact failure the old `needs.merge.result` guard
	# existed to prevent.
	local producers="coverage e2e-matrix"
	local doc
	for doc in docs/pages-publishing.md docs/reusable-workflows.md \
		docs/workflows/testing.md; do
		run awk -v producers="$producers" '
			BEGIN { split(producers, p, " "); for (i in p) is_producer[p[i]] = 1 }
			# A new job key ends the previous job block, so a `needs:` never
			# leaks across snippet boundaries.
			/^[[:space:]]*[a-z0-9-]+:[[:space:]]*$/ { pending = 0 }
			/^[[:space:]]+needs:[[:space:]]/ {
				value = $0
				sub(/^[[:space:]]+needs:[[:space:]]*/, "", value)
				# Normalise the list form `needs: [a, b]` to bare names so both
				# spellings are accepted and neither is accepted vacuously.
				gsub(/[][,]/, " ", value)
				pending = 0
				n = split(value, names, " ")
				for (i = 1; i <= n; i++) {
					if (names[i] in is_producer) { pending = 1 }
				}
			}
			/reusable-publish-test-results-pages\.yml@/ {
				calls += 1
				if (pending) { ordered += 1 }
			}
			END { exit !(calls > 0 && calls == ordered) }
		' "${PROJECT_ROOT}/${doc}"
		assert_success
	done
}

# --- language test reusables artifact namespacing (#1091) -------------------
#
# The language test reusables uploaded flat names (`python-coverage`,
# `rust-coverage-lcov`, `shell-coverage`, `<lang>-results-<version>`) with
# overwrite: true, so a caller invoking one of them twice in a run silently kept
# only the second call's coverage (#1074 reproduction). They now share the E2E
# `artifact-prefix` contract (#752): every upload name and download glob is
# built from the input, the same script validates it, and the default is the
# language word so a single-call consumer keeps today's names.
#
# "<file>:<default prefix>:<job that validates>[,<job>]"
LANGUAGE_TEST_WORKFLOWS=(
	"reusable-test-python.yml:python:prepare"
	"reusable-test-node.yml:node:prepare"
	"reusable-test-node-custom.yml:node_custom:prepare"
	"reusable-rust-test.yml:rust:prepare"
	"reusable-test-shell.yml:shell:test,shard-setup"
)

# Raw value of `key` under the `with:` block of the named step inside the named
# job (the shell workflow repeats step names across jobs). A `>-` folded scalar
# is joined into one line. Fails loudly when the job, step or key is absent so
# a renamed step cannot make the comparisons below pass vacuously.
_lang_with_value() {
	local file="$1" job="$2" step_name="$3" with_key="$4" value
	value="$(awk -v job="  ${job}:" -v step="      - name: ${step_name}" \
		-v key="          ${with_key}: " '
		$0 == job { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:$/ { exit }
		in_job && $0 == step { in_step = 1; next }
		in_step && folded {
			if ($0 ~ /^            /) {
				line = $0
				sub(/^ +/, "", line)
				out = (out == "" ? line : out " " line)
				next
			}
			exit
		}
		in_step && /^      - name: / { exit }
		in_step && index($0, key) == 1 {
			v = substr($0, length(key) + 1)
			if (v == ">-") { folded = 1; next }
			print v
			exit
		}
		END { if (folded) print out }
	' "${WORKFLOW_DIR}/${file}")"
	if [[ -z "$value" ]]; then
		echo "no '${with_key}:' under step '${step_name}' in job '${job}' of ${file}" >&2
		return 1
	fi
	printf '%s' "$value"
}

# Folded value of the publish-test-summary job's coverage-artifact-name handoff.
_lang_publish_coverage_name() {
	local file="$1" value
	value="$(awk '
		/^  publish-test-summary:$/ { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:$/ { exit }
		in_job && folded {
			if ($0 ~ /^        /) {
				line = $0
				sub(/^ +/, "", line)
				out = (out == "" ? line : out " " line)
				next
			}
			exit
		}
		in_job && /^      coverage-artifact-name: / {
			v = $0
			sub(/^      coverage-artifact-name: /, "", v)
			if (v == ">-") { folded = 1; next }
			print v
			exit
		}
		END { if (folded) print out }
	' "${WORKFLOW_DIR}/${file}")"
	if [[ -z "$value" ]]; then
		echo "no coverage-artifact-name handoff in publish-test-summary of ${file}" >&2
		return 1
	fi
	printf '%s' "$value"
}

# Substitutes a candidate prefix and representative leg coordinates into a
# template taken from the YAML (either an expression or the shell-quoted glob
# handed to wait-for-artifacts.sh).
_lang_render() {
	local t="$1" prefix="$2"
	t="${t//'${{ inputs.artifact-prefix }}'/$prefix}"
	t="${t//'${{ inputs.comment-marker }}'/shell-test-results}"
	t="${t//'${{ matrix.python-version }}'/3.12}"
	t="${t//'${{ matrix.node-version }}'/22}"
	t="${t//'${{ matrix.rust-toolchain }}'/stable}"
	t="${t//'${{ matrix.shard }}'/1}"
	t="${t//'${ARTIFACT_PREFIX}'/$prefix}"
	t="${t//'${COMMENT_MARKER}'/shell-test-results}"
	printf '%s' "$t"
}

# Resolves the node variants' coverage-name expression (override, else
# <artifact-prefix>-coverage). Only that exact shape is understood: any other
# text fails rather than being rendered by guesswork.
_lang_render_coverage_name() {
	local t="$1" prefix="$2" override="$3"
	local shape="\${{ inputs.coverage-artifact-name != '' && inputs.coverage-artifact-name || format('{0}-coverage', inputs.artifact-prefix) }}"
	if [[ "$t" != "$shape" ]]; then
		echo "unexpected coverage name expression: ${t}" >&2
		return 1
	fi
	if [[ -n "$override" ]]; then
		printf '%s' "$override"
	else
		printf '%s-coverage' "$prefix"
	fi
}

# Emits "<line>\t<value>" for the artifact name of every upload-artifact step
# and the name/pattern of every download-artifact step in the file.
_lang_artifact_sites() {
	local file="$1"
	awk '
		/uses: actions\/(upload|download)-artifact@/ { in_block = 1; start = NR; next }
		in_block && folded {
			if ($0 ~ /^            /) {
				line = $0
				sub(/^ +/, "", line)
				out = (out == "" ? line : out " " line)
				next
			}
			print start "\t" out
			folded = 0
			in_block = 0
		}
		in_block && /^      - name: / { in_block = 0 }
		in_block && /^          (name|pattern): / {
			line = $0
			sub(/^          (name|pattern): /, "", line)
			if (line == ">-") { folded = 1; out = ""; next }
			print start "\t" line
			in_block = 0
		}
		END { if (folded) print start "\t" out }
	' "${WORKFLOW_DIR}/${file}"
}

# Emits "<wired|unwired>\t<glob>" for every wait-for-artifacts.sh call in the
# job: the glob argument that follows "$EXPECTED_COUNT", and whether the same
# step put the input into ARTIFACT_PREFIX.
_lang_wait_globs() {
	local file="$1" job="$2"
	awk -v job="  ${job}:" '
		$0 == job { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:$/ { exit }
		in_job && /^      - name: / { wired = 0 }
		in_job && /ARTIFACT_PREFIX: \$\{\{ inputs\.artifact-prefix \}\}$/ { wired = 1 }
		in_job && /wait-for-artifacts\.sh$/ { want = 1; next }
		want {
			line = $0
			sub(/^ *"\$EXPECTED_COUNT" /, "", line)
			gsub(/"/, "", line)
			print (wired ? "wired" : "unwired") "\t" line
			want = 0
		}
	' "${WORKFLOW_DIR}/${file}"
}

_lang_job_validates_prefix() {
	local file="$1" job="$2"
	# Both facts must hold for the *same* step, as in the E2E test above.
	awk -v job="  ${job}:" '
		$0 == job { in_job = 1; next }
		in_job && /^  [a-zA-Z0-9_-]+:$/ { exit }
		in_job && /^      - name: / { step_script = 0; step_wired = 0 }
		in_job && /validate-artifact-prefix\.sh$/ { step_script = 1 }
		in_job && /ARTIFACT_PREFIX: \$\{\{ inputs\.artifact-prefix \}\}$/ { step_wired = 1 }
		step_script && step_wired { ok = 1 }
		END { exit !ok }
	' "${WORKFLOW_DIR}/${file}"
}

@test "language test reusables: artifact-prefix defaults to the language word" {
	local entry wf prefix
	for entry in "${LANGUAGE_TEST_WORKFLOWS[@]}"; do
		IFS=: read -r wf prefix _ <<<"$entry"
		run awk '/^      artifact-prefix:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
			"${WORKFLOW_DIR}/${wf}"
		assert_success
		assert_output --partial "default: \"${prefix}\""
		assert_output --partial "type: string"
		assert_output --partial "required: false"
		# The default itself must pass the validator the workflow runs.
		run env ARTIFACT_PREFIX="$prefix" bash "$PREFIX_VALIDATOR"
		assert_success
	done
}

# The validator must run in a job every upload and download depends on, so an
# invalid prefix fails before any artifact site uses it. The shell workflow has
# no prepare job: its single-job path validates in `test` and the sharded path
# in `shard-setup`, which `test-sharded` and `aggregate` depend on.
@test "language test reusables: an upstream job validates the prefix" {
	local entry wf jobs job
	for entry in "${LANGUAGE_TEST_WORKFLOWS[@]}"; do
		IFS=: read -r wf _ jobs <<<"$entry"
		for job in ${jobs//,/ }; do
			run _lang_job_validates_prefix "$wf" "$job"
			assert_success
		done
	done
}

# Validation only helps if a rejected prefix also stops the artifact sites that
# run under always(). The shell workflow is the one with such sites outside a
# prepare-dependent job: its aggregate job must list shard-setup and require
# its success (the E2E merge-job rule), and the single-job uploads must
# require the validator step's success rather than uploading under a value the
# validator refused.
@test "reusable-test-shell: a rejected prefix blocks the always()-gated artifact sites" {
	run awk '
		/^  aggregate:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  aggregate:$/ { exit }
		in_job && /^    needs: / && /shard-setup/ && /test-sharded/ { needs_setup = 1 }
		in_job && /^    if: / { in_if = 1 }
		in_job && in_if && /always\(\)/ { always = 1 }
		in_job && in_if && /needs\.shard-setup\.result == .success./ { gated = 1 }
		in_job && in_if && /^    [a-z]/ && !/^    if: / { in_if = 0 }
		END { exit !(needs_setup && always && gated) }
	' "${WORKFLOW_DIR}/reusable-test-shell.yml"
	assert_success
	local step
	for step in "Upload test results" "Upload coverage report"; do
		run awk -v step="      - name: ${step}" '
			/^  test:$/ { in_job = 1 }
			in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  test:$/ { exit }
			in_job && $0 == step { in_step = 1; next }
			in_step && /^      - name: / { exit }
			in_step && /steps\.artifact-prefix\.outcome == .success./ { gated = 1 }
			END { exit !gated }
		' "${WORKFLOW_DIR}/reusable-test-shell.yml"
		assert_success
	done
	# The id those conditions refer to is the validator step itself.
	run awk '
		/^  test:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  test:$/ { exit }
		in_job && /^      - name: Validate artifact prefix$/ { in_step = 1; next }
		in_step && /^      - name: / { in_step = 0 }
		in_step && /^        id: artifact-prefix$/ { has_id = 1 }
		END { exit !has_id }
	' "${WORKFLOW_DIR}/reusable-test-shell.yml"
	assert_success
}

# Every producer and every consumer, or the input is incomplete (#728/#752):
# a flat upload would collide again, and an unprefixed download glob would
# collect the other call's artifacts. The Pages HTML bundle is the one
# documented exemption: `pages-coverage-artifact-name` is already a per-call
# name input whose default is baked into consumers' Pages bundles.
@test "language test reusables: every artifact name and download glob is built from the input" {
	local entry wf sites line value count min
	for entry in "${LANGUAGE_TEST_WORKFLOWS[@]}"; do
		IFS=: read -r wf _ _ <<<"$entry"
		sites="$(_lang_artifact_sites "$wf")"
		count=0
		while IFS=$'\t' read -r line value; do
			[[ -n "$line" ]] || continue
			count=$((count + 1))
			case "$value" in
			*'inputs.artifact-prefix'*) ;;
			'${{ inputs.pages-coverage-artifact-name }}') ;;
			*)
				echo "${wf}:${line}: artifact site not built from artifact-prefix: ${value}" >&2
				return 1
				;;
			esac
		done <<<"$sites"
		# Non-vacuous: the sweep must have seen every site the workflow has.
		case "$wf" in
		reusable-test-python.yml) min=2 ;;
		reusable-test-node.yml) min=6 ;;
		reusable-test-node-custom.yml) min=3 ;;
		reusable-rust-test.yml) min=3 ;;
		reusable-test-shell.yml) min=7 ;;
		esac
		[ "$count" -ge "$min" ] || {
			echo "${wf}: expected at least ${min} artifact sites, swept ${count}" >&2
			return 1
		}
	done
}

# The #803 availability wait downloads by glob too; it must use the prefixed
# glob and take the prefix from the input in the same step, or the aggregate
# would count another call's summaries as its own legs.
@test "language test reusables: the artifact-availability wait globs by the prefix" {
	local entry wf job globs wired glob found
	for entry in \
		"reusable-test-python.yml:aggregate" \
		"reusable-test-node.yml:aggregate-tests" \
		"reusable-rust-test.yml:aggregate" \
		"reusable-test-shell.yml:aggregate"; do
		wf="${entry%%:*}"
		job="${entry##*:}"
		globs="$(_lang_wait_globs "$wf" "$job")"
		found=0
		while IFS=$'\t' read -r wired glob; do
			[[ -n "$glob" ]] || continue
			found=$((found + 1))
			[ "$wired" = "wired" ] || {
				echo "${wf}: wait step does not wire ARTIFACT_PREFIX from the input" >&2
				return 1
			}
			case "$glob" in
			'${ARTIFACT_PREFIX}-'*'*') ;;
			*)
				echo "${wf}: wait glob is not prefixed: ${glob}" >&2
				return 1
				;;
			esac
		done <<<"$globs"
		[ "$found" -ge 1 ] || {
			echo "${wf}: no wait-for-artifacts.sh call found in job ${job}" >&2
			return 1
		}
	done
}

# The rich coverage comment downloads by the name handed over here; a literal
# would read a sibling call's coverage for every non-default prefix.
@test "language test reusables: the summary publisher reads the prefixed coverage name" {
	run _lang_publish_coverage_name reusable-test-python.yml
	assert_success
	assert_output --partial "format('{0}-coverage', inputs.artifact-prefix)"
	run _lang_publish_coverage_name reusable-rust-test.yml
	assert_success
	assert_output --partial "format('{0}-coverage-lcov', inputs.artifact-prefix)"
	# The node variants are asserted exactly, upload and publisher alike, above.
}

# A caller that passes nothing must keep today's names byte-for-byte: this is
# a backwards-compatible input addition. node_custom-coverage is the single
# documented rename (was node-custom-coverage).
@test "language test reusables: the default prefix reproduces today's names" {
	local entry wf job step key expected value rendered
	for entry in \
		"reusable-test-python.yml|test|Upload matrix test summary|name|python-results-3.12" \
		"reusable-test-python.yml|test|Upload coverage report|name|python-coverage" \
		"reusable-test-node.yml|test-vitest|Upload build artifact|name|node-build-22" \
		"reusable-test-node.yml|test-vitest|Upload matrix test summary|name|node-results-22" \
		"reusable-test-node.yml|test-vitest|Upload coverage report|name|node-coverage-22" \
		"reusable-rust-test.yml|test|Upload LCOV for test summary|name|rust-coverage-lcov" \
		"reusable-rust-test.yml|test|Upload matrix test summary|name|rust-results-stable" \
		"reusable-test-shell.yml|test|Upload test results|name|shell-test-results" \
		"reusable-test-shell.yml|test|Upload coverage report|name|shell-coverage" \
		"reusable-test-shell.yml|test-sharded|Upload test results|name|shell-test-results-shell-test-results-shard-1" \
		"reusable-test-shell.yml|test-sharded|Upload coverage report|name|shell-coverage-shell-test-results-shard-1" \
		"reusable-test-shell.yml|aggregate|Download shard TAP artifacts|pattern|shell-test-results-shell-test-results-shard-*" \
		"reusable-test-shell.yml|aggregate|Download shard coverage artifacts|pattern|shell-coverage-shell-test-results-shard-*" \
		"reusable-test-shell.yml|aggregate|Upload merged coverage report|name|shell-coverage"; do
		IFS='|' read -r wf job step key expected <<<"$entry"
		value="$(_lang_with_value "$wf" "$job" "$step" "$key")"
		# The language word is the file's own default, read from the YAML.
		rendered="$(_lang_render "$value" "$(awk '/^      artifact-prefix:$/{show=1;next} show&&/^        default: /{sub(/^        default: "/, ""); sub(/"$/, ""); print; exit}' "${WORKFLOW_DIR}/${wf}")")"
		[ "$rendered" = "$expected" ] || {
			echo "${wf} / ${job} / ${step} / ${key}: ${rendered} (expected ${expected})" >&2
			return 1
		}
	done
	# The wait globs with the default prefix are the ones #803 documented.
	run _lang_wait_globs reusable-test-python.yml aggregate
	assert_output --partial $'wired\t${ARTIFACT_PREFIX}-results-*'
	[ "$(_lang_render '${ARTIFACT_PREFIX}-results-*' python)" = "python-results-*" ]
}

# Two calls with distinct prefixes must not see each other's artifacts: each
# call's download glob matches its own upload names and none of the other's.
@test "language test reusables: distinct prefixes are mutually invisible" {
	local entry wf up_job up_step dl_job glob_tpl name_tpl a_name b_name a_glob b_glob
	for entry in \
		"reusable-test-python.yml|test|Upload matrix test summary|aggregate" \
		"reusable-test-node.yml|test-vitest|Upload matrix test summary|aggregate-tests" \
		"reusable-rust-test.yml|test|Upload matrix test summary|aggregate" \
		"reusable-test-shell.yml|test-sharded|Upload test results|aggregate"; do
		IFS='|' read -r wf up_job up_step dl_job <<<"$entry"
		name_tpl="$(_lang_with_value "$wf" "$up_job" "$up_step" name)"
		glob_tpl="$(_lang_wait_globs "$wf" "$dl_job" | head -n 1 | cut -f2)"
		a_name="$(_lang_render "$name_tpl" sib_a)"
		b_name="$(_lang_render "$name_tpl" sib_b)"
		a_glob="$(_lang_render "$glob_tpl" sib_a)"
		b_glob="$(_lang_render "$glob_tpl" sib_b)"
		[ "$a_name" != "$b_name" ] || {
			echo "${wf}: distinct prefixes produced the same upload name: ${a_name}" >&2
			return 1
		}
		# shellcheck disable=SC2053 # deliberate glob match, pattern must stay unquoted
		[[ $a_name == $a_glob ]] || {
			echo "${wf}: ${a_glob} does not collect its own ${a_name}" >&2
			return 1
		}
		# shellcheck disable=SC2053
		[[ $b_name == $b_glob ]] || {
			echo "${wf}: ${b_glob} does not collect its own ${b_name}" >&2
			return 1
		}
		# shellcheck disable=SC2053
		if [[ $b_name == $a_glob ]] || [[ $a_name == $b_glob ]]; then
			echo "${wf}: a prefix's glob also matches the other call's upload" >&2
			return 1
		fi
	done
	# The substring pair the validator exists to refuse (#739 reasoning).
	run env ARTIFACT_PREFIX="py-312" bash "$PREFIX_VALIDATOR"
	assert_failure
	run env ARTIFACT_PREFIX="py312" bash "$PREFIX_VALIDATOR"
	assert_success
}

# The *-publish workflows are consumers in a separate caller job: they must
# take the same input, validate it before the download, and download the
# prefixed name/glob, or a non-default prefix on the producer strands the
# Pages publish on a 404 (#1091).
@test "reusable-test-*-publish: the publish consumers accept and apply the prefix" {
	local entry wf prefix key expected value
	for entry in \
		"reusable-test-python-publish.yml|python|name|\${{ inputs.artifact-prefix }}-coverage" \
		"reusable-test-node-publish.yml|node|pattern|\${{ inputs.artifact-prefix }}-coverage-*"; do
		IFS='|' read -r wf prefix key expected <<<"$entry"
		run awk '/^      artifact-prefix:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
			"${WORKFLOW_DIR}/${wf}"
		assert_success
		assert_output --partial "default: \"${prefix}\""
		run _lang_job_validates_prefix "$wf" publish
		assert_success
		value="$(_lang_with_value "$wf" publish "Download coverage" "$key")"
		[ "$value" = "$expected" ] || {
			echo "${wf}: Download coverage ${key} is ${value}, expected ${expected}" >&2
			return 1
		}
		# The validator precedes the download in the same job.
		run awk '
			/^  publish:$/ { in_job = 1 }
			in_job && /validate-artifact-prefix\.sh$/ { v = NR }
			in_job && /^      - name: Download coverage$/ { d = NR }
			END { exit !(v && d && v < d) }
		' "${WORKFLOW_DIR}/${wf}"
		assert_success
	done
	# The Node merge script receives the prefix the glob was built from.
	run awk '
		/^      - name: Merge coverage report$/ { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && /^          ARTIFACT_PREFIX: \$\{\{ inputs\.artifact-prefix \}\}$/ { ok = 1 }
		END { exit !ok }
	' "${WORKFLOW_DIR}/reusable-test-node-publish.yml"
	assert_success
	run grep -nE "name: python-coverage$|pattern: node-coverage-\*$" \
		"${WORKFLOW_DIR}/reusable-test-python-publish.yml" \
		"${WORKFLOW_DIR}/reusable-test-node-publish.yml"
	assert_failure
}

# The coverage publish path and both coverage uploads in the Python workflow
# must agree on the name, with and without a custom prefix.
@test "reusable-test-python: the coverage upload and the summary publisher share the prefixed name" {
	local upload publish rendered
	upload="$(_lang_with_value reusable-test-python.yml test "Upload coverage report" name)"
	publish="$(_lang_publish_coverage_name reusable-test-python.yml)"
	rendered="$(_lang_render "$upload" py312)"
	[ "$rendered" = "py312-coverage" ]
	[[ "$publish" == *"format('{0}-coverage', inputs.artifact-prefix)"* ]]
	[[ "$publish" != *"'python-coverage'"* ]]
}
