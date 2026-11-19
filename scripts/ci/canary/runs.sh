#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bound fixture dispatches, distinguish queue/execution time, and cancel owned runs.
# Host functions: fixture_api, lgtm_ci_api, dispatch_workflow, delete_canary_branch,
# is_gate, workflow_role, log_info, log_warn and _write_summary (external-canary.sh), and
# infra_canary_signatures (../lib/infra-signatures.sh, sourced by the host).

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

# Number of jobs GitHub created for a run, whatever their status. A run that
# waits for a runner already has queued jobs; a run GitHub never started has
# none (#1601). One small read: total_count, not the job pages. Fails on an
# API error or a malformed answer, which never counts as "no jobs".
run_job_count() {
	local count
	count="$(fixture_api -X GET "repos/${FIXTURE_REPO}/actions/runs/${1:?}/jobs?per_page=1" --jq .total_count)" || return 1
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
}

# Request cancellation of a run GitHub never started. GitHub answers HTTP 409
# ("has not been queued yet") for such a run, even to force-cancel; that is
# expected, and the run is left alone. The answer is logged so another error
# (403, 500) is not mistaken for it.
cancel_never_started_run() {
	local id="${1:?}" file="${2:?}" error
	error="$(fixture_api -X POST "repos/${FIXTURE_REPO}/actions/runs/${id}/cancel" 2>&1 >/dev/null)" ||
		log_info "fixture run ${id} (${file}) was not cancelled ($(api_text "$error")); GitHub refuses that for a run it has not queued, and the run is left alone"
}

# API error text ($1) on one line, for a log message. log_info and log_warn
# use `echo -e`; doubling each backslash makes them print it as is.
api_text() {
	local text
	text="$(printf '%s' "${1:-no detail}" | tr '\t\r\n' '   ')"
	printf '%s' "${text//\\/\\\\}"
}

# Final row of a fixture dispatched again because its first run never started
# (#1601). The second run decides, with two exceptions that keep a failure
# from being hidden:
#   - the abandoned first run started late and was seen to conclude something
#     other than `cancelled` or the expected conclusion while the second run
#     concluded as expected: the first run's conclusion and URL take the row
#     (retry status `late-first`, ninth field the second run), so a failure of
#     either run counts. The first run goes through the same infrastructure
#     classifier as any other run (retry_eligible), and a proven reason is
#     kept as the row's evidence: inconclusive for a gate, never a retry;
#   - the first run started late and the second run concluded `cancelled`
#     (a fixture concurrency group can cancel it): the row carries evidence,
#     which makes a gate inconclusive instead of failed.
# Arguments: file, row, first run's conclusion (empty unless seen completed),
# non-empty when the first run was seen to start.
late_first_run_row() {
	local file="${1:?}" row="${2:?}" first="${3:-}" started="${4:-}" expected second reason=""
	expected="$(workflow_expected "$file")"
	second="$(cut -f2 <<<"$row")"
	if [[ -n "$first" && "$first" != cancelled && "$first" != "$expected" && "$second" == "$expected" ]]; then
		reason="$(retry_eligible "$file" "$first" "$(cut -f9 <<<"$row")")" || reason=""
		awk -F'\t' -v OFS='\t' -v c="$first" -v e="$reason" '{ u = $3; $2 = c; $3 = $9; $9 = u; $6 = e; $8 = "late-first"; print }' <<<"$row"
	elif [[ -n "$started" && "$second" == cancelled && "$expected" != cancelled ]]; then
		awk -F'\t' -v OFS='\t' '{ $6 = "first-run-started-late"; print }' <<<"$row"
	else
		printf '%s\n' "$row"
	fi
}

