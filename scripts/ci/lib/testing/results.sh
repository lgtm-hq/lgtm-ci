#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: results.v1 contract helpers (#1080): build, validate, write and read
#          the normalized results.json every runner emits.
#
# Usage:
#   source "scripts/ci/lib/testing/results.sh"
#   results_v1_build >results.json          # from the RESULTS_* / TESTS_* env below
#   results_v1_validate results.json        # schema check (jq, schemas/results.v1.json)
#   results_v1_write results/pytest/3.12/results.json
#   results_v1_github_outputs results.json  # tests-passed=... etc. to GITHUB_OUTPUT
#
# Builder inputs (environment):
#   RESULTS_TOOL            (required) native tool: pytest, vitest, playwright, ...
#   RESULTS_RUNNER          (required) lgtm-ci runner id: run-pytest, run-vitest, ...
#   RESULTS_SOURCE_VERSION  tooling revision (default: LGTM_CI_TOOLING_SHA or "unknown")
#   RESULTS_PARSE_STATUS    ok (default) | missing | invalid | incomplete -
#                           native report state (incomplete: a sharded run
#                           lost a shard to a cancel or timeout, #1531)
#   RESULTS_INCOMPLETE      reason the counts and coverage are partial (optional;
#                           written as the document's "incomplete" property)
#   RESULTS_TAP_PLANNED, RESULTS_TAP_REPORTED  informational TAP plan
#                           mismatch (optional; both or neither; written as
#                           "tap_plan" when the counted results differ from
#                           the summed plans; never changes the status)
#   RESULTS_STATUS         explicit status; overrides the rule below (audits
#                           report a clean scan as passed, not no-tests)
#   TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL  counts (default 0)
#   TESTS_XFAILED, TESTS_XPASSED  expected failures and unexpected passes
#                           (optional, #1685; written as counts.xfailed and
#                           counts.xpassed only when set; total includes them)
#   RESULTS_EXPECTED_FAILURES_FILE  JSON file (or readable stream, such as a
#                           process substitution) holding an array of
#                           {"id": ..., "reason": ...} in report order
#                           (optional, #1685). It reaches jq as a file,
#                           never as an argument (one argument is limited to
#                           128 KiB on Linux). The builder bounds it into
#                           "expected_failures": the first 50 entries with a
#                           non-empty string id, id and reason cut to 500
#                           characters, and the count of the rest in omitted.
#                           A file that is missing, not such an array or
#                           without one usable entry is ignored.
#   RESULTS_EXPECTED_FAILURES_OMITTED  entries the producer already left out
#                           of that file (optional, digits; #1686); added to
#                           omitted.
#   TESTS_DURATION_MS       whole milliseconds (default 0)
#   EXIT_CODE               native tool exit code (optional; feeds status)
#   COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS
#                           percentages; a value that is empty, "n/a" or not a
#                           number from 0 to 100 is omitted (#1692: 500 is no
#                           percentage, and pytest/vitest pass raw values). No lines => no
#                           coverage object.
#   RESULTS_ARTIFACTS       newline-separated "kind=path" entries (optional)
#   MATRIX_KEY, MATRIX_VALUE  matrix coordinate (optional; both or neither)
#
# Status rule (documented in docs/workflow-contract.md, Results contract):
#   error     RESULTS_PARSE_STATUS is missing, invalid or incomplete, or a count is not a
#             whole number of at most nine digits (a native report with
#             failed: -1 is not a passing one, and a longer number is never
#             read through bash's 64-bit arithmetic, which wraps 2^64 to 0;
#             TESTS_XFAILED and TESTS_XPASSED count when set)
#   failed    TESTS_FAILED > 0, or EXIT_CODE set and non-zero
#   no-tests  TESTS_TOTAL == 0
#   passed    otherwise

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_RESULTS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_RESULTS_LOADED=1

_LGTM_CI_TESTING_RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

# Schema location: the repository root for a full checkout, which the
# tooling sparse-checkout (schemas/ listed in sparse-checkout-extra) mirrors.
# RESULTS_V1_SCHEMA overrides it.
RESULTS_V1_SCHEMA_DEFAULT="$_LGTM_CI_TESTING_RESULTS_DIR/../../../../schemas/results.v1.json"
export RESULTS_V1_SCHEMA_DEFAULT

