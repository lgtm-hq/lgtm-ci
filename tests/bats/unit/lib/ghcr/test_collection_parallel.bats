#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Actual HTTP-boundary concurrency, aggregation, and cancellation.
load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export CASE_DIR="$BATS_TEST_TMPDIR"
	export FAKE_DELAY=0.12 SCENARIO=normal
	mkdir -p "$CASE_DIR/scratch"
	printf '0 0 0\n' >"$CASE_DIR/counts"
	: >"$CASE_DIR/pids"
	: >"$CASE_DIR/deletes"
	mock_command_multi curl '
		*)
			url=""
			for arg in "$@"; do
				[[ "$arg" != https://* ]] || url="$arg"
			done
			case "$url" in
			https://ghcr.io/token*) printf "%s" "{\"token\":\"offline\"}"; exit 0;;
			https://ghcr.io/v2/offline/pkg/*) ;;
			*) exit 99;;
			esac
			counter() {
				flock "$CASE_DIR/lock" bash -c '"'"'
					read -r active peak requests <"$CASE_DIR/counts"
					active=$((active + $1))
					if (($1 > 0)); then requests=$((requests + 1)); fi
					if ((active > peak)); then peak=$active; fi
					printf "%s %s %s\n" "$active" "$peak" "$requests" >"$CASE_DIR/counts"
				'"'"' _ "$1"
			}
			counter 1
			trap "counter -1" EXIT
			printf "%s\n" "$BASHPID" >>"$CASE_DIR/pids"
			sleep "$FAKE_DELAY"
			n="${url##*-}"
			if [[ "$SCENARIO" == error && "$url" == */manifests/sha256:root-0 ]]; then
				printf "%s\n503\n" "unavailable"
			elif [[ "$url" == */manifests/* ]]; then
				printf "{\"manifests\":[{\"digest\":\"sha256:child-%s\"}],\"subject\":{\"digest\":\"sha256:subject-%s\"}}\n200\n" "$n" "$n"
			else
				printf "{\"manifests\":[{\"digest\":\"sha256:referrer-%s\"}]}\n200\n" "$n"
			fi;;
	'
}

teardown() {
	restore_path
	teardown_temp_dir
}

make_versions() {
	jq -n --argjson count "$1" '[range($count) | {
		id:., name:("sha256:root-" + tostring),updated_at:"2020-01-01T00:00:00Z",
		metadata:{container:{tags:["latest"]}}}]' >"$CASE_DIR/versions"
}

collect_file() {
	TMPDIR="$CASE_DIR/scratch" bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		_ghcr_xtrace_off
		versions=$(<"$CASE_DIR/versions")
		_ghcr_xtrace_restore
		result=0
		ghcr_collect_referenced_digests offline pkg versions offline complete_result "$CASE_DIR/protected" || result=$?
		printf "complete=%s exit=%s\n" "$complete_result" "$result"
		exit "$result"
	'
}

assert_drained() {
	local pid active peak requests
	read -r active peak requests <"$CASE_DIR/counts"
	[ "$active" -eq 0 ]
	while read -r pid; do
		! kill -0 "$pid" 2>/dev/null
	done <"$CASE_DIR/pids"
	[ -z "$(find "$CASE_DIR/scratch" -mindepth 1 -print)" ]
}

@test "collector: empty single and multiple roots retain every reference with at most four HTTP requests" {
	local count active peak requests n kind
	for count in 0 1 9; do
		make_versions "$count"
		printf '0 0 0\n' >"$CASE_DIR/counts"
		run collect_file
		assert_success
		assert_output --partial complete=true
		read -r active peak requests <"$CASE_DIR/counts"
		[ "$requests" -eq "$((2 * count))" ]
		[ "$peak" -le 4 ]
		if ((count == 1)); then [ "$peak" -eq 1 ]; fi
		if ((count > 4)); then [ "$peak" -gt 1 ]; fi
		: >"$CASE_DIR/expected"
		for ((n=0; n<count; n++)); do
			for kind in root child subject referrer; do
				printf 'sha256:%s-%s\n' "$kind" "$n" >>"$CASE_DIR/expected"
			done
		done
		sort -u "$CASE_DIR/expected" -o "$CASE_DIR/expected"
		cmp "$CASE_DIR/expected" "$CASE_DIR/protected"
		assert_drained
	done
}

@test "collector: failure in one worker makes the whole traversal incomplete and drains siblings" {
	make_versions 9
	export SCENARIO=error
	run collect_file
	assert_success
	assert_output --partial complete=false
	assert_drained
}

@test "collector: TERM drains owned HTTP children cleans files and refuses publication" {
	make_versions 24
	collect_file >"$CASE_DIR/cancel.log" 2>&1 &
	local wrapper_pid=$! collector_pid active peak requests attempt
	# collect_file runs a single bash child; signal that exact owner, not a group.
	collector_pid=""
	for ((attempt=0; attempt<200; attempt++)); do
		collector_pid=$(pgrep -P "$wrapper_pid" -x bash || true)
		read -r active peak requests <"$CASE_DIR/counts"
		[[ -z "$collector_pid" || "$active" -eq 0 ]] || break
		sleep 0.01
	done
	[ -n "$collector_pid" ]
	[ "$active" -gt 0 ]
	[ ! -s "$CASE_DIR/protected" ]
	kill -TERM "$collector_pid"
	local result=0
	wait "$wrapper_pid" || result=$?
	[ "$result" -ne 0 ]
	grep -q 'complete=false' "$CASE_DIR/cancel.log"
	[ ! -s "$CASE_DIR/protected" ]
	assert_drained
	read -r active peak requests <"$CASE_DIR/counts"
	[ "$requests" -le 8 ]
}

@test "collector: abnormal worker exit refuses publication and drains successful workers" {
	make_versions 9
	mock_command_multi mv '
		*)
			if [[ "${*: -1}" == */0/digests ]]; then exit 19; fi
			exec /usr/bin/mv "$@";;
	'
	run collect_file
	assert_failure
	assert_output --partial complete=false
	[ ! -s "$CASE_DIR/protected" ]
	assert_drained
}

