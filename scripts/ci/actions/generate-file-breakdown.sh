#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fetch PR changed files and generate a file breakdown PR comment
#
# STEP dispatch (set STEP env var):
#   fetch    - Fetch the PR changed-files payload via gh api --paginate
#     Required env: GH_TOKEN, PR_NUMBER, GITHUB_REPOSITORY, PR_FILES_JSON (output path)
#   generate - Render the markdown comment from the fetched JSON payload
#     Required env: PR_FILES_JSON (input path)
#     Optional env: COMMENT_OUTPUT (write to file; stdout when unset),
#       MAX_ROWS (detail rows cap, default 50),
#       FILE_BREAKDOWN_CONFIG (category config path; default .github/file-breakdown.yml),
#       GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_SERVER_URL (build link)

set -euo pipefail

# Default category definitions for file classification.
# Order matters: first match wins. "Implementation" is the catch-all (must be last).
DEFAULT_CATEGORIES='[
  {"name":"CI-CD","patterns":["^\\.github/","^\\.gitlab-ci","^\\.circleci/","^Jenkinsfile$","^\\.travis\\.yml$"]},
  {"name":"Tests","patterns":["(^|/)tests?/","(^|/)__tests__/","(^|/)spec/","(^|/)test_[^/]+$","_test\\.[^/]+$","\\.test\\.[^/]+$","_spec\\.[^/]+$","\\.spec\\.[^/]+$","(^|/)conftest\\.py$"]},
  {"name":"Docs","patterns":["\\.md$","\\.rst$","\\.txt$","^docs?/","^LICENSE","^CHANGELOG","^CONTRIBUTING","^AUTHORS"]},
  {"name":"Images","patterns":["\\.png$","\\.jpe?g$","\\.gif$","\\.svg$","\\.ico$","\\.webp$","\\.bmp$"]},
  {"name":"Config","patterns":["\\.ya?ml$","\\.toml$","\\.ini$","\\.cfg$","\\.conf$","\\.json$","(^|/)\\.env","(^|/)Makefile$","(^|/)Dockerfile","(^|/)\\.editorconfig$","(^|/)\\.gitignore$","\\.lock$"]},
  {"name":"Implementation","patterns":["."]}
]'

# Parse an optional YAML category config and print a JSON array.
# Prints nothing when the file is absent or unparseable.
load_category_config() {
	local config_path="${FILE_BREAKDOWN_CONFIG:-.github/file-breakdown.yml}"
	[[ -f "$config_path" ]] || return 0
	python3 -c '
import json, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
data = yaml.safe_load(sys.stdin)
if not isinstance(data, dict) or "categories" not in data:
    sys.exit(0)
cats = []
for name, patterns in data["categories"].items():
    if isinstance(patterns, list):
        cats.append({"name": name, "patterns": [str(p) for p in patterns]})
json.dump(cats, sys.stdout)
' <"$config_path" 2>/dev/null || true
}

# Merge user-defined categories with defaults.  User categories override
# same-named defaults; new categories are inserted before the catch-all.
merge_categories() {
	local user_json="$1"
	if [[ -z "$user_json" ]]; then
		printf '%s' "$DEFAULT_CATEGORIES"
		return
	fi
	jq -n --argjson defaults "$DEFAULT_CATEGORIES" '
		input as $user |
		($user | map({key: .name, value: .}) | from_entries) as $umap |
		($defaults | last) as $catchall |
		($defaults[:-1] | map(
			if $umap[.name] then $umap[.name] else . end
		)) as $merged |
		($user | map(
			select(.name as $n | $defaults | map(.name) | index($n) | not)
		)) as $new |
		$merged + $new + [$catchall]
	' <<<"$user_json"
}

# =============================================================================
# Step: fetch - Retrieve changed files for a PR as a single JSON array
# =============================================================================
step_fetch() {
	: "${GH_TOKEN:?GH_TOKEN is required}"
	: "${PR_NUMBER:?PR_NUMBER is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${PR_FILES_JSON:?PR_FILES_JSON is required}"

	if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
		echo "::error::PR_NUMBER must be numeric, got: ${PR_NUMBER}" >&2
		exit 1
	fi

	# --paginate emits one JSON array per page; merge them into a single array
	gh api --paginate \
		"repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100" |
		jq -s 'add // []' >"$PR_FILES_JSON"

	local count
	count=$(jq 'length' "$PR_FILES_JSON")
	echo "Fetched ${count} changed files for PR #${PR_NUMBER}"
}

