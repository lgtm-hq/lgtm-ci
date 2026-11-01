#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bound fixture dispatches, distinguish queue/execution time, and cancel owned runs.

# TSV: workflow file, status, conclusion, URL, name. Paginate so probe children
# and retried runs beyond the first page also participate in cleanup.
list_canary_runs() {
	local filter=""
	[[ -z "${2:-}" ]] || filter="&created=%3E%3D${2}"
	fixture_api -X GET \
		"repos/${FIXTURE_REPO}/actions/runs?branch=${1:?}&event=workflow_dispatch${filter}&per_page=100" \
		--paginate --jq '.workflow_runs[] | [(.path | sub("^\\.github/workflows/"; "")), .status, (.conclusion // ""), .html_url, .name] | @tsv'
}

# run_started_at includes queue time. Only a job that has actually left queued
# contributes a start timestamp; reusable and matrix jobs are paginated.
first_job_start() {
	fixture_api -X GET "repos/${FIXTURE_REPO}/actions/runs/${1:?}/jobs?per_page=100" \
		--paginate --jq '.jobs[] | select(.status != "queued" and .conclusion != "skipped" and .started_at != null) | .started_at | fromdateiso8601' |
		sort -n | sed -n '1p'
}

# Only gate runs that stopped in fixture setup may be dispatched once more.
# Print the reason on success. Consume every jobs page before deciding: an API
# error, missing failed-step evidence, or any later executed step fails closed.
retry_eligible() {
	local file="${1:?}" conclusion="${2:?}" url="${3:-}" id jobs
	[[ "$conclusion" == startup_failure || "$conclusion" == failure ]] || return 1
	[[ "$file" != *-probe.yml ]] && is_gate "$file" || return 1
	id="${url##*/}"
	[[ "$id" =~ ^[0-9]+$ ]] || return 1
	if [[ "$conclusion" == startup_failure ]]; then
		printf 'startup_failure\n'
		return 0
	fi
	jobs="$(fixture_api -X GET "repos/${FIXTURE_REPO}/actions/runs/${id}/jobs?per_page=100" --paginate)" || return 1
	jq -e -s '
		[.[] | .jobs[] | select(.conclusion == "failure")] as $failed |
		($failed | length) > 0 and all($failed[];
			.steps as $steps |
			($steps | map(.conclusion) | index("failure")) as $first |
			$first != null and
			($steps[$first].name | test("^(Set up job$|Pre Harden runner$|Harden runner$|Checkout|Prepare .* Matrix$)")) and
			all($steps[($first + 1):][]; .conclusion == null or .conclusion == "skipped")
		)
	' <<<"$jobs" >/dev/null || return 1
	printf 'infra\n'
}

cancel_canary_run() {
	fixture_api -X POST "repos/${FIXTURE_REPO}/actions/runs/${1:?}/cancel" >/dev/null ||
		log_warn "could not cancel fixture run $1 (it may have completed)"
}

