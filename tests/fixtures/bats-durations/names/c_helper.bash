# shellcheck shell=bash
# Registers one test at load time, as a shared helper might.
helper_made_test() {
	sleep 0.3
}
bats_test_function --description "helper made test" -- helper_made_test
