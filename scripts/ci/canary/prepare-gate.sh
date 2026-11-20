#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Excuse a reusable test workflow's aggregate job in a fixture run
#          when it failed only because its own prepare job failed on the
#          harden-runner agent (#1670). infra_signature_reason (runs.sh)
#          plans and checks it.
# Sourced by scripts/ci/actions/external-canary.sh next to runs.sh. Host
# functions: lgtm_ci_api and resolve_candidate_merge_base (external-canary.sh);
# INFRA_HR_SHAPE_JQ, INFRA_HR_MATRIX_STEP and INFRA_HR_MATRIX_MESSAGE
# (../lib/infra-signatures.sh).
#
# Fixture runs 43858549864 and 43886292079 (siblings.yml) and 43924199865
# (verify-fresh-install.yml): the prepare job's agent did not start, so the
# aggregate job (`needs: [prepare, test]`, `if: always()`) failed on its
# prepare gate before any checkout, and its always() matrix gate then failed
# because the skipped test job did not succeed.
#
# The rule trusts step names, conclusions and annotations that the
# candidate's own workflows produce; the jobs API shows no step body. Two
# things bound that trust: the aggregate job's text in the candidate's
# reusable workflows must equal the merge base's (prepare_gate_trusted), and
# the run carries only the prepare job's harden-runner label, so the excuse
# buys one retry and a repeat is a gate failure (agent_startup_repeated).

# Keep in step with the aggregate job of reusable-test-python.yml,
# reusable-rust-test.yml, reusable-rust-test-run.yml, reusable-test-node.yml,
# reusable-test-node-run.yml and reusable-test-node-custom.yml; a test pins
# the step order, both gate steps (condition and body) and the job's
# needs/if lines in each.
CANARY_PREPARE_GATE_STEP='Fail if matrix preparation did not succeed'
CANARY_PREPARE_GATE_MESSAGE="Matrix preparation concluded 'failure'; failing the check."

# Print the reusable workflow files whose aggregate job is named `Aggregate
# <family> Results` for family $1; return 1 for any other family.
prepare_gate_workflows() {
	case "${1:-}" in
	Python) printf '%s\n' reusable-test-python.yml ;;
	Rust) printf '%s\n' reusable-rust-test.yml reusable-rust-test-run.yml ;;
	Node.js) printf '%s\n' reusable-test-node.yml reusable-test-node-run.yml reusable-test-node-custom.yml ;;
	*) return 1 ;;
	esac
}

# jq defs, used with --arg gate CANARY_PREPARE_GATE_STEP and --arg matrix
# INFRA_HR_MATRIX_STEP:
#   prepare_gate_family: the prepare job's family for an aggregate family
#     (`.`), or null. The one name that differs: `Aggregate Node.js Results`
#     pairs with `Prepare Node Matrix`. The six reusables have no other pair.
#   prepare_gate_shape: on one job object, [caller, family] when the job is
#     `<caller> / Aggregate <family> Results` of a known family and its steps,
#     in number order, are exactly
#       Set up job, Pre Harden runner, Harden runner, Verify harden-runner
#       agent (all success), Fail on unknown egress-preset (skipped), the
#       prepare gate ($gate, failure),
#       any number of skipped steps (checkouts, tooling, aggregation),
#       the matrix gate ($matrix, failure), Recheck harden-runner agent, Post
#       Harden runner, Complete job (all success);
#     nothing for any other job. A completed job reports every step that did
#     not run as `skipped`, so an unconcluded step is never accepted.
# shellcheck disable=SC2016 # $n, $m, $s, $h, $t, $gate and $matrix are jq variables.
CANARY_PREPARE_GATE_JQ='def prepare_gate_family:
	{"Python": "Python", "Rust": "Rust", "Node.js": "Node"}[.] // null;