@test "collector: restores caller signal traps after a successful traversal" {
	make_versions 1
	run bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		trap "printf restored" TERM
		before=$(trap -p TERM)
		versions=$(<"$CASE_DIR/versions")
		ghcr_collect_referenced_digests offline pkg versions offline complete_result "$CASE_DIR/protected"
		after=$(trap -p TERM)
		[[ "$before" == "$after" ]]
		kill -TERM "$BASHPID"
	'
	assert_success
	assert_output restored
}

@test "collector: both shared cleanup filters preserve child subject and referrer digests" {
	make_versions 9
	jq '. + [
		{id:100,name:"sha256:child-0",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}},
		{id:101,name:"sha256:subject-0",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}},
		{id:102,name:"sha256:referrer-0",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}},
		{id:103,name:"sha256:root-100",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:["pr-100"]}}},
		{id:104,name:"sha256:unreferenced",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}}
	]' "$CASE_DIR/versions" >"$CASE_DIR/expanded"
	mv "$CASE_DIR/expanded" "$CASE_DIR/versions"
	mock_command_multi gh '
		*--method\ DELETE*) printf "%s\n" "${*: -1}" >>"$CASE_DIR/deletes";;
		*--paginate*) cat "$CASE_DIR/versions";;
		*) exit 99;;
	'
	export PACKAGE_NAME=pkg GITHUB_ORG=offline GH_TOKEN=offline
	export PROTECT_REFERENCED=true DRY_RUN=false KEEP_LATEST=0 PRUNE_BUILDCACHE=true
	run bash "$PROJECT_ROOT/scripts/ci/actions/ghcr-cleanup.sh"
	assert_success
	[ "$(wc -l <"$CASE_DIR/deletes")" -eq 1 ]
	grep -q '/104$' "$CASE_DIR/deletes"
	export SCENARIO=error
	: >"$CASE_DIR/deletes"
	run bash "$PROJECT_ROOT/scripts/ci/actions/ghcr-cleanup.sh"
	assert_success
	assert_output --partial incomplete
	[ ! -s "$CASE_DIR/deletes" ]
}