# Failed steps that only report another job's failure in the same fixture run.
# They carry no signature and never qualify a run on their own: at least one
# other failed job must carry an infrastructure signature (#1475).
# Each entry: fixture workflow file TAB job name TAB step name. The job must
# carry no failure annotation besides GitHub's exit-code line (#1475).
CANARY_INFRA_DOWNSTREAM_STEPS=(
	# Gate fixtures end in a `check` job (`needs` the reusable, `if: always()`).
	# The step named here asserts only that reusable's result, so it fails
	# whenever a leg of the reusable failed (#1503). Where a fixture also
	# asserts the product (publish, readonly, facade-validate), that runs in a
	# separate, later step that annotates its own failure, so it is never
	# excused (consumer-fixture PR 77, #1505); docker-orchestrator and
	# e2e-matrix assert only the result. A reusable's own `always()` job that
	# only reports a failed leg (the e2e merge) is listed the same way. Keep
	# these names in step with the fixture and the reusable: renaming only one
	# side drops the excuse.
	# docker-publish.yml: fixture run 43070043408.
	$'docker-publish.yml\tcheck\tAssert the published index lists both platforms'
	# readonly-docker.yml: fixture run 43251873428 (check run 131300515022).
	$'readonly-docker.yml\tcheck\tAssert the build passed and both SARIF artifacts exist'
	# docker-facade-validate.yml and docker-orchestrator.yml: same shape.
	$'docker-facade-validate.yml\tcheck\tAssert the facade validated and uploaded both SARIF categories'
	$'docker-orchestrator.yml\tcheck\tAssert the split path ran through the facade'
	# e2e-matrix.yml: fixture run 43020328220. reusable-test-e2e-matrix.yml's
	# merge job runs after a failed leg; given test-result, a shard report the
	# dead leg never wrote is only a warning there, so the step fails with
	# GitHub's exit-code annotation alone. A merge ::error:: (a shard missing
	# after a green test job, a totals mismatch) is never excused.
	$'e2e-matrix.yml\te2e-matrix / Merge Reports\tMerge reports'
	# The fixture's check job asserts only the e2e-matrix result.
	$'e2e-matrix.yml\tcheck\tRequire the e2e-matrix job to succeed'
)
# At most this many jobs' annotations are read to classify one fixture run.
CANARY_INFRA_MAX_ANNOTATION_JOBS=5

# Print the label of the infrastructure signature (file $1: label TAB failed
# step name TAB message regex per line) that the check-run annotations of a
# job prove, given the name of the job's only failed step ($2) and the
# paginated annotations JSON on stdin. Annotations carry no step reference,
# so the job's failure annotations must be exactly one message matching an
# entry for that step name plus at most GitHub's generic `Process completed
# with exit code N.` (the failed step's own exit). Any other failure
# annotation, from any step, fails closed (#1475).
match_annotation_signature() {
	jq -e -r -s --rawfile sigs "${1:?}" --arg step "${2:?}" '
		"^Process completed with exit code [0-9]+\\.$" as $exit
		| [.[][] | select(.annotation_level == "failure") | .message] as $msgs
		| [$msgs[] | select(test($exit))] as $exits
		| [$msgs[] | select(test($exit) | not)] as $own
		| select(($exits | length) <= 1 and ($own | length) == 1)
		| first($sigs | split("\n")[] | split("\t")
			| select(length == 3 and .[1] == $step) as [$label, $_, $re]
			| select($own[0] | test($re)) | $label)'
}

