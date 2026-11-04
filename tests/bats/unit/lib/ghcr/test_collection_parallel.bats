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
		printf '# drained owned HTTP pid=%s\n' "$pid"
	done <"$CASE_DIR/pids"
	[ -z "$(find "$CASE_DIR/scratch" -mindepth 1 -print)" ]
}

@test "collector: caller versions names including status retain success and failure behavior" {
	local variable_name count
	for count in 0 1; do
		make_versions "$count"
		for variable_name in status complete owner package_name registry_token complete_var digests_file work_dir cancel_file saved_traps worker_count worker pid wait_status cancelled worker_pids worker_versions worker_complete _parallel_versions; do
			# Empty input covers every former wrapper local; status also traverses a root.
			if ((count == 1)) && [[ "$variable_name" != status ]]; then continue; fi
			run env VARIABLE_NAME="$variable_name" TMPDIR="$CASE_DIR/scratch" bash -c '
				source "$LIB_DIR/ghcr/registry.sh"
				_ghcr_xtrace_off
				printf -v "$VARIABLE_NAME" "%s" "$(<"$CASE_DIR/versions")"
				_ghcr_xtrace_restore
				ghcr_collect_referenced_digests offline pkg "$VARIABLE_NAME" offline complete_result "$CASE_DIR/protected" || exit 98
				[[ "$complete_result" == true ]] || exit 97
				_ghcr_write_var_to_file "$VARIABLE_NAME" "$CASE_DIR/after"
				printf "\n" >>"$CASE_DIR/after"
				cmp "$CASE_DIR/versions" "$CASE_DIR/after"
			'
			assert_success
			[ "$(wc -l <"$CASE_DIR/protected")" -eq "$((4 * count))" ]
			assert_drained
		done
	done
	printf 'invalid' >"$CASE_DIR/versions"
	run env TMPDIR="$CASE_DIR/scratch" bash -c '
		source "$LIB_DIR/ghcr/registry.sh"
		status=$(<"$CASE_DIR/versions")
		complete_result=true
		exit_status=0
		ghcr_collect_referenced_digests offline pkg status offline complete_result "$CASE_DIR/protected" || exit_status=$?
		[[ "$exit_status" == 1 && "$complete_result" == false && "$status" == invalid ]]
	'
	assert_success
	[ ! -s "$CASE_DIR/protected" ]
	assert_drained
}

@test "collector: caller completion names including status receive the actual result" {
	local variable_name count scenario
	for count in 0 1; do
		make_versions "$count"
		for variable_name in status complete owner package_name registry_token complete_var digests_file work_dir cancel_file saved_traps worker_count worker pid wait_status cancelled worker_pids worker_versions worker_complete _parallel_versions; do
			if ((count == 1)) && [[ "$variable_name" != status ]]; then continue; fi
			for scenario in normal error; do
				run env VARIABLE_NAME="$variable_name" SCENARIO="$scenario" TMPDIR="$CASE_DIR/scratch" bash -c '
					source "$LIB_DIR/ghcr/registry.sh"
					versions=$(<"$CASE_DIR/versions")
					printf -v "$VARIABLE_NAME" "%s" true
					exit_status=0
					ghcr_collect_referenced_digests offline pkg versions offline "$VARIABLE_NAME" "$CASE_DIR/protected" || exit_status=$?
					[[ "$exit_status" == 0 ]] || exit 98
					if [[ "$SCENARIO" == error && "$versions" != "[]" ]]; then
						[[ "${!VARIABLE_NAME}" == false ]]
					else
						[[ "${!VARIABLE_NAME}" == true ]]
					fi
				'
				assert_success
				assert_drained
			done
		done
	done
}

