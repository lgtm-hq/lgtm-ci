#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract test (#1310). github/codeql-action/upload-sarif and
#          github/codeql-action/analyze look up the current workflow run through
#          the Actions API, which needs `actions: read` on GITHUB_TOKEN. In
#          private repositories a job without it gets a 403 at upload time.
#          Every job that runs either action (directly, or through the
#          scan-vulnerabilities composite that uploads SARIF) must therefore
#          declare `actions: read` in its job-level `permissions:` block.

load "../../helpers/common"

# Print "<workflow>:<job>" for every job that runs a SARIF-uploading action
# but whose job-level permissions block lacks `actions: read`.
_jobs_missing_actions_read() {
	local workflow="$1"
	awk -v wf="$(basename "$workflow")" '
		function flush() {
			if (job != "" && uploads && !has_actions) print wf ":" job
		}
		/^[a-z_-]+:/ { flush(); job = ""; in_jobs = ($0 ~ /^jobs:/); uploads = 0; has_actions = 0; in_perms = 0; next }
		in_jobs && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
			flush()
			job = $1; sub(/:$/, "", job)
			uploads = 0; has_actions = 0; in_perms = 0
			next
		}
		/^    permissions:[[:space:]]*$/ { in_perms = 1; next }
		in_perms && /^      actions:[[:space:]]+(read|write)/ { has_actions = 1; next }
		in_perms && /^      (#|[a-z-]+:)/ { next }
		in_perms { in_perms = 0 }
		/^[[:space:]]*#/ { next }
		/uses:[[:space:]]+github\/codeql-action\/(upload-sarif|analyze)@/ { uploads = 1 }
		/uses:[[:space:]]+[^[:space:]]*\/actions\/scan-vulnerabilities/ { uploads = 1 }
		END { flush() }
	' "$workflow"
}

@test "SARIF upload: the detector flags a job lacking actions: read" {
	local fixture="${BATS_TEST_TMPDIR}/wf.yml"
	cat >"$fixture" <<'EOF'
jobs:
  bad:
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: github/codeql-action/upload-sarif@abc # v4
  good:
    permissions:
      actions: read
      contents: read
    steps:
      - uses: github/codeql-action/analyze@abc # v4
EOF
	run _jobs_missing_actions_read "$fixture"
	assert_success
	assert_output "wf.yml:bad"
}

@test "SARIF upload: every job running codeql-action upload-sarif or analyze declares actions: read" {
	local workflow missing="" found=0 out
	for workflow in "${PROJECT_ROOT}"/.github/workflows/*.yml; do
		if grep -qE 'codeql-action/(upload-sarif|analyze)@|/actions/scan-vulnerabilities' "$workflow"; then
			found=$((found + 1))
		fi
		out="$(_jobs_missing_actions_read "$workflow")"
		[[ -z "$out" ]] || missing+="${out}"$'\n'
	done
	# Guard against the scan silently matching nothing.
	((found >= 5))
	if [[ -n "$missing" ]]; then
		echo "jobs running SARIF upload without job-level 'actions: read' (#1310):" >&2
		printf '%s' "$missing" >&2
		return 1
	fi
}

@test "SARIF upload: the Docker scan and CodeQL jobs named in #1310 are covered" {
	local pairs=(
		"reusable-docker-build.yml:build"
		"reusable-docker-build.yml:scan"
		"reusable-docker-multiplatform.yml:upload-scan-results"
		"reusable-docker-multiplatform-publish.yml:scan"
		"reusable-codeql.yml:codeql"
		"reusable-scorecards.yml:scorecards"
		"reusable-sbom.yml:sbom"
	)
	local pair file job
	for pair in "${pairs[@]}"; do
		file="${pair%%:*}"
		job="${pair##*:}"
		run awk -v job="$job" '
			$0 ~ "^  " job ":[[:space:]]*$" { in_job = 1; next }
			in_job && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { exit }
			in_job && /^      actions:[[:space:]]+read/ { found = 1 }
			END { exit found ? 0 : 1 }
		' "${PROJECT_ROOT}/.github/workflows/${file}"
		assert_success
	done
}
