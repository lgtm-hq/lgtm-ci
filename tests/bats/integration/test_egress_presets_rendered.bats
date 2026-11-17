#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the generated egress preset map every reusable embeds (#913)
#
# step-security/harden-runner installs its agent in the action pre hook, so a
# reusable workflow's allowlist must be a literal at job start. Each reusable
# therefore carries the rendered preset map in env.LGTM_CI_EGRESS_PRESETS and
# selects from it by expression. These tests pin the three properties that
# make that safe: the copies cannot drift from presets.sh, the selection
# expression reads only job-start values, and no harden-runner block carries a
# hand-maintained host list any more.

load "../../helpers/common"

WORKFLOWS_DIR="${PROJECT_ROOT}/.github/workflows"
RENDER="${PROJECT_ROOT}/scripts/ci/egress/render-presets.sh"
SYNC="${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh"
PRESETS="${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"
BEGIN_MARK="# lgtm-ci-egress-presets:begin"
END_MARK="# lgtm-ci-egress-presets:end"

# reusable-scorecards.yml carries the map in its egress-preset job's env and
# its scorecard job takes the composed allowlist from that job's output: the
# Scorecard API rejects workflow and job env in the scorecard job (#1173).
SCORECARDS="reusable-scorecards.yml"
SCORECARD_NEEDS_AE="allowed-endpoints: \${{ needs.egress-preset.outputs.allowed-endpoints }}"

STORAGE_KEY="LGTM_CI_EGRESS_RESULTS_STORAGE"
STORAGE_PRESETS_KEY="LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS"

# The embedded block of one workflow (keys and values), de-indented to the
# markers: what render-presets.sh printed for it.
embedded_block() {
	awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
		index($0, end) { on = 0 }
		on { if (!ind) { match($0, /^ +/); ind = RLENGTH } print substr($0, ind + 1) }
		index($0, begin) { on = 1 }
	' "$1"
}

# Lines of one embedded value (default: the preset map), de-indented.
embedded_map() {
	local key="${2:-LGTM_CI_EGRESS_PRESETS}"
	embedded_block "$1" | awk -v key="$key" '
		/^[A-Z_]+: >-$/ { on = ($0 == key ": >-"); next }
		on { sub(/^ +/, ""); print }
	'
}

# What sync-workflow-presets.sh renders for one workflow.
expected_block() {
	local accepted flag=()
	accepted="$(bash "$SYNC" --accepted "$1")"
	grep -qE 'fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[' "$1" || flag=(--without-results-storage)
	bash "$RENDER" --presets "$accepted" ${flag[@]+"${flag[@]}"}
}

# The allowed-endpoints value (and continuation lines) of every harden-runner
# step in one workflow, one block per step separated by a blank line.
harden_allowed_endpoints_blocks() {
	awk '
		/uses: step-security\/harden-runner@/ { in_step = 1; next }
		in_step && /^      - / { in_step = 0; in_ae = 0; print "" }
		in_step && /^          allowed-endpoints:/ { in_ae = 1; print; next }
		in_step && in_ae && /^            / { print; next }
		in_step && in_ae { in_ae = 0; print "" }
	' "$1"
}