# Print "infra:<labels>" when every failed job in the paginated jobs JSON ($1)
# failed exactly one step and either that job's check-run annotations prove
# an infrastructure signature for that step (infra_canary_signatures,
# match_annotation_signature) or the step is a downstream report
# (CANARY_INFRA_DOWNSTREAM_STEPS), with at least one signature job. A job's id
# is its check-run id, and the annotations endpoint is served by
# api.github.com, which the external-canary egress preset already allows.
# Any other failed step, several failed steps in one job, an annotation API
# error or more than CANARY_INFRA_MAX_ANNOTATION_JOBS annotation reads in
# all (signature and downstream jobs together) fails closed (#1475).
infra_signature_reason() {
	local workflow="${2:?}" plan kind id step label labels="" fetches=0 signatures=0 status=0 sigf annf
	plan="$(jq -r -s --arg workflow "$workflow" '
		[.[] | .jobs[]] as $jobs
		| [$jobs[] | select(.conclusion == "failure")] as $failed
		| [$ARGS.positional[] | split("\t") | select(.[0] == $workflow)] as $downstream
		# A timed-out, cancelled or unfinished job is not explained by any
		# signature: retrying the gate could hide it (#1475).
		| if any($jobs[]; .conclusion | IN("success", "skipped", "neutral", "failure") | not)
			or ($failed | length) == 0 then "invalid" else
			$failed[] | . as $job | [(.steps // [])[] | select(.conclusion == "failure")] as $steps
			| if ($steps | length) != 1 then "invalid"
			elif any($downstream[]; .[1] == $job.name and .[2] == $steps[0].name)
				and ($job.id | type) == "number" then
				["downstream", ($job.id | tostring), $steps[0].name] | join("\t")
			elif (.id | type) == "number" and ($steps[0].name | type) == "string"
				and ($steps[0].name | test("[\t\n]") | not) then
				["annotations", (.id | tostring), $steps[0].name] | join("\t")
			else "invalid" end
		end' --args "${CANARY_INFRA_DOWNSTREAM_STEPS[@]}" <<<"${1:?}" 2>/dev/null)" || return 1
	[[ -n "$plan" ]] && ! grep -qx invalid <<<"$plan" || return 1
	sigf="$(mktemp)"
	annf="$(mktemp)"
	infra_canary_signatures >"$sigf" || status=1
	while ((status == 0)) && IFS=$'\t' read -r kind id step; do
		# Every annotation read counts toward one budget, downstream or not.
		fetches=$((fetches + 1))
		if ((fetches > CANARY_INFRA_MAX_ANNOTATION_JOBS)); then
			status=1
			break
		fi
		if [[ "$kind" == downstream ]]; then
			fixture_api -X GET "repos/${FIXTURE_REPO}/check-runs/${id}/annotations?per_page=50" --paginate >"$annf" &&
				jq -e -s '[.[][] | select(.annotation_level == "failure") | .message]
					| length == 1 and all(.[]; test("^Process completed with exit code [0-9]+\\.$"))' \
					<"$annf" >/dev/null 2>&1 || status=1
			continue
		fi
		[[ "$kind" == annotations ]] || {
			status=1
			break
		}
		signatures=$((signatures + 1))
		if ! fixture_api -X GET "repos/${FIXTURE_REPO}/check-runs/${id}/annotations?per_page=50" --paginate >"$annf" ||
			! label="$(match_annotation_signature "$sigf" "$step" <"$annf" 2>/dev/null)" ||
			[[ -z "$label" ]]; then
			status=1
		elif [[ ",${labels}," != *",${label},"* ]]; then
			labels="${labels:+${labels},}${label}"
		fi
	done <<<"$plan"
	rm -f "$sigf" "$annf"
	((status == 0 && signatures > 0)) || return 1
	printf 'infra:%s\n' "$labels"
}

# Only gate runs that stopped in fixture setup, or whose failed lgtm-ci steps
# ended on a confirmed infrastructure signature (infra_signature_reason), may
# be dispatched once more. Print the reason on success. Consume every jobs
# page before deciding: an API error, missing failed-step evidence, or any
# later executed step fails closed.
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
	# A timed-out, cancelled or unfinished job is explained by neither retry
	# path, and a retry could hide it: check before either path (#1475).
	jq -e -s 'all(.[] | .jobs[]; .conclusion | IN("success", "skipped", "neutral", "failure"))' \
		<<<"$jobs" >/dev/null 2>&1 || return 1
	if jq -e -s '
		[.[] | .jobs[] | select(.conclusion == "failure")] as $failed |
		($failed | length) > 0 and all($failed[];
			.steps as $steps |
			($steps | map(.conclusion) | index("failure")) as $first |
			$first != null and
			($steps[$first].name | test("^(Set up job$|Pre Harden runner$|Harden runner$|Checkout|Prepare .* Matrix$)")) and
			all($steps[($first + 1):][]; .conclusion == null or .conclusion == "skipped")
		)
	' <<<"$jobs" >/dev/null 2>&1; then
		printf 'infra\n'
		return 0
	fi
	infra_signature_reason "$jobs" "$file"
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
	# Never-started re-dispatch (#1601): runs known to have jobs, files whose
	# re-dispatch the cap refused, and stuck first runs not yet seen to start.
	# The host sets CANARY_REDISPATCH_AFTER_SECONDS and CANARY_MAX_REDISPATCHES;
	# unset or a cap of 0 turns it off, and then no job is ever counted.
	local redispatches=0 late count
	local -A has_jobs=() cap_logged=() stuck_id=() late_cancelled=() late_first=() late_started=()
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
			if [[ -n "${stuck_id[$file]:-}" ]] && ((list_ok)); then
				# The abandoned first run started after all: cancel it once, then
				# keep watching until it completes, because a conclusion it reaches
				# anyway still counts (late_first_run_row). The main snapshot costs
				# no extra call.
				late="$(awk -F'\t' -v u="${first_urls[$file]}" '$4 == u { print $2 "\t" $3; exit }' <<<"$runs")"
				if [[ "${late%%$'\t'*}" == completed ]]; then
					late_first[$file]="${late#*$'\t'}"
					late_started[$file]=1
					log_warn "first run ${first_urls[$file]} of ${file} started late and concluded '${late_first[$file]}'"
					unset 'stuck_id[$file]'
				elif [[ -n "$late" && "${late%%$'\t'*}" != queued && -z "${late_cancelled[$file]:-}" ]]; then
					log_info "first run ${first_urls[$file]} of ${file} started late (${late%%$'\t'*}); cancelling it"
					cancel_canary_run "${stuck_id[$file]}"
					late_cancelled[$file]=1
					late_started[$file]=1
				fi
			fi
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
				elif [[ -z "$conclusion" && "$status" == queued && -n "$id" && "${CANARY_DISPATCH:-false}" == true &&
					-n "${dispatched[$file]:-}" && -z "${retry_reason[$file]:-}${has_jobs[$file]:-}${cap_logged[$file]:-}" &&
					-n "${CANARY_REDISPATCH_AFTER_SECONDS:-}" ]] && ((${CANARY_MAX_REDISPATCHES:-0} > 0)) &&
					((now - dispatched[$file] >= CANARY_REDISPATCH_AFTER_SECONDS)) &&
					[[ "$(workflow_role "$file")" != manual ]]; then
					# Never started (#1601): still queued with no job at all past the
					# threshold. Jobs are counted only here, once per run that has
					# them, so a normal runner wait costs one extra read in total.
					if ! count="$(run_job_count "$id")"; then
						log_warn "cannot count the jobs of fixture run ${url} (${file}); not re-dispatching it on this poll"
					elif ((count > 0)); then
						has_jobs[$file]=1
					elif ((redispatches >= CANARY_MAX_REDISPATCHES)); then
						cap_logged[$file]=1
						log_warn "not re-dispatching ${file}: run ${url} never started, but this canary already used its ${CANARY_MAX_REDISPATCHES} extra dispatch(es) (CANARY_MAX_REDISPATCHES)"
					else
						redispatches=$((redispatches + 1))
						log_warn "re-dispatching ${file}: run ${url} is still queued with no jobs $((now - dispatched[$file]))s after dispatch (extra dispatch ${redispatches} of ${CANARY_MAX_REDISPATCHES}); the new run decides"
						cancel_never_started_run "$id" "$file"
						first_conclusion[$file]=queued-timeout
						first_urls[$file]="$url"
						first_name[$file]="$name"
						retry_reason[$file]=never-started
						stuck_id[$file]="$id"
						# A run that never started holds no runner: free its slot.
						active=$((active - 1))
						unset 'sent[$file]' 'ambiguous[$file]' 'matched_url[$file]' 'matched_name[$file]'
						continue
					fi
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
	for file in "${files[@]}"; do
		row="${results[$file]}"
		if [[ "${retry_reason[$file]:-}" == never-started && "$(cut -f8 <<<"$row")" == dispatched ]]; then
			row="$(late_first_run_row "$file" "$row" "${late_first[$file]:-}" "${late_started[$file]:-}")"
		fi
		printf '%s\n' "$row"
	done
}

# Stale refs pinned by fixture runs GitHub never started (#1605).
#
# Such a run stays `queued` with no job, and cancel and force-cancel both
# answer HTTP 409 for it (#1601), so it used to pin its canary ref for good: a
# ref is kept while any run on it is unfinished. On the ref of a completed
# canary attempt, a run counts as never started only when a fresh read says
# `queued` on that very branch, GitHub created no job for it (a run that waits
# for a runner already has queued jobs), and its latest attempt is at least
# CANARY_NEVER_STARTED_PRUNE_HOURS old. The age runs from the later of
# created_at and run_started_at: a re-run keeps created_at, but starts a new
# attempt. The threshold is never below 24 hours, GitHub's limit for a job
# that waits for a runner. Any API error, missing or unparseable timestamp,
# job, younger attempt, threshold that is unset, malformed or below 24, or any
# other unfinished run keeps the ref.
#
# When every unfinished run on the ref is such a run, each is deleted once
# (DELETE /actions/runs/{id}). The ref is then listed again, and every run
# still unfinished on it is read again: it must be one of the runs checked,
# still `queued` on the branch, on the same attempt, still with no job and
# still old enough. Only then is the ref deleted, whether or not GitHub
# allowed the run delete. Why that is safe:
#   - GitHub ends a job that waits for a runner after 24 hours, and a run with
#     no job at that age has no job that could start;
#   - the run is pinned to its head SHA, not to the ref;
#   - tested live on the fixture (2026-11-19): DELETE of such a run (queued 17
#     days, 0 jobs) answered HTTP 403 "Could not delete the workflow run" even
#     for the repository owner, and DELETE of its ref answered 204; the run
#     stayed queued with 0 jobs afterwards.
# The run delete is still tried because it may succeed for other runs. A ref
# removed while a refused run is still listed queued is counted and logged,
# so the queued runs left behind stay visible.

# Seconds a never-started run's latest attempt must reach, from
# CANARY_NEVER_STARTED_PRUNE_HOURS. Fail when it is unset, malformed or
# below 24 hours.
never_started_threshold_seconds() {
	local hours="${CANARY_NEVER_STARTED_PRUNE_HOURS:-}"
	[[ "$hours" =~ ^[1-9][0-9]{0,4}$ ]] && ((hours >= 24)) || return 1
	printf '%s\n' "$((hours * 3600))"
}

# Print "attempt TAB age" for fixture run $1 when it is a never-started run on
# branch $2 (queued there, no job), the age in seconds from the later of
# created_at and run_started_at. Fail otherwise or on any error, including a
# missing run_started_at.
never_started_run_age() {
	local id="${1:?}" branch="${2:?}" info status head attempt created started now count
	[[ "$id" =~ ^[0-9]+$ ]] || return 1
	info="$(fixture_api -X GET "repos/${FIXTURE_REPO}/actions/runs/${id}" \
		--jq '[.status, .head_branch, .run_attempt, (.created_at | fromdateiso8601 | floor),
			(.run_started_at | fromdateiso8601 | floor)] | @tsv')" || return 1
	IFS=$'\t' read -r status head attempt created started <<<"$info"
	[[ "$status" == queued && "$head" == "$branch" && "$attempt" =~ ^[1-9][0-9]{0,5}$ &&
		"$created" =~ ^[0-9]{1,12}$ && "$started" =~ ^[0-9]{1,12}$ ]] || return 1
	if ((started > created)); then created="$started"; fi
	count="$(run_job_count "$id")" || return 1
	((count == 0)) || return 1
	now="$(date +%s)"
	[[ "$now" =~ ^[0-9]+$ ]] && ((now >= created)) || return 1
	printf '%s\t%s\n' "$attempt" "$((now - created))"
}