# Relative path a runner leg writes its document to.
# Usage: results_v1_path <runner> <matrix-value>
# Output: results/<runner>/<matrix-value>/results.json
results_v1_path() {
	local runner="${1:?runner is required}"
	local leg="${2:-default}"
	[[ -z "$leg" ]] && leg="default"
	printf 'results/%s/%s/results.json' "$runner" "$leg"
}

# Resolve the schema file; prints its path, fails when absent.
results_v1_schema() {
	local schema="${RESULTS_V1_SCHEMA:-$RESULTS_V1_SCHEMA_DEFAULT}"
	if [[ ! -f "$schema" ]]; then
		local hint=""
		if [[ -z "${RESULTS_V1_SCHEMA:-}" ]]; then
			hint=" (add schemas/ to sparse-checkout-extra of the calling job)"
		fi
		echo "results_v1: schema not found: ${schema}${hint}" >&2
		return 1
	fi
	printf '%s' "$schema"
}

# Internal: derive the status from the builder inputs.
_results_v1_status() {
	local parse_status="${RESULTS_PARSE_STATUS:-ok}"
	local failed="${TESTS_FAILED:-0}"
	local total="${TESTS_TOTAL:-0}"
	local exit_code="${EXIT_CODE:-}"

	case "$parse_status" in
	missing | invalid | incomplete)
		echo "error"
		return 0
		;;
	esac
	# Nine digits at most, checked as text before any arithmetic below: bash
	# integers are 64-bit and wrap (2^64 reads as 0), so a longer count could
	# otherwise turn a failed run into a pass (#1702). The same bound as the
	# comment's comment_read_count.
	local count
	for count in "${TESTS_PASSED:-0}" "${TESTS_FAILED:-0}" "${TESTS_SKIPPED:-0}" "${TESTS_TOTAL:-0}" \
		"${TESTS_XFAILED:-0}" "${TESTS_XPASSED:-0}"; do
		if [[ ! "$count" =~ ^[0-9]{1,9}$ ]]; then
			echo "error"
			return 0
		fi
	done
	if [[ -n "${RESULTS_STATUS:-}" ]]; then
		echo "$RESULTS_STATUS"
		return 0
	fi
	if [[ "$failed" =~ ^[0-9]{1,9}$ && "$((10#$failed))" -gt 0 ]]; then
		echo "failed"
	elif [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
		echo "failed"
	elif [[ ! "$total" =~ ^[0-9]{1,9}$ || "$((10#$total))" -eq 0 ]]; then
		echo "no-tests"
	else
		echo "passed"
	fi
}

# Internal: print a coverage percentage as a JSON number, or null when it is
# not a number from 0 to 100 (#1692).
_results_v1_percent_or_null() {
	local value="${1:-}"
	if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$value" 'BEGIN { exit !(p <= 100) }'; then
		printf '%s' "$value"
	else
		printf 'null'
	fi
}

# Internal: print a value as a JSON number or null (non-numeric => null).
_results_v1_num_or_null() {
	local value="${1:-}"
	if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
		printf '%s' "$value"
	else
		printf 'null'
	fi
}

# Internal: print a non-negative integer or 0 (anything else => 0).
_results_v1_uint() {
	local value="${1:-}"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s' "$value"
	else
		printf '0'
	fi
}

# Internal: tell whether a coverage value was given but is no percentage:
# "invalid" (the shared readers' verdict) or a number outside 0 to 100. Such a
# value is unreadable (#1692), never "not measured": a gate reading the
# document must not pass on what is left. Empty, "n/a" and istanbul's
# "Unknown" are not measured, as before: the whole-report check
# (coverage_report_readable) lets "Unknown" through only as istanbul's blank
# metric (a total and a covered count of 0, an empty coverage map).
_results_v1_coverage_value_unreadable() {
	local value="${1:-}"
	[[ "$value" == invalid ]] && return 0
	[[ "$value" =~ ^[-+0-9.eE]+$ ]] && [[ "$(_results_v1_percent_or_null "$value")" == null ]]
}

# Internal: tell whether any COVERAGE_* value is unreadable (see above).
_results_v1_coverage_unreadable() {
	local value
	for value in "${COVERAGE_LINES:-}" "${COVERAGE_BRANCHES:-}" "${COVERAGE_FUNCTIONS:-}"; do
		_results_v1_coverage_value_unreadable "$value" && return 0
	done
	return 1
}