@test "collector: reserved input and completion names explicitly fail closed before work" {
	local variable_name mode
	for mode in input output; do
		for variable_name in _ghcr_parallel_status _ghcr_parallel_versions _ghcr_parallel_worker_versions _ghcr_src _ghcr_dest _status _GHCR_XTRACE_RESTORE; do
			if [[ "$mode" == output && "$variable_name" != _ghcr_parallel_* ]]; then continue; fi
			printf 'stale digest\n' >"$CASE_DIR/protected"
			run env MODE="$mode" VARIABLE_NAME="$variable_name" TMPDIR="$CASE_DIR/scratch" bash -c '
				source "$LIB_DIR/ghcr/registry.sh"
				trap "printf unexpected-signal" HUP INT TERM
				before=$(trap -p HUP INT TERM)
				versions="[]"
				complete_result=true
				exit_status=0
				if [[ "$MODE" == input ]]; then
					printf -v "$VARIABLE_NAME" "%s" "[]"
					ghcr_collect_referenced_digests offline pkg "$VARIABLE_NAME" offline complete_result "$CASE_DIR/protected" || exit_status=$?
					[[ "$complete_result" == false ]] || exit 97
				else
					printf -v "$VARIABLE_NAME" "%s" true
					ghcr_collect_referenced_digests offline pkg versions offline "$VARIABLE_NAME" "$CASE_DIR/protected" || exit_status=$?
					[[ "${!VARIABLE_NAME}" == false ]] || exit 98
				fi
				[[ "$exit_status" == 1 && "$before" == "$(trap -p HUP INT TERM)" ]]
			'
			assert_success
			assert_output --partial 'Reserved collector variable name'
			[ ! -s "$CASE_DIR/protected" ]
			[ "$(<"$CASE_DIR/counts")" == '0 0 0' ]
			assert_drained
		done
	done
}

# Inject at an actual collector command, without sleeps or PID discovery.
write_boundary_hook() {
	cat >"$CASE_DIR/boundary-hook" <<'EOF'
set -T
boundary_armed=1
trap 'if [[ "${FUNCNAME[0]:-}" == ghcr_collect_referenced_digests &&
    "$BASH_COMMAND" == "$CANCEL_AT" && "$boundary_armed" == 1 ]]; then
    boundary_armed=0
    printf "INJECT TERM at collector boundary\n" >&2
    kill -TERM "$BASHPID"
fi' DEBUG
EOF
}

# The baseline restores caller traps before this publication command. Keep
# injecting there after repair, and also on each side of the handoff boundary.
write_publication_hook() {
	cat >"$CASE_DIR/publication-hook" <<'EOF'
signal_count=0
if [[ "$HANDLER" == returning ]]; then
    trap 'signal_count=$((signal_count + 1))' HUP INT TERM
else
    trap '' HUP INT TERM
fi
before=$(trap -p HUP INT TERM)
set -T
boundary_armed=1
trap 'if [[ "${FUNCNAME[0]:-}" == ghcr_collect_referenced_digests &&
    "${_ghcr_parallel_cancel_file-unset}" == "" && "$boundary_armed" == 1 ]] && {
    [[ "$BOUNDARY" == publication && "$BASH_COMMAND" == "printf -v \"\$_ghcr_parallel_complete_var\""* ]] ||
    [[ "$BOUNDARY" == handoff && "$BASH_COMMAND" == "eval \"\$_ghcr_parallel_saved_traps\"" ]] ||
    [[ "$BOUNDARY" == returned && "$BASH_COMMAND" == "return \"\$_ghcr_parallel_status\"" ]];
}; then
    boundary_armed=0
    for owned_worker_pid in "${_ghcr_parallel_worker_pids[@]}"; do
        if kill -0 "$owned_worker_pid" 2>/dev/null; then exit 96; fi
        printf "# drained owned worker pid=%s\n" "$owned_worker_pid"
    done
    caller_traps_restored=false
    [[ "$before" != "$(trap -p HUP INT TERM)" ]] || caller_traps_restored=true
    printf "BOUNDARY=%s caller_traps_restored=%s\n" "$BOUNDARY" "$caller_traps_restored"
    if [[ "$INJECT" == true ]]; then
        printf "INJECT TERM at publication/handoff\n" >&2
        kill -TERM "$BASHPID"
    fi