# Rolling admission: queued runs occupy slots too. The queue budget starts
# before admission, bounding total scheduling time even on a saturated fixture.
# CANARY_DISPATCH=false supports polling an already dispatched set in tests/tools.
poll_runs() {
	local branch="${1:?branch required}" since="${2:?since required}"
	shift 2
	local files=("$@") file row status conclusion url name id start fresh runs=""
	local queue_deadline
	queue_deadline=$(($(date +%s) + CANARY_QUEUE_TIMEOUT_SECONDS))
	local active=0 done_count=0 list_ok=0 now reason retry_status row_list_ok
	local -A sent=() results=() started=() first_rows=() retry_reason=() retry_since=() retry_runs=() first_urls=()
	((${#files[@]})) || return 0
	if [[ "${CANARY_DISPATCH:-false}" != true ]]; then
		for file in "${files[@]}"; do sent[$file]=1; done
	fi
	while :; do
		now="$(date +%s)"
		for file in "${files[@]}"; do
			[[ -z "${sent[$file]:-}${results[$file]:-}" ]] || continue
			if ((now >= queue_deadline)); then
				# No retry was dispatched: retain the original terminal result.
				results[$file]="${first_rows[$file]:-$(printf '%s\tqueued-timeout\t\t' "$file")}"
				done_count=$((done_count + 1))
			elif ((active < CANARY_MAX_IN_FLIGHT)); then
				sent[$file]=1
				if [[ -n "${first_rows[$file]:-}" ]]; then
					# No slack: the old run must not satisfy the retry's poll. The
					# old URL is also excluded for dispatches in the same second.
					retry_since[$file]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
				fi
				# Journal before the write: cancellation can interrupt the response.
				[[ -z "$CANARY_STATE_DIR" ]] || printf '%s\n' "$file" >>"$CANARY_STATE_DIR/attempted"
				if dispatch_workflow "$file" "$branch"; then
					log_info "dispatched ${file} on ${branch}"
					retry_status=dispatched
				else
					results[$file]="${first_rows[$file]:-$(printf '%s\tdispatch_failed\t\t' "$file")}"
					done_count=$((done_count + 1))
					retry_status=failed
				fi
				if [[ -n "${first_rows[$file]:-}" && -n "$CANARY_STATE_DIR" ]]; then
					mkdir -p "$CANARY_STATE_DIR/retries"
					printf '%s\t%s\t%s\n' "${retry_reason[$file]}" "${first_urls[$file]}" "$retry_status" >"$CANARY_STATE_DIR/retries/$file"
				fi
				# Even an ambiguous failed write occupies a slot until seen terminal.
				active=$((active + 1))
			fi
		done
		if fresh="$(list_canary_runs "$branch" "$since")"; then
			runs="$fresh"
			list_ok=1
		else
			list_ok=0
			log_warn "run list fetch failed; keeping the previous snapshot"
		fi
		active=0
		now="$(date +%s)"
		for file in "${files[@]}"; do
			[[ -n "${sent[$file]:-}" ]] || continue
			row_list_ok="$list_ok"
			if [[ -n "${retry_since[$file]:-}" ]]; then
				if fresh="$(list_canary_runs "$branch" "${retry_since[$file]}")"; then
					retry_runs[$file]="$fresh"
					row_list_ok=1
				else
					row_list_ok=0
					log_warn "retry run list fetch failed for ${file}; keeping the previous snapshot"
				fi
				row="$(awk -F'\t' -v f="$file" -v old="${first_urls[$file]}" '$1 == f && $4 != old { print; exit }' <<<"${retry_runs[$file]:-}")"
			else
				row="$(awk -F'\t' -v f="$file" '$1 == f { print; exit }' <<<"$runs")"
			fi
			status="$(cut -f2 <<<"$row")"
			[[ "$status" == completed ]] || active=$((active + 1))
			[[ -z "${results[$file]:-}" ]] || continue
			url="$(cut -f4 <<<"$row")"
			name="$(cut -f5 <<<"$row")"
			conclusion=""
			if [[ "$status" == completed ]]; then
				conclusion="$(cut -f3 <<<"$row")"
			else
				id="${url##*/}"
				if [[ -n "$id" && -z "${started[$file]:-}" ]]; then
					if start="$(first_job_start "$id")"; then
						[[ -z "$start" ]] || started[$file]="$start"
					else
						# A failed job lookup cannot prove queue pressure.
						conclusion=monitoring_failed
					fi
				fi
				if [[ -n "${started[$file]:-}" ]]; then
					((now - started[$file] < CANARY_TIMEOUT_SECONDS)) || conclusion=timeout
				elif [[ -z "$conclusion" ]] && ((now >= queue_deadline)); then
					if ((row_list_ok)); then conclusion=queued-timeout; else conclusion=monitoring_failed; fi
				fi
			fi
			if [[ -n "$conclusion" ]]; then
				if ((now < queue_deadline)) && [[ "${CANARY_DISPATCH:-false}" == true && "${CANARY_RETRY_INFRA:-true}" == true && -z "${first_rows[$file]:-}" ]] &&
					reason="$(retry_eligible "$file" "$conclusion" "$url")"; then
					first_rows[$file]="$(printf '%s\t%s\t%s\t%s' "$file" "$conclusion" "$url" "$name")"
					first_urls[$file]="$url"
					retry_reason[$file]="$reason"
					unset 'sent[$file]' 'started[$file]'
					continue
				fi
				results[$file]="$(printf '%s\t%s\t%s\t%s' "$file" "$conclusion" "$url" "$name")"
				done_count=$((done_count + 1))
				if [[ "$status" != completed && -n "$id" ]]; then cancel_canary_run "$id"; fi
			fi
		done
		((done_count < ${#files[@]})) || break
		log_info "waiting on fixture workflows (${done_count}/${#files[@]} resolved; ${active} in flight)"
		sleep "$CANARY_POLL_SECONDS"
	done
	for file in "${files[@]}"; do printf '%s\n' "${results[$file]}"; done
}

# Never prune an active owning attempt's ref between dispatch waves. Empty listings
# cannot prove that an ambiguous dispatch was rejected, so retain those too.
# Check the exact attempt encoded in the ref, independently of fixture visibility.
# Only terminal, visible runs on a completed canary attempt's ref are safe to prune.
cleanup_stale_canary_branches() {
	local owned="${1:?owned branch required}" sha refs ref branch owner_status runs
	[[ "$CANARY_KEEP_BRANCH" != true ]] || return 0
	sha="${owned#canary/}"
	sha="${sha%%-*}"
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
	if ! refs="$(fixture_api -X GET "repos/${FIXTURE_REPO}/git/matching-refs/heads/canary/${sha}-" --paginate --jq '.[].ref')"; then
		log_warn "cannot list stale canary refs for ${sha}; leaving them untouched"
		return 0
	fi
	while IFS= read -r ref; do
		branch="${ref#refs/heads/}"
		[[ "$branch" != "$owned" && "$branch" =~ ^canary/${sha}-([0-9]+)-([0-9]+)$ ]] || continue
		if ! owner_status="$(lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/actions/runs/${BASH_REMATCH[1]}/attempts/${BASH_REMATCH[2]}" --jq .status)"; then
			log_warn "cannot verify owner of ${branch}; leaving it untouched"
			continue
		fi
		[[ "$owner_status" == completed ]] || continue
		if ! runs="$(list_canary_runs "$branch")"; then
			log_warn "cannot verify fixture runs on ${branch}; leaving it untouched"
			continue
		fi
		[[ -n "$runs" ]] || continue
		if awk -F'\t' '$2 != "completed" { exit 1 }' <<<"$runs"; then
			delete_canary_branch "$branch" || true
		fi
	done <<<"$refs"
}

# The journal is private to this Actions run. It exists only after this process
# created the ref, so a failed create never cancels another canary's runs.
cleanup_fixture_runs() {
	[[ -n "$CANARY_STATE_DIR" && -f "$CANARY_STATE_DIR/branch" ]] || return 0
	local branch runs file status url id name conclusion attempt missing count
	branch="$(cat "$CANARY_STATE_DIR/branch")"
	[[ "$branch" == canary/* ]] || return 1
	cleanup_stale_canary_branches "$branch"
	for attempt in 1 2 3; do
		if ! runs="$(list_canary_runs "$branch")"; then
			log_warn "retained ${FIXTURE_REPO}@${branch}: cannot verify fixture runs"
			return 0
		fi
		missing=0
		if [[ -f "$CANARY_STATE_DIR/attempted" ]]; then
			while read -r count file; do
				awk -F'\t' -v f="$file" -v expected="$count" '$1 == f { found++ } END { exit found < expected }' <<<"$runs" || missing=1
			done < <(sort "$CANARY_STATE_DIR/attempted" | uniq -c)
		fi
		while IFS=$'\x1f' read -r file status conclusion url name; do
			[[ -n "$file" && "$status" != completed ]] || continue
			missing=1
			id="${url##*/}"
			[[ "$id" =~ ^[0-9]+$ ]] && cancel_canary_run "$id"
		done < <(tr '\t' '\037' <<<"$runs")
		if ((missing == 0)); then
			if [[ "$CANARY_KEEP_BRANCH" != true ]]; then
				if delete_canary_branch "$branch"; then rm -f "$CANARY_STATE_DIR/branch"; fi
			fi
			return 0
		fi
		[[ "$attempt" == 3 ]] || sleep "$CANARY_CLEANUP_POLL_SECONDS"
	done
	log_warn "retained ${FIXTURE_REPO}@${branch}: fixture runs may still need this ref"
	_write_summary "" "> ⚠️ Retained \`${FIXTURE_REPO}@${branch}\` until unfinished or late-visible fixture runs complete; cancellation was requested for every visible unfinished run."
}