def prepare_gate_shape:
	(.name // null) as $n
	| [(.steps // [])[]] as $raw
	| ((if ($n | type) == "string" then
		first($n | capture("^(?<caller>[^\t\n]+) / Aggregate (?<family>[^/\t\n]+) Results$"))
		else null end) // null) as $m
	| if $m != null and ($m.family | prepare_gate_family) != null
		and all($raw[]; (.number | type) == "number" and (.name | type) == "string")
	then ($raw | sort_by(.number) | map([.name, .conclusion])) as $s
		| [["Set up job", "success"], ["Pre Harden runner", "success"], ["Harden runner", "success"],
			["Verify harden-runner agent", "success"], ["Fail on unknown egress-preset", "skipped"],
			[$gate, "failure"]] as $head
		| [[$matrix, "failure"], ["Recheck harden-runner agent", "success"],
			["Post Harden runner", "success"], ["Complete job", "success"]] as $tail
		| ($head | length) as $h | ($tail | length) as $t
		| if ($s | length) >= $h + $t and $s[:$h] == $head and $s[(($s | length) - $t):] == $tail
			and all($s[$h:(($s | length) - $t)][]; .[1] == "skipped")
		then [$m.caller, $m.family] else empty end
	else empty end;'

# Return 0 when the paginated check-run annotations JSON on stdin of a
# prepare_gate_shape job holds exactly the prepare gate's message
# (CANARY_PREPARE_GATE_MESSAGE) once, the matrix gate's message
# (INFRA_HR_MATRIX_MESSAGE) once, at most one `Process completed with exit
# code N.` line per failed step (two) and no other failure annotation.
prepare_gate_annotations() {
	jq -e -s --arg gate "$CANARY_PREPARE_GATE_MESSAGE" --arg matrix "${INFRA_HR_MATRIX_MESSAGE:?}" '
		"^Process completed with exit code [0-9]+\\.$" as $exit
		| [.[][] | select(.annotation_level == "failure") | .message] as $msgs
		| all($msgs[]; type == "string")
		and ([$msgs[] | select(. == $gate)] | length) == 1
		and ([$msgs[] | select(. == $matrix)] | length) == 1
		and ([$msgs[] | select(test($exit))] | length) <= 2
		and ([$msgs[] | select(. != $gate and . != $matrix and (test($exit) | not))] | length) == 0' \
		>/dev/null 2>&1
}

# Print the text of the one job of the workflow YAML on stdin whose `name:`
# line is `    name: Aggregate <family> Results`, from its job key line to the
# line before the next job key or top-level key. Line-based, for the
# two-space indentation the repository's yamllint enforces. Return 1 unless
# exactly one such job exists.
aggregate_job_block() {
	awk '
		function flush() {
			if (isagg) { found++; out = buf }
			buf = ""
			isagg = 0
		}
		/^jobs:[[:space:]]*$/ { injobs = 1; next }
		injobs && /^[^ #]/ { flush(); injobs = 0; key = 0 }
		injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); key = 1; buf = $0 "\n"; next }
		injobs && key {
			buf = buf $0 "\n"
			if ($0 ~ /^    name: Aggregate [^\/]+ Results$/) isagg = 1
		}
		END {
			flush()
			if (found != 1) exit 1
			printf "%s", out
		}
	'
}

# Print the aggregate job text (aggregate_job_block) of lgtm-ci workflow file
# $1 at ref $2, read through the raw contents API on api.github.com (the
# canary's egress preset and its contents: read token already cover it).
prepare_gate_job_text() {
	local out
	out="$(lgtm_ci_api -X GET -H "Accept: application/vnd.github.raw+json" \
		"repos/${GITHUB_REPOSITORY:?}/contents/.github/workflows/${1:?}?ref=${2:?}")" || return 1
	aggregate_job_block <<<"$out"
}

# Return 0 when, for every reusable workflow of aggregate family $1
# (prepare_gate_workflows), the aggregate job's text at the candidate
# (CANARY_CANDIDATE_SHA) equals its text at the candidate's merge base with
# main. The comparison covers the job's needs/if lines and every step: the
# gate steps' conditions and bodies, the pre-gate steps and the recheck. Any
# difference, read error, missing job or missing candidate SHA fails closed:
# a candidate that edits the aggregate job gets no excuse.
prepare_gate_trusted() {
	local family="${1:?}" sha="${CANARY_CANDIDATE_SHA:-}" file files cand base
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	files="$(prepare_gate_workflows "$family")" || return 1
	resolve_candidate_merge_base "$sha" || return 1
	for file in $files; do
		cand="$(prepare_gate_job_text "$file" "$sha")" || return 1
		base="$(prepare_gate_job_text "$file" "${CANDIDATE_MERGE_BASE:?}")" || return 1
		[[ -n "$cand" && "$cand" == "$base" ]] || return 1
	done
}
