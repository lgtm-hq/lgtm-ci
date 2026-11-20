#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build Lychee CLI arguments from reusable workflow inputs.

set -euo pipefail

: "${PATHS:=.}"
: "${FILE_EXTENSIONS:=md,html}"
: "${EXCLUDE_PATTERNS:=}"
: "${CHECK_EXTERNAL:=true}"
: "${TIMEOUT:=10}"
: "${WORKING_DIRECTORY:=.}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

quote_arg() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
}

append_arg() {
	local value="$1"
	args+=("$(quote_arg "$value")")
}

split_csv() {
	local value="$1"
	local item

	IFS=',' read -ra raw_items <<<"$value"
	for item in "${raw_items[@]}"; do
		item="$(trim "$item")"
		[[ -n "$item" ]] && printf '%s\n' "$item"
	done
}

prefix_target() {
	local target="$1"

	if [[ "$WORKING_DIRECTORY" == "." || "$WORKING_DIRECTORY" == "" ]]; then
		printf '%s' "$target"
	elif [[ "$target" == "." ]]; then
		printf '%s' "$WORKING_DIRECTORY"
	else
		printf '%s/%s' "${WORKING_DIRECTORY%/}" "$target"
	fi
}

build_targets() {
	local path
	local extension
	local prefixed

	for path in "${paths[@]}"; do
		prefixed="$(prefix_target "$path")"
		if [[ "$prefixed" == *"*"* || "$prefixed" == *"?"* || "$prefixed" == *"["* ]]; then
			append_arg "$prefixed"
		elif [[ -f "$prefixed" ]]; then
			append_arg "$prefixed"
		else
			for extension in "${extensions[@]}"; do
				extension="${extension#.}"
				if [[ "$prefixed" == "." ]]; then
					append_arg "**/*.${extension}"
				else
					append_arg "${prefixed%/}/**/*.${extension}"
				fi
			done
		fi
	done
}

# --output is set via lychee-action `output:` input (v2.9+ rejects both).
args=(
	"--no-progress"
	"--format" "markdown"
	"--timeout" "$TIMEOUT"
	"--max-retries" "3"
	"--accept" "200..=204"
)

if [[ "$CHECK_EXTERNAL" != "true" ]]; then
	args+=("--offline")
fi

declare -a paths=()
declare -a extensions=()
declare -a exclusions=()

while IFS= read -r item; do
	paths+=("$item")
done < <(split_csv "$PATHS")

while IFS= read -r item; do
	extensions+=("$item")
done < <(split_csv "$FILE_EXTENSIONS")

while IFS= read -r item; do
	exclusions+=("$item")
done < <(split_csv "$EXCLUDE_PATTERNS")

if [[ "${#paths[@]}" -eq 0 ]]; then
	paths=(".")
fi

if [[ "${#extensions[@]}" -eq 0 ]]; then
	extensions=("md" "html")
fi

for exclusion in "${exclusions[@]}"; do
	args+=("--exclude")
	append_arg "$exclusion"
done

build_targets

# TIMEOUT, WORKING_DIRECTORY and the patterns are caller input that can hold
# newlines: write under the shared random delimiter, never a fixed one (#1675).
set_github_output_multiline "args" "${args[*]}"
