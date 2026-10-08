#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract for the external consumer canary workflow (#1074).
#
# The canary is a caller workflow that runs with a token for a foreign
# repository, so it must harden before anything else, allow only the GitHub
# API, resolve nothing through a caller-local action path, pass one named
# secret, and keep its header's gate / informational lists in step with the
# classification in scripts/ci/actions/external-canary.sh.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/external-consumer-canary.yml"
SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/external-canary.sh"
VALIDATOR="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh"
PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"
SYNC="${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh"

# Runner *file* for calling functions of the script. Under kcov (CI
# coverage) `bash -c "source ..."` leaves BASH_SOURCE unbound and the
# script's `set -u` aborts; a script file keeps it bound (see
# test_egress_presets_rendered.bats). Usage: bash "$CANARY_EVAL" '<cmd>'
_write_canary_eval() {
	export CANARY_EVAL="${BATS_TEST_TMPDIR}/canary-eval.sh"
	printf '%s\n' '# shellcheck disable=SC1090' 'source "$SCRIPT"' 'eval "$1"' >"$CANARY_EVAL"
}

setup() {
	export SCRIPT
	_write_canary_eval
}

# Names listed under one header comment of the workflow (indented `#   `
# continuation lines up to the next non-continuation line).
_header_list() {
	awk -v header="$1" '
		index($0, header) { on = 1; next }
		on && /^#   / { sub(/^#   /, ""); print; next }
		on { exit }
	' "$WORKFLOW" | tr ' ' '\n' | sed '/^$/d' | sort
}

@test "external-canary workflow: first step of every job is the pinned direct harden-runner in block mode" {
	local harden_sha
	harden_sha="$(sed -nE "s/^HARDEN_SHA='([a-f0-9]{40})'.*/\1/p" "$VALIDATOR" | head -1)"
	[[ -n "$harden_sha" ]]
	# First `uses:` after `steps:` is harden-runner at the validator's SHA.
	run awk '/^    steps:/ { on = 1; next } on && /uses:/ { print; exit }' "$WORKFLOW"
	assert_output --partial "uses: step-security/harden-runner@${harden_sha}"
	run grep -c 'uses: step-security/harden-runner@' "$WORKFLOW"
	assert_output "1"
	run grep -cE '^          egress-policy: block$' "$WORKFLOW"
	assert_output "1"
}

@test "external-canary workflow: harden-runner allowlist is the external-canary preset from the env map" {
	run grep -F "allowed-endpoints:" "$WORKFLOW"
	assert_success
	run grep -F "\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['external-canary'] }}" "$WORKFLOW"
	assert_success
	# The preset exists, is exactly the GitHub API pair, and the embedded map is current.
	run bash -c "source '$PRESETS' && egress_preset_endpoints external-canary"
	assert_success
	assert_output "$(printf 'github.com:443\napi.github.com:443')"
	run bash "$SYNC" --check
	assert_success
	run grep -cF "# lgtm-ci-egress-presets:begin" "$WORKFLOW"
	assert_output "1"
	run grep -F '"external-canary":"github.com:443 api.github.com:443"' "$WORKFLOW"
	assert_success
}

@test "external-canary workflow: references no caller-local or tooling action path" {
	run grep -E '\./\.github/actions|\.lgtm-ci-tooling|lgtm-hq/lgtm-ci/\.github/actions' "$WORKFLOW"
	refute_output
}

@test "external-canary workflow: shell logic lives in the script, not inline" {
	run grep -cE '^        run: ' "$WORKFLOW"
	assert_output "1"
	run grep -F 'run: bash scripts/ci/actions/external-canary.sh "$CANDIDATE_REF"' "$WORKFLOW"
	assert_success
	assert_file_exists "$SCRIPT"
}

@test "external-canary workflow: one named secret, no secrets: inherit, no fixture write via GITHUB_TOKEN" {
	run grep -c 'secrets\.' "$WORKFLOW"
	assert_output "1"
	run grep -F 'GH_TOKEN: ${{ secrets.EXTERNAL_FIXTURE_TOKEN }}' "$WORKFLOW"
	assert_success
	run grep -E "^[[:space:]]+secrets: inherit" "$WORKFLOW"
	refute_output
	run grep -cE '^permissions: \{\}$' "$WORKFLOW"
	assert_output "1"
	# Job permission block is read-only: contents (ref, script) and
	# pull-requests (changed-file list for the run/skip decision).
	run awk '/^    permissions:/ { on = 1; next } on && /^      [a-z-]+:/ { print } on && !/^      / { on = 0 }' "$WORKFLOW"
	assert_output "$(printf '      contents: read\n      pull-requests: read')"
}