# =============================================================================
# Step: generate - Render the markdown comment
# =============================================================================
step_generate() {
	: "${PR_FILES_JSON:?PR_FILES_JSON is required}"
	local max_rows="${MAX_ROWS:-50}"

	if [[ ! -f "$PR_FILES_JSON" ]]; then
		echo "::error::PR files payload not found: ${PR_FILES_JSON}" >&2
		exit 1
	fi
	if ! jq -e 'type == "array"' "$PR_FILES_JSON" >/dev/null 2>&1; then
		echo "::error::PR files payload is not a JSON array: ${PR_FILES_JSON}" >&2
		exit 1
	fi
	# Normalize: reject non-numeric/zero, strip leading zeros (jq --argjson
	# rejects "05"), and clamp to a hard cap so a huge max-rows cannot push
	# the rendered comment past GitHub's comment size limit.
	local max_rows_cap=500
	if ! [[ "$max_rows" =~ ^[0-9]+$ ]] || [[ "$max_rows" -eq 0 ]]; then
		max_rows=50
	else
		max_rows=$((10#$max_rows))
	fi
	if ((max_rows > max_rows_cap)); then
		max_rows=$max_rows_cap
	fi

	# Byte budget for the assembled comment body. GitHub rejects comment bodies
	# over ~65,536 characters; keep headroom below that so the row cap alone
	# cannot push a worst-case long-path PR past the limit and fail publish.
	local body_byte_budget=60000

	local categories_json
	categories_json="$(merge_categories "$(load_category_config)")"

	local repo build_url
	repo="${GITHUB_REPOSITORY:-unknown/unknown}"
	build_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}"

	local total_files total_add total_del
	total_files=$(jq 'length' "$PR_FILES_JSON")
	total_add=$(jq '[.[].additions] | add // 0' "$PR_FILES_JSON")
	total_del=$(jq '[.[].deletions] | add // 0' "$PR_FILES_JSON")

	local body
	if [[ "$total_files" -eq 0 ]]; then
		body="$(
			cat <<EOF
## PR File Breakdown

No files changed.

---

[View full build details](${build_url})

<sub>Generated by file breakdown workflow</sub>
EOF
		)"
	else
		local status_line
		status_line=$(jq -r \
			'group_by(.status) | map("\(length) \(.[0].status)") | join(", ")' \
			"$PR_FILES_JSON")

		# Classify files into semantic categories and build summary rows
		# with a Unicode distribution bar per category.
		local -a all_group_rows=()
		mapfile -t all_group_rows < <(jq -r --argjson cats "$categories_json" '
			def classify:
				.filename as $f |
				(first(
					$cats[] | select(.patterns | any(. as $p | try ($f | test($p)) catch false))
				).name) // "Other";
			def bar($pct):
				(($pct / 5 | round) | if . > 20 then 20 elif . < 0 then 0 else . end) as $blocks |
				(20 - $blocks) as $eblocks |
				([range($blocks)] | map("\u2588") | join("")) as $full |
				([range($eblocks)] | map("\u2591") | join("")) as $empty |
				"\($full)\($empty) \($pct)%";
			length as $total |
			map(. + {category: classify}) |
			group_by(.category) |
			sort_by(-(.|length), .[0].category) |
			.[] |
			(length) as $count |
			(map(.additions) | add // 0) as $add |
			(map(.deletions) | add // 0) as $del |
			(if $total > 0 then ($count * 100 / $total | floor) else 0 end) as $pct |
			"| \(.[0].category | gsub("\\|"; "\\|")) | \($count) | +\($add) | -\($del) | \(bar($pct)) |"
		' "$PR_FILES_JSON")
		local total_groups=${#all_group_rows[@]}

		# Render each candidate detail row (bounded by the row cap) as a single
		# neutralized line so rows can be dropped one-by-one to fit the budget.
		local -a all_rows=()
		mapfile -t all_rows < <(jq -r --argjson max "$max_rows" '
			def esc: gsub("[\r\n]"; " ") | gsub("\\|"; "\\|") | gsub("`"; "");
			.[:$max][]
			| "| `\(.filename | esc)` | \(.status) | +\(.additions) | -\(.deletions) |"
		' "$PR_FILES_JSON")
		local candidate_rows=${#all_rows[@]}

		# Assemble the body showing the first <shown> detail rows. When rows are
		# hidden, the note explains why: <size_forced> distinguishes the byte
		# budget from the plain row cap.
		assemble_body() {
			local shown="$1" size_forced="$2" shown_groups="$3" group_size_forced="$4"
			local group_rows="" detail_rows="" details_summary="Changed files" truncation_note=""
			if ((shown_groups > 0)); then
				printf -v group_rows '%s\n' "${all_group_rows[@]:0:shown_groups}"
				group_rows=${group_rows%$'\n'}
			fi
			if ((shown_groups < total_groups)); then
				local remaining_groups=$((total_groups - shown_groups))
				local group_reason="not shown"
				if ((group_size_forced)); then
					group_reason="dropped to keep this comment within GitHub's size limit"
				fi
				group_rows+=$'\n'"| _${remaining_groups} category(ies) ${group_reason}_ | — | — | — | — |"
				group_rows=${group_rows#$'\n'}
			fi
			if ((shown > 0)); then
				printf -v detail_rows '%s\n' "${all_rows[@]:0:shown}"
				detail_rows=${detail_rows%$'\n'}
			fi
			if ((shown < total_files)); then
				local remaining=$((total_files - shown))
				details_summary="Changed files (first ${shown} of ${total_files})"
				if ((size_forced)); then
					truncation_note=$'\n'"…and ${remaining} more file(s) not shown"
					truncation_note+=" (dropped to keep this comment within GitHub's size limit)."
				else
					truncation_note=$'\n'"…and ${remaining} more file(s) not shown."
				fi
			fi
			cat <<EOF
## PR File Breakdown

**${total_files} file(s) changed** (+${total_add} / -${total_del}) — ${status_line}

| Category | Files | Additions | Deletions | Distribution |
| --- | ---: | ---: | ---: | --- |
${group_rows}

<details>
<summary>${details_summary}</summary>

| File | Status | Additions | Deletions |
| --- | --- | ---: | ---: |
${detail_rows}
${truncation_note}

</details>

---

[View full build details](${build_url})

<sub>Generated by file breakdown workflow</sub>
EOF
		}

		# Start with the row-capped view, then shrink to satisfy the byte budget.
		local shown=$candidate_rows
		local shown_groups=$total_groups
		body="$(assemble_body "$shown" 0 "$shown_groups" 0)"
		if (($(printf '%s' "$body" | wc -c) > body_byte_budget)); then
			# Binary search for the largest row count whose body fits the budget.
			local lo=0 hi=$((candidate_rows - 1)) best=0 mid trial
			while ((lo <= hi)); do
				mid=$(((lo + hi) / 2))
				trial="$(assemble_body "$mid" 1 "$shown_groups" 0)"
				if (($(printf '%s' "$trial" | wc -c) <= body_byte_budget)); then
					best=$mid
					lo=$((mid + 1))
				else
					hi=$((mid - 1))
				fi
			done
			shown=$best
			body="$(assemble_body "$shown" 1 "$shown_groups" 0)"
			if (($(printf '%s' "$body" | wc -c) > body_byte_budget)); then
				# With zero detail rows, very many categories can still exceed
				# the budget. Drop category rows as the final shrink target.
				lo=0
				hi=$total_groups
				best=0
				shown=0
				while ((lo <= hi)); do
					mid=$(((lo + hi) / 2))
					trial="$(assemble_body "$shown" 1 "$mid" 1)"
					if (($(printf '%s' "$trial" | wc -c) <= body_byte_budget)); then
						best=$mid
						lo=$((mid + 1))
					else
						hi=$((mid - 1))
					fi
				done
				shown_groups=$best
				body="$(assemble_body "$shown" 1 "$shown_groups" 1)"
			fi
		fi
		unset -f assemble_body
	fi

	if [[ -n "${COMMENT_OUTPUT:-}" ]]; then
		printf '%s\n' "$body" >"$COMMENT_OUTPUT"
	else
		printf '%s\n' "$body"
	fi
}

# =============================================================================
# Dispatch
# =============================================================================
STEP="${STEP:-generate}"
case "$STEP" in
fetch)
	step_fetch
	;;
generate)
	step_generate
	;;
*)
	echo "::error::Unknown STEP: ${STEP} (expected fetch or generate)" >&2
	exit 1
	;;
esac
