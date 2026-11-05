#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bound fixture dispatches, distinguish queue/execution time, and cancel owned runs.
# Host functions: fixture_api, lgtm_ci_api, dispatch_workflow, delete_canary_branch,
# is_gate, log_info, log_warn and _write_summary (external-canary.sh).

# TSV: workflow file, status, conclusion, URL, name. Paginate so probe children
# and retried runs beyond the first page also participate in cleanup.
list_canary_runs() {
	local filter=""
	[[ -z "${2:-}" ]] || filter="&created=%3E%3D${2}"
	fixture_api -X GET \
		"repos/${FIXTURE_REPO}/actions/runs?branch=${1:?}&event=workflow_dispatch${filter}&per_page=100" \
		--paginate --jq '.workflow_runs[] | [(.path | sub("^\\.github/workflows/"; "")), .status, (.conclusion // ""), .html_url, .name] | @tsv'
}

# A nonzero dispatch response does not prove rejection. Read the workflow's
# complete owned-branch listing, at most ten pages / 1,000 runs. Never use a
# cached or partial snapshot for this decision, or choose between duplicates.
# The immutable fixture commit comes from branch creation, not the mutable ref.
# A retry passes its first run URL, which is the only run allowed besides it.
observed_dispatch_run() {
	local branch="$1" file="$2" head="$3" dispatched="$4" exclude="${5:-}" now
	local page response total="" count runs='[]'
	[[ "$branch" == canary/* && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
	for page in {1..10}; do
		response="$(fixture_api -X GET "repos/${FIXTURE_REPO}/actions/workflows/${file}/runs?branch=${branch}&event=workflow_dispatch&per_page=100&page=${page}")" || return 1
		count="$(jq -er '
			select((.total_count | type) == "number" and .total_count >= 0
				and .total_count <= 1000 and (.total_count | floor) == .total_count)
			| select((.workflow_runs | type) == "array" and (.workflow_runs | length) <= 100)
			| .total_count' <<<"$response")" || return 1
		[[ -z "$total" || "$total" == "$count" ]] || return 1
		total="$count"
		runs="$(jq -cn --argjson runs "$runs" --argjson response "$response" '$runs + $response.workflow_runs')" || return 1
		count="$(jq length <<<"$runs")"
		((count <= total)) || return 1
		((count < total)) || break
		# A short page with more advertised results is incomplete evidence.
		[[ "$(jq '.workflow_runs | length' <<<"$response")" == 100 ]] || return 1
	done
	((count == total)) || return 1
	# Runs may be created while any page is in flight. Bound evidence after GET.
	now="$(date +%s)"
	jq -er --arg branch "$branch" --arg path ".github/workflows/$file" \
		--arg head "$head" --arg repo "$FIXTURE_REPO" \
		--argjson dispatched "$dispatched" --argjson now "$now" --arg exclude "$exclude" '
		map(select($exclude == "" or .html_url != $exclude))
		| select(length == 1) | .[0]
		| select(.head_branch == $branch and .head_sha == $head
			and .path == $path and .event == "workflow_dispatch"
			and .repository.full_name == $repo and .head_repository.full_name == $repo)
		| select((.id | type) == "number" and .id > 0 and (.id | floor) == .id)
		| select(.html_url == ("https://github.com/" + $repo + "/actions/runs/" + (.id | tostring)))
		| select((.created_at | fromdateiso8601) >= $dispatched
			and (.created_at | fromdateiso8601) <= $now)
		| select((.name | type) == "string")
		| select(if .status == "completed" then
			(.conclusion as $c | ["success", "failure", "neutral", "cancelled", "skipped",
				"timed_out", "action_required", "stale", "startup_failure"] | index($c)) != null
		else (.status as $s | ["queued", "in_progress", "requested", "waiting", "pending"] | index($s)) != null
			and .conclusion == null end)
		| [(.path | sub("^\\.github/workflows/"; "")), .status,
			(.conclusion // ""), .html_url, .name] | @tsv' <<<"$runs"
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

# One result row: file, conclusion, URL, name, then the optional dispatch
# error, inconclusive evidence (the proven infrastructure reason) and retry
# record (reason, status, first run URL). The row itself carries the evidence
# so verdicts never depend on an optional state directory. Trailing empty
# optional fields are dropped, so ordinary rows keep four fields.
result_row() {
	local -a fields=("$@")
	while ((${#fields[@]} > 4)) && [[ -z "${fields[${#fields[@]} - 1]}" ]]; do
		unset 'fields[${#fields[@]}-1]'
	done
	local IFS=$'\t'
	printf '%s' "${fields[*]}"
}

# Rolling admission: queued runs occupy slots too. The queue budget starts
# before admission, bounding total scheduling time even on a saturated fixture.
# CANARY_DISPATCH=false supports polling an already dispatched set in tests/tools.
poll_runs() {
	local branch="${1:?branch required}" since="${2:?since required}"
	shift 2
	local files=("$@") file row status conclusion url name id start fresh runs=""
	local queue_deadline errf error
	local -A ambiguous=() dispatched=() matched_url=() matched_name=()
	queue_deadline=$(($(date +%s) + CANARY_QUEUE_TIMEOUT_SECONDS))
	local active=0 done_count=0 list_ok=0 now reason row_list_ok
	local -A sent=() results=() started=() retry_reason=() retry_since=() retry_runs=()
	local -A first_conclusion=() first_urls=() first_name=()
	((${#files[@]})) || return 0
	if [[ "${CANARY_DISPATCH:-false}" != true ]]; then
		for file in "${files[@]}"; do sent[$file]=1; done
	fi
	while :; do
		now="$(date +%s)"
		for file in "${files[@]}"; do
			[[ -z "${sent[$file]:-}${results[$file]:-}" ]] || continue
			now="$(date +%s)"
			if ((now >= queue_deadline)); then
				if [[ -n "${retry_reason[$file]:-}" ]]; then
					# No retry was dispatched: keep the first result as inconclusive.
					results[$file]="$(result_row "$file" "${first_conclusion[$file]}" "${first_urls[$file]}" "${first_name[$file]}" "" "${retry_reason[$file]}")"
				else
					results[$file]="$(printf '%s\tqueued-timeout\t\t' "$file")"
				fi
				done_count=$((done_count + 1))
			elif ((active < CANARY_MAX_IN_FLIGHT)); then
				sent[$file]=1
				if [[ -n "${retry_reason[$file]:-}" ]]; then
					# No slack: the old run must not satisfy the retry's poll. The
					# old URL is also excluded for dispatches in the same second.
					retry_since[$file]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
				fi
				# Journal before the write: cancellation can interrupt the response.
				[[ -z "$CANARY_STATE_DIR" ]] || printf '%s\n' "$file" >>"$CANARY_STATE_DIR/attempted"
				dispatched[$file]="$(date +%s)"
				errf="$(mktemp)"
				if dispatch_workflow "$file" "$branch" 2>"$errf"; then
					log_info "dispatched ${file} on ${branch}"
				else
					ambiguous[$file]="$(tr '\t\r\n' '   ' <"$errf")"
					[[ -n "${ambiguous[$file]}" ]] || ambiguous[$file]="dispatch response failed"
				fi
				cat "$errf" >&2
				rm -f "$errf"
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
			if [[ -n "${ambiguous[$file]:-}" && -z "${results[$file]:-}" ]]; then
				# A loose run-list row cannot release this slot or prove execution.
				row="$(observed_dispatch_run "$branch" "$file" "${CANARY_FIXTURE_HEAD:-}" "${dispatched[$file]}" "${first_urls[$file]:-}")" || row=""
				if [[ -n "$row" ]]; then
					url="$(cut -f4 <<<"$row")"
					if [[ -n "${matched_url[$file]:-}" && "${matched_url[$file]}" != "$url" ]]; then
						row=""
					else
						matched_url[$file]="$url"
						matched_name[$file]="$(cut -f5 <<<"$row")"
					fi
				fi
			fi
			# Refresh budgets after reconciliation, including failed/invalid reads.
			now="$(date +%s)"
			status="$(cut -f2 <<<"$row")"
			[[ "$status" == completed ]] || active=$((active + 1))
			[[ -z "${results[$file]:-}" ]] || continue
			url="$(cut -f4 <<<"$row")"
			name="$(cut -f5 <<<"$row")"
			conclusion="" id=""
			if [[ -n "${ambiguous[$file]:-}" && -z "$row" ]]; then
				# Retain ownership for diagnostics/cancellation, never a cached verdict.
				url="${matched_url[$file]:-}"
				name="${matched_name[$file]:-}"
				id="${url##*/}"
				if [[ -n "${started[$file]:-}" ]]; then
					((now - started[$file] < CANARY_TIMEOUT_SECONDS)) || conclusion=monitoring_failed
				else
					((now < queue_deadline)) || conclusion=dispatch_failed
				fi
			elif [[ "$status" == completed ]]; then
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
				now="$(date +%s)"
				if [[ -n "${started[$file]:-}" ]]; then
					((now - started[$file] < CANARY_TIMEOUT_SECONDS)) || conclusion=timeout
				elif [[ -z "$conclusion" ]] && ((now >= queue_deadline)); then
					if ((row_list_ok)); then conclusion=queued-timeout; else conclusion=monitoring_failed; fi
				fi
			fi
			if [[ -n "$conclusion" ]]; then
				# An unresolved ambiguous write is never an informational queue expiry.
				if [[ -n "${ambiguous[$file]:-}" && "$conclusion" == queued-timeout ]]; then conclusion=dispatch_failed; fi
				error="${ambiguous[$file]:-}"
				if [[ -n "${retry_reason[$file]:-}" && "$conclusion" == dispatch_failed ]]; then
					# The retry POST never produced a matching run: keep the first
					# result and its proven infrastructure evidence (inconclusive).
					results[$file]="$(result_row "$file" "${first_conclusion[$file]}" "${first_urls[$file]}" "${first_name[$file]}" \
						"$error" "${retry_reason[$file]}" "${retry_reason[$file]}" failed "${first_urls[$file]}")"
				else
					reason=""
					reason="$(retry_eligible "$file" "$conclusion" "$url")" || true
					if ((now < queue_deadline)) && [[ "${CANARY_DISPATCH:-false}" == true && "${CANARY_RETRY_INFRA:-true}" == true && -z "${retry_reason[$file]:-}" && -n "$reason" ]]; then
						first_conclusion[$file]="$conclusion"
						first_urls[$file]="$url"
						first_name[$file]="$name"
						retry_reason[$file]="$reason"
						unset 'sent[$file]' 'started[$file]' 'ambiguous[$file]' 'matched_url[$file]' 'matched_name[$file]'
						continue
					fi
					if [[ -n "${retry_reason[$file]:-}" ]]; then
						results[$file]="$(result_row "$file" "$conclusion" "$url" "$name" "$error" "$reason" \
							"${retry_reason[$file]}" dispatched "${first_urls[$file]}")"
					else
						results[$file]="$(result_row "$file" "$conclusion" "$url" "$name" "$error" "$reason")"
					fi
				fi
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
