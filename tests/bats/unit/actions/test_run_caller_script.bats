#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/run-caller-script.sh"
	setup_temp_dir
	export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$GITHUB_WORKSPACE/scripts"
	cat >"$GITHUB_WORKSPACE/scripts/default.sh" <<'EOF'
#!/usr/bin/env bash
echo default-ok
EOF
	chmod +x "$GITHUB_WORKSPACE/scripts/default.sh"
}

teardown() {
	teardown_temp_dir
}

@test "run-caller-script executes the default path" {
	run env DEFAULT_SCRIPT_PATH=scripts/default.sh bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"default-ok"* ]]
}

@test "run-caller-script rejects paths outside the workspace" {
	run env \
		DEFAULT_SCRIPT_PATH=scripts/default.sh \
		RAW_SCRIPT_PATH=/etc/passwd \
		bash "$SCRIPT"
	[ "$status" -eq 1 ]
}
