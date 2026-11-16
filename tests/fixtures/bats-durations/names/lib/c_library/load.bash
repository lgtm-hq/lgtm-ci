# shellcheck shell=bash
# Registers one test at load time, as a shared library might.
library_made_test() {
	sleep 0.3
}
bats_test_function --description "library made test" -- library_made_test
