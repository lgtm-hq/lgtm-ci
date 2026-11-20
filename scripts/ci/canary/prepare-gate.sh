#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Excuse a reusable test workflow's aggregate job in a fixture run
#          when it failed only because its own prepare job failed on the
#          harden-runner agent (#1670). infra_signature_reason (runs.sh)
#          plans and checks it.
# Sourced by scripts/ci/actions/external-canary.sh next to runs.sh. Host
# function: lgtm_ci_api (external-canary.sh); host settings GITHUB_REPOSITORY
# and LGTM_CI_MAIN_BRANCH; INFRA_HR_SHAPE_JQ, INFRA_HR_MATRIX_STEP and
# INFRA_HR_MATRIX_MESSAGE (../lib/infra-signatures.sh).
#
# Fixture runs 43858549864 and 43886292079 (siblings.yml) and 43924199865
# (verify-fresh-install.yml): the prepare job's agent did not start, so the
# aggregate job (`needs: [prepare, test]`, `if: always()`) failed on its
# prepare gate before any checkout, and its always() matrix gate then failed
# because the skipped test job did not succeed.
#
# The rule trusts step names, conclusions and annotations that the
# candidate's own workflows produce; the jobs API shows no step body. Two
# things bound that trust: the candidate changes none of the files that
# define what an aggregate job runs, or the canary's classifier
# (prepare_gate_unchanged), and the run carries only the prepare job's
# harden-runner label, so the excuse buys one retry and a repeat is a gate
# failure (agent_startup_repeated). This code itself runs from the pull
# request head, so the file rule narrows the excuse; it is not a trust
# boundary.

# Keep in step with the aggregate job of reusable-test-python.yml,
# reusable-rust-test.yml, reusable-rust-test-run.yml, reusable-test-node.yml,
# reusable-test-node-run.yml and reusable-test-node-custom.yml; a test pins
# the step order, both gate steps (condition and body) and the job's
# needs/if lines in each.
CANARY_PREPARE_GATE_STEP='Fail if matrix preparation did not succeed'
CANARY_PREPARE_GATE_MESSAGE="Matrix preparation concluded 'failure'; failing the check."

# The scripts behind the steps an excused aggregate job runs (harden-runner
# and its verify step, the egress-preset step, both gate steps, the recheck
# step) in the six reusable test workflows. Those steps run only inline code,
# generated from these sources by sync_inline_blocks.py, and the pinned
# harden-runner action; they use no local action and source nothing. A test
# derives this list from the six workflows and fails when it is out of date.
CANARY_PREPARE_GATE_STEP_SCRIPTS=(
	scripts/ci/bootstrap/fail-unknown-egress-preset.sh
	scripts/ci/bootstrap/recheck-harden-runner-agent.sh
	scripts/ci/bootstrap/verify-harden-runner-agent.sh
)
# Paths whose change at the candidate (against its merge base with main)
# withholds the excuse. Prefixes end in `/`; every other entry is an exact
# file name. Matched literally, never as a pattern:
#   - every workflow and action: they define what an aggregate job runs,
#     including workflow-level env, defaults and permissions, whichever
#     reusable a job's display name claims;
#   - the step scripts above;
#   - the canary's classifier and the signatures it reads, so a pull request
#     that edits them cannot use this excuse on itself.
CANARY_PREPARE_GATE_WATCHED=(
	.github/workflows/
	.github/actions/
	"${CANARY_PREPARE_GATE_STEP_SCRIPTS[@]}"
	scripts/ci/canary/
	scripts/ci/actions/external-canary.sh
	scripts/ci/lib/infra-signatures.sh
)
# GitHub's compare API lists at most 300 changed files and compares at most
# 250 commits; a response at either limit may be incomplete.
CANARY_PREPARE_GATE_MAX_FILES=300
CANARY_PREPARE_GATE_MAX_COMMITS=250

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

# Return 0 when the compare JSON on stdin (GET compare/<main>...<candidate>)
# is complete and none of its changed files, nor a renamed file's previous
# name, is a watched path (CANARY_PREPARE_GATE_WATCHED, given as the
# positional arguments). Complete means: an object with a full merge-base
# SHA, a numeric total_commits below CANARY_PREPARE_GATE_MAX_COMMITS + 1, and
# a files array of fewer than CANARY_PREPARE_GATE_MAX_FILES entries, each with
# a string filename and a string or absent previous_filename. Paths are
# compared with startswith (an entry ending in `/`) or equality, never as a
# pattern built from API data.
prepare_gate_compare_clean() {
	jq -e --argjson maxfiles "$CANARY_PREPARE_GATE_MAX_FILES" \
		--argjson maxcommits "$CANARY_PREPARE_GATE_MAX_COMMITS" '
		. as $c
		| $ARGS.positional as $watched
		| def watched($p): any($watched[]; . as $w
			| if ($w | endswith("/")) then ($p | startswith($w)) else $p == $w end);
		($c | type) == "object"
		and (($c.merge_base_commit.sha? // null) | type) == "string"
		and ($c.merge_base_commit.sha | test("^[0-9a-f]{40}$"))
		and ($c.total_commits | type) == "number" and $c.total_commits <= $maxcommits
		and ($c.files | type) == "array" and ($c.files | length) < $maxfiles
		and all($c.files[];
			type == "object" and (.filename | type) == "string"
			and ((.previous_filename // "") | type) == "string")
		and ([$c.files[] | .filename, (.previous_filename // empty) | select(watched(.))] | length) == 0' \
		--args "${CANARY_PREPARE_GATE_WATCHED[@]}" >/dev/null 2>&1
}

# Return 0 when the candidate (CANARY_CANDIDATE_SHA, a full SHA) changes no
# watched path against its merge base with LGTM_CI_MAIN_BRANCH: one compare
# call (api.github.com, the token and egress the canary already has), whose
# file list GitHub returns whole on the first page. A candidate already on
# main compares with no files and passes. A missing or symbolic SHA, an API
# error or an incomplete or malformed response fails closed.
prepare_gate_unchanged() {
	local sha="${CANARY_CANDIDATE_SHA:-}" out
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	out="$(lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY:?}/compare/${LGTM_CI_MAIN_BRANCH:?}...${sha}")" || return 1
	prepare_gate_compare_clean <<<"$out"
}
