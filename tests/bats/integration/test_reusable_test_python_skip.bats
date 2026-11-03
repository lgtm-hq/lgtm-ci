#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Exercise Python skip job planning and real workflow shell boundaries (#1297).

load "../../helpers/common"

@test "python skip: single, matrix and empty version lists retain running test jobs" {
	require_python_yaml
	run "$PY" "${PROJECT_ROOT}/tests/helpers/python_skip_workflow.py" planning "$PROJECT_ROOT"
	assert_success
}

@test "python skip: lightweight steps run without tooling, dependencies or artifacts" {
	require_python_yaml
	run "$PY" "${PROJECT_ROOT}/tests/helpers/python_skip_workflow.py" lightweight "$PROJECT_ROOT"
	assert_success
}

@test "python skip: job and workflow passed outputs reject local failures and cancellations" {
	require_python_yaml
	run "$PY" "${PROJECT_ROOT}/tests/helpers/python_skip_workflow.py" outputs "$PROJECT_ROOT"
	assert_success
}

@test "python skip: real pytest failure and aggregate guards remain blocking" {
	require_python_yaml
	run "$PY" "${PROJECT_ROOT}/tests/helpers/python_skip_workflow.py" failure "$PROJECT_ROOT"
	assert_success
}

@test "python skip: an executed failing pytest remains a failing workflow step" {
	require_python_yaml
	local pytest_python="${PYTEST_PYTHON:-$PY}"
	if ! "$pytest_python" -c 'import pytest' 2>/dev/null; then
		skip "pytest is unavailable; set PYTEST_PYTHON to an existing test interpreter"
	fi
	run env PYTEST_PYTHON="$pytest_python" "$PY" \
		"${PROJECT_ROOT}/tests/helpers/python_skip_workflow.py" real-failure "$PROJECT_ROOT"
	assert_success
}
