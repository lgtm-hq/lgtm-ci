#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Test runner and coverage format detection utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"
#   runner=$(detect_test_runner)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_DETECT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_DETECT_LOADED=1

# =============================================================================
# Test runner detection
# =============================================================================

# Detect the appropriate test runner based on project files
# Usage: detect_test_runner [directory]
# Output: pytest|vitest|playwright|unknown
detect_test_runner() {
	local dir="${1:-.}"

	# Check for Python test indicators
	if [[ -f "$dir/pytest.ini" ]]; then
		echo "pytest"
		return 0
	fi
	if [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool\.pytest' "$dir/pyproject.toml" 2>/dev/null; then
		echo "pytest"
		return 0
	fi
	# Check for tests directory with Python files (independent of pyproject.toml/setup.py)
	if [[ -d "$dir/tests" ]] && find "$dir/tests" \( -name "test_*.py" -o -name "*_test.py" \) 2>/dev/null | head -1 | grep -q .; then
		echo "pytest"
		return 0
	fi

	# Check for Playwright indicators
	if [[ -f "$dir/playwright.config.ts" ]] || [[ -f "$dir/playwright.config.js" ]]; then
		echo "playwright"
		return 0
	fi

	# Check for Vitest indicators
	if [[ -f "$dir/vitest.config.ts" ]] || [[ -f "$dir/vitest.config.js" ]] || [[ -f "$dir/vitest.config.mts" ]]; then
		echo "vitest"
		return 0
	fi

	# Check for vitest in package.json
	if [[ -f "$dir/package.json" ]]; then
		if grep -q '"vitest"' "$dir/package.json" 2>/dev/null; then
			echo "vitest"
			return 0
		fi
		# Check for playwright in dependencies
		if grep -q '"@playwright/test"' "$dir/package.json" 2>/dev/null; then
			echo "playwright"
			return 0
		fi
	fi

	echo "unknown"
	return 1
}

# Detect all available test runners in a project
# Usage: detect_all_runners [directory]
# Output: space-separated list of runners
detect_all_runners() {
	local dir="${1:-.}"
	local runners=""

	# Check for pytest
	if [[ -f "$dir/pytest.ini" ]]; then
		runners="pytest"
	elif [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool\.pytest' "$dir/pyproject.toml" 2>/dev/null; then
		runners="pytest"
	elif [[ -d "$dir/tests" ]] && find "$dir/tests" \( -name "test_*.py" -o -name "*_test.py" \) 2>/dev/null | head -1 | grep -q .; then
		runners="pytest"
	fi

	# Check for vitest
	if [[ -f "$dir/vitest.config.ts" ]] || [[ -f "$dir/vitest.config.js" ]] || [[ -f "$dir/vitest.config.mts" ]]; then
		runners="${runners:+$runners }vitest"
	elif [[ -f "$dir/package.json" ]] && grep -q '"vitest"' "$dir/package.json" 2>/dev/null; then
		runners="${runners:+$runners }vitest"
	fi

	# Check for playwright
	if [[ -f "$dir/playwright.config.ts" ]] || [[ -f "$dir/playwright.config.js" ]]; then
		runners="${runners:+$runners }playwright"
	elif [[ -f "$dir/package.json" ]] && grep -q '"@playwright/test"' "$dir/package.json" 2>/dev/null; then
		runners="${runners:+$runners }playwright"
	fi

	echo "$runners"
}

# =============================================================================
# Coverage format detection
# =============================================================================

# Detect coverage format from file extension or content
# Usage: detect_coverage_format "coverage.xml"
# Output: xml|json|lcov|html|cobertura|istanbul|unknown
detect_coverage_format() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		echo "unknown"
		return 1
	fi

	# Check by extension first
	case "${file##*.}" in
	xml)
		# Determine if cobertura or clover format
		# Use grep -E with POSIX alternation for portability (BSD/macOS)
		if head -20 "$file" | grep -qE '<coverage.*line-rate|<coverage.*lines-valid|<package.*name='; then
			echo "cobertura"
		elif head -20 "$file" | grep -qE '<coverage.*clover'; then
			echo "clover"
		else
			echo "xml"
		fi
		return 0
		;;
	json)
		# Determine if istanbul or coverage.py format
		# Use grep -E with POSIX character classes for portability (BSD/macOS)
		if head -5 "$file" | grep -qE '"meta"[[:space:]]*:[[:space:]]*\{.*"version"'; then
			echo "coverage-py"
		elif head -20 "$file" | grep -qE '"path"[[:space:]]*:[[:space:]]*"|"statementMap"[[:space:]]*:'; then
			echo "istanbul"
		else
			echo "json"
		fi
		return 0
		;;
	lcov | info)
		echo "lcov"
		return 0
		;;
	html)
		echo "html"
		return 0
		;;
	esac

	# Check content for format detection
	local first_line
	first_line=$(head -1 "$file")

	if [[ "$first_line" == "TN:"* ]] || [[ "$first_line" == "SF:"* ]]; then
		echo "lcov"
		return 0
	fi

	if [[ "$first_line" == "<?xml"* ]] || [[ "$first_line" == "<coverage"* ]]; then
		if grep -qE 'line-rate|lines-valid' "$file" 2>/dev/null; then
			echo "cobertura"
		else
			echo "xml"
		fi
		return 0
	fi

	if [[ "$first_line" == "{"* ]]; then
		echo "json"
		return 0
	fi

	echo "unknown"
	return 1
}

# Detect if a coverage file is from Python (coverage.py) or JavaScript (istanbul/v8)
# Usage: detect_coverage_source "coverage.json"
# Output: python|javascript|unknown
detect_coverage_source() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		echo "unknown"
		return 1
	fi

	local format
	format=$(detect_coverage_format "$file")

	case "$format" in
	coverage-py | cobertura)
		# Check for Python-specific patterns (use ERE for portability)
		if grep -qE '\.py("|$)' "$file" 2>/dev/null; then
			echo "python"
			return 0
		fi
		;;
	istanbul)
		echo "javascript"
		return 0
		;;
	lcov)
		# Check file extensions in the lcov report
		if grep -E '^SF:.*\.(ts|tsx|js|jsx|mjs|cjs)$' "$file" 2>/dev/null | head -1 | grep -q .; then
			echo "javascript"
		elif grep -E '^SF:.*\.py$' "$file" 2>/dev/null | head -1 | grep -q .; then
			echo "python"
		else
			echo "unknown"
		fi
		return 0
		;;
	esac

	echo "unknown"
	return 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f detect_test_runner detect_all_runners
export -f detect_coverage_format detect_coverage_source