# Internal: coverage object as JSON, or null when no lines value was given.
_results_v1_coverage_json() {
	local lines branches functions
	lines="$(_results_v1_percent_or_null "${COVERAGE_LINES:-}")"
	branches="$(_results_v1_percent_or_null "${COVERAGE_BRANCHES:-}")"
	functions="$(_results_v1_percent_or_null "${COVERAGE_FUNCTIONS:-}")"
	if [[ "$lines" == "null" ]]; then
		printf 'null'
		return 0
	fi
	jq -cn \
		--argjson lines "$lines" \
		--argjson branches "$branches" \
		--argjson functions "$functions" \
		'{lines: $lines}
		+ (if $branches == null then {} else {branches: $branches} end)
		+ (if $functions == null then {} else {functions: $functions} end)'
}

# Internal: artifacts array as JSON from RESULTS_ARTIFACTS ("kind=path" lines).
_results_v1_artifacts_json() {
	local line kind path
	local entries="[]"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		kind="${line%%=*}"
		path="${line#*=}"
		[[ -z "$kind" || -z "$path" || "$kind" == "$line" ]] && continue
		entries="$(jq -c --arg kind "$kind" --arg path "$path" '. + [{kind: $kind, path: $path}]' <<<"$entries")"
	done <<<"${RESULTS_ARTIFACTS:-}"
	printf '%s' "$entries"
}

# Most expected failures a document lists, and the most characters of a test
# id or reason (#1685). The schema states the same limits.
RESULTS_V1_XFAIL_MAX_TESTS=50
RESULTS_V1_XFAIL_MAX_CHARS=500
export RESULTS_V1_XFAIL_MAX_TESTS RESULTS_V1_XFAIL_MAX_CHARS

# jq program: bound a raw array of {id, reason} entries into the
# expected_failures object. Entries without a non-empty string id are
# dropped (not counted); a reason that is not a string becomes "". A string
# longer than $chars keeps $chars - 1 characters and an ellipsis.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _RESULTS_V1_JQ_XFAIL_BOUND <<'JQ' || true
def cut($n): if length > $n then .[0:($n - 1)] + "\u2026" else . end;
if type != "array" then null
else
  [ .[] | objects
    | select((.id | type) == "string" and (.id | length) > 0)
    | {id: (.id | cut($chars)),
       reason: (if (.reason | type) == "string" then .reason | cut($chars) else "" end)} ]
  | if length == 0 then null
    else {tests: .[0:$max], omitted: (([length - $max, 0] | max) + $extra)} end
end
JQ
export _RESULTS_V1_JQ_XFAIL_BOUND

# Internal: expected_failures object as JSON from RESULTS_EXPECTED_FAILURES_FILE,
# or null (no file, not an array). Usage: _results_v1_xfail_json
_results_v1_xfail_json() {
	local file="${RESULTS_EXPECTED_FAILURES_FILE:-}"
	if [[ -z "$file" || -d "$file" || ! -r "$file" ]]; then
		printf 'null'
		return 0
	fi
	local extra="${RESULTS_EXPECTED_FAILURES_OMITTED:-0}"
	[[ "$extra" =~ ^[0-9]{1,9}$ ]] || extra=0
	jq -c --argjson max "$RESULTS_V1_XFAIL_MAX_TESTS" --argjson chars "$RESULTS_V1_XFAIL_MAX_CHARS" \
		--argjson extra "$((10#$extra))" \
		"$_RESULTS_V1_JQ_XFAIL_BOUND" "$file" 2>/dev/null || printf 'null'
}

