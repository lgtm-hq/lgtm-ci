# SPDX-License-Identifier: MIT

.PHONY: all test test-bats lint fmt clean

all: test

test: test-bats

test-bats:
	bats --recursive tests/bats

lint:
	uv run lintro chk

fmt:
	uv run lintro fmt

clean:
	rm -rf .lintro/ coverage-report/