@test "embedded Docker Hub presets allow only the exact observed AWS blob endpoint (#1269)" {
	local workflow expected count=0
	for workflow in "$WORKFLOWS_DIR"/*.yml; do
		grep -qF "$BEGIN_MARK" "$workflow" || continue
		# Each workflow embeds only the presets it accepts (#1623): expect the
		# exact host for whichever of the three Docker Hub presets it carries.
		expected="$(embedded_map "$workflow" | tr '\n' ' ' | jq -r 'keys_unsorted[]
			| select(. == "docker" or . == "quality" or . == "rust-release")
			| "\(.) docker-images-prod.s3.dualstack.us-east-1.amazonaws.com:443"')"
		[[ -n "$expected" ]] && count=$((count + 1))
		# Inspect decoded endpoint tokens, including any broader or malformed AWS entries.
		run jq -r 'to_entries[] | .key as $preset | .value | split(" ")[]
			| select(contains("amazonaws.com")) | "\($preset) \(.)"' <<<"$(embedded_map "$workflow" | tr '\n' ' ')"
		assert_success
		assert_output "$expected"
		run embedded_map "$workflow" "$STORAGE_KEY"
		refute_output --partial "amazonaws.com"
	done
	[[ "$count" -gt 0 ]]
}

@test "render-presets: --json is one JSON object covering every preset name" {
	run bash -c "bash '$RENDER' --json | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert isinstance(m, dict) and m, m
for k, v in m.items():
    assert v.split(), k
print(len(m))
'"
	assert_success
	local count
	count="$(bash -c "source '$PRESETS' && egress_preset_names" | wc -l | tr -d ' ')"
	assert_output "$count"
}

# Decode a rendered env block (stdin) the way YAML folds it and compose each
# preset's effective allow-list the way the workflow expression does: own
# hosts, plus the results storage hosts when the preset is listed for them.
# Prints sorted JSON {"<preset>": "<sorted hosts>"}.
COMPOSE_PY='
import json, re, sys
values, key = {}, None
for line in sys.stdin.read().splitlines():
    m = re.fullmatch(r"([A-Z_]+): >-", line)
    if m:
        key = m[1]; values[key] = []; continue
    assert line.startswith("  "), line
    values[key].append(line.strip())
folded = {k: " ".join(v) for k, v in values.items()}
presets = json.loads(folded["LGTM_CI_EGRESS_PRESETS"])
users = json.loads(folded.get("LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS", "[]"))
storage = folded.get("LGTM_CI_EGRESS_RESULTS_STORAGE", "").split()
out = {k: " ".join(sorted(set(v.split()) | (set(storage) if k in users else set())))
       for k, v in presets.items()}
print(json.dumps(out, sort_keys=True))
'
SORT_JSON_PY='
import json, sys
m = json.load(sys.stdin)
print(json.dumps({k: " ".join(sorted(set(v.split()))) for k, v in m.items()}, sort_keys=True))
'

@test "render-presets: the folded block composes to the same allow-lists as --json" {
	run bash -c "diff <(bash '$RENDER' --json | python3 -c '$SORT_JSON_PY') <(bash '$RENDER' | python3 -c '$COMPOSE_PY')"
	assert_success
	assert_output ""
	run bash -c "diff <(bash '$RENDER' --json --presets npm-publish,quality | python3 -c '$SORT_JSON_PY') <(bash '$RENDER' --presets quality,npm-publish | python3 -c '$COMPOSE_PY')"
	assert_success
	assert_output ""
}

@test "render-presets: the results storage hosts are rendered once, only for the presets that use them" {
	run bash "$RENDER"
	assert_success
	[[ "$(grep -o 'productionresultssa[0-9]*\.' <<<"$output" | wc -l | tr -d ' ')" -eq \
		"$(bash -c "source '$PRESETS' && egress_github_results_storage_endpoints" | wc -l | tr -d ' ')" ]]
	assert_line "${STORAGE_PRESETS_KEY}: >-"
	assert_line '  ["github-results","npm-publish","release-recover"]'
	# A selection without a storage preset carries neither storage key.
	run bash "$RENDER" --presets quality,github-minimal
	assert_success
	refute_output --partial "$STORAGE_KEY"
	refute_output --partial "productionresultssa"
	run bash "$RENDER" --presets github-minimal,npm-publish
	assert_line '  ["npm-publish"]'
	# --without-results-storage drops both keys, also for a storage preset.
	run bash "$RENDER" --presets release-recover --without-results-storage
	assert_success
	refute_output --partial "$STORAGE_KEY"
	refute_output --partial "productionresultssa"
}

@test "render-presets: --presets keeps render order and rejects an unknown name" {
	run bash "$RENDER" --json --presets quality,github-minimal
	assert_success
	assert_output --regexp '^\{"github-minimal":".*","quality":".*"\}$'
	run bash "$RENDER" --presets quality,typo
	assert_failure
	assert_output --partial "unknown preset 'typo'"
	run bash "$RENDER" --presets ''
	assert_failure
	run bash "$RENDER" --presets
	assert_failure
}

@test "render-presets: every rendered value equals egress_preset_endpoints" {
	# Runs from a script file (not bash -c) so BASH_SOURCE is bound under
	# kcov's DEBUG trap; paths arrive via exported variables.
	local check="$BATS_TEST_TMPDIR/compare.sh"
	cat >"$check" <<'SH'
set -euo pipefail
source "$PRESETS"
json="$(bash "$RENDER" --json)"
while IFS= read -r name; do
	expected="$(egress_preset_endpoints "$name" | tr '\n' ' ' | sed 's/ $//')"
	actual="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$name")"
	[[ "$expected" == "$actual" ]] || { echo "mismatch for $name"; exit 1; }
done < <(egress_preset_names)
echo compared
SH
	PRESETS="$PRESETS" RENDER="$RENDER" run bash "$check"
	assert_success
	assert_output "compared"
}

@test "render-presets: lines stay under yamllint's limit once indented" {
	# Deepest copy: the job-level env in reusable-scorecards.yml, whose
	# markers sit 6 spaces deep (values are already indented 2 more).
	run bash -c "bash '$RENDER' | awk 'length(\$0) + 6 > 120 { bad = 1; print } END { exit bad }'"
	assert_success
}

# A presets file with one wildcard host. No real preset carries a wildcard
# since #1495, but the renderer must still never glob-expand one.
write_wildcard_presets() {
	cat >"$1" <<'SH'
egress_preset_names() { printf '%s\n' github-minimal; }
egress_preset_endpoints() { printf '%s\n' github.com:443 '*.example.com:443'; }
SH
}

@test "render-presets: wildcard hosts survive a matching filename in the working directory" {
	# `*.example.com:443` must not undergo pathname expansion.
	local fake="$BATS_TEST_TMPDIR/presets.sh" tmp="$BATS_TEST_TMPDIR/cwd"
	write_wildcard_presets "$fake"
	mkdir -p "$tmp"
	touch "$tmp/x.example.com:443"
	local mode
	for mode in --json ""; do
		run bash -c "cd '$tmp' && EGRESS_PRESETS_FILE='$fake' bash '$RENDER' $mode"
		assert_success
		assert_output --partial '*.example.com:443'
		refute_output --partial 'x.example.com:443'
	done
}

@test "render-presets: wildcard hosts survive an inherited nullglob" {
	local fake="$BATS_TEST_TMPDIR/presets.sh"
	write_wildcard_presets "$fake"
	run bash -O nullglob -c "cd / && EGRESS_PRESETS_FILE='$fake' bash '$RENDER' | tr '\n' ' '"
	assert_success
	assert_output --partial '*.example.com:443'
}

@test "render-presets: a preset that fails to resolve aborts instead of rendering empty" {
	# egress_preset_names lists a name egress_preset_endpoints does not know.
	local fake="$BATS_TEST_TMPDIR/presets.sh"
	cat >"$fake" <<'SH'
egress_preset_names() { printf '%s\n' github-minimal typo; }
egress_preset_endpoints() {
	case "$1" in
	github-minimal) printf '%s\n' github.com:443 api.github.com:443 ;;
	*) echo "unknown egress preset: $1" >&2; return 1 ;;
	esac
}
SH
	run env EGRESS_PRESETS_FILE="$fake" bash "$RENDER"
	assert_failure
	refute_output --partial '"typo":""'
	run env EGRESS_PRESETS_FILE="$fake" bash "$RENDER" --json
	assert_failure
	refute_output --partial '"typo":""'
}

@test "render-presets: rejects unknown flags" {
	run bash "$RENDER" --bogus
	assert_failure
}

@test "sync-workflow-presets --check: every reusable carries the current map" {
	run bash "$SYNC" --check
	assert_success
}

@test "sync-workflow-presets --check: detects a drifted copy" {
	local tmp
	tmp="$(mktemp -d)"
	mkdir -p "$tmp/.github/workflows"
	cp "$WORKFLOWS_DIR/reusable-test-python.yml" "$tmp/.github/workflows/"
	# Drop one host from the embedded map.
	sed -i.bak 's/ files\.pythonhosted\.org:443//' "$tmp/.github/workflows/reusable-test-python.yml"
	run env REPO_ROOT="$PROJECT_ROOT" WORKFLOWS_DIR="$tmp/.github/workflows" bash "$SYNC" --check
	assert_failure
	assert_output --partial "differs from render-presets.sh"
	assert_output --partial "reusable-test-python.yml"
	rm -rf "$tmp"
}

@test "sync-workflow-presets --check: flags a reusable without the markers" {
	local tmp
	tmp="$(mktemp -d)"
	mkdir -p "$tmp/.github/workflows"
	printf 'name: x\non:\n  workflow_call:\njobs: {}\n' >"$tmp/.github/workflows/reusable-x.yml"
	run env REPO_ROOT="$PROJECT_ROOT" WORKFLOWS_DIR="$tmp/.github/workflows" bash "$SYNC" --check
	assert_failure
	assert_output --partial "no ${BEGIN_MARK}"
	assert_output --partial "reusable-x.yml"
	rm -rf "$tmp"
}

@test "sync-workflow-presets: rewrites a drifted copy back to the rendered map" {
	local tmp
	tmp="$(mktemp -d)"
	mkdir -p "$tmp/.github/workflows"
	cp "$WORKFLOWS_DIR/reusable-test-python.yml" "$tmp/.github/workflows/"
	sed -i.bak 's/ files\.pythonhosted\.org:443//' "$tmp/.github/workflows/reusable-test-python.yml"
	run env REPO_ROOT="$PROJECT_ROOT" WORKFLOWS_DIR="$tmp/.github/workflows" bash "$SYNC"
	assert_success
	assert_output --partial "updated reusable-test-python.yml"
	run diff "$WORKFLOWS_DIR/reusable-test-python.yml" "$tmp/.github/workflows/reusable-test-python.yml"
	assert_success
	rm -rf "$tmp"
}

@test "every reusable embeds exactly one preset map identical to the render" {
	local workflow
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		run grep -cF "$BEGIN_MARK" "$workflow"
		assert_output "1"
		run grep -cF "LGTM_CI_EGRESS_PRESETS: >-" "$workflow"
		assert_output "1"
		run embedded_block "$workflow"
		assert_output "$(expected_block "$workflow")"
	done
}

@test "a workflow embeds only the presets it selects or defaults to (#1623)" {
	# The accepted set is read from the workflow (quoted names in its
	# selectors, defaults of the inputs they read and of egress-preset), so
	# any other name finds no entry and fails the unknown-preset guard.
	local workflow keys accepted
	for workflow in "$WORKFLOWS_DIR"/*.yml; do
		grep -qF "$BEGIN_MARK" "$workflow" || continue
		keys="$(embedded_map "$workflow" | tr '\n' ' ' | jq -r 'keys[]' | sort | paste -sd, -)"
		accepted="$(bash "$SYNC" --accepted "$workflow")"
		[[ -n "$accepted" && "$keys" == "$accepted" ]] || {
			echo "${workflow##*/}: embeds [$keys], accepts [$accepted]"
			return 1
		}
	done
	# Spot checks against the documented defaults.
	run bash "$SYNC" --accepted "$WORKFLOWS_DIR/reusable-ai-review.yml"
	assert_output "ai-review"
	run bash "$SYNC" --accepted "$WORKFLOWS_DIR/reusable-deploy-site-with-reports.yml"
	assert_output "github-pages,playwright"
	run bash "$SYNC" --accepted "$WORKFLOWS_DIR/reusable-site-quality.yml"
	assert_output "github-tooling"
	run bash "$SYNC" --accepted "$WORKFLOWS_DIR/reusable-release-recover.yml"
	assert_output "release-recover"
}