fi' DEBUG
EOF
	# Keep a source-file context when a caller enables nounset under kcov.
	cat >"$CASE_DIR/publication-caller" <<'EOF'
source "$CASE_DIR/publication-hook"
source "$CALLER"
EOF
}

@test "collector: signal handoff preserves returning ignored default and mixed dispositions" {
	cat >"$CASE_DIR/handoff-hook" <<'EOF'
signal_count=0
case "$HANDLER" in
    returning) trap 'signal_count=$((signal_count + 1))' HUP INT TERM ;;
    ignored) trap '' HUP INT TERM ;;
    default) trap - HUP INT TERM ;;
    mixed)
        trap 'signal_count=$((signal_count + 1))' HUP
        trap '' INT
        trap - TERM ;;
esac
before=$(trap -p HUP INT TERM)
target_before=$(trap -p "$SIGNAL")
handoff_started=0
boundary_armed=1
set -T
trap 'if [[ "${FUNCNAME[0]:-}" == ghcr_collect_referenced_digests && "$boundary_armed" == 1 ]]; then
    if [[ "$BASH_COMMAND" == "trap - HUP INT TERM" ||
        "$BASH_COMMAND" == "eval \"\$_ghcr_parallel_saved_traps\"" ]]; then
        handoff_started=1
    elif [[ "$handoff_started" == 1 && "$(trap -p "$SIGNAL")" != *_ghcr_parallel_cancelled* ]]; then
        boundary_armed=0
        for owned_worker_pid in "${_ghcr_parallel_worker_pids[@]}"; do
            if kill -0 "$owned_worker_pid" 2>/dev/null; then exit 96; fi
            printf "# drained owned worker pid=%s\n" "$owned_worker_pid"
        done
        [[ -z "$(find "$CASE_DIR/scratch" -mindepth 1 -print)" ]] || exit 95
        target_restored=false
        [[ "$target_before" != "$(trap -p "$SIGNAL")" ]] || target_restored=true
        printf "HANDOFF signal=%s complete=%s target_restored=%s\n" "$SIGNAL" "$complete_result" "$target_restored"
        if [[ "$INJECT" == true ]]; then
            printf "INJECT %s at signal handoff\n" "$SIGNAL"
            kill -s "$SIGNAL" "$BASHPID"
        fi
    fi
fi' DEBUG
EOF
	local count handler signal inject expected_signals signal_number
	for count in 0 1; do
		make_versions "$count"
		for handler in returning ignored default mixed; do
			for signal in HUP INT TERM; do
				case "$signal" in
					HUP) signal_number=1 ;;
					INT) signal_number=2 ;;
					TERM) signal_number=15 ;;
				esac
				for inject in true false; do
					run env HANDLER="$handler" SIGNAL="$signal" INJECT="$inject" TMPDIR="$CASE_DIR/scratch" bash -c '
						source "$LIB_DIR/ghcr/registry.sh"
						source "$CASE_DIR/handoff-hook"
						versions=$(<"$CASE_DIR/versions")
						result=0
						ghcr_collect_referenced_digests offline pkg versions offline complete_result "$CASE_DIR/protected" || result=$?
						trap - DEBUG
						[[ "$boundary_armed" == 0 && "$target_restored" == true && "$before" == "$(trap -p HUP INT TERM)" ]] || exit 99
						printf "complete=%s exit=%s signals=%s restored=true\n" "$complete_result" "$result" "$signal_count"
						exit "$result"
					'
					printf '# handoff count=%s handler=%s signal=%s inject=%s status=%s\n%s\n' "$count" "$handler" "$signal" "$inject" "$status" "$output"
					if [[ "$inject" == true && ("$handler" == default || ("$handler" == mixed && "$signal" == TERM)) ]]; then
						[ "$status" -eq "$((128 + signal_number))" ]
					else
						assert_success
						expected_signals=0
						if [[ "$inject" == true && ("$handler" == returning || ("$handler" == mixed && "$signal" == HUP)) ]]; then
							expected_signals=1
						fi
						assert_output --partial "complete=true exit=0 signals=$expected_signals restored=true"
					fi
					assert_output --partial "HANDOFF signal=$signal complete=true target_restored=true"
					if [[ "$inject" == true ]]; then
						assert_output --partial "INJECT $signal at signal handoff"
					else
						refute_output --partial 'INJECT '
					fi
					[ "$(wc -l <"$CASE_DIR/protected")" -eq "$((4 * count))" ]
					assert_drained
				done
			done
		done
	done
}

