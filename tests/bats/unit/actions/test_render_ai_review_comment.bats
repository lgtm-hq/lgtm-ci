#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/render-ai-review-comment.sh
#          (state parse/append/recompute, cumulative math, rendering)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/render-ai-review-comment.sh"

setup() {
	setup_temp_dir
	STATE="${BATS_TEST_TMPDIR}/state.json"
	RUN="${BATS_TEST_TMPDIR}/run.json"
	OUT="${BATS_TEST_TMPDIR}/comment.md"
}

teardown() {
	teardown_temp_dir
}

# Emit a run object; args: model status total_tok cost p1 [extra-jq]
make_run() {
	local model="$1" status="$2" total="$3" cost="$4" p1="${5:-0}"
	jq -n --arg m "$model" --arg s "$status" --argjson t "$total" \
		--argjson c "$cost" --argjson p1 "$p1" \
		'{sha:"abcdef1234",time:"12:00",model:$m,provider:"anthropic",
		  input_tokens:($t/2|floor),output_tokens:($t - ($t/2|floor)),
		  total_tokens:$t,cost_usd:$c,depth:1,duration_s:10,status:$s,
		  error_kind:(if $s=="error" then "auth" else "" end),
		  error:(if $s=="error" then "401 invalid key" else "" end),
		  p1:$p1,p2:0,p3:0,summary:"summary text",findings:[]}'
}

extract_state() {
	tail -1 "$OUT" | sed -E 's/^<!-- lintro-ai-review-state: //; s/ -->$//'
}

@test "render: appends run to empty state and shows cumulative" {
	echo '{"runs":[]}' >"$STATE"
	make_run claude-sonnet-4 ok 12004 0.02 1 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "## 🔎 Lintro AI Review"
	assert_output --partial "**Cumulative (this PR):** 12,004 tokens"
	assert_output --partial "1 runs"
	assert_output --partial '`claude-sonnet-4 ×1`'
	run extract_state
	run jq '.runs|length' <<<"$output"
	assert_output "1"
}

@test "render: cumulative sums tokens and cost across ok runs only" {
	jq -n '{runs:[]}' >"$STATE"
	# seed two ok runs + one error run into state
	s="$(jq -c '.runs += ['"$(make_run a ok 10000 0.05 0)"']' "$STATE")"
	s="$(jq -c '.runs += ['"$(make_run b error 0 0 0)"']' <<<"$s")"
	echo "$s" >"$STATE"
	make_run c ok 5000 0.01 0 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	# 10000 + 5000 = 15000 tokens (error contributes 0); 3 runs total
	assert_output --partial "15,000 tokens"
	assert_output --partial "3 runs"
}

@test "render: per-model counts aggregate and sort by frequency" {
	jq -n '{runs:[]}' >"$STATE"
	s="$(jq -c '.runs += ['"$(make_run claude-sonnet-4 ok 100 0 0)"']' "$STATE")"
	s="$(jq -c '.runs += ['"$(make_run claude-sonnet-4 ok 100 0 0)"']' <<<"$s")"
	s="$(jq -c '.runs += ['"$(make_run claude-opus-4 ok 100 0 0)"']' <<<"$s")"
	echo "$s" >"$STATE"
	make_run claude-sonnet-4 ok 100 0 0 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial '`claude-sonnet-4 ×3`, `claude-opus-4 ×1`'
}

@test "render: latest ok run shows severity header and mechanics" {
	echo '{"runs":[]}' >"$STATE"
	make_run claude-sonnet-4 ok 12004 0.02 2 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "### Latest — 🔴 2 · 🟠 0 · 🟡 0"
	assert_output --partial "run: \`claude-sonnet-4\`"
	assert_output --partial "depth 1"
}

@test "render: previous runs collapse into details with mechanics" {
	echo "{\"runs\":[$(make_run claude-opus-4 ok 15900 0.05 0)]}" >"$STATE"
	make_run claude-sonnet-4 ok 12004 0.02 1 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "<details><summary>⏱ Previous runs (1)</summary>"
	assert_output --partial '`claude-opus-4` · 15900 tok'
}

@test "render: bounded history truncates to MAX_RUNS" {
	jq -n '{runs: [range(25) | {sha:("s"+(.|tostring)),time:"t",model:"m",provider:"p",input_tokens:1,output_tokens:1,total_tokens:2,cost_usd:0,depth:1,duration_s:1,status:"ok",error_kind:"",error:"",p1:0,p2:0,p3:0,summary:"",findings:[]}]}' >"$STATE"
	make_run m ok 2 0 0 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" MAX_RUNS=20 run bash "$SCRIPT"
	assert_success
	run extract_state
	run jq '.runs|length' <<<"$output"
	assert_output "20"
}

@test "render: errored run header maps each error kind" {
	echo '{"runs":[]}' >"$STATE"
	for kind_pair in "auth:❌ Review skipped" "quota:❌ No credits" "rate_limit:⚠️ Rate limited" "transient:⚠️ Provider unavailable"; do
		kind="${kind_pair%%:*}"
		header="${kind_pair#*:}"
		jq -n --arg k "$kind" \
			'{sha:"s",time:"t",model:"m",provider:"anthropic",input_tokens:0,output_tokens:0,total_tokens:0,cost_usd:0,depth:1,duration_s:1,status:"error",error_kind:$k,error:("msg-"+$k),p1:0,p2:0,p3:0,summary:"",findings:[]}' >"$RUN"
		STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
		assert_success
		run cat "$OUT"
		assert_output --partial "### Latest — ${header}"
		assert_output --partial "msg-${kind}"
	done
}

@test "render: errored run appears in previous-runs list with error kind" {
	echo "{\"runs\":[$(make_run claude-sonnet-4 error 0 0 0)]}" >"$STATE"
	make_run claude-sonnet-4 ok 100 0.01 0 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "❌ error: auth"
}

@test "render: skip note preserves cumulative and does not append a run" {
	echo "{\"runs\":[$(make_run claude-sonnet-4 ok 12004 0.02 0)]}" >"$STATE"
	STEP=render STATE_FILE="$STATE" SKIP_REASON=no-key OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "12,004 tokens"
	assert_output --partial "### Latest — ⚠️ skipped"
	assert_output --partial "ANTHROPIC_API_KEY"
	# state unchanged: still 1 run
	run extract_state
	run jq '.runs|length' <<<"$output"
	assert_output "1"
}

@test "render: fork skip note explains no-secret behaviour" {
	echo '{"runs":[]}' >"$STATE"
	STEP=render STATE_FILE="$STATE" SKIP_REASON=fork OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "skipped (fork)"
}

@test "render: embedded state round-trips as valid JSON" {
	echo '{"runs":[]}' >"$STATE"
	make_run claude-sonnet-4 ok 12004 0.02 1 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run extract_state
	run jq -e '.runs[0].model == "claude-sonnet-4"' <<<"$output"
	assert_success
}

@test "render: labels comment as automated and includes state marker" {
	echo '{"runs":[]}' >"$STATE"
	make_run claude-sonnet-4 ok 12004 0.02 0 >"$RUN"
	STEP=render STATE_FILE="$STATE" RUN_FILE="$RUN" OUTPUT_FILE="$OUT" run bash "$SCRIPT"
	assert_success
	run cat "$OUT"
	assert_output --partial "🤖 automated · not a substitute for human review"
	assert_output --partial "<!-- lintro-ai-review-state:"
}