@test "sync-workflow-presets --accepted: selector literals, the inputs they read and egress-preset" {
	local wf="$BATS_TEST_TMPDIR/reusable-x.yml"
	cat >"$wf" <<'YAML'
on:
  workflow_call:
    inputs:
      egress-preset:
        type: string
        default: "pypi"
      build-preset:
        type: string
        default: "docker"
      unused-preset:
        type: string
        default: "quality"
      empty-preset:
        type: string
        default: ""
jobs:
  a:
    steps:
      - with:
          allowed-endpoints: ${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.build-preset || 'docker'] }}
      - with:
          allowed-endpoints: ${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.empty-preset || 'sbom'] }}
      - with:
          allowed-endpoints: ${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
YAML
	run bash "$SYNC" --accepted "$wf"
	assert_success
	assert_output "docker,github-minimal,pypi,sbom"
}

@test "sync-workflow-presets --check: flags a workflow that selects no preset" {
	local tmp
	tmp="$(mktemp -d)"
	mkdir -p "$tmp/.github/workflows"
	printf 'on:\n  workflow_call:\nenv:\n  %s\n  %s\njobs: {}\n' "$BEGIN_MARK" "$END_MARK" \
		>"$tmp/.github/workflows/reusable-x.yml"
	run env REPO_ROOT="$PROJECT_ROOT" WORKFLOWS_DIR="$tmp/.github/workflows" bash "$SYNC" --check
	assert_failure
	assert_output --partial "no egress preset selected or defaulted in: reusable-x.yml"
	rm -rf "$tmp"
}

