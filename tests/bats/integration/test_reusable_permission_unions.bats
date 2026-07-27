#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Pin the caller-facing permission union of the reusable workflows
#          whose conditional publishing jobs used to widen it (#737, #770).
#
# GitHub validates a reusable workflow's `permissions:` request STATICALLY,
# before any job `if:` is evaluated. The caller must therefore grant at least
# the union of every scope declared across the called workflow's jobs, even the
# jobs its inputs disable. These tests pin that union so a job-level permission
# change cannot silently widen what every consumer must grant, and assert that
# the documented caller snippets still match it exactly.
#
# #737 established that every publish-only scope was genuinely exercised by the
# job declaring it, so the only lever was moving that job out of the file. #770
# pulled it: the Pages deploy now lives in
# reusable-publish-test-results-pages.yml and the release-asset upload in
# reusable-sbom-release-upload.yml, both invoked by the caller only when it
# actually publishes.
#
# The unions below are therefore an acceptance criterion, not a description.
# They are asserted two ways on purpose: exactly, so a re-added publishing job
# fails here rather than silently re-widening every consumer; and per scope, so
# the specific grants #770 removed cannot creep back under a different job name.

load "../../helpers/common"

# Print the union of all job-level `permissions:` scopes in a workflow, one
# `scope: level` pair per line, sorted, with `write` outranking `read`.
_permission_union() {
	local workflow="$1"
	awk '
		function rank(v) { return v == "write" ? 2 : (v == "read" ? 1 : 0) }
		/^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { in_perms = 0 }
		/^    permissions:[[:space:]]*$/ { in_perms = 1; next }
		in_perms && /^      #/ { next }
		in_perms && /^      [a-z-]+:[[:space:]]+[a-z-]+/ {
			scope = $1
			sub(/:$/, "", scope)
			if (rank($2) > rank(seen[scope])) seen[scope] = $2
			next
		}
		in_perms { in_perms = 0 }
		END { for (s in seen) print s ": " seen[s] }
	' "$workflow" | sort
}

# Print every `permissions:` block that a doc snippet attaches to a caller job
# invoking the given reusable workflow, one block per line as a sorted
# comma-separated list of `scope: level` pairs.
_doc_permission_blocks() {
	local file="$1" ref="$2"
	awk -v ref="$ref" '
		function flush() {
			if (in_perms) { print block; block = ""; in_perms = 0 }
		}
		index($0, "workflows/" ref "@") { flush(); armed = 1; next }
		armed && /^[[:space:]]*#/ { next }
		armed && /^[[:space:]]+permissions:[[:space:]]*$/ {
			armed = 0
			in_perms = 1
			block = ""
			next
		}
		armed { armed = 0 }
		in_perms && /^[[:space:]]*#/ { next }
		in_perms && /^[[:space:]]+[a-z-]+:[[:space:]]+[a-z-]+/ {
			scope = $1
			sub(/:$/, "", scope)
			block = block (block == "" ? "" : "|") scope ": " $2
			next
		}
		in_perms { flush() }
		END { flush() }
	' "$file" | while IFS= read -r block; do
		printf '%s\n' "$block" | tr '|' '\n' | sort | paste -sd, -
	done
}

# Assert that every documented caller snippet for a workflow grants exactly its
# union. `expected_blocks` guards against a snippet silently disappearing.
_assert_docs_match_union() {
	local workflow="$1" ref="$2" expected_blocks="$3"
	shift 3

	local union
	union="$(_permission_union "$workflow" | paste -sd, -)"

	local blocks=() doc
	for doc in "$@"; do
		local line
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			blocks+=("$line")
		done < <(_doc_permission_blocks "$doc" "$ref")
	done

	if [[ "${#blocks[@]}" -ne "$expected_blocks" ]]; then
		echo "expected $expected_blocks documented ${ref} caller snippets," \
			"found ${#blocks[@]}" >&2
		return 1
	fi

	local block
	for block in "${blocks[@]}"; do
		if [[ "$block" != "$union" ]]; then
			echo "documented ${ref} caller grant does not match the union" >&2
			echo "  documented: $block" >&2
			echo "  union:      $union" >&2
			return 1
		fi
	done
}

@test "reusable-sbom: caller permission union is pinned" {
	run _permission_union "${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"
	assert_success
	assert_output "attestations: write
contents: read
id-token: write
security-events: write"
}

@test "reusable-coverage: caller permission union is pinned" {
	run _permission_union "${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml"
	assert_success
	assert_output "contents: read
pull-requests: write"
}

