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

# Lines of the embedded map in one workflow, de-indented (env block body).
embedded_map() {
	awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
		index($0, end) { on = 0 }
		on && !/LGTM_CI_EGRESS_PRESETS: >-/ { sub(/^    /, ""); print }
		index($0, begin) { on = 1 }
	' "$1"
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

@test "render-presets: folded lines decode to the same JSON as --json" {
	run bash -c "diff <(bash '$RENDER' --json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))') <(bash '$RENDER' | tr '\n' ' ' | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True))')"
	assert_success
	assert_output ""
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
	run bash -c "bash '$RENDER' | awk 'length(\$0) + 4 > 120 { bad = 1; print } END { exit bad }'"
	assert_success
}

@test "render-presets: wildcard hosts survive a matching filename in the working directory" {
	# `*.blob.core.windows.net:443` must not undergo pathname expansion.
	local tmp
	tmp="$(mktemp -d)"
	touch "$tmp/x.blob.core.windows.net:443"
	run bash -c "cd '$tmp' && bash '$RENDER' --json"
	assert_success
	assert_output --partial '*.blob.core.windows.net:443'
	refute_output --partial 'x.blob.core.windows.net:443'
	rm -rf "$tmp"
}

@test "render-presets: wildcard hosts survive an inherited nullglob" {
	run bash -O nullglob -c "cd / && bash '$RENDER' | tr '\n' ' '"
	assert_success
	assert_output --partial '*.blob.core.windows.net:443'
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
	local workflow expected
	expected="$(bash "$RENDER")"
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		run grep -cF "$BEGIN_MARK" "$workflow"
		assert_output "1"
		run grep -cF "LGTM_CI_EGRESS_PRESETS: >-" "$workflow"
		assert_output "1"
		run embedded_map "$workflow"
		assert_output "$expected"
	done
}

@test "the preset map is a workflow-level env literal (not job or step scoped)" {
	local workflow
	for workflow in "$WORKFLOWS_DIR"/reusable-*.yml; do
		# `env:` at column 0 immediately introduces the map block.
		run awk -v begin="$BEGIN_MARK" '
			/^env:$/ { env_line = NR }
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