@test "collector: publication and handoff retain cancellation with returning and ignored caller traps" {
	write_publication_hook
	local count handler boundary inject
	for count in 0 1; do
		make_versions "$count"
		for handler in returning ignored; do
			for boundary in publication handoff returned; do
				for inject in true false; do
					run env HANDLER="$handler" BOUNDARY="$boundary" INJECT="$inject" TMPDIR="$CASE_DIR/scratch" bash -c '
						source "$LIB_DIR/ghcr/registry.sh"
						source "$CASE_DIR/publication-hook"
						versions=$(<"$CASE_DIR/versions")
						result=0
						ghcr_collect_referenced_digests offline pkg versions offline complete_result "$CASE_DIR/protected" || result=$?
						trap - DEBUG
						[[ "$boundary_armed" == 0 && "$before" == "$(trap -p HUP INT TERM)" ]] || exit 99
						printf "complete=%s exit=%s signals=%s restored=true\n" "$complete_result" "$result" "$signal_count"
						exit "$result"
					'
					if [[ "$inject" == true && "$boundary" != returned ]]; then
						[ "$status" -eq 1 ]
						assert_output --partial 'complete=false exit=1 signals=0 restored=true'
						[ ! -s "$CASE_DIR/protected" ]
					else
						assert_success
						assert_output --partial 'complete=true exit=0'
						[ "$(wc -l <"$CASE_DIR/protected")" -eq "$((4 * count))" ]
						if [[ "$inject" == true && "$handler" == returning ]]; then
							assert_output --partial 'signals=1 restored=true'
						else
							assert_output --partial 'signals=0 restored=true'
						fi
					fi
					if [[ "$boundary" == returned ]]; then
						assert_output --partial "BOUNDARY=$boundary caller_traps_restored=true"
					else
						assert_output --partial "BOUNDARY=$boundary caller_traps_restored=false"
					fi
					if [[ "$inject" == true ]]; then
						assert_output --partial 'INJECT TERM at publication/handoff'
					else
						refute_output --partial 'INJECT TERM'
					fi
					refute_output --partial 'No such file or directory'
					printf '%s\n' "$output"
					assert_drained
				done
			done
		done
	done
}

@test "collector: both cleanup callers refuse publication cancellation with returning or ignored traps" {
	write_publication_hook
	make_versions 1
	jq '. + [
		{id:100,name:"sha256:staging-unreferenced",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:["build-100-linux-amd64"]}}},
		{id:101,name:"sha256:untagged-unreferenced",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}}
	]' "$CASE_DIR/versions" >"$CASE_DIR/expanded"
	mv "$CASE_DIR/expanded" "$CASE_DIR/versions"
	mock_command_multi gh '
		*--method\ DELETE*) printf "%s\n" "${*: -1}" >>"$CASE_DIR/deletes";;
		*--paginate*) cat "$CASE_DIR/versions";;
		*) exit 99;;
	'
	export PACKAGE_NAME=pkg GITHUB_ORG=offline GH_TOKEN=offline
	export PROTECT_REFERENCED=true DRY_RUN=false KEEP_LATEST=0 KEEP_RECENT=0
	export BOUNDARY=publication
	local caller handler inject
	for caller in actions/ghcr-cleanup.sh maintenance/prune-build-staging-tags.sh; do
		for handler in returning ignored; do
			for inject in true false; do
				: >"$CASE_DIR/deletes"
				run env CALLER="$PROJECT_ROOT/scripts/ci/$caller" HANDLER="$handler" INJECT="$inject" TMPDIR="$CASE_DIR/scratch" bash "$CASE_DIR/publication-caller"
				if [[ "$inject" == true ]]; then
					assert_failure
					assert_output --partial 'INJECT TERM at publication/handoff'
					assert_output --partial 'Failed to write referenced-digest set'
					[ ! -s "$CASE_DIR/deletes" ]
				else
					assert_success
					refute_output --partial 'INJECT TERM'
					[ "$(wc -l <"$CASE_DIR/deletes")" -eq 1 ]
				fi
				assert_output --partial 'BOUNDARY=publication caller_traps_restored=false'
				refute_output --partial 'No such file or directory'
				printf '%s\n' "$output"
				assert_drained
			done
		done
	done
}