@test "reusable-test-e2e-matrix: caller permission union is pinned" {
	run _permission_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	assert_success
	assert_output "contents: read"
}

# The two workflows the publishing jobs moved into. Pinning their unions too
# keeps the accounting closed: every scope #770 removed from a producer above
# must reappear here, in a workflow a caller invokes only when it publishes.
@test "reusable-publish-test-results-pages: caller permission union is pinned" {
	run _permission_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-results-pages.yml"
	assert_success
	assert_output "actions: write
contents: read
id-token: write
pages: write"
}

@test "reusable-sbom-release-upload: caller permission union is pinned" {
	run _permission_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml"
	assert_success
	assert_output "contents: write"
}

# Per-scope minimality, asserted independently of the exact-union tests above.
# An exact-match assertion is easy to "fix" by updating the expected string; a
# named scope that must not appear at all states the #770 acceptance criterion
# in terms a future edit cannot quietly satisfy.
@test "non-publishing callers: no Pages scope survives in the producers" {
	local workflow scope
	for workflow in reusable-coverage.yml reusable-test-e2e-matrix.yml; do
		for scope in "pages: write" "id-token: write" "actions: write"; do
			run _permission_union "${PROJECT_ROOT}/.github/workflows/${workflow}"
			assert_success
			refute_output --partial "$scope"
		done
	done
}

@test "non-publishing callers: reusable-sbom requests no contents: write" {
	run _permission_union "${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"
	assert_success
	refute_output --partial "contents: write"
	# Read is still required and must not have been dropped along with write.
	assert_output --partial "contents: read"
}

# The e2e matrix workflow declares no `pull-requests` scope in any job: it
# publishes to Pages, not to a PR comment. Documenting one would be an
# over-grant, which is how the docs drifted before #737.
@test "reusable-test-e2e-matrix: no job requests a pull-requests scope" {
	run grep -q "pull-requests:" \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	assert_failure
}

# The `actions: write` grant is the one that looked like #730's removable
# over-grant. It is not: the publish path shells out to the REST artifact API
# with GITHUB_TOKEN, so `permissions:` really does gate it. That is why #770
# had to move the job rather than drop the scope, and why the scope is still
# declared — by reusable-publish-test-results-pages.yml now.
@test "publish-test-results deletes stale Pages artifacts over the REST API" {
	local script="${PROJECT_ROOT}/scripts/ci/actions/delete-run-pages-artifacts.sh"
	assert_file_contains_literal "$script" "gh api --method DELETE"
	assert_file_contains_literal "$script" "/actions/artifacts/"
	run grep -q "GH_TOKEN" \
		"${PROJECT_ROOT}/.github/actions/publish-test-results/action.yml"
	assert_success
}

# The SBOM `contents: write` grant is likewise real: the upload job ends in a
# GITHUB_TOKEN-authenticated release-asset write. Since #770 that job — and the
# only `gh release upload` invocation left in any workflow of this family —
# lives in reusable-sbom-release-upload.yml.
@test "reusable-sbom-release-upload: writes release assets with GITHUB_TOKEN" {
	local script="${PROJECT_ROOT}/scripts/ci/actions/upload-sbom-release-assets.sh"
	assert_file_contains_literal "$script" "gh release upload"
	run grep -q "GH_TOKEN: \${{ github.token }}" \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml"
	assert_success
}

@test "reusable-sbom: no job still invokes the release-asset upload script" {
	run grep -q "upload-sbom-release-assets.sh" \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"
	assert_failure
}

@test "docs: reusable-sbom caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml" \
		"reusable-sbom.yml" \
		5 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md" \
		"${PROJECT_ROOT}/docs/workflow-contract.md"
	assert_success
}

@test "docs: reusable-coverage caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml" \
		"reusable-coverage.yml" \
		2 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}

@test "docs: reusable-test-e2e-matrix caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml" \
		"reusable-test-e2e-matrix.yml" \
		2 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}

# The publishers' own snippets are held to the same standard: a caller copying
# one must end up granting exactly what the workflow requests, no more. An
# over-granting migration snippet would hand back the least privilege the split
# was performed to obtain.
@test "docs: publisher caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-publish-test-results-pages.yml" \
		"reusable-publish-test-results-pages.yml" \
		2 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}

@test "docs: sbom release upload caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml" \
		"reusable-sbom-release-upload.yml" \
		1 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}
