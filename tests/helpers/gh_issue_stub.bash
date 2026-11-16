#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: A gh stub for the tracking-issue scripts (lib/github/tracking_issue.sh)
#
# Usage: In your .bats file:
#   load "../../helpers/gh_issue_stub"
#   setup() { ...; install_gh_issue_stub; }
#
# gh behaves like the real CLI where the scripts depend on it:
# `api --paginate repos/<repo>/issues?...` splits STUB_ISSUES (a JSON array
# of open issues) into 100-issue pages and applies the script's own --jq
# filter to each page with jq, as gh does (without --paginate only the first
# page is returned); `issue view --json body --jq <filter>` applies the
# filter to that issue's body. A broken filter therefore fails the tests.
# `api meta` prints $FIXTURE (results-hosts-drift). STUB_LIST_FAIL makes the
# listing fail. Every call is logged to GH_CALLS so tests can assert which
# writes ran.

# Install the stub first on PATH and reset GH_CALLS and STUB_ISSUES.
install_gh_issue_stub() {
	export GH_CALLS="${BATS_TEST_TMPDIR}/gh_calls"
	export STUB_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
	: >"$GH_CALLS"
	echo '[]' >"$STUB_ISSUES"
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
filter="" paginate=0 endpoint="" number=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
	--jq | -q) filter="${args[i + 1]}" ;;
	--paginate) paginate=1 ;;
	repos/*) endpoint="${args[i]}" ;;
	esac
done
case "$1 $2" in
"api meta") cat "$FIXTURE" ;;
"api --paginate" | "api repos/"*)
	[[ "$endpoint" == "repos/${GITHUB_REPOSITORY}/issues?state=open&per_page=100" ]] || exit 1
	[[ -z "${STUB_LIST_FAIL:-}" ]] || exit 1
	[[ -n "$filter" ]] || exit 1
	total="$(jq length "$STUB_ISSUES")"
	pages=$(((total + 99) / 100))
	((pages > 0)) || pages=1
	((paginate)) || pages=1
	for ((p = 0; p < pages; p++)); do
		jq -c --argjson p "$p" '.[$p * 100:($p + 1) * 100]' "$STUB_ISSUES" | jq -r "$filter"
	done
	;;
"issue view")
	number="$3"
	jq -c --argjson n "$number" '.[] | select(.number == $n) | {body}' "$STUB_ISSUES" | jq -r "$filter"
	;;
"issue create")
	[[ -z "${STUB_CREATE_FAIL:-}" ]] || exit 1
	echo "https://github.com/lgtm-hq/lgtm-ci/issues/77"
	;;
"issue edit" | "issue comment" | "issue close") ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# add_issue <number> <login> <type> <body|null>: append one open issue.
add_issue() {
	local body_json='null'
	[[ "$4" == "null" ]] || body_json="$(jq -Rs . <<<"$4")"
	jq --argjson n "$1" --arg l "$2" --arg t "$3" --argjson b "$body_json" \
		'. + [{number: $n, user: {login: $l, type: $t}, body: $b}]' \
		"$STUB_ISSUES" >"${STUB_ISSUES}.tmp"
	mv "${STUB_ISSUES}.tmp" "$STUB_ISSUES"
}

# add_filler <count>: append unrelated open issues (numbers from 1000).
add_filler() {
	jq --argjson c "$1" \
		'. + [range(1000; 1000 + $c) | {number: ., user: {login: "someone", type: "User"}, body: "unrelated"}]' \
		"$STUB_ISSUES" >"${STUB_ISSUES}.tmp"
	mv "${STUB_ISSUES}.tmp" "$STUB_ISSUES"
}

# assert_new_issue_only: exactly one create, no other issue write or read.
assert_new_issue_only() {
	run grep -c '^issue create' "$GH_CALLS"
	assert_output "1"
	run grep -E '^issue (edit|comment|close|view)' "$GH_CALLS"
	assert_failure
}