@test "external-canary workflow: runs on every pull_request and on workflow_dispatch(ref), with no job-level guard" {
	run grep -cE '^  workflow_dispatch:$' "$WORKFLOW"
	assert_output "1"
	run grep -cE '^      ref:$' "$WORKFLOW"
	assert_output "1"
	run grep -F "    types: [opened, synchronize, reopened, ready_for_review, labeled]" "$WORKFLOW"
	assert_success
	# Always-run / fast-skip: no `if:` on the job and no `paths:` filter, so
	# the check reports on every PR; the script decides full vs skip.
	run grep -E '^    if:|^    paths' "$WORKFLOW"
	refute_output
	run grep -E '^  (push|schedule|merge_group):' "$WORKFLOW"
	refute_output
}

@test "external-canary workflow: passes the decision inputs (event, PR number, labels, fork) to the script" {
	run grep -F "EVENT_NAME: \${{ github.event_name }}" "$WORKFLOW"
	assert_success
	run grep -F "PR_NUMBER: \${{ github.event.pull_request.number }}" "$WORKFLOW"
	assert_success
	run grep -F "PR_LABELS: \${{ join(github.event.pull_request.labels.*.name, ',') }}" "$WORKFLOW"
	assert_success
	run grep -F "PR_HEAD_REPO_FORK: \${{ github.event.pull_request.head.repo.fork }}" "$WORKFLOW"
	assert_success
	run grep -F "EVENT_ACTION: \${{ github.event.action }}" "$WORKFLOW"
	assert_success
	run grep -F "EVENT_LABEL: \${{ github.event.label.name }}" "$WORKFLOW"
	assert_success
	# The concurrency key is the candidate, on dispatch too.
	run grep -F "group: external-consumer-canary-\${{ inputs.ref || github.event.pull_request.head.sha || github.sha }}" "$WORKFLOW"
	assert_success
	# The two labels the script honours are named in the header.
	run grep -F "needs-external-canary" "$WORKFLOW"
	assert_success
	run grep -F "canary-informational" "$WORKFLOW"
	assert_success
}

@test "external-canary workflow: header gate list equals the script's expected-gate list" {
	local listed expected
	listed="$(_header_list "Gate workflows (")"
	expected="$(env -u CANARY_EXPECTED_GATES bash "$CANARY_EVAL" "printf '%s\n' \$CANARY_EXPECTED_GATES | sort")"
	[[ -n "$listed" && -n "$expected" ]]
	run diff <(printf '%s\n' "$expected") <(printf '%s\n' "$listed")
	assert_output ""
	local name
	while IFS= read -r name; do
		run bash "$CANARY_EVAL" "classify_workflow '${name}.yml'"
		assert_output "$(printf 'gate\tsuccess')"
	done <<<"$listed"
}

@test "external-canary workflow: header informational and manual lists match the script's classification" {
	local name listed expected
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		run bash "$CANARY_EVAL" "classify_workflow '${name}.yml' | cut -f1"
		assert_output "informational"
	done < <(_header_list "Informational workflows (")
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		run bash "$CANARY_EVAL" "classify_workflow '${name}.yml' | cut -f1"
		assert_output "manual"
	done < <(_header_list "Manual workflows (")
	# Every non-gate arm of the script is listed in one of the two headers.
	listed="$( (_header_list "Informational workflows ("; _header_list "Manual workflows (") | sort)"
	expected="$(sed -nE 's/^\t([a-z0-9-]+\.yml( \| [a-z0-9-]+\.yml)*)\)$/\1/p' "$SCRIPT" | tr ' ' '\n' | grep -v '^|$' | sed 's/\.yml$//' | sort)"
	[[ -n "$expected" ]]
	run diff <(printf '%s\n' "$expected") <(printf '%s\n' "$listed")
	assert_output ""
}