# Internal: a count as JSON when it was given as a whole number of at most
# nine digits, or null (unset, empty, malformed or longer: the status is
# error then, see above). Checked as text first, so 10#$value never wraps.
_results_v1_opt_uint() {
	local value="${1:-}"
	if [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
		printf '%s' "$((10#$value))"
	else
		printf 'null'
	fi
}

# Build a results.v1 document on stdout from the environment (see header).
results_v1_build() {
	local tool="${RESULTS_TOOL:?RESULTS_TOOL is required}"
	local runner="${RESULTS_RUNNER:?RESULTS_RUNNER is required}"
	local version="${RESULTS_SOURCE_VERSION:-${LGTM_CI_TOOLING_SHA:-unknown}}"
	[[ -z "$version" ]] && version="unknown"
	local status coverage artifacts exit_code matrix coverage_unreadable=false
	status="$(_results_v1_status)"
	coverage="$(_results_v1_coverage_json)"
	# Coverage given but unreadable (#1692): the document says error and has
	# no coverage object, and the builder fails, so no parse step publishes
	# a coverage-percent a gate could pass on.
	if _results_v1_coverage_unreadable; then
		coverage_unreadable=true
		status="error"
		coverage="null"
		echo "::error::The coverage report is unreadable (a metric is not a percentage from 0 to 100); no coverage is recorded" >&2
	fi
	artifacts="$(_results_v1_artifacts_json)"
	exit_code="$(_results_v1_num_or_null "${EXIT_CODE:-}")"
	if [[ "$exit_code" != "null" && ! "$exit_code" =~ ^[0-9]+$ ]]; then
		exit_code="null"
	fi
	matrix="null"
	if [[ -n "${MATRIX_KEY:-}" && -n "${MATRIX_VALUE:-}" ]]; then
		matrix="$(jq -cn --arg key "$MATRIX_KEY" --arg value "$MATRIX_VALUE" '{key: $key, value: $value}')"
	fi

	jq -n \
		--arg tool "$tool" \
		--arg status "$status" \
		--argjson passed "$(_results_v1_uint "${TESTS_PASSED:-0}")" \
		--argjson failed "$(_results_v1_uint "${TESTS_FAILED:-0}")" \
		--argjson skipped "$(_results_v1_uint "${TESTS_SKIPPED:-0}")" \
		--argjson total "$(_results_v1_uint "${TESTS_TOTAL:-0}")" \
		--argjson duration "$(_results_v1_uint "${TESTS_DURATION_MS:-0}")" \
		--argjson coverage "$coverage" \
		--argjson artifacts "$artifacts" \
		--arg runner "$runner" \
		--arg version "$version" \
		--argjson matrix "$matrix" \
		--argjson exit_code "$exit_code" \
		--arg incomplete "${RESULTS_INCOMPLETE:-}" \
		--argjson tap_plan "$(_results_v1_tap_plan_json)" \
		--argjson xfailed "$(_results_v1_opt_uint "${TESTS_XFAILED:-}")" \
		--argjson xpassed "$(_results_v1_opt_uint "${TESTS_XPASSED:-}")" \
		--slurpfile xfail_doc <(_results_v1_xfail_json) \
		'($xfail_doc[0] // null) as $xfail
		| {
			tool: $tool,
			status: $status,
			counts: ({passed: $passed, failed: $failed, skipped: $skipped, total: $total}
				+ (if $xfailed == null then {} else {xfailed: $xfailed} end)
				+ (if $xpassed == null then {} else {xpassed: $xpassed} end)),
			duration_ms: $duration
		}
		+ (if $coverage == null then {} else {coverage: $coverage} end)
		+ {artifacts: $artifacts, source: {runner: $runner, version: $version}}
		+ (if $matrix == null then {} else {matrix: $matrix} end)
		+ (if $exit_code == null then {} else {exit_code: $exit_code} end)
		+ (if $incomplete == "" then {} else {incomplete: $incomplete} end)
		+ (if $tap_plan == null then {} else {tap_plan: $tap_plan} end)
		+ (if $xfail == null then {} else {expected_failures: $xfail} end)' || return 1
	[[ "$coverage_unreadable" == false ]]
}

# Internal: informational TAP plan mismatch as JSON, or null (#1531, #1539).
_results_v1_tap_plan_json() {
	local planned="${RESULTS_TAP_PLANNED:-}" reported="${RESULTS_TAP_REPORTED:-}"
	if [[ "$planned" =~ ^[0-9]+$ && "$reported" =~ ^[0-9]+$ ]]; then
		printf '{"planned":%s,"reported":%s}' "$planned" "$reported"
	else
		printf 'null'
	fi
}

# jq program: a deliberately small JSON Schema interpreter driven by the
# schema file itself, so the schema stays the single source of truth without
# a second validator binary to pin (see docs/workflow-contract.md for why).
# Supported keywords: type, properties, required, additionalProperties
# (false), enum, minimum, maximum, minLength, maxLength, pattern, items,
# maxItems, $ref (local #/$defs/... only). String lengths count characters
# (code points), as JSON Schema does. Any other validation keyword in the schema is an error,
# so a schema edit that this interpreter does not understand fails loudly
# instead of validating nothing.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _RESULTS_V1_JQ_VALIDATOR <<'JQ' || true
def known_keywords:
  ["$schema","$id","$defs","title","description","type","properties",
   "required","additionalProperties","enum","minimum","maximum","minLength",
   "maxLength","pattern","items","maxItems","$ref"];

def resolve($schema; $root):
  if ($schema | type) == "object" and ($schema | has("$ref")) then
    ($schema["$ref"] | ltrimstr("#/") | split("/")) as $p
    | ($root | getpath($p)) as $target
    | if $target == null then error("unresolvable $ref \($schema["$ref"])") else $target end
  else $schema end;

def type_ok($t; $v):
  if $t == "integer" then (($v | type) == "number" and ($v == ($v | floor)))
  elif $t == "number" then ($v | type) == "number"
  else ($v | type) == $t end;

def validate($schema; $v; $path; $root):
  resolve($schema; $root) as $s
  | ($s | keys - known_keywords) as $unknown
  | if ($unknown | length) > 0 then error("unsupported schema keyword(s) at \($path): \($unknown | join(", "))") else . end
  | (
      if ($s | has("type")) then
        ([$s.type] | flatten) as $types
        | if any($types[]; type_ok(.; $v)) then empty
          else "\($path): expected \($types | join("|")), got \($v | type)" end
      else empty end
    ),
    (
      if ($s | has("enum")) and (any($s.enum[]; . == $v) | not) then
        "\($path): must be one of \($s.enum | map(tojson) | join(", "))"
      else empty end
    ),
    (
      if ($s | has("minimum")) and ($v | type) == "number" and $v < $s.minimum then
        "\($path): must be >= \($s.minimum)"
      else empty end
    ),
    (
      if ($s | has("maximum")) and ($v | type) == "number" and $v > $s.maximum then
        "\($path): must be <= \($s.maximum)"
      else empty end
    ),
    (
      if ($s | has("minLength")) and ($v | type) == "string" and ($v | length) < $s.minLength then
        "\($path): must be at least \($s.minLength) character(s)"
      else empty end
    ),
    (
      if ($s | has("maxLength")) and ($v | type) == "string" and ($v | length) > $s.maxLength then
        "\($path): must be at most \($s.maxLength) character(s)"
      else empty end
    ),
    (
      if ($s | has("maxItems")) and ($v | type) == "array" and ($v | length) > $s.maxItems then
        "\($path): must have at most \($s.maxItems) item(s)"
      else empty end
    ),
    (
      if ($s | has("pattern")) and ($v | type) == "string" and (($v | test($s.pattern)) | not) then
        "\($path): must match \($s.pattern)"
      else empty end
    ),
    (
      if ($v | type) == "object" then
        (
          ($s.required // [])[] | . as $name
          | select(($v | has($name)) | not)
          | "\($path): missing required property \($name)"
        ),
        (
          $v | to_entries[] | . as $e
          | if (($s.properties // {}) | has($e.key)) then
              validate($s.properties[$e.key]; $e.value; "\($path).\($e.key)"; $root)
            elif ($s.additionalProperties == false) then
              "\($path): unexpected property \($e.key)"
            else empty end
        )
      else empty end
    ),
    (
      if ($v | type) == "array" and ($s | has("items")) then
        $v | to_entries[] | validate($s.items; .value; "\($path)[\(.key)]"; $root)
      else empty end
    );

[validate($schema; .; "$"; $schema)]
JQ
export _RESULTS_V1_JQ_VALIDATOR

# jq program: preflight the whole schema file, independent of any instance,
# so an unsupported keyword under an optional property the instance omits
# (or a $ref carrying sibling constraints, which this interpreter would
# drop) is a hard error rather than a silently weaker check.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _RESULTS_V1_JQ_PREFLIGHT <<'JQ' || true
def known_keywords:
  ["$schema","$id","$defs","title","description","type","properties",
   "required","additionalProperties","enum","minimum","maximum","minLength",
   "maxLength","pattern","items","maxItems","$ref"];
def schema_nodes:
  .. | objects | select(has("type") or has("$ref") or has("properties") or has("items") or has("enum"));
(
  [schema_nodes | (keys - known_keywords)[]] | unique
  | if length > 0 then "unsupported schema keyword(s): \(join(", "))" else empty end
),
(
  [schema_nodes | select(has("$ref")) | (keys - ["$ref","description"])[]] | unique
  | if length > 0 then "$ref with sibling keyword(s) is not supported: \(join(", "))" else empty end
),
(
  [schema_nodes | select(has("$ref")) | .["$ref"] | select(test("^#/[$]defs/[A-Za-z0-9_-]+$") | not)] | unique
  | if length > 0 then "only local #/$defs/<name> references are supported: \(join(", "))" else empty end
),
(
  [schema_nodes | select(has("additionalProperties")) | .additionalProperties | select(type != "boolean")] | length
  | if . > 0 then "additionalProperties must be a boolean (a schema value would be ignored)" else empty end
)
JQ
export _RESULTS_V1_JQ_PREFLIGHT

# Fail when the schema uses anything the interpreter does not implement.
# Usage: results_v1_schema_preflight <schema>
results_v1_schema_preflight() {
	local schema="${1:?schema is required}"
	local problems
	if ! problems="$(jq -r "$_RESULTS_V1_JQ_PREFLIGHT" "$schema" 2>&1)"; then
		echo "results_v1: schema preflight failed on ${schema}: ${problems}" >&2
		return 2
	fi
	if [[ -n "$problems" ]]; then
		echo "results_v1: schema ${schema}: ${problems}" >&2
		return 2
	fi
	return 0
}

# Validate a results document against the schema.
# Usage: results_v1_validate <file> [schema]
# Returns 0 when valid; 1 with one "<file>: <message>" line per violation on
# stderr; 2 when the file or schema is missing or not JSON.
results_v1_validate() {
	local file="${1:-}"
	local schema="${2:-}"
	if [[ -z "$schema" ]]; then
		schema="$(results_v1_schema)" || return 2
	fi
	if [[ ! -f "$file" ]]; then
		echo "results_v1: file not found: ${file}" >&2
		return 2
	fi
	if ! jq -e 'true' "$file" >/dev/null 2>&1; then
		echo "results_v1: not valid JSON: ${file}" >&2
		return 2
	fi
	# jq would validate each value of a concatenated stream separately.
	if [[ "$(jq -s 'length' "$file" 2>/dev/null)" != "1" ]]; then
		echo "results_v1: expected exactly one JSON document: ${file}" >&2
		return 2
	fi
	results_v1_schema_preflight "$schema" || return 2
	local errors
	if ! errors="$(jq -r --slurpfile schema_doc "$schema" \
		'$schema_doc[0] as $schema | '"$_RESULTS_V1_JQ_VALIDATOR"' | .[]' "$file" 2>&1)"; then
		echo "results_v1: validator failed on ${file}: ${errors}" >&2
		return 2
	fi
	if [[ -n "$errors" ]]; then
		while IFS= read -r line; do
			echo "${file}: ${line}" >&2
		done <<<"$errors"
		return 1
	fi
	return 0
}

# Build, validate and write the document (creates parent directories).
# Usage: results_v1_write <path>
results_v1_write() {
	local path="${1:?path is required}"
	local doc
	doc="$(results_v1_build)" || return 1
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$doc" >"$path"
	results_v1_validate "$path"
}

# Internal: rewrite a document in place through a jq filter and revalidate.
_results_v1_rewrite() {
	local file="$1" filter="$2"
	shift 2
	local tmp
	tmp="$(mktemp)"
	# The new document replaces the old one only once it is valid (#1692):
	# a rejected rewrite leaves the previous, valid document in place.
	if ! jq "$@" "$filter" "$file" >"$tmp" || ! results_v1_validate "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$file"
}

# Override the status of an existing document (a later gate, such as a
# coverage threshold, failed the leg after the parser wrote it).
# Usage: results_v1_set_status <file> <passed|failed|no-tests|error>
results_v1_set_status() {
	local file="${1:?file is required}" status="${2:?status is required}"
	# shellcheck disable=SC2016 # jq filter, $status is a jq variable
	_results_v1_rewrite "$file" '.status = $status' --arg status "$status"
}

# Attach or replace the coverage lines percentage of an existing document
# (runners whose coverage is parsed in a later step, e.g. kcov). A value that
# is not a number (empty, N/A) leaves the document untouched; an unreadable
# one ("invalid", or a number outside 0 to 100) sets its status to error
# instead (#1692).
# Usage: results_v1_set_coverage <file> <lines> [branches] [functions]
results_v1_set_coverage() {
	local file="${1:?file is required}"
	local lines branches functions value
	for value in "${2:-}" "${3:-}" "${4:-}"; do
		if _results_v1_coverage_value_unreadable "$value"; then
			echo "::error::The coverage report is unreadable; the results document says error" >&2
			# One rewrite (#1692): coverage, an optional object, is removed and
			# the status set together, so no step between can leave the
			# document saying passed.
			_results_v1_rewrite "$file" 'del(.coverage) | .status = "error"'
			return
		fi
	done
	lines="$(_results_v1_percent_or_null "${2:-}")"
	branches="$(_results_v1_percent_or_null "${3:-}")"
	functions="$(_results_v1_percent_or_null "${4:-}")"
	if [[ "$lines" == "null" ]]; then
		return 0
	fi
	# shellcheck disable=SC2016 # jq filter, $lines etc. are jq variables
	_results_v1_rewrite "$file" \
		'.coverage = ({lines: $lines}
			+ (if $branches == null then {} else {branches: $branches} end)
			+ (if $functions == null then {} else {functions: $functions} end))' \
		--argjson lines "$lines" --argjson branches "$branches" --argjson functions "$functions"
}

# Internal: write one GITHUB_OUTPUT line with or without the actions lib.
_results_v1_output() {
	local key="$1" value="$2"
	if declare -f set_github_output >/dev/null 2>&1; then
		set_github_output "$key" "$value"
	elif [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "${key}=${value}" >>"$GITHUB_OUTPUT"
	fi
}

# Publish the public step outputs from a results document, so every
# tests-*/coverage-percent value a workflow exposes is read back from the
# contract rather than from parser variables.
# Usage: results_v1_github_outputs <file>
# Outputs: tests-passed, tests-failed, tests-skipped, tests-total,
#          tests-xfailed, tests-xpassed (0 when the document has none, #1702),
#          status, duration-ms; coverage-percent (lines) only when coverage is
#          present.
results_v1_github_outputs() {
	local file="${1:?file is required}"
	local passed failed skipped total status duration coverage xfailed xpassed
	IFS=$'\t' read -r passed failed skipped total status duration coverage xfailed xpassed < <(
		jq -r '[.counts.passed, .counts.failed, .counts.skipped, .counts.total,
			.status, .duration_ms, (.coverage.lines // "-"),
			(.counts.xfailed // 0), (.counts.xpassed // 0)] | @tsv' "$file"
	)
	# "-" marks an absent coverage: bash collapses adjacent tab separators.
	[[ "$coverage" == "-" ]] && coverage=""
	_results_v1_output "tests-passed" "$passed"
	_results_v1_output "tests-failed" "$failed"
	_results_v1_output "tests-skipped" "$skipped"
	_results_v1_output "tests-total" "$total"
	_results_v1_output "tests-xfailed" "$xfailed"
	_results_v1_output "tests-xpassed" "$xpassed"
	_results_v1_output "status" "$status"
	_results_v1_output "duration-ms" "$duration"
	if [[ -n "$coverage" ]]; then
		_results_v1_output "coverage-percent" "$coverage"
	fi
}

# Print a document's "incomplete" reason (#1531), or nothing.
# Usage: results_v1_incomplete_reason <file>
results_v1_incomplete_reason() {
	jq -r '.incomplete // ""' "${1:?file is required}"
}

# The one warning every step summary prints above the partial counts of an
# incomplete run (#1531), so the sharded and single-job paths read the same.
# Usage: results_v1_partial_notice <reason>
results_v1_partial_notice() {
	echo "> [!WARNING]"
	echo "> Incomplete run, partial counts only (not a full total): ${1}"
}

# Export functions
export -f results_v1_incomplete_reason results_v1_partial_notice
export -f results_v1_path results_v1_schema results_v1_schema_preflight results_v1_build results_v1_validate
export -f results_v1_write results_v1_github_outputs results_v1_set_status results_v1_set_coverage
export -f _results_v1_rewrite
export -f _results_v1_status _results_v1_num_or_null _results_v1_uint _results_v1_percent_or_null
export -f _results_v1_coverage_value_unreadable _results_v1_coverage_unreadable
export -f _results_v1_xfail_json _results_v1_opt_uint
export -f _results_v1_tap_plan_json _results_v1_coverage_json _results_v1_artifacts_json _results_v1_output
