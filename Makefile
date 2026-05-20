# SPDX-License-Identifier: MIT

.PHONY: test test-bats lint fmt

test: test-bats

test-bats:
	bats --recursive tests/bats

lint:
	uv run lintro chk

fmt:
	uv run lintro fmt
