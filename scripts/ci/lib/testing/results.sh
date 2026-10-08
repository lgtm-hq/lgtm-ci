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
#   RESULTS_PARSE_STATUS    ok (default) | missing | invalid - native report state
#   RESULTS_STATUS          explicit status; overrides the rule below (audits
#                           report a clean scan as passed, not no-tests)
#   TESTS_PASSED, TESTS_FAILED, TESTS_SKIPPED, TESTS_TOTAL  counts (default 0)
#   TESTS_DURATION_MS       whole milliseconds (default 0)
#   EXIT_CODE               native tool exit code (optional; feeds status)
#   COVERAGE_LINES, COVERAGE_BRANCHES, COVERAGE_FUNCTIONS
#                           percentages; a value that is empty, "n/a" or not a
#                           number is omitted (not measured). No lines => no
#                           coverage object.
#   RESULTS_ARTIFACTS       newline-separated "kind=path" entries (optional)
#   MATRIX_KEY, MATRIX_VALUE  matrix coordinate (optional; both or neither)
#
# Status rule (documented in docs/workflow-contract.md, Results contract):
#   error     RESULTS_PARSE_STATUS is missing or invalid, or a count is not a
#             non-negative integer (a native report with failed: -1 is not a
#             passing one)
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
		echo "results_v1: schema not found: ${schema}" >&2
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
	missing | invalid)
		echo "error"
		return 0
		;;
	esac
	local count
	for count in "${TESTS_PASSED:-0}" "${TESTS_FAILED:-0}" "${TESTS_SKIPPED:-0}" "${TESTS_TOTAL:-0}"; do
		if [[ ! "$count" =~ ^[0-9]+$ ]]; then
			echo "error"
			return 0
		fi
	done
	if [[ -n "${RESULTS_STATUS:-}" ]]; then
		echo "$RESULTS_STATUS"
		return 0
	fi
	if [[ "$failed" =~ ^[0-9]+$ && "$failed" -gt 0 ]]; then
		echo "failed"
	elif [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
		echo "failed"
	elif [[ ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
		echo "no-tests"
	else
		echo "passed"
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

# Internal: coverage object as JSON, or null when no lines value was given.
_results_v1_coverage_json() {
	local lines branches functions
	lines="$(_results_v1_num_or_null "${COVERAGE_LINES:-}")"
	branches="$(_results_v1_num_or_null "${COVERAGE_BRANCHES:-}")"
	functions="$(_results_v1_num_or_null "${COVERAGE_FUNCTIONS:-}")"
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

# Build a results.v1 document on stdout from the environment (see header).
results_v1_build() {
	local tool="${RESULTS_TOOL:?RESULTS_TOOL is required}"
	local runner="${RESULTS_RUNNER:?RESULTS_RUNNER is required}"
	local version="${RESULTS_SOURCE_VERSION:-${LGTM_CI_TOOLING_SHA:-unknown}}"
	[[ -z "$version" ]] && version="unknown"
	local status coverage artifacts exit_code matrix
	status="$(_results_v1_status)"
	coverage="$(_results_v1_coverage_json)"
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
		'{
			tool: $tool,
			status: $status,
			counts: {passed: $passed, failed: $failed, skipped: $skipped, total: $total},
			duration_ms: $duration
		}
		+ (if $coverage == null then {} else {coverage: $coverage} end)
		+ {artifacts: $artifacts, source: {runner: $runner, version: $version}}
		+ (if $matrix == null then {} else {matrix: $matrix} end)
		+ (if $exit_code == null then {} else {exit_code: $exit_code} end)'
}

# jq program: a deliberately small JSON Schema interpreter driven by the
# schema file itself, so the schema stays the single source of truth without
# a second validator binary to pin (see docs/workflow-contract.md for why).
# Supported keywords: type, properties, required, additionalProperties
# (false), enum, minimum, maximum, minLength, pattern, items, $ref (local
# #/$defs/... only). Any other validation keyword in the schema is an error,
# so a schema edit that this interpreter does not understand fails loudly
# instead of validating nothing.
# shellcheck disable=SC2016 # jq program, not shell expansion
read -r -d '' _RESULTS_V1_JQ_VALIDATOR <<'JQ' || true
def known_keywords:
  ["$schema","$id","$defs","title","description","type","properties",
   "required","additionalProperties","enum","minimum","maximum","minLength",
   "pattern","items","$ref"];

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
   "pattern","items","$ref"];
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
	jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
	results_v1_validate "$file"
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
# is not a number (empty, N/A) leaves the document untouched.
# Usage: results_v1_set_coverage <file> <lines> [branches] [functions]
results_v1_set_coverage() {
	local file="${1:?file is required}"
	local lines branches functions
	lines="$(_results_v1_num_or_null "${2:-}")"
	branches="$(_results_v1_num_or_null "${3:-}")"
	functions="$(_results_v1_num_or_null "${4:-}")"
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
# Outputs: tests-passed, tests-failed, tests-skipped, tests-total, status,
#          duration-ms; coverage-percent (lines) only when coverage is present.
results_v1_github_outputs() {
	local file="${1:?file is required}"
	local passed failed skipped total status duration coverage
	IFS=$'\t' read -r passed failed skipped total status duration coverage < <(
		jq -r '[.counts.passed, .counts.failed, .counts.skipped, .counts.total,
			.status, .duration_ms, (.coverage.lines // "-")] | @tsv' "$file"
	)
	# "-" marks an absent coverage: bash collapses adjacent tab separators.
	[[ "$coverage" == "-" ]] && coverage=""
	_results_v1_output "tests-passed" "$passed"
	_results_v1_output "tests-failed" "$failed"
	_results_v1_output "tests-skipped" "$skipped"
	_results_v1_output "tests-total" "$total"
	_results_v1_output "status" "$status"
	_results_v1_output "duration-ms" "$duration"
	if [[ -n "$coverage" ]]; then
		_results_v1_output "coverage-percent" "$coverage"
	fi
}

# Export functions
export -f results_v1_path results_v1_schema results_v1_schema_preflight results_v1_build results_v1_validate
export -f results_v1_write results_v1_github_outputs results_v1_set_status results_v1_set_coverage
export -f _results_v1_rewrite
export -f _results_v1_status _results_v1_num_or_null _results_v1_uint
export -f _results_v1_coverage_json _results_v1_artifacts_json _results_v1_output
