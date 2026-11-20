#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/github/comment_sanitize.sh (#1676): the
# bash entry to the shared sanitiser and its fail-closed fallback.

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# A PATH with the tools the fallback needs and no python3.
no_python_path() {
	local bin="${BATS_TEST_TMPDIR}/nopy"
	mkdir -p "$bin"
	local tool
	for tool in bash cat tr sed jq dirname date awk grep head tail cut wc mktemp rm sort env od; do
		ln -sf "$(command -v "$tool")" "${bin}/${tool}"
	done
	printf '%s' "$bin"
}

@test "comment_sanitize: text from stdin is escaped, mention broken" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"; printf "%s" "@org/team <b>" | comment_sanitize text'
	assert_success
	assert_output '@&#8203;org/team &lt;b&gt;'
}

@test "comment_sanitize: a value is never read as an option" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"; printf "%s" "--nul" | comment_sanitize text'
	assert_success
	assert_output -- '--nul'
}

@test "comment_sanitize: --nul batches keep their order" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		mapfile -d "" out < <(printf "%s\0" "a|b" "" "#1" | comment_sanitize cell --nul)
		printf "[%s]\n" "${out[@]}"'
	assert_success
	assert_line --index 0 '[a\|b]'
	assert_line --index 1 '[]'
	assert_line --index 2 '[\#&#8203;1]'
}

@test "comment_sanitize: url is empty for a non-HTTPS URL" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"; printf "%s" "javascript:alert(1)" | comment_sanitize url'
	assert_success
	assert_output ''
}

@test "comment_sanitize: sourcing does not start python3" {
	local bin="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$bin"
	printf '#!/bin/sh\necho started >>"%s/started"\n' "$BATS_TEST_TMPDIR" >"${bin}/python3"
	chmod +x "${bin}/python3"
	run env PATH="${bin}:${PATH}" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"'
	assert_success
	assert [ ! -e "${BATS_TEST_TMPDIR}/started" ]
}

@test "comment_sanitize: without python3 inline text fails closed with a warning" {
	run env PATH="$(no_python_path)" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		printf "%s" "@org/team <b> www.x" | comment_sanitize text'
	assert_success
	assert_line --index 0 --partial '::warning::comment_sanitize: no python3'
	assert_line --index 1 '?org?team ?b? www?x'
}

@test "comment_sanitize: without python3 url gives nothing and fence keeps lines" {
	run env PATH="$(no_python_path)" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		printf "%s" "https://example.com/" | comment_sanitize url 2>/dev/null
		printf "%s" $'"'"'a`b\nc'"'"' | comment_sanitize fence 2>/dev/null'
	assert_success
	assert_output $'```\na?b\nc\n```'
}

@test "comment_sanitize: without python3 markdown only breaks comment openers" {
	run env PATH="$(no_python_path)" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		printf "%s" "**x** <!-- lgtm-ci:history:start -->" | comment_sanitize markdown 2>/dev/null'
	assert_success
	assert_output '**x** <!- - lgtm-ci:history:start -->'
}

@test "comment_sanitize: without python3 url, host and link succeed with nothing under set -e" {
	run env PATH="$(no_python_path)" REPORT_URL="" bash -c 'set -eo pipefail
		source "$LIB_DIR/github/comment_sanitize.sh"
		a="$(comment_sanitize url --env REPORT_URL 2>/dev/null)"
		b="$(printf "%s" "https://example.com/" | comment_sanitize host 2>/dev/null)"
		c="$(printf "%s" "https://example.com/" | comment_sanitize link 2>/dev/null)"
		printf "[%s][%s][%s] carried on" "$a" "$b" "$c"'
	assert_success
	assert_output '[][][] carried on'
}

@test "comment_sanitize: without python3 a --nul batch keeps every record, reduced" {
	run env PATH="$(no_python_path)" bash -c 'set -eo pipefail
		source "$LIB_DIR/github/comment_sanitize.sh"
		mapfile -d "" out < <(printf "%s\0" "unit-tests" "" "shard 0 <b>" | comment_sanitize text --nul 2>/dev/null)
		printf "%s|" "${#out[@]}" "${out[@]}"'
	assert_success
	assert_output '3|unit-tests||shard 0 ?b?|'
}

