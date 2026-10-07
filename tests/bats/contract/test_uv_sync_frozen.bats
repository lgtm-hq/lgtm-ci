#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for #1021 — CI installs Python dependencies only with
#          `uv sync --frozen`, and private git dependency auth in
#          reusable-test-python.yml is an explicit, named, optional secret
#          wired to a dedicated step that is gated on the secret being set.
#          No `secrets: inherit`, no generic pre-sync hook.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml"

# Print the YAML block of the step with the given name (from its `- name:`
# line up to, not including, the next `- name:` line).
_step_block() {
	awk -v want="$1" '
		/^      - name: / {
			in_block = ($0 == "      - name: " want)
		}
		in_block { print }
	' "$WORKFLOW"
}

@test "uv-sync-frozen: no uv sync without --frozen anywhere under scripts/ci" {
	# Executable lines only: strip comments and echo text, then look for a
	# `uv sync` invocation that is not immediately followed by --frozen.
	run bash -c "
		grep -rn 'uv sync' '${PROJECT_ROOT}/scripts/ci' \
			| grep -vE ':[[:space:]]*#' \
			| grep -vE 'echo ' \
			| grep -vE 'uv sync --frozen' || true
	"
	assert_output ""
}

@test "uv-sync-frozen: setup-python.sh deps step uses --frozen in both branches" {
	# Executable invocations only (no comments, no echo text): exactly the
	# EXTRAS branch and the plain branch.
	run bash -c "
		grep -E '^[[:space:]]*uv sync' '${PROJECT_ROOT}/scripts/ci/actions/setup-python.sh'
	"
	assert_success
	assert_line --index 0 --partial 'uv sync --frozen "${UV_ARGS[@]}"'
	assert_line --index 1 --partial 'uv sync --frozen'
	run bash -c "
		grep -cE '^[[:space:]]*uv sync' '${PROJECT_ROOT}/scripts/ci/actions/setup-python.sh'
	"
	assert_output "2"
}

@test "uv-sync-frozen: reusable-test-python declares GIT_DEPS_TOKEN as an optional named secret" {
	run awk '/^    secrets:$/,/^    outputs:$/' "$WORKFLOW"
	assert_output --partial "      GIT_DEPS_TOKEN:"
	assert_output --partial "        required: false"
	refute_output --partial "required: true"
}

@test "uv-sync-frozen: reusable-test-python never uses secrets: inherit" {
	# A YAML key, not the prose in the secret description.
	run grep -nE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' "$WORKFLOW"
	assert_failure
}

@test "uv-sync-frozen: auth step is gated on the secret and precedes the install step" {
	run _step_block "Configure git auth for private dependencies"
	assert_success
	assert_line --partial "if: env.GIT_DEPS_TOKEN_PRESENT == 'true'"
	assert_line --partial "STEP: configure"
	assert_line --partial "GIT_DEPS_TOKEN: \${{ secrets.GIT_DEPS_TOKEN }}"
	assert_line --partial "GIT_DEPS_HOST: \${{ inputs.git-deps-host }}"
	assert_line --partial "configure-git-deps-auth.sh"

	# Job-level flag is the only place the secret presence is evaluated.
	run grep -n "GIT_DEPS_TOKEN_PRESENT: \${{ secrets.GIT_DEPS_TOKEN != '' }}" "$WORKFLOW"
	assert_success

	# Order: configure -> install -> cleanup.
	run awk '
		/^      - name: Configure git auth for private dependencies$/ { print "configure" }
		/^      - name: Install dependencies$/ { print "install" }
		/^      - name: Remove git auth for private dependencies$/ { print "cleanup" }
	' "$WORKFLOW"
	assert_output $'configure\ninstall\ncleanup'
}

@test "uv-sync-frozen: cleanup step always runs when the secret is set" {
	run _step_block "Remove git auth for private dependencies"
	assert_success
	assert_line --partial "if: always() && env.GIT_DEPS_TOKEN_PRESENT == 'true'"
	assert_line --partial "STEP: cleanup"
	refute_line --partial "GIT_DEPS_TOKEN: "
}

@test "uv-sync-frozen: host and username inputs are declared with safe defaults" {
	run awk '/^      git-deps-host:$/,/^      git-deps-username:$/' "$WORKFLOW"
	assert_output --partial 'default: "github.com"'
	run awk '/^      git-deps-username:$/,/^      working-directory:$/' "$WORKFLOW"
	assert_output --partial 'default: "x-access-token"'
}