@test "results storage hosts: once per workflow, only where a selected preset uses them (#1623)" {
	local workflow uses storage n
	for workflow in "$WORKFLOWS_DIR"/*.yml; do
		grep -qF "$BEGIN_MARK" "$workflow" || continue
		n="$(grep -oE 'productionresultssa[0-9]+\.blob\.core\.windows\.net:443' "$workflow" | wc -l | tr -d ' ')"
		storage="$(grep -cF "${STORAGE_KEY}: >-" "$workflow" || true)"
		uses=0
		if grep -qE 'fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[' "$workflow"; then
			uses="$(embedded_map "$workflow" | tr '\n' ' ' | jq -r 'keys[]' |
				grep -cxE 'github-results|npm-publish|release-recover' || true)"
		fi
		if ((uses)); then
			[[ "$storage" -eq 1 ]] || fail "${workflow##*/}: storage preset without ${STORAGE_KEY}"
			[[ "$n" -eq "$(bash -c "source '$PRESETS' && egress_github_results_storage_endpoints" | wc -l | tr -d ' ')" ]] ||
				fail "${workflow##*/}: $n storage hosts"
		else
			[[ "$storage" -eq 0 && "$n" -eq 0 ]] || fail "${workflow##*/}: storage hosts without a storage preset"
			run grep -c "env.${STORAGE_PRESETS_KEY}\|env.${STORAGE_KEY}\b" "$workflow"
			assert_output 0
		fi
	done
}