@test "comment_sanitize: without python3 a --nul url batch gives one empty record each" {
	run env PATH="$(no_python_path)" bash -c 'set -eo pipefail
		source "$LIB_DIR/github/comment_sanitize.sh"
		mapfile -d "" out < <(printf "%s\0" "https://a.example/" "x" | comment_sanitize url --nul 2>/dev/null)
		printf "%s|" "${#out[@]}" "${out[@]}"'
	assert_success
	assert_output '2|||'
}

@test "comment_sanitize: a --nul last record without its NUL still counts" {
	run env PATH="$(no_python_path)" bash -c 'set -eo pipefail
		source "$LIB_DIR/github/comment_sanitize.sh"
		mapfile -d "" out < <(printf "a\0b" | comment_sanitize text --nul 2>/dev/null)
		printf "%s|" "${#out[@]}" "${out[@]}"'
	assert_success
	assert_output '2|a|b|'
}

@test "comment_sanitize: without python3 a --json cell-code batch stays code spans" {
	run env PATH="$(no_python_path)" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		printf "%s" "[\"a|b\",\"c\"]" | comment_sanitize cell-code --json 2>/dev/null'
	assert_success
	assert_output '["`a?b`","`c`"]'
}

@test "comment_sanitize: without python3 report mode keeps lines and reduces the rest" {
	run env PATH="$(no_python_path)" bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		printf "%s" $'"'"'## a @b\nc'"'"' | comment_sanitize report 2>/dev/null'
	assert_success
	assert_output $'?? a ?b\nc'
}

@test "comment_read_count and comment_read_decimal: only plain numbers pass; the rest is listed" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		comment_read_count A a 0012
		comment_read_count B b -1 2>/dev/null
		comment_read_count C c 1234567890 2>/dev/null
		comment_read_count D d "1 | x" 2>/dev/null
		comment_read_decimal E e 85.71428571428571
		comment_read_decimal F f n/a 2>/dev/null
		comment_read_decimal G g n/a n/a
		printf "%s " "$A" "$B" "$C" "$D" "$E" "$F" "$G" "|" "${COMMENT_UNREADABLE[@]}"
		printf "\n"
		comment_unreadable_lines'
	assert_success
	assert_line --index 0 '12 0 0 0 85.71428571428571 0 n/a | b c d f '
	assert_line --index 1 "⚠️ The report's \`b\` value is not a number; see the job log."
	assert_line --index 4 "⚠️ The report's \`f\` value is not a number; see the job log."
}

@test "comment_read_decimal: a keep word that is not a plain lower-case word is ignored (#1676)" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		comment_read_decimal V v "<b>@x" "<b>@x" 2>/dev/null
		comment_read_decimal W w "N/A" "N/A" 2>/dev/null
		printf "%s %s | %s\n" "$V" "$W" "${COMMENT_UNREADABLE[*]}"'
	assert_success
	assert_output '0 0 | v w'
}

@test "comment_read_count: the warning names the label, never the value" {
	run bash -c 'source "$LIB_DIR/github/comment_sanitize.sh"
		comment_read_count V "stats.failed" $'"'"'::error::x\n@team'"'"''
	assert_success
	assert_output "::warning::The report's stats.failed value is not a number; the comment says so"
}

@test "comment_sanitize: a real renderer without python3 runs under set -e, with and without a URL" {
	local coverage="${BATS_TEST_TMPDIR}/coverage.json" outputs="${BATS_TEST_TMPDIR}/outputs"
	printf '%s' '{"total":{"lines":{"pct":85.5},"branches":{"pct":75},"functions":{"pct":90},"statements":{"pct":85}}}' \
		>"$coverage"
	local url
	for url in "" "https://o.github.io/r/report/"; do
		: >"$outputs"
		run env PATH="$(no_python_path)" GITHUB_OUTPUT="$outputs" COVERAGE_FILE="$coverage" \
			REPORT_URL="$url" TEST_SUITE_NAME="Unit Tests" \
			bash "${PROJECT_ROOT}/scripts/ci/actions/generate-coverage-comment.sh"
		assert_success
		assert_file_contains_literal "$outputs" "## 📊 Code Coverage Report — Unit Tests"
		assert_file_contains_literal "$outputs" "| **Lines** | 🟢 86% | 80% |"
		run grep -c "View Detailed Report" "$outputs"
		assert_output "0"
	done
}