@test "collector: late cleanup and terminal handoff cancellation refuse completion" {
	write_boundary_hook
	local count
	for count in 0 1; do
		make_versions "$count"
		for CANCEL_AT in 'rm -rf -- "$_ghcr_parallel_work_dir"' 'eval "$_ghcr_parallel_saved_traps"'; do
			export CANCEL_AT
			run env TMPDIR="$CASE_DIR/scratch" bash -c '
				source "$LIB_DIR/ghcr/registry.sh"
				source "$CASE_DIR/boundary-hook"
				trap "printf caller-signal" HUP INT TERM
				before=$(trap -p HUP INT TERM)
				versions=$(<"$CASE_DIR/versions")
				result=0
				ghcr_collect_referenced_digests offline pkg versions offline complete_result "$CASE_DIR/protected" || result=$?
				trap - DEBUG
				[[ "$before" == "$(trap -p HUP INT TERM)" ]] || exit 99
				printf "complete=%s exit=%s\n" "$complete_result" "$result"
				exit "$result"
			'
			[ "$status" -eq 1 ]
			assert_output --partial 'INJECT TERM at collector boundary'
			assert_output --partial 'complete=false exit=1'
			refute_output --partial 'No such file or directory'
			refute_output --partial caller-signal
			[ ! -s "$CASE_DIR/protected" ]
			assert_drained
		done
	done
}

@test "collector: both cleanup callers refuse every DELETE on terminal cancellation" {
	make_versions 1
	jq '. + [
		{id:100,name:"sha256:staging-unreferenced",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:["build-100-linux-amd64"]}}},
		{id:101,name:"sha256:untagged-unreferenced",updated_at:"2020-01-01T00:00:00Z",metadata:{container:{tags:[]}}}
	]' "$CASE_DIR/versions" >"$CASE_DIR/expanded"
	mv "$CASE_DIR/expanded" "$CASE_DIR/versions"
	mock_command_multi gh '
		*--method\ DELETE*) printf "%s\n" "${*: -1}" >>"$CASE_DIR/deletes";;
		*--paginate*) cat "$CASE_DIR/versions";;
		*) exit 99;;
	'
	export PACKAGE_NAME=pkg GITHUB_ORG=offline GH_TOKEN=offline
	export PROTECT_REFERENCED=true DRY_RUN=false KEEP_LATEST=0 KEEP_RECENT=0
	export CANCEL_AT='eval "$_ghcr_parallel_saved_traps"'
	write_boundary_hook
	local caller
	for caller in actions/ghcr-cleanup.sh maintenance/prune-build-staging-tags.sh; do
		export CALLER="$PROJECT_ROOT/scripts/ci/$caller"
		: >"$CASE_DIR/deletes"
		run env TMPDIR="$CASE_DIR/scratch" bash "$CALLER"
		assert_success
		[ "$(wc -l <"$CASE_DIR/deletes")" -eq 1 ]
		assert_drained
		: >"$CASE_DIR/deletes"
		run env TMPDIR="$CASE_DIR/scratch" bash -c '
			source "$CASE_DIR/boundary-hook"
			source "$CALLER"
		'
		assert_failure
		assert_output --partial 'INJECT TERM at collector boundary'
		assert_output --partial 'Failed to write referenced-digest set'
		refute_output --partial 'No such file or directory'
		[ ! -s "$CASE_DIR/deletes" ]
		assert_drained
	done
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