# Try to delete the never-started runs that pin a completed attempt's branch
# ($1), given its run listing ($2). Return 0 when every unfinished run on it is
# a never-started run past the threshold (each delete tried once); 2 when every
# unfinished run is a never-started run but one is too young (the ref is kept
# and counted); 1 otherwise (the ref is kept). Fills the caller's
# NEVER_STARTED_ATTEMPT (run id to attempt) and NEVER_STARTED_REFUSED (runs
# GitHub would not delete).
delete_never_started_runs() {
	local branch="${1:?}" runs="${2:?}" file status url id info min error young=0
	NEVER_STARTED_ATTEMPT=()
	NEVER_STARTED_REFUSED=()
	if ! min="$(never_started_threshold_seconds)"; then
		log_warn "kept ${FIXTURE_REPO}@${branch}: CANARY_NEVER_STARTED_PRUNE_HOURS threshold unset, malformed or below 24h ('${CANARY_NEVER_STARTED_PRUNE_HOURS:-}')"
		return 1
	fi
	while IFS=$'\x1f' read -r file status _ url _; do
		[[ -n "$file" && "$status" != completed ]] || continue
		[[ "$status" == queued ]] || return 1
		id="${url##*/}"
		info="$(never_started_run_age "$id" "$branch")" || return 1
		NEVER_STARTED_ATTEMPT[$id]="${info%%$'\t'*}"
		((${info#*$'\t'} >= min)) || young=1
	done < <(tr '\t' '\037' <<<"$runs")
	((${#NEVER_STARTED_ATTEMPT[@]})) || return 1
	if ((young)); then
		log_info "kept ${FIXTURE_REPO}@${branch}: a fixture run on it never started but its latest attempt is younger than ${CANARY_NEVER_STARTED_PRUNE_HOURS}h"
		return 2
	fi
	for id in "${!NEVER_STARTED_ATTEMPT[@]}"; do
		if error="$(fixture_api -X DELETE "repos/${FIXTURE_REPO}/actions/runs/${id}" 2>&1 >/dev/null)"; then
			log_info "deleted never-started fixture run ${id} on ${branch}"
		else
			NEVER_STARTED_REFUSED+=("$id")
			log_info "GitHub did not delete never-started fixture run ${id} on ${branch} ($(api_text "$error")); the ref goes if a fresh check still finds only never-started runs"
		fi
	done
}

# After delete_never_started_runs, list branch $1 again and read every run still
# unfinished on it: it must be one of the runs checked, still `queued` on the
# branch, on the same attempt, with no job and past the threshold. Print the
# ids of those runs. Fail on any difference or error.
recheck_never_started_runs() {
	local branch="${1:?}" runs file status url id info min
	min="$(never_started_threshold_seconds)" || return 1
	runs="$(list_canary_runs "$branch")" || return 1
	while IFS=$'\x1f' read -r file status _ url _; do
		[[ -n "$file" && "$status" != completed ]] || continue
		id="${url##*/}"
		[[ "$status" == queued && "$id" =~ ^[0-9]+$ && -n "${NEVER_STARTED_ATTEMPT[$id]:-}" ]] || return 1
		info="$(never_started_run_age "$id" "$branch")" || return 1
		[[ "${info%%$'\t'*}" == "${NEVER_STARTED_ATTEMPT[$id]}" ]] && ((${info#*$'\t'} >= min)) || return 1
		printf '%s\n' "$id"
	done < <(tr '\t' '\037' <<<"$runs")
}

# Never prune an active owning attempt's ref between dispatch waves. Empty listings
# cannot prove that an ambiguous dispatch was rejected, so retain those too.
# Check the exact attempt encoded in the ref, independently of fixture visibility.
# Only terminal, visible runs on a completed canary attempt's ref, or the
# never-started runs described above, allow pruning it.
cleanup_stale_canary_branches() {
	local owned="${1:?owned branch required}" sha refs ref branch owner_status runs status left id
	local kept=0 orphaned=0 queued_left=0 leftover
	local -A NEVER_STARTED_ATTEMPT=()
	local -a NEVER_STARTED_REFUSED=()
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
		NEVER_STARTED_REFUSED=()
		leftover=""
		if ! awk -F'\t' '$2 != "completed" { exit 1 }' <<<"$runs"; then
			status=0
			delete_never_started_runs "$branch" "$runs" || status=$?
			if ((status == 2)); then kept=$((kept + 1)); fi
			((status == 0)) || continue
			# An empty fresh listing (every run deleted) lets the ref go.
			if ! left="$(recheck_never_started_runs "$branch")"; then
				log_warn "kept ${FIXTURE_REPO}@${branch}: cannot confirm that only its never-started fixture runs are unfinished"
				continue
			fi
			# Runs left queued without a ref: refused deletes still listed queued.
			for id in "${NEVER_STARTED_REFUSED[@]}"; do
				if grep -qx "$id" <<<"$left"; then leftover="${leftover:+${leftover} }${id}"; fi
			done
		fi
		if delete_canary_branch "$branch" && [[ -n "$leftover" ]]; then
			orphaned=$((orphaned + 1))
			queued_left=$((queued_left + $(wc -w <<<"$leftover")))
			log_warn "removed ${FIXTURE_REPO}@${branch}; GitHub refused to delete its never-started run(s) ${leftover}, which stay queued"
		fi
	done <<<"$refs"
	if ((orphaned)); then
		log_warn "removed ${orphaned} stale canary ref(s) for ${sha} despite a refused run delete; ${queued_left} never-started fixture run(s) stay queued without a ref (#1605)"
		_write_summary "" "> ℹ️ Removed ${orphaned} stale canary ref(s) for \`${sha}\` in \`${FIXTURE_REPO}\` whose never-started fixture runs GitHub would not delete; ${queued_left} such run(s) stay queued without a ref."
	fi
	((kept)) || return 0
	log_warn "kept ${kept} stale canary ref(s) for ${sha} because their never-started fixture runs are younger than ${CANARY_NEVER_STARTED_PRUNE_HOURS}h (#1605)"
	_write_summary "" "> ℹ️ Kept ${kept} stale canary ref(s) for \`${sha}\` in \`${FIXTURE_REPO}\` because their never-started fixture runs are younger than ${CANARY_NEVER_STARTED_PRUNE_HOURS}h (CANARY_NEVER_STARTED_PRUNE_HOURS)."
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
