#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Pin the caller-facing permission union of the reusable workflows
#          whose conditional publishing jobs widen it (#737).
#
# GitHub validates a reusable workflow's `permissions:` request STATICALLY,
# before any job `if:` is evaluated. The caller must therefore grant at least
# the union of every scope declared across the called workflow's jobs, even the
# jobs its inputs disable. These tests pin that union so a job-level permission
# change cannot silently widen what every consumer must grant, and assert that
# the documented caller snippets still match it exactly.
#
# Every scope in the expected unions below is genuinely exercised by the job
# that declares it — see the annotations at each declaration and the
# "Scopes a caller cannot avoid granting" section of docs/reusable-workflows.md.
# Splitting the publishing jobs out, which is the only way to shrink these
# unions, is tracked in #770.

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
contents: write
id-token: write
security-events: write"
}

@test "reusable-coverage: caller permission union is pinned" {
	run _permission_union "${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml"
	assert_success
	assert_output "actions: write
contents: read
id-token: write
pages: write
pull-requests: write"
}

@test "reusable-test-e2e-matrix: caller permission union is pinned" {
	run _permission_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	assert_success
	assert_output "actions: write
contents: read
id-token: write
pages: write"
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
# with GITHUB_TOKEN, so `permissions:` really does gate it.
@test "publish-test-results deletes stale Pages artifacts over the REST API" {
	local script="${PROJECT_ROOT}/scripts/ci/actions/delete-run-pages-artifacts.sh"
	assert_file_contains_literal "$script" "gh api --method DELETE"
	assert_file_contains_literal "$script" "/actions/artifacts/"
	run grep -q "GH_TOKEN" \
		"${PROJECT_ROOT}/.github/actions/publish-test-results/action.yml"
	assert_success
}

# The SBOM `contents: write` grant is likewise real: the upload jobs end in a
# GITHUB_TOKEN-authenticated release-asset write.
@test "reusable-sbom: release upload writes release assets with GITHUB_TOKEN" {
	local script="${PROJECT_ROOT}/scripts/ci/actions/upload-sbom-release-assets.sh"
	assert_file_contains_literal "$script" "gh release upload"
	run grep -q "GH_TOKEN: \${{ github.token }}" \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml"
	assert_success
}

@test "docs: reusable-sbom caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom.yml" \
		"reusable-sbom.yml" \
		4 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md" \
		"${PROJECT_ROOT}/docs/workflow-contract.md"
	assert_success
}

@test "docs: reusable-coverage caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml" \
		"reusable-coverage.yml" \
		1 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}

@test "docs: reusable-test-e2e-matrix caller snippets grant exactly the union" {
	run _assert_docs_match_union \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml" \
		"reusable-test-e2e-matrix.yml" \
		1 \
		"${PROJECT_ROOT}/docs/reusable-workflows.md"
	assert_success
}
