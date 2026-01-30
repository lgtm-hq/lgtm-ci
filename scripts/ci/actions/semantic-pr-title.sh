#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate PR title follows conventional commit format
#
# Required environment variables:
#   TITLE - PR title to validate
#   ALLOWED_TYPES - Comma-separated list of allowed types
#   ALLOWED_SCOPES - Comma-separated list of allowed scopes (optional)
#   REQUIRE_SCOPE - Whether scope is required (true/false)
#   MAX_LENGTH - Maximum title length (0 for no limit)
#   FAIL_ON_INVALID - Whether to exit non-zero on invalid title

set -euo pipefail

: "${TITLE:?TITLE is required}"
: "${ALLOWED_TYPES:=feat,fix,docs,style,refactor,perf,test,build,ci,chore,revert}"
: "${ALLOWED_SCOPES:=}"
: "${REQUIRE_SCOPE:=false}"
: "${MAX_LENGTH:=72}"
: "${FAIL_ON_INVALID:=true}"

echo "Validating: $TITLE"

# Parse allowed types
IFS=',' read -ra TYPES_ARRAY <<<"$ALLOWED_TYPES"
TYPES_PATTERN=$(
	IFS='|'
	echo "${TYPES_ARRAY[*]}"
)

# Build regex pattern
if [[ "$REQUIRE_SCOPE" == "true" ]]; then
	PATTERN="^(${TYPES_PATTERN})\(([a-zA-Z0-9_-]+)\)!?: .+"
else
	PATTERN="^(${TYPES_PATTERN})(\([a-zA-Z0-9_-]+\))?!?: .+"
fi

# Check format
if ! [[ "$TITLE" =~ $PATTERN ]]; then
	echo "::error::PR title does not match conventional commit format"
	echo "Expected format: type(scope): description"
	echo "Allowed types: $ALLOWED_TYPES"
	echo "valid=false" >>"$GITHUB_OUTPUT"
	echo "error=Title does not match format: type(scope): description" >>"$GITHUB_OUTPUT"
	if [[ "$FAIL_ON_INVALID" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

# Extract components
TYPE=$(echo "$TITLE" | sed -E 's/^([a-z]+).*/\1/')
SCOPE=$(echo "$TITLE" | sed -nE 's/^[a-z]+\(([^)]+)\).*/\1/p')
DESC=$(echo "$TITLE" | sed -E 's/^[a-z]+(\([^)]+\))?!?: //')

# Check scope allowlist if provided
if [[ -n "$ALLOWED_SCOPES" && -n "$SCOPE" ]]; then
	IFS=',' read -ra SCOPES_ARRAY <<<"$ALLOWED_SCOPES"
	SCOPE_VALID=false
	for allowed in "${SCOPES_ARRAY[@]}"; do
		if [[ "$SCOPE" == "$allowed" ]]; then
			SCOPE_VALID=true
			break
		fi
	done
	if [[ "$SCOPE_VALID" == "false" ]]; then
		echo "::error::Scope '$SCOPE' is not in allowed list: $ALLOWED_SCOPES"
		echo "valid=false" >>"$GITHUB_OUTPUT"
		echo "error=Scope '$SCOPE' not allowed" >>"$GITHUB_OUTPUT"
		if [[ "$FAIL_ON_INVALID" == "true" ]]; then
			exit 1
		fi
		exit 0
	fi
fi

# Check length - validate MAX_LENGTH is numeric first
if ! [[ "$MAX_LENGTH" =~ ^[0-9]+$ ]]; then
	echo "::warning::MAX_LENGTH '$MAX_LENGTH' is not a valid number, skipping length check"
	MAX_LENGTH=0
fi
if [[ "$MAX_LENGTH" -gt 0 && ${#TITLE} -gt $MAX_LENGTH ]]; then
	echo "::error::PR title exceeds maximum length of $MAX_LENGTH characters (${#TITLE})"
	echo "valid=false" >>"$GITHUB_OUTPUT"
	echo "error=Title exceeds $MAX_LENGTH characters" >>"$GITHUB_OUTPUT"
	if [[ "$FAIL_ON_INVALID" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

# Output extracted components after all validations pass
{
	echo "type=$TYPE"
	echo "scope=$SCOPE"
	echo "description=$DESC"
} >>"$GITHUB_OUTPUT"

echo "valid=true" >>"$GITHUB_OUTPUT"
echo "::notice::PR title is valid: $TYPE${SCOPE:+($SCOPE)}: $DESC"
