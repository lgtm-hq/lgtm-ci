#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the #770 publishing split.
#
# Three producer workflows carried a conditional publishing job. Because a
# reusable workflow's `permissions:` request is validated STATICALLY, before any
# job `if:` is evaluated, those jobs' scopes were part of the union every caller
# had to grant — including callers that had publishing switched off. #737
# established that each scope was genuinely used by the job declaring it, which
# left moving the job as the only lever.
#
# The permission unions themselves are pinned in
# test_reusable_permission_unions.bats. What is asserted here is that the split
# is *usable*: the artifact handoff each migrating caller depends on still lines
# up end to end, and the inputs left behind are accepted, inert and loud.

load "../../helpers/common"

WORKFLOW_DIR="${PROJECT_ROOT}/.github/workflows"
PUBLISHER="${WORKFLOW_DIR}/reusable-publish-test-results-pages.yml"
SBOM_UPLOAD="${WORKFLOW_DIR}/reusable-sbom-release-upload.yml"
COVERAGE="${WORKFLOW_DIR}/reusable-coverage.yml"
E2E_MATRIX="${WORKFLOW_DIR}/reusable-test-e2e-matrix.yml"
SBOM="${WORKFLOW_DIR}/reusable-sbom.yml"

# Raw value of `key` under the `with:` block of the named step.
#
# Fails loudly when the step or key is absent: an empty string with status 0
# would let the comparisons below pass vacuously the moment a step is renamed.
_step_with_value() {
	local workflow="$1" step_name="$2" with_key="$3" value
	value="$(awk -v step="      - name: ${step_name}" -v key="          ${with_key}: " '
		$0 == step { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && index($0, key) == 1 { print substr($0, length(key) + 1); exit }
	' "$workflow")"
	if [[ -z "$value" ]]; then
		echo "no '${with_key}:' under step '${step_name}' in ${workflow}" >&2
		return 1
	fi
	printf '%s' "$value"
}

# --- the artifact handoff --------------------------------------------------
#
# The split turned three in-workflow `needs:` edges into three artifact
# handoffs across workflow boundaries. Nothing in GitHub Actions checks that a
# downloaded name matches an uploaded one, so a drifted name surfaces as a red
# publish job on an otherwise green run — after the tests have already passed.

@test "publisher: downloads exactly the artifact the caller names" {
	local value
	value="$(_step_with_value "$PUBLISHER" "Download report artifact" name)"
	[ "$value" = '${{ inputs.artifact-name }}' ] || {
		echo "publisher downloads '${value}', not its artifact-name input" >&2
		return 1
	}
}

# The producer's upload name is an input, so a migrating caller can pass the
# same expression to both. What must not happen is the producer hardcoding a
# name the publisher cannot be told about.
@test "coverage: the artifact a caller hands the publisher is caller-nameable" {
	local value
	value="$(_step_with_value "$COVERAGE" "Upload coverage report" name)"
	[ "$value" = '${{ inputs.coverage-artifact-name }}' ] || {
		echo "coverage uploads '${value}', which a caller cannot name" >&2
		return 1
	}
}

@test "e2e-matrix: the merged report name derives from artifact-prefix" {
	local value
	value="$(_step_with_value "$E2E_MATRIX" "Upload merged report" name)"
	[ "$value" = '${{ inputs.artifact-prefix }}-merged-report' ] || {
		echo "e2e-matrix uploads '${value}'; docs promise <prefix>-merged-report" >&2
		return 1
	}
}

# The SBOM handoff is the one the split created outright: release-assets mode
# used to generate, sign and upload to the release in a single job. Both the
# producer's upload and the uploader's download default to `sbom`, so a caller
# that overrides neither still works.
@test "sbom: producer upload and release upload agree on the artifact name" {
	local produced consumed
	produced="$(_step_with_value "$SBOM" "Upload SBOM assets as artifact" name)"
	consumed="$(_step_with_value "$SBOM_UPLOAD" "Download SBOM artifact" name)"
	[ "$produced" = '${{ inputs.artifact-name }}' ]
	[ "$consumed" = '${{ inputs.artifact-name }}' ]
}

# release-assets mode signs before handing over, or the signatures never reach
# the release: the split moved the upload, not the signing.
@test "sbom: release-assets signs before the artifact handoff" {
	run awk '
		/^  release-assets:$/ { in_job = 1 }
		in_job && /^  [a-zA-Z0-9_-]+:$/ && !/^  release-assets:$/ { exit }
		in_job && /^      - name: / { n += 1 }
		in_job && /^      - name: Sign SBOM files$/ { sign = n }
		in_job && /^      - name: Upload SBOM assets as artifact$/ { upload = n }
		END { exit !(sign && upload && sign < upload) }
	' "$SBOM"
	assert_success
}

# --- deprecated inputs: accepted, inert, loud ------------------------------

# Accepted: a reusable workflow rejects an unknown input with a hard
# startup_failure, so deleting these now would break every pinned caller at
# parse time instead of letting it migrate.
@test "deprecated inputs are still accepted by their workflows" {
	local entry workflow input
	for entry in \
		"reusable-coverage.yml:publish-pages" \
		"reusable-test-e2e-matrix.yml:publish-results" \
		"reusable-test-e2e-matrix.yml:pages-target-dir" \
		"reusable-test-e2e-matrix.yml:publish-egress-preset" \
		"reusable-test-e2e-matrix.yml:publish-allowed-endpoints" \
		"reusable-sbom.yml:upload-release-assets"; do
		workflow="${entry%%:*}"
		input="${entry#*:}"
		run awk -v key="      ${input}:" '
			$0 == key { found = 1 }
			END { exit !found }
		' "${WORKFLOW_DIR}/${workflow}"
		assert_success
	done
}

# Inert: each is read exactly once, by its own deprecation warning. A second
# reader would mean some behaviour still hangs off it, and a caller told the
# input does nothing would be misled.
@test "deprecated inputs are read only by their deprecation warning" {
	local entry workflow input count
	for entry in \
		"reusable-coverage.yml:publish-pages" \
		"reusable-test-e2e-matrix.yml:publish-results" \
		"reusable-test-e2e-matrix.yml:pages-target-dir" \
		"reusable-test-e2e-matrix.yml:publish-egress-preset" \
		"reusable-test-e2e-matrix.yml:publish-allowed-endpoints" \
		"reusable-sbom.yml:upload-release-assets"; do
		workflow="${entry%%:*}"
		input="${entry#*:}"
		count="$(grep -c "inputs\.${input}" "${WORKFLOW_DIR}/${workflow}" || true)"
		[ "$count" -eq 1 ] || {
			echo "${workflow}: inputs.${input} is read ${count} times, expected 1" >&2
			return 1
		}
		run grep -qF "INPUT_VALUE: \${{ inputs.${input} }}" \
			"${WORKFLOW_DIR}/${workflow}"
		assert_success
	done
}

# Loud: every deprecated input has a warning wired to the real script, and
# every warning names a replacement rather than just saying "removed".
@test "every deprecated input warns and names its replacement" {
	local workflow
	for workflow in reusable-coverage.yml reusable-test-e2e-matrix.yml \
		reusable-sbom.yml; do
		run grep -q "warn-deprecated-workflow-input.sh" \
			"${WORKFLOW_DIR}/${workflow}"
		assert_success
		run grep -q "REPLACEMENT:" "${WORKFLOW_DIR}/${workflow}"
		assert_success
	done
	# The coverage and e2e migrations must name the workflow to call, not just
	# say the input is gone.
	run grep -q "reusable-publish-test-results-pages.yml" "$COVERAGE"
	assert_success
	run grep -q "reusable-publish-test-results-pages.yml" "$E2E_MATRIX"
	assert_success
	run grep -q "reusable-sbom-release-upload.yml" "$SBOM"
	assert_success
}

# The deprecated outputs must stay declared — a caller (and actionlint in the
# caller's repo) resolves a removed output to nothing — and must evaluate to a
# constant rather than to a job that no longer exists. The value is an empty
# *expression*, not an empty string: actionlint rejects `value: ""` outright.
@test "deprecated Pages URL outputs are declared and constant" {
	# Passed through -v rather than inlined: the literal contains the single
	# quotes that would otherwise close the awk program's own quoting.
	local constant="        value: \${{ '' }}"
	local entry workflow output
	for entry in "${COVERAGE}:pages-url" "${E2E_MATRIX}:report-url"; do
		workflow="${entry%:*}"
		output="${entry##*:}"
		run awk -v key="      ${output}:" -v constant="$constant" '
			$0 == key { in_output = 1; next }
			in_output && /^      [a-z-]+:$/ { exit }
			in_output && $0 == constant { ok = 1 }
			END { exit !ok }
		' "$workflow"
		assert_success
	done
	# The live URL is available from the publisher instead.
	run grep -q 'value: ${{ jobs.publish.outputs.pages-url }}' "$PUBLISHER"
	assert_success
}

# --- the publisher's own contract ------------------------------------------

# Required, not defaulted: both name something the caller alone knows, and the
# Pages directory is URL-visible — a default would publish a half-migrated
# caller's report over the site root.
@test "publisher: artifact-name and pages-target-dir are required" {
	local input
	for input in artifact-name pages-target-dir; do
		run awk -v key="      ${input}:" '
			$0 == key { in_input = 1; next }
			in_input && /^      [a-z-]+:$/ { exit }
			in_input && /^        required: true$/ { ok = 1 }
			in_input && /^        default:/ { bad = 1 }
			END { exit !(ok && !bad) }
		' "$PUBLISHER"
		assert_success
	done
}

@test "publisher: threads the resolved paths into publish-test-results" {
	local key value
	for key in results-path coverage-path badge-path; do
		value="$(_step_with_value "$PUBLISHER" "Publish to GitHub Pages" "$key")"
		[ "$value" = "\${{ steps.paths.outputs.${key} }}" ] || {
			echo "publisher passes '${value}' as ${key}, not the resolved path" >&2
			return 1
		}
	done
	# The resolver step must be the one producing those outputs.
	run awk '
		/^      - name: Resolve report paths$/ { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && /^        id: paths$/ { id = 1 }
		in_step && /resolve-publish-report-paths\.sh$/ { script = 1 }
		END { exit !(id && script) }
	' "$PUBLISHER"
	assert_success
}

# The extraction directory is the publisher's own business, so the resolver has
# to be told the same literal the download step used. Drift between the two
# stages an empty tree over the live site.
@test "publisher: the resolver and the download agree on the extraction dir" {
	local download_path resolver_dir
	download_path="$(_step_with_value "$PUBLISHER" "Download report artifact" path)"
	resolver_dir="$(awk '
		/^      - name: Resolve report paths$/ { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && /^          DOWNLOAD_DIR: / { sub(/^          DOWNLOAD_DIR: /, ""); print; exit }
	' "$PUBLISHER")"

	[ -n "$resolver_dir" ]
	[ "$download_path" = "$resolver_dir" ] || {
		echo "download path '${download_path}' != DOWNLOAD_DIR '${resolver_dir}'" >&2
		return 1
	}
}

# The concurrency group and the environment had to move WITH the job (#770):
# without the shared group two publishers for the same repo+ref race and each
# deploy replaces the whole site, and without the environment the deployment
# does not appear where every other Pages publisher in this repo reports it.
@test "publisher: keeps the shared concurrency group and github-pages environment" {
	run awk '
		/^  publish:$/ { in_job = 1 }
		in_job && /group: pages-\$\{\{ github.repository \}\}-\$\{\{ github.ref \}\}/ { group = 1 }
		in_job && /^      cancel-in-progress: false$/ { serial = 1 }
		in_job && /^      name: github-pages$/ { env = 1 }
		END { exit !(group && serial && env) }
	' "$PUBLISHER"
	assert_success
}

@test "publisher: is reachable from the docs a migrating caller reads" {
	local doc
	for doc in docs/reusable-workflows.md docs/pages-publishing.md \
		docs/workflows/testing.md docs/workflows/README.md; do
		run grep -q "reusable-publish-test-results-pages" "${PROJECT_ROOT}/${doc}"
		assert_success
	done
	for doc in docs/reusable-workflows.md docs/workflow-contract.md \
		docs/workflows/README.md; do
		run grep -q "reusable-sbom-release-upload" "${PROJECT_ROOT}/${doc}"
		assert_success
	done
}