@test "every selector in a workflow with results storage appends it for the listed presets" {
	# A selector without the storage clause would silently narrow a storage
	# preset to its own hosts; one with it in a workflow without the keys
	# would fail fromJSON(''). Pin both, whitespace-normalised.
	local workflow blocks n_select n_compose
	for workflow in "$WORKFLOWS_DIR"/*.yml; do
		grep -qF "${STORAGE_KEY}: >-" "$workflow" || continue
		blocks="$(harden_allowed_endpoints_blocks "$workflow" | tr -s ' \n' ' ')"
		n_select="$(grep -oE "fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[[^]]+\]," <<<"$blocks" | wc -l | tr -d ' ')"
		n_compose="$(grep -oE "fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[([^]]+)\], contains\(fromJSON\(env\.${STORAGE_PRESETS_KEY}\), [^)]+\) && env\.${STORAGE_KEY} \|\| ''," <<<"$blocks" | wc -l | tr -d ' ')"
		[[ "$n_select" -gt 0 && "$n_select" -eq "$n_compose" ]] || {
			echo "${workflow##*/}: $n_select selectors, $n_compose compose the storage"
			return 1
		}
	done
}

@test "a wrapper forwards egress-preset only to reusables that accept its presets" {
	# A wrapper that passes inputs.egress-preset on must not accept a name
	# its callee rejects, or a valid call would fail one level down.
	local workflow callee wrapper_set callee_set name
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		while IFS= read -r callee; do
			[[ -n "$callee" ]] || continue
			wrapper_set="$(bash "$SYNC" --accepted "$workflow")"
			callee_set=",$(bash "$SYNC" --accepted "$WORKFLOWS_DIR/$callee"),"
			for name in ${wrapper_set//,/ }; do
				[[ "$callee_set" == *",$name,"* ]] ||
					fail "${workflow##*/} accepts $name but forwards egress-preset to $callee"
			done
		done < <(awk '
			/^    uses: \.\/\.github\/workflows\// { callee = $2; sub(/.*\//, "", callee) }
			/^      egress-preset: \$\{\{ inputs\.egress-preset \}\}$/ { print callee }
		' "$workflow" | sort -u)
	done
}

@test "the preset map is a job-start env literal (workflow-level; job-level only in scorecards)" {
	local workflow env_re
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		# `env:` at column 0 immediately introduces the map block; in
		# reusable-scorecards.yml it is the egress-preset job's env (#1173).
		env_re='^env:$'
		[[ "${workflow##*/}" != "$SCORECARDS" ]] || env_re='^    env:$'
		run awk -v begin="$BEGIN_MARK" -v env_re="$env_re" '
			$0 ~ env_re && !mark_line { env_line = NR }
			index($0, begin) { mark_line = NR }
			END { exit !(env_line && mark_line && mark_line > env_line && mark_line - env_line < 12) }
		' "$workflow"
		assert_success
		# No expression inside the map: it must be a literal at job start.
		run bash -c "awk -v begin='$BEGIN_MARK' -v end='$END_MARK' 'index(\$0, end) { on = 0 } on { print } index(\$0, begin) { on = 1 }' '$workflow' | grep -c '\${{'"
		assert_output "0"
	done
}

@test "every harden-runner allowed-endpoints selects from the env map" {
	local workflow blocks n_steps n_select
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		n_steps="$(grep -c 'uses: step-security/harden-runner@' "$workflow" || true)"
		[[ "$n_steps" -gt 0 ]] || continue
		blocks="$(harden_allowed_endpoints_blocks "$workflow")"
		n_select="$(grep -cF 'fromJSON(env.LGTM_CI_EGRESS_PRESETS)' <<<"$blocks" || true)"
		if [[ "${workflow##*/}" == "$SCORECARDS" ]]; then
			n_select=$((n_select + $(grep -cxF "          $SCORECARD_NEEDS_AE" <<<"$blocks" || true)))
		fi
		[[ "$n_select" -eq "$n_steps" ]] || {
			echo "$workflow: $n_steps harden-runner steps but $n_select env-map selections"
			echo "$blocks"
			return 1
		}
	done
}

# The validator's expression analyser (expressions may reference only inputs
# and env; nothing outside an expression may be a host:port). Sourced from the
# script so the BATS contract and the CI validator can never disagree.
# shellcheck disable=SC1090
source <(sed -n '/^_allowed_endpoints_violations()/,/^}/p' "${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh")

@test "no harden-runner allowed-endpoints reads any context other than inputs and env" {
	local workflow block
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		while IFS= read -r -d $'\x1e' block; do
			[[ -n "${block//[[:space:]]/}" ]] || continue
			# The scorecard job's exact needs-output block (#1173) is the only exception.
			if [[ "${workflow##*/}" == "$SCORECARDS" && "$(sed -e 's/^[[:space:]]*//' -e '/^#/d' -e '/^$/d' <<<"$block")" == "$SCORECARD_NEEDS_AE" ]]; then
				continue
			fi
			run _allowed_endpoints_violations <<<"$block"
			assert_output ""
		done < <(harden_allowed_endpoints_blocks "$workflow" | awk 'BEGIN { RS = ""; ORS = "\x1e" } { print }')
	done
}

@test "the expression analyser rejects a literal host next to an expression" {
	run _allowed_endpoints_violations <<<"          allowed-endpoints: \${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['a'] }} evil.example:443"
	assert_output --partial "literal host:port (evil.example:443)"
	run _allowed_endpoints_violations <<<"          allowed-endpoints: >
            \${{ format('{0} {1}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)['a'], github.head_ref) }}"
	assert_output --partial "found: github"
}

@test "every preset name selected by expression exists in presets.sh" {
	local workflow name
	while IFS= read -r name; do
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$name' >/dev/null"
		assert_success
	done < <(
		grep -hoE "fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[[^]]*'[a-z-]+'\]" "$WORKFLOWS_DIR"/reusable-*.yml |
			grep -oE "'[a-z-]+'\]" | tr -d "']" | sort -u
	)
}

@test "every egress-preset input default exists in presets.sh" {
	local name
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		run bash -c "source '$PRESETS' && egress_preset_endpoints '$name' >/dev/null"
		assert_success
	done < <(
		awk '
			/^      (egress-preset|egress-build-preset|egress-deploy-preset):$/ { on = 1; next }
			on && /^        default:/ { gsub(/"/, "", $2); print $2; on = 0 }
			on && /^      [a-z-]+:$/ { on = 0 }
		' "$WORKFLOWS_DIR"/reusable-*.yml | sort -u
	)
}

@test "caller-selectable blocks fall back to the workflow's egress-preset default" {
	# Each `inputs.egress-preset || '<name>'` literal must equal that
	# workflow's egress-preset input default, so an explicit empty string
	# selects the same preset the input documents.
	local workflow default literal
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		default="$(awk '
			/^      egress-preset:$/ { on = 1; next }
			on && /^        default:/ { gsub(/"/, "", $2); print $2; exit }
			on && /^      [a-z-]+:$/ { on = 0 }
		' "$workflow")"
		[[ -n "$default" ]] || continue
		while IFS= read -r literal; do
			[[ "$literal" == "$default" ]] || {
				echo "$workflow: inputs.egress-preset falls back to '$literal' but the input default is '$default'"
				return 1
			}
		done < <(grep -oE "\[inputs\.egress-preset \|\| '[a-z-]+'\]" "$workflow" | grep -oE "'[a-z-]+'" | tr -d "'")
	done
}

@test "caller-selectable blocks use the canonical replace/append expression verbatim" {
	# The replace/append semantics live in one expression repeated across the
	# reusables (proven live by the consumer fixture, #913). Pin its exact
	# shape, whitespace-normalised, so a drifting copy cannot quietly drop the
	# caller list or the preset:
	#   replace + non-empty list -> the list alone
	#   otherwise               -> preset (+ list in append mode)
	local workflow default blocks expected n_blocks n_match
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		default="$(awk '
			/^      egress-preset:$/ { on = 1; next }
			on && /^        default:/ { gsub(/"/, "", $2); print $2; exit }
			on && /^      [a-z-]+:$/ { on = 0 }
		' "$workflow")"
		[[ -n "$default" ]] || continue
		blocks="$(harden_allowed_endpoints_blocks "$workflow" | tr -s ' \n' ' ')"
		n_blocks="$(grep -o "\[inputs.egress-preset || '$default'\]" <<<"$blocks" | wc -l | tr -d ' ')"
		[[ "$n_blocks" -gt 0 ]] || continue
		expected="\${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '') && inputs.allowed-endpoints || format('{0} {1}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || '$default'], inputs.allowed-endpoints) }}"
		# A workflow carrying the results storage appends it for the listed
		# presets (#1623); its selectors use that form instead.
		if grep -qF "${STORAGE_KEY}: >-" "$workflow"; then
			expected="\${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '') && inputs.allowed-endpoints || format('{0} {1} {2}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || '$default'], contains(fromJSON(env.${STORAGE_PRESETS_KEY}), inputs.egress-preset || '$default') && env.${STORAGE_KEY} || '', inputs.allowed-endpoints) }}"
		fi
		n_match="$(grep -oF "$expected" <<<"$blocks" | wc -l | tr -d ' ')"
		# (site-quality's test job selects via `inputs.test-egress-preset ||
		# inputs.egress-preset || ...` and is covered by the per-job test below.)
		[[ "$n_match" -eq "$n_blocks" ]] || {
			echo "$workflow: $n_blocks blocks select '$default' but only $n_match use the canonical expression"
			echo "$blocks"
			return 1
		}
	done
}

@test "per-job variants (deploy-site, site-quality test job) keep the same replace/append gate" {
	local workflow blocks
	for workflow in reusable-deploy-site-with-reports reusable-site-quality; do
		blocks="$(harden_allowed_endpoints_blocks "$WORKFLOWS_DIR/$workflow.yml" | tr -s ' \n' ' ')"
		run grep -oF "(inputs.allowed-endpoints-mode != 'append' && (inputs." <<<"$blocks"
		assert_success
		run grep -oF "|| format('{0} {1}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs." <<<"$blocks"
		assert_success
	done
	# deploy-site: build and deploy jobs select their own preset inputs.
	# Two harden-runner selectors plus their two unknown-preset guards.
	run grep -oE "\[inputs\.egress-(build|deploy)-preset \|\| '(playwright|github-pages)'\]" "$WORKFLOWS_DIR/reusable-deploy-site-with-reports.yml"
	assert_success
	[[ "$(wc -l <<<"$output" | tr -d ' ')" -eq 4 ]]
	# site-quality test job: test-egress-preset falls back to egress-preset.
	run grep -F "[inputs.test-egress-preset || inputs.egress-preset || 'github-tooling']" "$WORKFLOWS_DIR/reusable-site-quality.yml"
	assert_success
}

@test "every caller-selectable harden-runner step is followed by an unknown-preset guard with the same selector" {
	# The pre hook cannot refuse an unknown name (it just gets an empty
	# baseline), so the very next step must fail by name instead of letting
	# the job die later with an opaque network error.
	local workflow bad
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		bad="$(awk '
			/uses: step-security\/harden-runner@/ { in_harden = 1; selector = ""; next }
			in_harden && match($0, /fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[inputs\.[^]]+\]/) {
				selector = substr($0, RSTART, RLENGTH)
			}
			# The generated agent check (#1203) sits between the two steps.
			in_harden && /^      - name: Verify harden-runner agent$/ { next }
			in_harden && /^      - / {
				in_harden = 0
				if (selector != "") {
					if ($0 !~ /- name: Fail on unknown egress-preset/) { print "missing guard after " selector; next }
					want = selector " == null"
					expect = 1
					next
				}
			}
			# The guard if: may wrap across lines; compare the joined text.
			expect && !/^      - / { joined = joined " " $0; gsub(/[[:space:]]+/, " ", joined) }
			expect && index(joined, want) { expect = 0; want = ""; joined = "" }
			expect && /^      - / { print "guard selector differs from harden selector: " want; expect = 0; joined = "" }
		' "$workflow")"
		[[ -z "$bad" ]] || {
			echo "$workflow: $bad"
			return 1
		}
	done
}

@test "the unknown-preset guard is skipped when replace mode uses the caller list alone" {
	# In replace mode with a non-empty allowed-endpoints the preset is not
	# consulted, so a stale preset name must not fail the job (Greptile P1).
	local workflow n_guards n_gated
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		n_guards="$(grep -c '^      - name: Fail on unknown egress-preset' "$workflow" || true)"
		[[ "$n_guards" -gt 0 ]] || continue
		n_gated="$(grep -c "^          (inputs.allowed-endpoints-mode == 'append'" "$workflow" || true)"
		[[ "$n_gated" -eq "$n_guards" ]] || {
			echo "$workflow: $n_guards guards but $n_gated carry the replace-mode gate"
			return 1
		}
		# The agent check (#1203) rejects any policy but block before the guard
		# runs, so the guard no longer carries an audit escape.
		run grep -c "inputs.egress-policy != 'audit'" "$workflow"
		assert_output 0
	done
}

@test "allowed-endpoints inputs default to empty so the preset is the baseline" {
	# A non-empty default would silently replace the preset in replace mode
	# and re-create the hand-maintained host lists this contract removes.
	local workflow bad
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		bad="$(awk '
			/^      (allowed-endpoints|allowed-endpoints-build|allowed-endpoints-deploy|test-allowed-endpoints):$/ { on = 1; name = $1; next }
			on && /^        default:/ { if ($0 !~ /default: ""$/) print name " " $0; on = 0 }
			on && /^      [a-z-]+:$/ { on = 0 }
		' "$workflow")"
		[[ -z "$bad" ]] || {
			echo "$workflow: $bad"
			return 1
		}
	done
}

@test "the removed resolve step and bundle are gone" {
	run bash -c "grep -lE 'resolve-egress-allowlist|\.github/actions/harden-runner' '$WORKFLOWS_DIR'/*.yml '${PROJECT_ROOT}'/.github/actions/*/action.yml"
	assert_failure
	[[ ! -e "${PROJECT_ROOT}/.github/actions/resolve-egress-allowlist" ]]
	[[ ! -e "${PROJECT_ROOT}/.github/actions/harden-runner" ]]
}
